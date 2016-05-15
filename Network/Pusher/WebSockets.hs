{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets
  ( -- * Pusher
    Pusher
  , PusherClosed(..)
  , Key(..)
  , Options(..)
  , Cluster(..)
  , pusherWithKey
  , defaultOptions

  -- ** Monad
  , PusherClient
  , runPusherClient

  -- ** Connection
  , ConnectionState(..)
  , connectionState
  , disconnect
  , disconnectBlocking

  -- * Re-exports
  , module Network.Pusher.WebSockets.Channel
  , module Network.Pusher.WebSockets.Event
  , module Network.Pusher.WebSockets.Util
  ) where

-- 'base' imports
import Control.Arrow (second)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (fromException, throwIO)
import Control.Monad (forever)
import Data.Maybe (isJust, isNothing)

-- library imports
import Control.Concurrent.STM (atomically, check, retry)
import Control.Concurrent.STM.TQueue (tryReadTQueue)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (^?), (.~), ix)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), decode', encode)
import Data.Aeson.Lens (_Integral, _Object, _String, _Value)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import Data.Text (Text, pack)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Word (Word16)
import Network.WebSockets (Connection, runClientWith, sendClose)
import qualified Network.WebSockets as WS
import Wuss (runSecureClientWith)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Util

-- Haddock doesn't like the import/export shortcut when generating
-- docs.
{-# ANN module ("HLint: ignore Use import/export shortcut" :: String) #-}

-------------------------------------------------------------------------------
-- Connection

-- | Connect to Pusher.
pusherWithKey :: Key -> Options -> IO Pusher
pusherWithKey key opts
  | encrypted opts = run (runSecureClientWith host port path)
  | otherwise      = run (runClientWith host (fromIntegral port) path)

  where
    (host, port, path) = makeURL key opts

    -- Run the client
    run withConn = do
      pusher <- defaultPusher key opts

      let connOpts = WS.defaultConnectionOptions
            { WS.connectionOnPong = atomically . writeTVar (lastReceived pusher) =<< getCurrentTime }
      let withConnection = withConn connOpts []

      _ <- forkIO (pusherClient withConnection pusher)
      pure pusher

-- | Get the connection state.
connectionState :: PusherClient ConnectionState
connectionState = readTVarIO . connState =<< ask

-- | Gracefully close the connection. The connection will remain open
-- and events will continue to be processed until the server accepts
-- the request.
disconnect :: PusherClient ()
disconnect = do
  pusher <- ask
  liftIO (sendCommand pusher Terminate)

-- | Like 'disconnect', but block until the connection is actually
-- closed.
disconnectBlocking :: PusherClient ()
disconnectBlocking = do
  disconnect
  pusher <- ask
  liftIO . atomically $ do
    cstate <- readTVar (connState pusher)
    case cstate of
      Disconnected _ -> pure ()
      _ -> retry

-------------------------------------------------------------------------------
-- Pusher client

-- | Client thread: connect to Pusher and process commands,
-- reconnecting automatically, until finally told to terminate.
--
-- Does not automatically fork.
pusherClient :: ((Connection -> IO ()) -> IO ()) -> Pusher -> IO ()
pusherClient withConnection pusher = do
  -- Bind default handlers
  runPusherClient pusher $
    mapM_ (\(e, h) -> bind e Nothing h) defaultHandlers

  -- Run client
  catchAll
    (reconnecting
      (changeConnectionState pusher Connecting >>
       withConnection (client pusher))
      (changeConnectionState pusher Unavailable >>
       threadDelay (1 * 1000 * 1000)))
    (\e -> case fromException e of
      Just (TerminatePusher closeCode) ->
        changeConnectionState pusher (Disconnected closeCode)
      Nothing ->
        changeConnectionState pusher (Disconnected Nothing))

  -- Kill forked threads
  readTVarIO (threadStore pusher) >>= mapM_ killThread

-- | Fork off event handling and pinging threads, subscribe to
-- channels, and loop processing commands until terminated.
client :: Pusher -> Connection -> IO ()
client pusher conn = flip catchAll handleExc $ do
  -- Fork off an event handling thread
  closevar <- newTVarIO Nothing
  _ <- forkIO (handleThread pusher conn closevar)

  -- Wait for the pusher:connection_established event.
  liftIO . atomically $
    check . isJust =<< readTVar (idleTimer pusher)
  changeConnectionState pusher Connected

  -- This will do more pinging than necessary, but it's far simpler
  -- than keeping track of the actual inactivity, and ensures that
  -- enough pings are sent.
  _ <- forkIO (pingThread pusher conn closevar)

  -- Subscribe to channels
  channels <- liftIO . atomically $ do
    writeTVar (presenceChannels pusher) H.empty
    readTVar (allChannels pusher)
  runPusherClient pusher $
    mapM_ (subscribe . unChannel) channels

  -- Handle commands
  forever $
    handleCommandOrClose pusher conn =<< awaitCommandOrClose pusher closevar

  where
    -- Mark the connection as closed by clearing the idle timer and
    -- socket ID and rethrow the exception.
    handleExc e = do
      strictModifyTVarIO (idleTimer pusher) (const Nothing)
      strictModifyTVarIO (socketId  pusher) (const Nothing)
      throwIO e

-- | Wait for a command or close signal.
awaitCommandOrClose :: Pusher
                    -> TVar (Maybe Word16)
                    -> IO (Either Word16 PusherCommand)
awaitCommandOrClose pusher closevar = atomically $ do
  cmd   <- tryReadTQueue (commandQueue pusher)
  ccode <- readTVar closevar
  case (cmd, ccode) of
    (Just cmd', _)         -> pure (Right cmd')
    (Nothing, Just ccode') -> pure (Left  ccode')
    (Nothing, Nothing) -> retry

-- | Handle a command or close signal. Throws an exception on
-- disconnect: 'TerminatePusher' if the connection should not be
-- re-established, and 'WS.ConnectionClosed' if it should be.
handleCommandOrClose :: Pusher
                     -> Connection
                     -> Either Word16 PusherCommand
                     -> IO ()
handleCommandOrClose pusher conn (Right pusherCommand) =
  handleCommand pusher conn pusherCommand
handleCommandOrClose _ _ (Left closeCode) =
  throwCloseException closeCode

-- | Handle a command.
handleCommand :: Pusher -> Connection -> PusherCommand -> IO ()
handleCommand pusher conn pusherCommand = case pusherCommand of
  SendMessage      json -> sendJSON json
  SendLocalMessage json -> handleEvent pusher (Right json)
  Subscribe handle channelData -> do
    sendJSON . Object $ H.fromList
      [ ("event", String "pusher:subscribe")
      , ("data", channelData)
      ]
    strictModifyTVarIO (allChannels pusher) (S.insert handle)
  Terminate -> sendClose conn ("goodbye" :: Text)
  where
    -- Send some JSON down the channel.
    sendJSON = WS.sendDataMessage conn . WS.Text . encode

-- | Throw the appropriate exception for a close code.
throwCloseException :: Word16 -> IO a
throwCloseException closeCode
  -- Graceful termination
  | closeCode < 4000 =
    throwIO $ TerminatePusher Nothing
  -- Server specified not to reconnect
  | closeCode >= 4000 && closeCode < 4100 =
    throwIO . TerminatePusher $ Just closeCode
  -- Reconnect
  | otherwise =
    throwIO WS.ConnectionClosed

-- | Send a ping every time the timeout elapses. If the connection
-- closes the 'reconnectImmediately' close code is written to the
-- 'TVar'.
pingThread :: Pusher -> Connection -> TVar (Maybe Word16) -> IO ()
pingThread pusher conn closevar = do
  timeout <- liftIO . atomically $
    maybe retry pure =<< readTVar (idleTimer pusher)
  pinger timeout 0

  where
    pinger :: Int -> Integer -> IO ()
    pinger timeout i = do
      -- Wait for the timeout to elapse
      threadDelay (timeout * 1000 * 1000)
      -- Send a ping
      WS.sendPing conn (pack $ show i)
      -- Check the time of receipt of the last message: if it's longer
      -- ago than the timeout signal disconnection. Otherwise loop.
      now     <- getCurrentTime
      lastMsg <- readTVarIO (lastReceived pusher)
      if now `diffUTCTime` lastMsg > fromIntegral timeout
       then atomically (writeTVar closevar reconnectImmediately)
       else pinger timeout (i + 1)

-- | Receive and handle events until the connection is closed, at
-- which point the close code is written to the provided 'TVar'.
handleThread :: Pusher -> Connection -> TVar (Maybe Word16) -> IO ()
handleThread pusher conn closevar = handler `catchAll` finaliser
  where
    handler = forever $ do
      msg <- awaitEvent conn
      atomically . writeTVar (lastReceived pusher) =<< getCurrentTime
      handleEvent pusher msg

    finaliser e = atomically . writeTVar closevar $ case fromException e of
      Just (WS.CloseRequest ccode _) -> Just ccode
      _ -> reconnectImmediately

-- | Block and wait for an event.
awaitEvent :: WS.Connection -> IO (Either ByteString Value)
awaitEvent = fmap decode . WS.receiveDataMessage where
  decode (WS.Text   bs) = maybe (Left bs) Right (decode' bs)
  decode (WS.Binary bs) = Left bs

-- | Launch all event handlers which are bound to the current event.
handleEvent :: Pusher -> Either ByteString Value -> IO ()
handleEvent pusher (Right event) = do
  let match (Handler e c _) = (isNothing e || e == Just (eventType event)) &&
                              (isNothing c || c == eventChannel event)

  handlers <- filter match . H.elems <$> readTVarIO (eventHandlers pusher)
  runPusherClient pusher $
    mapM_ (fork . (\(Handler _ _ h) -> h event)) handlers
-- Discard events which couldn't be decoded.
handleEvent _ _ = pure ()

-- | @Just 4200@ = generic reconnect immediately
reconnectImmediately :: Maybe Word16
reconnectImmediately = Just 4200

-- | Set the connection state and send a state change event if
-- necessary.
changeConnectionState :: Pusher -> ConnectionState -> IO ()
changeConnectionState pusher connst = do
  ev <- atomically $ do
    oldState <- readTVar (connState pusher)
    writeTVar (connState pusher) connst
    pure $ (Object . H.singleton "event" . String) <$>
      (if oldState == connst then Nothing else Just (connectionEvent connst))
  maybe (pure ()) (handleEvent pusher . Right) ev

-------------------------------------------------------------------------------
-- Default event handlers

-- | Default event handlers
defaultHandlers :: [(Text, Value -> PusherClient ())]
defaultHandlers =
  [ ("pusher:ping", pingHandler)
  , ("pusher:connection_established", establishConnection)
  , ("pusher_internal:subscription_succeeded", addChannel)
  , ("pusher_internal:member_added", addPresenceMember)
  , ("pusher_internal:member_removed", rmPresenceMember)
  ]

-- | Immediately send a pusher:pong
pingHandler :: Value -> PusherClient ()
pingHandler _ = triggerEvent "pusher:pong" Nothing (Object H.empty)

-- | Record the activity timeout and socket ID.
establishConnection :: Value -> PusherClient ()
establishConnection event = do
  let socketidmay = event ^? ix "data" . ix "socket_id"        . _String
  let timeoutmay  = event ^? ix "data" . ix "activity_timeout" . _Integral

  case (,) <$> socketidmay <*> timeoutmay of
    Just (socketid, timeout) -> do
      pusher <- ask
      strictModifyTVarIO (idleTimer pusher) (const (Just timeout))
      strictModifyTVarIO (socketId  pusher) (const (Just socketid))
    Nothing -> pure ()

-- | Save the list of users (if there is one) and send the internal
-- "pusher:subscription_succeeded" event.
addChannel :: Value -> PusherClient ()
addChannel event = do
  let channelmay = eventChannel event
  let usersmay   = event ^? ix "data" . ix "hash" . _Object

  case channelmay of
    Just channel -> do
      pusher <- ask
      maybe (pure ()) (mapUsers channel . const) usersmay
      let json = event & ix "event" .~ "pusher:subscription_succeeded"
      liftIO $ handleEvent pusher (Right json)
    Nothing -> pure ()

-- | Record a presence channel user.
addPresenceMember :: Value -> PusherClient ()
addPresenceMember event = do
  let channelmay = eventChannel event
  let uidmay     = event ^? ix "data" . ix "user_id"   . _String
  let infomay    = event ^? ix "data" . ix "user_info" . _Value

  case (,,) <$> channelmay <*> uidmay <*> infomay of
    Just (channel, uid, info) ->
      mapUsers channel (H.insert uid info)
    Nothing -> pure ()

-- | Remove a presence channel user.
rmPresenceMember :: Value -> PusherClient ()
rmPresenceMember event = do
  let channelmay = eventChannel event
  let uidmay     = event ^? ix "data" . ix "user_id" . _String

  case (,) <$> channelmay <*> uidmay of
    Just (channel, uid) ->
      mapUsers channel (H.delete uid)
    Nothing -> pure ()

-- | Apply a function to the users list of a presence channel
mapUsers :: Channel
         -> (H.HashMap Text Value -> H.HashMap Text Value)
         -> PusherClient ()
mapUsers channel f = do
  pusher <- ask
  strictModifyTVarIO (presenceChannels pusher) (H.adjust (second f) channel)
