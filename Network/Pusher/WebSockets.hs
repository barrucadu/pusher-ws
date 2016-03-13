{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

module Network.Pusher.WebSockets
  ( PusherClient
  , Options(..)
  , defaultOptions
  , pusherWithKey
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..), decode', decodeStrict', encode)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H (lookup, fromList)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Version (Version(..), showVersion)
import qualified Network.WebSockets as WS
import qualified Wuss as WS (runSecureClient)
import Paths_pusher_ws (version)

-- | A value of type @PusherClient a@ is a computation with access to
-- a connection to Pusher which, when executed, may perform
-- Pusher-specific actions such as subscribing to channels and
-- receiving events, as well as arbitrary I/O.
newtype PusherClient a = P { runClient :: WS.ClientApp a }

instance Functor PusherClient where
  fmap f (P a) = P $ fmap f . a

instance Applicative PusherClient where
  pure = liftIO . pure

  (P f) <*> (P a) = P $ \conn -> f conn <*> a conn

instance Monad PusherClient where
  (P a) >>= f = P $ \conn -> do
    a' <- a conn
    runClient (f a') conn

instance MonadIO PusherClient where
  liftIO = P . const

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

-- | Connect to Pusher.
--
-- Takes the application key and options, and runs a client. Whent he
-- client terminates, the connection is closed.
pusherWithKey :: String -> Options -> PusherClient a -> IO a
pusherWithKey key options
  | encrypted options = WS.runSecureClient host 443 path . runClient
  | otherwise         = WS.runClient       host  80 path . runClient

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

-- | Block and wait for an event. If the event could not be
-- decoded, the original @ByteString@ is returned instead, although
-- this should never happen!
--
-- This automatically responds to control events.
awaitEvent :: PusherClient (Either ByteString Value)
awaitEvent = awaitEventWith (Just . String)

-- | Variant of 'awaitEvent' that attempts to decode the \"data\"
-- field of the event as JSON.
awaitEventJSON :: PusherClient (Either ByteString Value)
awaitEventJSON = awaitEventWith (decodeStrict' . encodeUtf8)

-- | Variant of 'awaitEventJSON' that takes a function to decode
-- the \"data\" field of the event. If the field can not be decoded,
-- the @ByteString@ of the entire event is returned instead.
awaitEventWith :: (Text -> Maybe Value) -> PusherClient (Either ByteString Value)
awaitEventWith f = P $ \conn -> do
  msg <- WS.receiveDataMessage conn
  let decoded = decode msg

  when (isPing decoded) $
    runClient (triggerEvent "pusher:pong" $ Object (H.fromList [])) conn

  pure decoded

  where
    decode (WS.Text bs) = maybe (Left bs) Right $ do
      Object o <- decode' bs
      event <- H.lookup "event" o
      String d <- H.lookup "data" o
      data_ <- f d
      pure . Object $ H.fromList [("event", event), ("data", data_)]
    decode (WS.Binary bs) = Left bs

    isPing (Right (Object v)) = H.lookup "event" v == Just (String "pusher:ping")
    isPing _ = False

-- | Send an event with some JSON data.
triggerEvent :: Text -> Value -> PusherClient ()
triggerEvent event data_ = P $ \conn -> WS.sendDataMessage conn (WS.Text msg) where
  msg = encode . Object $ H.fromList [("event", String event), ("data", data_)]
