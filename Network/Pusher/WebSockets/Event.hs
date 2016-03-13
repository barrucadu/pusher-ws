{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets.Event
  ( bind
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

-------------------------------------------------------------------------------

-- | Send an event with some JSON data.
triggerEvent :: Text -> Value -> PusherClient ()
triggerEvent event data_ = sendJSON msg where
  msg = Object $ H.fromList [("event", String event), ("data", data_)]

-- | Send some JSON down the channel.
sendJSON :: Value -> PusherClient ()
sendJSON data_ = do
  state <- ask
  liftIO $ WS.sendDataMessage (connection state) (WS.Text $ encode data_)
