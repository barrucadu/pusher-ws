-- |
-- Module      : Network.Pusher.WebSockets
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : portable
--
-- Pusher has two APIs: the REST API and the websocket API. The
-- websocket API, which is what this package implements, is used by
-- clients primarily to subscribe to channels and receive events. This
-- library encourages a callback-style approach to Pusher, where the
-- 'pusherWithOptions' function is used to subscribe to some channels
-- and bind some event handlers, and then block until the connection
-- is closed.
--
-- A small example, which simply prints all received events:
--
-- > let key = "your-key"
-- > let channels = ["your", "channels"]
-- >
-- > -- Connect to Pusher with your key, SSL, and the us-east-1 region,
-- > -- and do some stuff.
-- > pusherWithOptions (defaultOptions key) $ do
-- >   -- Subscribe to all the channels
-- >   mapM_ subscribe channels
-- >
-- >   -- Bind an event handler for all events on all channels which
-- >   -- prints the received JSON.
-- >   bindAll Nothing (liftIO . print)
-- >
-- >   -- Wait for user input and then close the connection.
-- >   liftIO (void getLine)
-- >   disconnectBlocking
--
-- See <https://pusher.com/docs/pusher_protocol> for details of the
-- protocol.
module Network.Pusher.WebSockets
  ( -- * Pusher
    PusherClient
  , PusherClosed(..)
  , AppKey(..)
  , Options(..)
  , Cluster(..)
  , pusherWithOptions
  , defaultOptions

  -- ** Connection
  , ConnectionState(..)
  , connectionState
  , disconnect
  , disconnectBlocking
  , blockUntilDisconnected

  -- * Re-exports
  , module Network.Pusher.WebSockets.Channel
  , module Network.Pusher.WebSockets.Event
  , module Network.Pusher.WebSockets.Util
  ) where

-- 'base' imports
import Control.Concurrent (forkIO)

-- library imports
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent.STM.TVar (readTVar, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.Time.Clock (getCurrentTime)
import Network.WebSockets (runClientWith)
import qualified Network.WebSockets as WS
import Wuss (runSecureClientWith)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Internal.Client
import Network.Pusher.WebSockets.Util

-- Haddock doesn't like the import/export shortcut when generating
-- docs.
{-# ANN module "HLint: ignore Use import/export shortcut" #-}

-- | Connect to Pusher.
--
-- This does NOT automatically disconnect from Pusher when the
-- supplied action terminates, so either the action will need to call
-- 'disconnect' or 'disconnectBlocking' as the last thing it does, or
-- one of the event handlers will need to do so eventually.
pusherWithOptions :: Options -> PusherClient a -> IO a
pusherWithOptions opts action
  | encrypted opts = run (runSecureClientWith host port path)
  | otherwise      = run (runClientWith host (fromIntegral port) path)

  where
    (host, port, path) = makeURL opts

    -- Run the client
    run withConn = do
      pusher <- defaultPusher opts

      let connOpts = WS.defaultConnectionOptions
            { WS.connectionOnPong = atomically . writeTVar (lastReceived pusher) =<< getCurrentTime }
      let withConnection = withConn connOpts []

      _ <- forkIO (pusherClient pusher withConnection)
      runPusherClient pusher action

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
  blockUntilDisconnected

-- | Block until the connection is closed (but do not initiate a
-- disconnect).
--
-- This is useful if you run 'pusherWithOptions' in the main thread to
-- prevent the program from terminating until one of your event
-- handlers decides to disconnect.
blockUntilDisconnected :: PusherClient ()
blockUntilDisconnected = do
  pusher <- ask
  liftIO . atomically $ do
    cstate <- readTVar (connState pusher)
    case cstate of
      Disconnected _ -> pure ()
      _ -> retry
