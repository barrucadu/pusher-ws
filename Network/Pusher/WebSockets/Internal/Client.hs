{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.Pusher.WebSockets.Internal.Client
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- Pusher network client. This is NOT considered to form part of the
-- public API of this library.
module Network.Pusher.WebSockets.Internal.Client where

-- 'base' imports
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (fromException, throwIO)
import Control.Monad (forever)
import Data.Maybe (isJust)

-- library imports
import Control.Concurrent.STM (atomically, check, retry)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), encode, decode')
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import Data.Text (Text, pack)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Word (Word16)
import Network.WebSockets (Connection, sendClose)
import qualified Network.WebSockets as WS

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Internal.Event
import Network.Pusher.WebSockets.Internal.Util

-------------------------------------------------------------------------------
-- Pusher client

-- | Client thread: connect to Pusher and process commands,
-- reconnecting automatically, until finally told to terminate.
--
-- Does not automatically fork.
pusherClient :: Pusher IO -> ((Connection -> IO ()) -> IO ()) -> IO ()
pusherClient pusher withConnection = do
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
client :: Pusher IO -> Connection -> IO ()
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
      strictModifyTVarConc (idleTimer pusher) (const Nothing)
      strictModifyTVarConc (socketId  pusher) (const Nothing)
      throwIO e

-- | Handle a command or close signal. Throws an exception on
-- disconnect: 'TerminatePusher' if the connection should not be
-- re-established, and 'WS.ConnectionClosed' if it should be.
handleCommandOrClose :: Pusher IO
                     -> Connection
                     -> Either Word16 PusherCommand
                     -> IO ()
handleCommandOrClose pusher conn (Right pusherCommand) =
  handleCommand pusher conn pusherCommand
handleCommandOrClose _ _ (Left closeCode) =
  throwCloseException closeCode

-- | Handle a command.
handleCommand :: Pusher IO -> Connection -> PusherCommand -> IO ()
handleCommand pusher conn pusherCommand = case pusherCommand of
  SendMessage      json -> sendJSON json
  SendLocalMessage json -> handleEvent pusher (Right json)
  Subscribe handle channelData -> do
    sendJSON . Object $ H.fromList
      [ ("event", String "pusher:subscribe")
      , ("data", channelData)
      ]
    strictModifyTVarConc (allChannels pusher) (S.insert handle)
  Terminate -> sendClose conn ("goodbye" :: Text)
  where
    -- Send some JSON down the channel.
    sendJSON = WS.sendDataMessage conn . WS.Text . encode

-- | Send a ping every time the timeout elapses. If the connection
-- closes the 'reconnectImmediately' close code is written to the
-- 'TVar'.
pingThread :: Pusher IO -> Connection -> TVar (Maybe Word16) -> IO ()
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

-------------------------------------------------------------------------------
-- Handler dispatch

-- | Receive and handle events until the connection is closed, at
-- which point the close code is written to the provided 'TVar'.
handleThread :: Pusher IO -> Connection -> TVar (Maybe Word16) -> IO ()
handleThread pusher conn closevar = handler `catchAll` finaliser where
  handler = forever $ do
    msg <- awaitEvent conn
    atomically . writeTVar (lastReceived pusher) =<< getCurrentTime
    handleEvent pusher msg

  finaliser e = atomically . writeTVar closevar $ case fromException e of
    Just (WS.CloseRequest ccode _) -> Just ccode
    _ -> reconnectImmediately

-- | Block and wait for an event.
awaitEvent :: Connection -> IO (Either ByteString Value)
awaitEvent = fmap decode . WS.receiveDataMessage where
  decode (WS.Text   bs) = maybe (Left bs) Right (decode' bs)
  decode (WS.Binary bs) = Left bs
