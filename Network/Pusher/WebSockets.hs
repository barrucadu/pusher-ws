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
  , mockPusher
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

-- library imports
import Control.Concurrent.Classy (MonadConc, atomically, readTVarConc)
import qualified Control.Concurrent.Classy as C
import Control.Concurrent.Classy.STM (retry)
import Control.Concurrent.Classy.STM.TVar (readTVar)
import Control.Monad.Trans.Class (lift)
import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Network.WebSockets (runClientWith)
import qualified Network.WebSockets as WS
import Wuss (runSecureClientWith)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import qualified Network.Pusher.WebSockets.Internal.Client as Client
import qualified Network.Pusher.WebSockets.Internal.MockClient as Mock
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
pusherWithOptions :: Options
                  -- ^ Connection options.
                  -> PusherClient IO a
                  -- ^ Pusher client action.
                  -> IO a
pusherWithOptions opts action
  | encrypted opts = run (runSecureClientWith host port path)
  | otherwise      = run (runClientWith host (fromIntegral port) path)

  where
    (host, port, path) = makeURL opts

    -- Run the client
    run withConn = do
      now <- getCurrentTime
      let authurl = authorisationURL opts
      let appkey  = appKey opts
      pusher <- defaultPusher (Just now) (httpAuth authurl appkey)

      let connOpts = WS.defaultConnectionOptions
            { WS.connectionOnPong = updateTime pusher }
      let withConnection = withConn connOpts []

      _ <- C.fork (Client.pusherClient pusher withConnection)
      runPusherClient pusher action

-- | Mock a Pusher connection for testing purposes.
--
-- This takes a list of events to trigger, and triggers them all in turn,
-- yielding after each to give event handlers a chance to run. An event is a
-- JSON 'Value' which should be in the format:
--
-- @
--     { "event":   "name of the event"          -- required
--     , "channel": "name of the channel"        -- optional
--     , "data":    "string or stringified json" -- optional
--     }
-- @
--
-- The given 'PusherClient' action can do anything it normally could when passed
-- to 'pusherWithOptions', including subscribe to private and presence channels
-- (although they will appear to be empty).
mockPusher :: MonadConc m
           => (Text -> Bool)
           -- ^ Channel authorisation function. Takes the channel name and
           -- returns @True@ if the client is allowed in.
           -> [Value]
           -- ^ Events to trigger, in order.
           -> PusherClient m a
           -- ^ Pusher client action.
           -> m a
mockPusher authfunc events action = do
  pusher <- defaultPusher Nothing (\_ (Channel c) -> mockAuth authfunc c)
  _ <- C.fork (Mock.pusherClient pusher events)
  runPusherClient pusher action

-- | Get the connection state.
connectionState :: MonadConc m => PusherClient m ConnectionState
connectionState = lift . readTVarConc . connState =<< ask

-- | Gracefully close the connection. The connection will remain open
-- and events will continue to be processed until the server accepts
-- the request.
disconnect :: MonadConc m => PusherClient m ()
disconnect = do
  pusher <- ask
  lift (sendCommand pusher Terminate)

-- | Like 'disconnect', but block until the connection is actually
-- closed.
disconnectBlocking :: MonadConc m => PusherClient m ()
disconnectBlocking = do
  disconnect
  blockUntilDisconnected

-- | Block until the connection is closed (but do not initiate a
-- disconnect).
--
-- This is useful if you run 'pusherWithOptions' in the main thread to
-- prevent the program from terminating until one of your event
-- handlers decides to disconnect.
blockUntilDisconnected :: MonadConc m => PusherClient m ()
blockUntilDisconnected = do
  pusher <- ask
  lift . atomically $ do
    cstate <- readTVar (connState pusher)
    case cstate of
      Disconnected _ -> pure ()
      _ -> retry
