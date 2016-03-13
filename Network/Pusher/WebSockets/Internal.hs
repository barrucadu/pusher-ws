{-# LANGUAGE GADTs #-}

module Network.Pusher.WebSockets.Internal where

import Control.Concurrent (ThreadId)
import Control.DeepSeq (NFData(..), force)
import Control.Exception (SomeException, catch)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..))
import qualified Data.HashMap.Strict as H
import Data.IORef (IORef, atomicModifyIORef')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Network.WebSockets as WS

-------------------------------------------------------------------------------

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

-- | Private state for the client.
data ClientState = S
  { connection :: WS.Connection
  -- ^ Network connection
  , options :: Options
  -- ^ Connection options
  , idleTimer :: IORef (Maybe Int)
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

-------------------------------------------------------------------------------

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
