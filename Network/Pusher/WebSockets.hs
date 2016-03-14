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

  -- * Utilities
  , fork
  ) where

import Control.Arrow (second)
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.Exception (bracket_, finally)
import Control.Lens ((^?), ix)
import Control.Monad (forever)
import Data.Aeson (Value(..), decode', decodeStrict')
import Data.Aeson.Lens (_Integral, _Object, _String, _Value)
import Data.ByteString.Lazy (ByteString)
import Data.Functor (void)
import qualified Data.HashMap.Strict as H
import Data.Maybe (isNothing)
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

      let killLive = readTVarIO (threadStore state) >>= mapM_ killThread
      finally (runClient (wrap client) state) killLive

    -- Register default event handlers and fork off handling thread.
    wrap client = do
      mapM_ (\(e, h) -> bind e Nothing h) defaultHandlers
      void . fork . forever $ awaitEvent >>= handleEvent
      client

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
    pingHandler _ = triggerEvent "pusher:pong" Nothing $ Object H.empty

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
        strictModifyTVarIO (idleTimer state) (const $ Just timeout)
        strictModifyTVarIO (socketId  state) (const $ Just socketid)

    -- Save the list of users
    addPresenceChannel event = liftMaybe $ do
      channel <- eventChannel event
      users   <- event ^? ix "data" . ix "hash" . _Object

      pure . umap channel $ const users

    -- Add a user to the list
    addPresenceMember event = liftMaybe $ do
      channel <- eventChannel event
      uid     <- event ^? ix "data" . ix "user_id"   . _String
      info    <- event ^? ix "data" . ix "user_info" . _Value

      pure . umap channel $ H.insert uid info

    -- Remove a user from the list
    rmPresenceMember event = liftMaybe $ do
      channel <- eventChannel event
      uid     <- event ^? ix "data" . ix "user_id" . _String

      pure . umap channel $ H.delete uid

    --  Apply a function to the users list of a presence channel
    umap channel f = do
      state <- ask
      strictModifyTVarIO (presenceChannels state) $ H.adjust (second f) channel

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
handleEvent (Right event) = do
  state <- ask

  let match (Handler e c _) = (isNothing e || e == Just (eventType event)) &&
                              (isNothing c || c == eventChannel event)

  handlers <- filter match . H.elems <$> readTVarIO (eventHandlers state)
  mapM_ (fork . (\(Handler _ _ h) -> h event)) handlers
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
      strictModifyTVarIO (threadStore s) (tid:)

    -- Remove the thread ID from the list
    teardown = do
      tid <- myThreadId
      strictModifyTVarIO (threadStore s) (filter (/=tid))
