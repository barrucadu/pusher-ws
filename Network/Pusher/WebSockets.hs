{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

module Network.Pusher.WebSockets
  ( -- * Connection
    PusherClient
  , Options(..)
  , defaultOptions
  , pusherWithKey

  -- * Channels
  , Channel
  , subscribe
  , unsubscribe
  , members
  , whoami

  -- * Events
  , eventType
  , eventChannel

  -- * Event Handlers
  , Binding
  , bind
  , bindJSON
  , bindWith
  , unbind

  -- * Client Events
  , triggerEvent

  -- * Utilities
  , fork
  ) where

import Control.Arrow (second)
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Exception (bracket_, finally)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..), decode', decodeStrict')
import Data.ByteString.Lazy (ByteString)
import Data.Functor (void)
import qualified Data.HashMap.Strict as H
import Data.IORef (readIORef)
import Data.Maybe (isNothing)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Version (Version(..), showVersion)
import qualified Network.WebSockets as WS
import qualified Wuss as WS (runSecureClient)
import Paths_pusher_ws (version)

import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal

-------------------------------------------------------------------------------

-- | Connect to Pusher.
--
-- Takes the application key and options, and runs a client. When the
-- client terminates, the connection is closed.
pusherWithKey :: String -> Options -> PusherClient a -> IO a
pusherWithKey key opts
  | encrypted opts = WS.runSecureClient host 443 path . run
  | otherwise      = WS.runClient       host  80 path . run

  where
    host
      -- The primary cluster has a different domain to all the others
      | cluster opts == "us-east-1" = "ws.pusherapp.com"
      | otherwise = "ws-" ++ cluster opts ++ ".pusher.com"

    path = "/app/"
        ++ key
        ++ "?client=haskell-pusher-ws&protocol=7&version="
        ++ showVersion semver

    -- The server doesn't work with a 4-component version number, my
    -- guess is that it's assuming semver.
    semver = Version { versionBranch = take 3 $ versionBranch version
                     , versionTags = []
                     }

    -- Set-up and tear-down
    run client conn = do
      state <- defaultClientState conn opts

      let killLive = readIORef (threadStore state) >>= mapM_ killThread
      finally (runClient (wrap client) state) killLive

    -- Register default event handlers and fork off handling thread.
    wrap client = do
      mapM_ (\(e, h) -> bindJSON (Just e) Nothing h) defaultHandlers
      void . fork . forever $ awaitEvent >>= handleEvent
      client

-- | Default event handlers
defaultHandlers :: [(Text, Value -> Maybe Value -> PusherClient ())]
defaultHandlers =
  [ ("pusher:ping", pingHandler)
  , ("pusher:connection_established", establishConnection)
  , ("pusher_internal:subscription_succeeded", addPresenceChannel)
  , ("pusher_internal:member_added", addPresenceMember)
  , ("pusher_internal:member_removed", rmPresenceMember)
  ]

  where
    -- Immediately send a pusher:pong
    pingHandler _ _ = triggerEvent "pusher:pong" Nothing $ Object H.empty

    -- Record the activity timeout and socket ID.
    establishConnection _ (Just (Object data_)) = liftMaybe $ do
      Number timeout  <- H.lookup "activity_timeout" data_
      String socketid <- H.lookup "socket_id"        data_

      pure $ do
        state <- ask
        strictModifyIORef (idleTimer state) (const $ toBoundedInteger timeout)
        strictModifyIORef (socketId state) (const $ Just socketid)
    establishConnection _ _ = pure ()

    -- Save the list of users
    addPresenceChannel event (Just (Object data_)) = liftMaybe $ do
      channel <- eventChannel event

      Object users <- H.lookup "hash" data_

      pure . umap channel $ const users
    addPresenceChannel _ _ = pure ()

    -- Add a user to the list
    addPresenceMember event (Just (Object data_)) = liftMaybe $ do
      channel <- eventChannel event

      String uid <- H.lookup "user_id"   data_
      info       <- H.lookup "user_info" data_

      pure . umap channel $ H.insert uid info
    addPresenceMember _ _ = pure ()

    -- Remove a user from the list
    rmPresenceMember event (Just (Object data_)) = liftMaybe $ do
      channel <- eventChannel event

      String uid <- H.lookup "user_id" data_

      pure . umap channel $ H.delete uid
    rmPresenceMember _ _ = pure ()

    --  Apply a function to the users list of a presence channel
    umap channel f = do
      state <- ask
      strictModifyIORef (presenceChannels state) $ H.adjust (second f) channel

-- | Block and wait for an event.
awaitEvent :: PusherClient (Either ByteString Value)
awaitEvent = P $ \s -> decode <$> WS.receiveDataMessage (connection s) where
  decode (WS.Text bs) = maybe (Left bs) Right $ do
    Object o <- decode' bs
    String d <- H.lookup "data" o
    data_    <- decodeStrict' $ encodeUtf8 d
    pure . Object $ H.adjust (const data_) "data" o
  decode (WS.Binary bs) = Left bs

-- | Launch all event handlers which are bound to the current event.
handleEvent :: Either ByteString Value -> PusherClient ()
handleEvent (Right event@(Object o)) = do
  state <- ask

  let ty = eventType event
  let ch = eventChannel event
  let data_ = (\d -> case d of String s -> s; _ -> "") <$> H.lookup "data" o

  let match (Handler e c _ _) = (isNothing e || e == Just ty) &&
                                (isNothing c || c == ch)

  allHandlers <- liftIO . readIORef $ eventHandlers state
  let handlers = filter match $ H.elems allHandlers

  let handle (Handler _ _ d h) = h event $ data_ >>= d
  mapM_ (fork . handle) handlers
-- Discard events which couldn't be decoded.
handleEvent _ = pure ()

-------------------------------------------------------------------------------

-- | Fork a thread which will be killed when the connection is closed.
fork :: PusherClient () -> PusherClient ThreadId
fork (P action) = P $ \s -> forkIO (run s) where
  run s = bracket_ setup teardown (action s) where
    -- Add the thread ID to the list
    setup = do
      tid <- myThreadId
      strictModifyIORef (threadStore s) (tid:)

    -- Remove the thread ID from the list
    teardown = do
      tid <- myThreadId
      strictModifyIORef (threadStore s) (filter (/=tid))
