{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.Pusher.WebSockets.Internal.Util
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- Utilities for a Pusher client. This is NOT considered to form part of the
-- public API of this library.
module Network.Pusher.WebSockets.Internal.Util where

-- library imports
import Control.Concurrent.Classy (MonadConc, STM, atomically)
import Control.Concurrent.Classy.STM (retry)
import Control.Concurrent.Classy.STM.TQueue (tryReadTQueue)
import Control.Concurrent.Classy.STM.TVar (TVar, readTVar, writeTVar)
import Control.Monad.Catch (MonadThrow, throwM)
import Data.Aeson (Value(..))
import qualified Data.HashMap.Strict as H
import Data.Text ()
import Data.Word (Word16)
import Network.WebSockets (ConnectionException(..))

-- local imports
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Internal.Event
import Network.Pusher.WebSockets.Util

-- | Wait for a command or close signal.
awaitCommandOrClose :: MonadConc m
                    => Pusher m
                    -> TVar (STM m) (Maybe Word16)
                    -> m (Either Word16 PusherCommand)
awaitCommandOrClose pusher closevar = atomically $ do
  cmd   <- tryReadTQueue (commandQueue pusher)
  ccode <- readTVar closevar
  case (cmd, ccode) of
    (Just cmd', _)         -> pure (Right cmd')
    (Nothing, Just ccode') -> pure (Left  ccode')
    (Nothing, Nothing) -> retry

-- | Throw the appropriate exception for a close code.
throwCloseException :: MonadThrow m => Word16 -> m a
throwCloseException closeCode
  -- Graceful termination
  | closeCode < 4000 =
    throwM $ TerminatePusher Nothing
  -- Server specified not to reconnect
  | closeCode >= 4000 && closeCode < 4100 =
    throwM . TerminatePusher $ Just closeCode
  -- Reconnect
  | otherwise =
    throwM ConnectionClosed

-- | @Just 4200@ = generic reconnect immediately
reconnectImmediately :: Maybe Word16
reconnectImmediately = Just 4200

-- | Set the connection state and send a state change event if
-- necessary.
changeConnectionState :: MonadConc m => Pusher m -> ConnectionState -> m ()
changeConnectionState pusher connst = do
  ev <- atomically $ do
    oldState <- readTVar (connState pusher)
    writeTVar (connState pusher) connst
    pure $ (Object . H.singleton "event" . String) <$>
      (if oldState == connst then Nothing else Just (connectionEvent connst))
  maybe (pure ()) (handleEvent pusher . Right) ev
