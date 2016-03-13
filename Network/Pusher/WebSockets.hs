{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

module Network.Pusher.WebSockets
  ( -- * Connection
    PusherClient
  , Options(..)
  , defaultOptions
  , pusherWithKey

  -- * Channels
  , subscribe
  , unsubscribe
  , members
  , whoami

  -- * Events
  , bind
  , bindJSON
  , bindWith
  , triggerEvent

  -- * Utilities
  , fork
  ) where

import Control.Arrow (second)
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId)
import Control.DeepSeq (NFData(..), force)
import Control.Exception (SomeException, bracket_, catch, finally)
import Control.Lens ((^.), (&), (.~))
import Control.Monad (forever, when)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..), decode', decodeStrict', encode)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import Data.Maybe (fromMaybe, isNothing)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text, isPrefixOf)
import Data.Text.Encoding (encodeUtf8)
import Data.Version (Version(..), showVersion)
import qualified Network.WebSockets as WS
import qualified Network.Wreq as W
import qualified Wuss as WS (runSecureClient)
import Paths_pusher_ws (version)

-- | Event handlers: event name -> channel name -> decoder -> handler.
data Handler where
  Handler :: Maybe Text
          -> Maybe Text
          -> (Text -> Maybe a)
          -> (Value -> Maybe a -> PusherClient ())
          -> Handler

-- Cheats a bit.
instance NFData Handler where
  rnf (Handler e c _ _) = rnf (e, c)

-- | Private state for the client.
data ClientState = S
  { connection :: WS.Connection
  -- ^ Network connection
  , options :: Options
  -- ^ Connection options
  , activityTimeout :: IORef (Maybe Int)
  -- ^ Inactivity timeout before a ping should be sent. Set by Pusher
  -- on connect.
  , socketId :: IORef (Maybe Text)
  -- ^ Identifier of the socket. Set by Pusher on connect.
  , threadStore :: IORef [ThreadId]
  -- ^ Currently live threads.
  , eventHandlers :: IORef [Handler]
  -- ^ Event handlers.
  , presenceChannels :: IORef (H.HashMap Text (Value, H.HashMap Text Value))
  -- ^ Connected presence channels
  }

-- | A value of type @PusherClient a@ is a computation with access to
-- a connection to Pusher which, when executed, may perform
-- Pusher-specific actions such as subscribing to channels and
-- receiving events, as well as arbitrary I/O.
newtype PusherClient a = P { runClient :: ClientState -> IO a }

instance Functor PusherClient where
  fmap f (P a) = P $ fmap f . a

instance Applicative PusherClient where
  pure = P . const . pure

  (P f) <*> (P a) = P $ \s -> f s <*> a s

instance Monad PusherClient where
  (P a) >>= f = P $ \s -> do
    a' <- a s
    runClient (f a') s

instance MonadIO PusherClient where
  liftIO = P . const

-------------------------------------------------------------------------------

data Options = Options
  { encrypted :: Bool
  -- ^ If the connection should be made over an encrypted
  -- connection. Defaults to @True@.

  , authorisationURL :: Maybe String
  -- ^ The URL which will return the authentication signature needed
  -- for private and presence channels. If not given, private and
  -- presence channels cannot be used. Defaults to @Nothing@.

  , cluster :: String
  -- ^ Allows connecting to a different cluster by setting up correct
  -- hostnames for the connection. This parameter is mandatory when
  -- the app is created in a different cluster to the default
  -- us-east-1. Defaults to @"us-east-1"@.
  }

-- | See 'Options' field documentation for what is set here.
defaultOptions :: Options
defaultOptions = Options
  { encrypted = True
  , authorisationURL = Nothing
  , cluster = "us-east-1"
  }

-------------------------------------------------------------------------------

-- | Connect to Pusher.
--
-- Takes the application key and options, and runs a client. When the
-- client terminates, the connection is closed.
pusherWithKey :: String -> Options -> PusherClient a -> IO a
pusherWithKey key options
  | encrypted options = WS.runSecureClient host 443 path . run
  | otherwise         = WS.runClient       host  80 path . run

  where
    host
      -- The primary cluster has a different domain to all the others
      | cluster options == "us-east-1" = "ws.pusherapp.com"
      | otherwise = "ws-" ++ cluster options ++ ".pusher.com"

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
      timeout  <- newIORef Nothing
      sid      <- newIORef Nothing
      tids     <- newIORef []
      handlers <- newIORef []
      chans    <- newIORef H.empty
      let state = S conn options timeout sid tids handlers chans

      let killLive = readIORef tids >>= mapM_ killThread
      finally (runClient (wrap client) state) killLive

    -- Register default event handlers and fork off handling thread.
    wrap client = do
      mapM_ (\(e, h) -> bindJSON (Just e) Nothing h) defaultHandlers
      fork . forever $ awaitEvent >>= handleEvent
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
    pingHandler _ _ = triggerEvent "pusher:pong" $ Object H.empty

    -- Record the activity timeout and socket ID.
    establishConnection _ (Just (Object data_)) = liftMaybe $ do
      Number timeout  <- H.lookup "activity_timeout" data_
      String socketid <- H.lookup "socket_id"        data_

      pure $ do
        state <- ask
        strictModifyIORef (activityTimeout state) (const $ toBoundedInteger timeout)
        strictModifyIORef (socketId state) (const $ Just socketid)
    establishConnection _ _ = pure ()

    -- Save the list of users
    addPresenceChannel (Object event) (Just (Object data_)) = liftMaybe $ do
      String channel <- H.lookup "channel" event
      Object users   <- H.lookup "hash"    data_

      pure . umap channel $ const users
    addPresenceChannel _ _ = pure ()

    -- Add a user to the list
    addPresenceMember (Object event) (Just (Object data_)) = liftMaybe $ do
      String channel <- H.lookup "channel"   event
      String uid     <- H.lookup "user_id"   data_
      info           <- H.lookup "user_info" data_

      pure . umap channel $ H.insert uid info
    addPresenceMember _ _ = pure ()

    -- Remove a user from the list
    rmPresenceMember (Object event) (Just (Object data_)) = liftMaybe $ do
      String channel <- H.lookup "channel" event
      String uid     <- H.lookup "user_id" data_

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
    event <- H.lookup "event" o
    String d <- H.lookup "data" o
    data_ <- decodeStrict' $ encodeUtf8 d
    pure . Object $ H.fromList [("event", event), ("data", data_)]
  decode (WS.Binary bs) = Left bs

-- | Launch all event handlers which are bound to the current event.
handleEvent :: Either ByteString Value -> PusherClient ()
handleEvent (Right v@(Object o)) = do
  s <- ask

  let event   = (\(String s) -> s) <$> H.lookup "event"   o
  let channel = (\(String s) -> s) <$> H.lookup "channel" o
  let data_   = (\d -> case d of String s -> s; _ -> "") <$> H.lookup "data" o

  let match (Handler e c _ _) = (isNothing e || e == event) &&
                                (isNothing c || c == channel)
  handlers <- filter match <$> liftIO (readIORef $ eventHandlers s)

  let handle (Handler _ _ d h) = h v $ data_ >>= d
  mapM_ (fork . handle) handlers

-- Discard events which couldn't be decoded.
handleEvent (Left _) = pure ()

-------------------------------------------------------------------------------

-- | Subscribe to a channel. If the channel name begins with
-- \"private-\" or \"presence-\", authorisation is performed
-- automatically.
--
-- If authorisation fails, this returns @False@. Otherwise @True@ is
-- returned.
subscribe :: Text -> PusherClient Bool
subscribe channel = do
  data_ <- getSubscribeData
  case data_ of
    Just authdata -> triggerEvent "pusher:subscribe" authdata >> pure True
    Nothing -> pure False

  where
    getSubscribeData
      | "private-"  `isPrefixOf` channel = authorise channel
      | "presence-" `isPrefixOf` channel = authorise channel
      | otherwise = pure . Just . Object $ H.fromList [("channel", String channel)]

-- | Send a channel authorisation request
authorise :: Text -> PusherClient (Maybe Value)
authorise channel = do
  state <- ask
  let authURL = authorisationURL $ options state
  sockID <- liftIO . readIORef $ socketId state

  case (authURL, sockID) of
    (Just authURL', Just sockID') -> liftIO $ authorise' authURL' sockID'
    _ -> pure Nothing

  where
    authorise' authURL sockID = flip catchAll (const $ pure Nothing) $ do
      let params = W.defaults & W.param "channel_name" .~ [channel]
                              & W.param "socket_id"    .~ [sockID]
      r <- W.asValue =<< W.getWith params authURL
      pure . Just $ r ^. W.responseBody

-- | Unsubscribe from a channel.
unsubscribe :: Text -> PusherClient ()
unsubscribe channel = do
  -- Send the unsubscribe message
  let data_ = Object $ H.fromList [("channel", String channel)]
  triggerEvent "pusher:unsubscribe" data_

  -- Remove the presence channel
  state <- ask
  strictModifyIORef (presenceChannels state) $ H.delete channel

-- | Return the list of all members in a presence channel.
--
-- If we are not subscribed to this channel, returns @Nothing@
members :: Text -> PusherClient (Maybe (H.HashMap Text Value))
members channel = do
  state <- ask

  channels <- liftIO . readIORef $ presenceChannels state
  pure $ snd <$> H.lookup channel channels
  
-- | Return information about the local user in a presence channel.
--
-- If we are not subscribed to this channel, returns @Nothing@.
whoami :: Text -> PusherClient (Maybe Value)
whoami channel = do
  state <- ask

  channels <- liftIO . readIORef $ presenceChannels state
  pure $ fst <$> H.lookup channel channels

-------------------------------------------------------------------------------

-- | Bind an event handler to an event type, optionally restricted to a
-- channel. If no event name is given, bind to all events.
--
-- If multiple handlers match a received event, all will be
-- executed. The order is unspecified, and may not be consistent.
bind :: Maybe Text
     -- ^ Event name.
     -> Maybe Text
     -- ^ Channel name: If @Nothing@, all events of that name are
     -- handled.
     -> (Value -> PusherClient ())
     -- ^ Event handler.
     -> PusherClient ()
bind event channel handler = bindWith (const Nothing) event channel $
  \ev _ -> handler ev

-- | Variant of 'bind' which attempts to decode the \"data\" field of the event
-- as JSON.
bindJSON :: Maybe Text
         -- ^ Event name.
         -> Maybe Text
         -- ^ Channel name.
         -> (Value -> Maybe Value -> PusherClient ())
         -- ^ Event handler. Second parameter is the possibly-decoded
         -- \"data\" field.
         -> PusherClient ()
bindJSON = bindWith $ decodeStrict' . encodeUtf8

-- | Variant of 'bind' which attempts to decode the \"data\" field of
-- the event using some decoding function.
bindWith :: (Text -> Maybe a)
         -- ^ Decoder.
         -> Maybe Text
         -- ^ Event name.
         -> Maybe Text
         -- ^ Channel name.
         -> (Value -> Maybe a -> PusherClient ())
         -- ^ Event handler.
         -> PusherClient ()
bindWith decoder event channel handler = P $ \s ->
  let h = Handler event channel decoder handler
  in strictModifyIORef (eventHandlers s) (h:)

-- | Send an event with some JSON data.
triggerEvent :: Text -> Value -> PusherClient ()
triggerEvent event data_ = P $ \s -> WS.sendDataMessage (connection s) (WS.Text msg) where
  msg = encode . Object $ H.fromList [("event", String event), ("data", data_)]

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

-------------------------------------------------------------------------------

-- | Get the current state.
ask :: PusherClient ClientState
ask = P pure

-- | Turn a @Maybe@ action into a @PusherClient@ action.
liftMaybe :: Maybe (PusherClient ()) -> PusherClient ()
liftMaybe = fromMaybe $ pure ()

-- | Modify an @IORef@ strictly
strictModifyIORef :: (MonadIO m, NFData a) => IORef a -> (a -> a) -> m ()
strictModifyIORef ioref f =
  liftIO $ atomicModifyIORef' ioref (\a -> (force $ f a, ()))

-- | Catch all exceptions
catchAll :: IO a -> (SomeException -> IO a) -> IO a
catchAll = catch
