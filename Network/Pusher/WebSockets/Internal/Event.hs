{-# LANGUAGE OverloadedStrings #-}

-- | Eevnt handlers.
module Network.Pusher.WebSockets.Internal.Event where

-- 'base' imports
import Control.Arrow (second)
import Data.Maybe (isNothing)

-- library imports
import Control.Lens ((&), (^?), (.~), ix)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), decode')
import Data.Aeson.Lens (_Integral, _Object, _String, _Value)
import Data.ByteString.Lazy (ByteString)
import qualified Data.HashMap.Strict as H
import Data.Text (Text)
import Network.WebSockets (Connection, DataMessage(..), receiveDataMessage)

-- local imports
import Network.Pusher.WebSockets.Channel
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal
import Network.Pusher.WebSockets.Util

-------------------------------------------------------------------------------
-- Handler dispatch

-- | Block and wait for an event.
awaitEvent :: Connection -> IO (Either ByteString Value)
awaitEvent = fmap decode . receiveDataMessage where
  decode (Text   bs) = maybe (Left bs) Right (decode' bs)
  decode (Binary bs) = Left bs

-- | Launch all event handlers which are bound to the current event.
handleEvent :: Pusher -> Either ByteString Value -> IO ()
handleEvent pusher (Right event) = do
  let match (Handler e c _) = (isNothing e || e == Just (eventType event)) &&
                              (isNothing c || c == eventChannel event)

  handlers <- filter match . H.elems <$> readTVarIO (eventHandlers pusher)
  runPusherClient pusher $
    mapM_ (fork . (\(Handler _ _ h) -> h event)) handlers
-- Discard events which couldn't be decoded.
handleEvent _ _ = pure ()

-------------------------------------------------------------------------------
-- Default handlers

-- | Default event handlers
defaultHandlers :: [(Text, Value -> PusherClient ())]
defaultHandlers =
  [ ("pusher:ping", pingHandler)
  , ("pusher:connection_established", establishConnection)
  , ("pusher_internal:subscription_succeeded", addChannel)
  , ("pusher_internal:member_added", addPresenceMember)
  , ("pusher_internal:member_removed", rmPresenceMember)
  ]

-- | Immediately send a pusher:pong
pingHandler :: Value -> PusherClient ()
pingHandler _ = triggerEvent "pusher:pong" Nothing (Object H.empty)

-- | Record the activity timeout and socket ID.
establishConnection :: Value -> PusherClient ()
establishConnection event = do
  let socketidmay = event ^? ix "data" . ix "socket_id"        . _String
  let timeoutmay  = event ^? ix "data" . ix "activity_timeout" . _Integral

  case (,) <$> socketidmay <*> timeoutmay of
    Just (socketid, timeout) -> do
      pusher <- ask
      strictModifyTVarIO (idleTimer pusher) (const (Just timeout))
      strictModifyTVarIO (socketId  pusher) (const (Just socketid))
    Nothing -> pure ()

-- | Save the list of users (if there is one) and send the internal
-- "pusher:subscription_succeeded" event.
addChannel :: Value -> PusherClient ()
addChannel event = do
  let channelmay = eventChannel event
  let usersmay   = event ^? ix "data" . ix "hash" . _Object

  case channelmay of
    Just channel -> do
      pusher <- ask
      maybe (pure ()) (mapUsers channel . const) usersmay
      let json = event & ix "event" .~ "pusher:subscription_succeeded"
      liftIO $ handleEvent pusher (Right json)
    Nothing -> pure ()

-- | Record a presence channel user.
addPresenceMember :: Value -> PusherClient ()
addPresenceMember event = do
  let channelmay = eventChannel event
  let uidmay     = event ^? ix "data" . ix "user_id"   . _String
  let infomay    = event ^? ix "data" . ix "user_info" . _Value

  case (,,) <$> channelmay <*> uidmay <*> infomay of
    Just (channel, uid, info) ->
      mapUsers channel (H.insert uid info)
    Nothing -> pure ()

-- | Remove a presence channel user.
rmPresenceMember :: Value -> PusherClient ()
rmPresenceMember event = do
  let channelmay = eventChannel event
  let uidmay     = event ^? ix "data" . ix "user_id" . _String

  case (,) <$> channelmay <*> uidmay of
    Just (channel, uid) ->
      mapUsers channel (H.delete uid)
    Nothing -> pure ()

-------------------------------------------------------------------------------
-- Utilities

-- | Apply a function to the users list of a presence channel
mapUsers :: Channel
         -> (H.HashMap Text Value -> H.HashMap Text Value)
         -> PusherClient ()
mapUsers channel f = do
  pusher <- ask
  strictModifyTVarIO (presenceChannels pusher) (H.adjust (second f) channel)
