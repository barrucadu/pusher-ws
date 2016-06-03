{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Network.Pusher.WebSockets.Internal.MockClient
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- Mock Pusher network client. This is NOT considered to form part of the public
-- API of this library.
module Network.Pusher.WebSockets.Internal.MockClient where

-- 'base' imports
import Control.Monad (forever, unless, when)

-- library imports
import Control.Concurrent.Classy
import Data.Aeson (Value(..))
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S

-- local imports
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Internal.Event
import Network.Pusher.WebSockets.Internal.Util

-- | Mock client: start everything up and then process all the events in turn.
-- After triggering each event, the thread calls 'yield' to give others a chance
-- to work.
--
-- Does not automatically fork.
--
-- TODO: Mock presence channel authorisation.
pusherClient :: forall m. MonadConc m => Pusher m -> [Value] -> m ()
pusherClient pusher events = do
  -- Bind default handlers
  runPusherClient pusher $
    mapM_ (\(e, h) -> bind e Nothing h) defaultHandlers

  -- \"Connect\" to Pusher
  handleEvent pusher . Right . Object $ H.fromList
    [ ("event", String "pusher:connection_established")
    , ("data", Object $ H.fromList
        [ ("socket_id", String "mock")
        , ("activity_timeout", Number 120)
        ]
      )
    ]
  changeConnectionState pusher Connected

  -- Fork a command-handling thread.
  closeVar <- atomically (newTVar False)
  _ <- fork (handleCommands pusher closeVar)

  -- Process all events in order until they finish or \"disconnect\".
  handleEvents pusher closeVar events

  -- \"Disconnect\" from Pusher
  --
  -- TODO: Should this take an optional close code?
  changeConnectionState pusher (Disconnected Nothing)

  -- Kill forked threads
  readTVarConc (threadStore pusher) >>= mapM_ killThread

-- | Process commands and signal disconnect through the @closeVar@.
handleCommands :: MonadConc m => Pusher m -> TVar (STM m) Bool -> m ()
handleCommands pusher closeVar = forever $ do
  cmd <- atomically (readTQueue (commandQueue pusher))
  case cmd of
    SendMessage      _ -> pure ()
    SendLocalMessage json -> handleEvent pusher (Right json)
    Subscribe handle@(Channel channel) _ -> do
      strictModifyTVarConc (allChannels pusher) (S.insert handle)
      handleEvent pusher . Right . Object $ H.fromList
        [ ("event", String "pusher_internal:subscription_succeeded")
        , ("channel", String channel)
        ]
    Terminate -> atomically (writeTVar closeVar True)
  yield

-- | Process all events in order, or until the @closeVar@ contains @True@.
--
-- Note: tthis throws away events on channels we're not subscribed to.
handleEvents :: MonadConc m => Pusher m -> TVar (STM m) Bool -> [Value] -> m ()
handleEvents pusher closeVar = go where
  go (e:es) = do
    disconnect <- readTVarConc closeVar
    unless disconnect $ do
      subscriptions <- readTVarConc (allChannels pusher)
      when (maybe False (`S.member` subscriptions) (eventChannel e)) $
        handleEvent pusher (Right e)
      yield
      go es
  go [] = pure ()
