{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

module Network.Pusher.WebSockets
  ( -- * Connection
    Pusher
  , Key(..)
  , Options(..)
  , Cluster(..)
  , pusherWithKey
  , defaultOptions
  , disconnect

  -- ** The @PusherClient@ Monad
  , PusherClient
  , runPusherClient

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
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Exception (bracket_, throwIO)
import Control.Monad (forever)
import Data.Maybe (isNothing)
import Data.Version (Version(..), showVersion)

-- library imports
import Control.Concurrent.STM (atomically, retry, readTQueue, readTVar, writeTQueue, writeTVar)
import Control.Lens ((^?), ix)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT(..))
import Data.Aeson (Value(..), decode', encode)
import Data.Aeson.Lens (_Integral, _Object, _String, _Value)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import Data.Text (Text)
import Network.Socket (HostName, PortNumber)
import Network.WebSockets (runClient)
import qualified Network.WebSockets as WS
import Wuss (runSecureClient)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Paths_pusher_ws (version)

-------------------------------------------------------------------------------

-- | Connect to Pusher.
pusherWithKey :: Key -> Options -> IO Pusher
pusherWithKey key opts
  | encrypted opts = run (runSecureClient host port path)
  | otherwise      = run (runClient host (fromIntegral port) path)

  where
    (host, port, path) = makeURL key opts

    -- Run the client
    run withConnection = do
      state <- defaultPusher key opts
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
  ignoreAll () . reconnecting $ withConnection client

  -- Kill forked threads
  readTVarIO (threadStore state) >>= mapM_ killThread

  where
    client conn = flip catchAll handleExc $ do
      -- Fork off an event handling thread
      allClosed <- newEmptyMVar
      _ <- forkIO (handleThread conn allClosed)

      -- Wait for the pusher:connection_established event.
      timeout <- liftIO . atomically $
        maybe retry pure =<< readTVar (idleTimer state)

      -- This will do more pinging than necessary, but it's far
      -- simpler than keeping track of the actual inactivity, and
      -- ensures that enough pings are sent.
      WS.forkPingThread conn timeout

      -- Resubscribe to channels
      channels <- liftIO . atomically $ do
        writeTVar (presenceChannels state) H.empty
        readTVar (allChannels state)
      runPusherClient state $
        mapM_ (subscribe . unChannel) channels

      -- Handle commands
      forever $ do
        command <- atomically . readTQueue $ commandQueue state
        case command of
          SendMessage json -> sendJSON conn json
          Subscribe handle channelData -> do
            let json = Object $ H.fromList [ ("event", String "pusher:subscribe")
                                           , ("data", channelData)
                                           ]
            sendJSON conn json
            strictModifyTVarIO (allChannels state) (S.insert handle)
          Terminate -> do
            WS.sendClose conn ("goodbye" :: Text)
            takeMVar allClosed
            throwIO TerminatePusher

    -- Receive and handle events until the connection is closed.
    handleThread conn allClosed = do
      ignoreAll () . forever $
        awaitEvent conn >>= handleEvent state
      putMVar allClosed ()

    -- Send some JSON down the channel
    sendJSON conn = WS.sendDataMessage conn . WS.Text . encode

    -- Mark the connection as closed by clearing the idle timer and
    -- socket ID, then rethrow the exception.
    handleExc e = do
      strictModifyTVarIO (idleTimer state) (const Nothing)
      strictModifyTVarIO (socketId  state) (const Nothing)
      throwIO e

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
  , ("pusher_internal:subscription_succeeded", addPresenceChannel)
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
    establishConnection event = liftMaybe $ do
      socketid <- event ^? ix "data" . ix "socket_id"        . _String
      timeout  <- event ^? ix "data" . ix "activity_timeout" . _Integral

      pure $ do
        state <- ask
        strictModifyTVarIO (idleTimer state) (const (Just timeout))
        strictModifyTVarIO (socketId  state) (const (Just socketid))

    -- Save the list of users
    addPresenceChannel event = liftMaybe $ do
      channel <- eventChannel event
      users   <- event ^? ix "data" . ix "hash" . _Object

      pure (umap channel (const users))

    -- Add a user to the list
    addPresenceMember event = liftMaybe $ do
      channel <- eventChannel event
      uid     <- event ^? ix "data" . ix "user_id"   . _String
      info    <- event ^? ix "data" . ix "user_info" . _Value

      pure (umap channel (H.insert uid info))

    -- Remove a user from the list
    rmPresenceMember event = liftMaybe $ do
      channel <- eventChannel event
      uid     <- event ^? ix "data" . ix "user_id" . _String

      pure (umap channel (H.delete uid))

    --  Apply a function to the users list of a presence channel
    umap channel f = do
      state <- ask
      strictModifyTVarIO (presenceChannels state) (H.adjust (second f) channel)

-- | Block and wait for an event.
awaitEvent :: WS.Connection -> IO (Either ByteString Value)
awaitEvent conn = decode <$> WS.receiveDataMessage conn where
  decode (WS.Text   bs) = maybe (Left bs) Right (decode' bs)
  decode (WS.Binary bs) = Left bs

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
