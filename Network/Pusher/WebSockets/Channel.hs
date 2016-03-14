{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets.Channel
  ( Channel
  , subscribe
  , unsubscribe
  , members
  , whoami
  ) where

-- library imports
import Control.Lens ((^.), (&), (.~))
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..))
import qualified Data.HashMap.Strict as H
import Data.Text (Text, isPrefixOf)
import qualified Network.Wreq as W

-- local imports
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal

-------------------------------------------------------------------------------

-- | Subscribe to a channel. If the channel name begins with
-- \"private-\" or \"presence-\", authorisation is performed
-- automatically.
--
-- If authorisation fails, this returns @Nothing@.
subscribe :: Text -> PusherClient (Maybe Channel)
subscribe channel = do
  data_ <- getSubscribeData
  case data_ of
    Just authdata -> do
      triggerEvent "pusher:subscribe" Nothing authdata
      pure (Just handle)
    Nothing -> pure Nothing

  where
    getSubscribeData
      | "private-"  `isPrefixOf` channel = authorise handle
      | "presence-" `isPrefixOf` channel = authorise handle
      | otherwise = pure (Just channelData)

    handle = Channel channel

    channelData = Object (H.fromList [("channel", String channel)])

-- | Unsubscribe from a channel.
unsubscribe :: Channel -> PusherClient ()
unsubscribe channel = do
  -- Send the unsubscribe message
  triggerEvent "pusher:unsubscribe" (Just channel) Null

  -- Remove the presence channel
  state <- ask
  strictModifyTVarIO (presenceChannels state) (H.delete channel)

-- | Return the list of all members in a presence channel.
--
-- If we have unsubscribed from this channel, or it is not a presence
-- channel, returns an empty map.
members :: Channel -> PusherClient (H.HashMap Text Value)
members channel = do
  state <- ask

  chan <- H.lookup channel <$> readTVarIO (presenceChannels state)
  pure (maybe H.empty snd chan)
  
-- | Return information about the local user in a presence channel.
--
-- If we have unsubscribed from this channel, or it is not a presence
-- channel, returns @Null@.
whoami :: Channel -> PusherClient Value
whoami channel = do
  state <- ask

  chan <- H.lookup channel <$> readTVarIO (presenceChannels state)
  pure (maybe Null fst chan)

-------------------------------------------------------------------------------

-- | Send a channel authorisation request
authorise :: Channel -> PusherClient (Maybe Value)
authorise (Channel channel) = do
  state <- ask
  let authURL = authorisationURL (options state)
  sockID <- readTVarIO (socketId state)

  case (authURL, sockID) of
    (Just authURL', Just sockID') -> liftIO (authorise' authURL' sockID')
    _ -> pure Nothing

  where
    authorise' authURL sockID = ignoreAll Nothing $ do
      let params = W.defaults & W.param "channel_name" .~ [channel]
                              & W.param "socket_id"    .~ [sockID]
      r <- W.asValue =<< W.getWith params authURL
      let body = r ^. W.responseBody
      pure (Just body)
