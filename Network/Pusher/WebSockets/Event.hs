{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.Pusher.WebSockets.Event
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- Functions for creating event handlers and triggering events.
module Network.Pusher.WebSockets.Event
  ( eventType
  , eventChannel

  -- * Event Handlers
  , Binding
  , bind
  , bindAll
  , unbind

  -- * Client Events
  , triggerEvent
  , localEvent
  ) where

-- 'base' imports
import Data.Maybe (fromMaybe)

-- library imports
import Control.Concurrent.Classy (MonadConc, atomically)
import Control.Concurrent.Classy.STM (readTVar)
import Control.Lens ((^?), (.~), (&), ix)
import Control.Monad.Trans.Class (lift)
import Data.Aeson (Value(..), decodeStrict')
import Data.Aeson.Lens (_String)
import qualified Data.HashMap.Strict as H
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)

-- local imports
import Network.Pusher.WebSockets.Internal

-------------------------------------------------------------------------------

-- | Get the value of the \"event\" field.
--
-- If not present (which should never happen!), returns the empty
-- string.
eventType :: Value -> Text
eventType event = fromMaybe "" (event ^? ix "event" . _String)

-- | Get the value of the \"channel\" field.
--
-- This will be @Nothing@ if the event was broadcast to all clients,
-- with no channel restriction.
eventChannel :: Value -> Maybe Channel
eventChannel event = fmap Channel (event ^? ix "channel" . _String)

-------------------------------------------------------------------------------

-- | Bind an event handler to an event type, optionally restricted to a
-- channel.
--
-- Attempts to decode the \"data\" field of the event as stringified
-- JSON; if that fails, it is left as a string.
--
-- If multiple handlers match a received event, all will be
-- executed. The order is unspecified, and may not be consistent.
bind :: MonadConc m
     => Text
     -- ^ Event name.
     -> Maybe Channel
     -- ^ Channel name: If @Nothing@, all events of that name are
     -- handled.
     -> (Value -> PusherClient m ())
     -- ^ Event handler.
     -> PusherClient m Binding
bind = bindGeneric . Just

-- | Variant of 'bind' which binds to all events in the given channel;
-- or all events if no channel.
bindAll :: MonadConc m
        => Maybe Channel
        -> (Value -> PusherClient m ())
        -> PusherClient m Binding
bindAll = bindGeneric Nothing

-- | Internal: register a new event handler.
bindGeneric :: MonadConc m
            => Maybe Text
            -> Maybe Channel
            -> (Value -> PusherClient m ())
            -> PusherClient m Binding
bindGeneric event channel handler = do
  pusher <- ask
  lift . atomically $ do
    b@(Binding i) <- readTVar (nextBinding pusher)
    let b' = Binding (i+1)
    strictModifyTVar (nextBinding pusher) (const b')
    let h = Handler event channel wrappedHandler
    strictModifyTVar (eventHandlers pusher) (H.insert b h)
    pure b

  where
    -- Before invoking the handler, have a stab at decoding the data
    -- field.
    wrappedHandler ev@(Object o) = handler $
      case H.lookup "data" o >>= attemptDecode of
        Just decoded -> ev & ix "data" .~ decoded
        Nothing -> ev
    wrappedHandler ev = handler ev

    -- Attempt to interpret as stringified JSON.
    attemptDecode (String s) = decodeStrict' (encodeUtf8 s)
    attemptDecode _ = Nothing

-- | Remove a binding
unbind :: MonadConc m => Binding -> PusherClient m ()
unbind binding = do
  pusher <- ask
  lift (strictModifyTVarConc (eventHandlers pusher) (H.delete binding))

-------------------------------------------------------------------------------

-- | Send an event with some JSON data. This does not trigger local
-- event handlers.
triggerEvent :: MonadConc m => Text -> Maybe Channel -> Value -> PusherClient m ()
triggerEvent = sendMessage SendMessage

-- | Trigger local event handlers, but do not send the event over the
-- network.
localEvent :: MonadConc m => Text -> Maybe Channel -> Value -> PusherClient m ()
localEvent = sendMessage SendLocalMessage

-- | Helper function for 'triggerEvent' and 'localEvent'
sendMessage :: MonadConc m
            => (Value -> PusherCommand)
            -> Text -> Maybe Channel -> Value -> PusherClient m ()
sendMessage cmd event channel data_ = do
  pusher <- ask
  lift (sendCommand pusher (cmd json))

  where
    json = Object . H.fromList $ concat
      [ [("event",   String event)]
      , [("channel", String chan) | Just (Channel chan) <- [channel]]
      , [("data",    data_)]
      ]
