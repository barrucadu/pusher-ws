{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets.Channel
  ( subscribe
  , unsubscribe
  , members
  , whoami
  ) where

import Control.Lens ((^.), (&), (.~))
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..))
import qualified Data.HashMap.Strict as H
import Data.IORef (readIORef)
import Data.Text (Text, isPrefixOf)
import qualified Network.Wreq as W

import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal

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
      | otherwise = pure $ Just channelData

    channelData = Object $ H.fromList [("channel", String channel)]

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
