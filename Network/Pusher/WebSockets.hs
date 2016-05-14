{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

module Network.Pusher.WebSockets
  ( -- * Initialisation
    Pusher
  , Key(..)
  , Options(..)
  , Cluster(..)
  , pusherWithKey
  , defaultOptions

  -- ** The @PusherClient@ Monad
  , PusherClient
  , runPusherClient

  -- ** Connection
  , ConnectionState(..)
  , connectionState
  , disconnect

  -- * Channels
  , Channel
  , subscribe
  , unsubscribe

  -- ** Presence Channels
  , members
  , whoami

  -- * Events
  , eventType
  , eventChannel

  -- ** Event Handlers
  , Binding
  , bind
  , bindAll
  , unbind

  -- ** Client Events
  , triggerEvent

  -- * Concurrency
  , fork

  -- * Utilities
  , clusterName
  , makeURL
  ) where

-- 'base' imports
import Control.Arrow (second)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, threadDelay)
import Control.Exception (bracket_, throwIO)
import Control.Monad (forever, unless)
import Data.Maybe (isNothing)
import Data.Version (Version(..), showVersion)

-- library imports
import Control.Concurrent.STM (TVar, atomically, retry, newTVarIO, tryReadTQueue, readTVar, writeTVar)
import Control.Lens ((&), (^?), (.~), ix)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT(..))
import Data.Aeson (Value(..), decode', encode)
import Data.Aeson.Lens (_Integral, _Object, _String, _Value)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import Data.Text (Text, pack)
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Network.Socket (HostName, PortNumber)
import Network.WebSockets (runClientWith)
import qualified Network.WebSockets as WS
import Wuss (runSecureClientWith)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Paths_pusher_ws (version)

-------------------------------------------------------------------------------

-- | Connect to Pusher.
pusherWithKey :: Key -> Options -> IO Pusher
pusherWithKey key opts
  | encrypted opts = run (runSecureClientWith host port path)
  | otherwise      = run (runClientWith host (fromIntegral port) path)

  where
    (host, port, path) = makeURL key opts

    -- Run the client
    run withConn = do
      state <- defaultPusher key opts

      let connOpts = WS.defaultConnectionOptions
            { WS.connectionOnPong = atomically . writeTVar (lastReceived state) =<< getCurrentTime }
      let withConnection = withConn connOpts []

      _ <- forkIO (pusherClient withConnection state)
      pure state

-- | Gracefully close the connection. The connection will remain open
-- and events will continue to be processed until the server accepts
-- the request.
disconnect :: PusherClient ()
disconnect = do
  state <- ask
  liftIO . atomically $ writeTQueue (commandQueue state) Terminate

-- | Client thread: connect to Pusher and process commands,
-- reconnecting automatically, until finally told to terminate.
--
-- Does not automatically fork.
pusherClient :: ((WS.Connection -> IO ()) -> IO ()) -> Pusher -> IO ()
pusherClient withConnection state = do
  -- Bind default handlers
  runPusherClient state $
    mapM_ (\(e, h) -> bind e Nothing h) defaultHandlers

  -- Run client
  ignoreAll () $ reconnecting
    (changeConnectionState Connecting >> withConnection client)
    (changeConnectionState Unavailable >> threadDelay (1 * 1000 * 1000))
  changeConnectionState Disconnected

  -- Kill forked threads
  readTVarIO (threadStore state) >>= mapM_ killThread

  where
    client conn = flip catchAll handleExc $ do
      -- Fork off an event handling thread
      allClosed <- newEmptyMVar
      _ <- forkIO (handleThread conn (lastReceived state) allClosed)

      -- Wait for the pusher:connection_established event.
      timeout <- liftIO . atomically $
        maybe retry pure =<< readTVar (idleTimer state)
      changeConnectionState Connected

      -- This will do more pinging than necessary, but it's far
      -- simpler than keeping track of the actual inactivity, and
      -- ensures that enough pings are sent.
      closevar <- newTVarIO False
      _ <- forkIO (pingThread conn timeout closevar)

      -- Resubscribe to channels
      channels <- liftIO . atomically $ do
        writeTVar (presenceChannels state) H.empty
        readTVar (allChannels state)
      runPusherClient state $
        mapM_ (subscribe . unChannel) channels

      -- Handle commands
      forever $ do
        command <- atomically $ do
          cmd  <- tryReadTQueue (commandQueue state)
          kill <- readTVar closevar
          case (cmd, kill) of
            (Just cmd', _)   -> pure (Just cmd')
            (Nothing, True)  -> pure Nothing
            (Nothing, False) -> retry

        case command of
          Just (SendMessage json) ->
            sendJSON conn json

          Just (SendLocalMessage json) ->
            handleEvent state (Right json)

          Just (Subscribe handle channelData) -> do
            let json = Object $ H.fromList [ ("event", String "pusher:subscribe")
                                           , ("data", channelData)
                                           ]
            sendJSON conn json
            strictModifyTVarIO (allChannels state) (S.insert handle)

          Just Terminate -> do
            WS.sendClose conn ("goodbye" :: Text)
            takeMVar allClosed
            throwIO TerminatePusher

          Nothing -> throwIO WS.ConnectionClosed

    -- Receive and handle events until the connection is closed.
    handleThread conn lastMsgTime allClosed = do
      ignoreAll () . forever $
        awaitEvent conn lastMsgTime >>= handleEvent state
      putMVar allClosed ()

    -- Send a ping every time the timeout elapses, if the connection
    -- closes write 'True' to the provided 'TVar'.
    pingThread conn timeout closevar = pinger 0 where
      pinger :: Integer -> IO ()
      pinger i = do
        -- Wait for the timeout to elapse
        threadDelay (timeout * 1000 * 1000)
        -- Send a ping
        WS.sendPing conn (pack $ show i)
        -- Check the time of receipt of the last message: if it's
        -- longer ago than the timeout (+ some small delay to handle
        -- network delays) signal disconnection. Otherwise loop.
        now     <- getCurrentTime
        lastMsg <- readTVarIO (lastReceived state)
        let fuzz = 30
        if now `diffUTCTime` lastMsg > fromIntegral timeout + fuzz
        then atomically (writeTVar closevar True)
        else pinger (i + 1)

    -- Send some JSON down the channel
    sendJSON conn = WS.sendDataMessage conn . WS.Text . encode

    -- Mark the connection as closed by clearing the idle timer and
    -- socket ID, send the "unavailable" connection event if this
    -- disconnection wasn't requested, then rethrow the exception.
    handleExc e = do
      strictModifyTVarIO (idleTimer state) (const Nothing)
      strictModifyTVarIO (socketId  state) (const Nothing)
      throwIO e

    -- Set the connection state and send a state change event if
    -- necessary.
    changeConnectionState s = do
      ev <- atomically $ do
        oldState <- readTVar (connState state)
        writeTVar (connState state) s
        pure $ (Object . H.singleton "event" . String) <$>
          case (oldState == s, s) of
            (False, Connecting)   -> Just "connecting"
            (False, Connected)    -> Just "connected"
            (False, Unavailable)  -> Just "unavailable"
            (False, Disconnected) -> Just "disconnected"
            _ -> Nothing
      maybe (pure ()) (handleEvent state . Right) ev

-- | The hostname, port, and path (including querystring) to connect
-- to.
makeURL :: Key -> Options -> (HostName, PortNumber, String)
makeURL key@(Key k) opts = case pusherURL opts of
  Just (host, port, path) -> (host, port, path key ++ queryString)
  Nothing -> (defaultHost, defaultPort, defaultPath)

  where
    defaultHost
      -- The primary cluster has a different domain to all the others
      | cluster opts == MT1 = "ws.pusherapp.com"
      | otherwise = "ws-" ++ clusterName (cluster opts) ++ ".pusher.com"

    defaultPort
      | encrypted opts = 443
      | otherwise = 80

    defaultPath = "/app/" ++ k ++ queryString

    queryString = "?client=haskell-pusher-ws&protocol=7&version="
               ++ showVersion semver

    -- The server doesn't work with a 4-component version number, my
    -- guess is that it's assuming semver.
    semver = Version { versionBranch = take 3 (versionBranch version)
                     , versionTags = []
                     }

-- | Default event handlers
defaultHandlers :: [(Text, Value -> PusherClient ())]
defaultHandlers =
  [ ("pusher:ping", pingHandler)
  , ("pusher:connection_established", establishConnection)
  , ("pusher_internal:subscription_succeeded", addChannel)
  , ("pusher_internal:member_added", addPresenceMember)
  , ("pusher_internal:member_removed", rmPresenceMember)
  ]

  where
    -- Immediately send a pusher:pong
    pingHandler _ = triggerEvent "pusher:pong" Nothing (Object H.empty)

    -- Record the activity timeout and socket ID.
    --
    -- Not sure why this one needs a type signature but the others
    -- don't.
    establishConnection :: Value -> PusherClient ()
    establishConnection event = do
      let socketidmay = event ^? ix "data" . ix "socket_id"        . _String
      let timeoutmay  = event ^? ix "data" . ix "activity_timeout" . _Integral

      case (,) <$> socketidmay <*> timeoutmay of
        Just (socketid, timeout) -> do
          state <- ask
          strictModifyTVarIO (idleTimer state) (const (Just timeout))
          strictModifyTVarIO (socketId  state) (const (Just socketid))
        Nothing -> pure ()

    -- Save the list of users (if there is one) and send the internal
    -- "pusher:subscription_succeeded" event.
    addChannel event = do
      let channelmay = eventChannel event
      let usersmay   = event ^? ix "data" . ix "hash" . _Object

      case channelmay of
        Just channel -> do
          maybe (pure ()) (umap channel . const) usersmay
          local (event & ix "event" .~ "pusher:subscription_succeeded")
        Nothing -> pure ()

    -- Add a user to the list
    addPresenceMember event = do
      let channelmay = eventChannel event
      let uidmay     = event ^? ix "data" . ix "user_id"   . _String
      let infomay    = event ^? ix "data" . ix "user_info" . _Value

      case (,,) <$> channelmay <*> uidmay <*> infomay of
        Just (channel, uid, info) ->
          umap channel (H.insert uid info)
        Nothing -> pure ()

    -- Remove a user from the list
    rmPresenceMember event = do
      let channelmay = eventChannel event
      let uidmay     = event ^? ix "data" . ix "user_id" . _String

      case (,) <$> channelmay <*> uidmay of
        Just (channel, uid) ->
          umap channel (H.delete uid)
        Nothing -> pure ()

    --  Apply a function to the users list of a presence channel
    umap channel f = do
      state <- ask
      strictModifyTVarIO (presenceChannels state) (H.adjust (second f) channel)

    -- Send a local message
    local json = do
      state <- ask
      liftIO $ handleEvent state (Right json)

-- | Block and wait for an event.
awaitEvent :: WS.Connection -> TVar UTCTime -> IO (Either ByteString Value)
awaitEvent conn lastMsgTime = do
  msg <- WS.receiveDataMessage conn
  atomically . writeTVar lastMsgTime =<< getCurrentTime
  pure $ case msg of
    WS.Text   bs -> maybe (Left bs) Right (decode' bs)
    WS.Binary bs -> Left bs

-- | Launch all event handlers which are bound to the current event.
handleEvent :: Pusher -> Either ByteString Value -> IO ()
handleEvent state (Right event) = do
  let match (Handler e c _) = (isNothing e || e == Just (eventType event)) &&
                              (isNothing c || c == eventChannel event)

  handlers <- filter match . H.elems <$> readTVarIO (eventHandlers state)
  runPusherClient state $
    mapM_ (fork . (\(Handler _ _ h) -> h event)) handlers
-- Discard events which couldn't be decoded.
handleEvent _ _ = pure ()

-------------------------------------------------------------------------------

-- | Fork a thread which will be killed when the connection is closed.
fork :: PusherClient () -> PusherClient ThreadId
fork (ReaderT action) = ReaderT (forkIO . run) where
  run s = bracket_ setup teardown (action s) where
    -- Add the thread ID to the list
    setup = do
      tid <- myThreadId
      strictModifyTVarIO (threadStore s) (S.insert tid)

    -- Remove the thread ID from the list
    teardown = do
      tid <- myThreadId
      strictModifyTVarIO (threadStore s) (S.delete tid)

-- | Get the connection state.
connectionState :: PusherClient ConnectionState
connectionState = readTVarIO . connState =<< ask
