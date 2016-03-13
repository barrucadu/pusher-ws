{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets.Event
  ( eventType
  , eventChannel

  -- * Event Handlers
  , bind
  , bindJSON
  , bindWith
  , triggerEvent
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), decodeStrict', encode)
import qualified Data.HashMap.Strict as H
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import qualified Network.WebSockets as WS

import Network.Pusher.WebSockets.Internal

-------------------------------------------------------------------------------

-- | Get the value of the \"event\" field.
--
-- If not present (which should never happen!), returns the empty
-- string.
eventType :: Value -> Text
eventType (Object o) = maybe "" unJSON $ H.lookup "event" o where
  unJSON (String s) = s
  unJSON _ = ""
eventType _ = ""

-- | Get the value of the \"channel\" field.
--
-- This will be @Nothing@ if the event was broadcast to all clients,
-- with no channel restriction.
eventChannel :: Value -> Maybe Channel
eventChannel (Object o) = H.lookup "channel" o >>= unJSON where
  unJSON (String s) = Just $ Channel s
  unJSON _ = Nothing
eventChannel _ = Nothing

-------------------------------------------------------------------------------

-- | Bind an event handler to an event type, optionally restricted to a
-- channel. If no event name is given, bind to all events.
--
-- If multiple handlers match a received event, all will be
-- executed. The order is unspecified, and may not be consistent.
bind :: Maybe Text
     -- ^ Event name.
     -> Maybe Channel
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
         -> Maybe Channel
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
         -> Maybe Channel
         -- ^ Channel name.
         -> (Value -> Maybe a -> PusherClient ())
         -- ^ Event handler.
         -> PusherClient ()
bindWith decoder event channel handler = P $ \s ->
  let h = Handler event channel decoder handler
  in strictModifyIORef (eventHandlers s) (h:)

-------------------------------------------------------------------------------

-- | Send an event with some JSON data.
triggerEvent :: Text -> Maybe Channel -> Value -> PusherClient ()
triggerEvent event channel data_ = sendJSON msg where
  msg = Object . H.fromList $ concat
    [ [("event",   String event)]
    , [("channel", String chan) | Just (Channel chan) <- [channel]]
    , [("data",    data_)]
    ]

-- | Send some JSON down the socket.
sendJSON :: Value -> PusherClient ()
sendJSON data_ = do
  state <- ask
  liftIO $ WS.sendDataMessage (connection state) (WS.Text $ encode data_)
