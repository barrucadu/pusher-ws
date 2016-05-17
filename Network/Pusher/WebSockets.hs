{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets
  ( -- * Pusher
    Pusher
  , PusherClosed(..)
  , AppKey(..)
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
{-# ANN module ("HLint: ignore Use import/export shortcut" :: String) #-}

-- | Connect to Pusher.
pusherWithKey :: AppKey -> Options -> IO Pusher
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

      _ <- forkIO (pusherClient pusher withConnection)
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
