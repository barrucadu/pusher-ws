{-# LANGUAGE OverloadedStrings #-}

module Network.Pusher.WebSockets.Channel
  ( Channel
  , subscribe
  , unsubscribe
  , members
  , whoami
  ) where

-- 'base' imports
import Data.Monoid ((<>))

-- library imports
import Control.Lens ((&), (%~), ix)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..), decode)
import qualified Data.HashMap.Strict as H
import Data.Text (Text, isPrefixOf, pack)
import Data.Text.Encoding (encodeUtf8)
import qualified Network.HTTP.Conduit as W

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
  state <- ask
  data_ <- getSubscribeData
  case data_ of
    Just (Object o) -> do
      let channelData = Object (H.insert "channel" (String channel) o)
      liftIO (sendCommand state (Subscribe handle channelData))

      pure (Just handle)
    _ -> pure Nothing

  where
    getSubscribeData
      | "private-"  `isPrefixOf` channel = authorise handle
      | "presence-" `isPrefixOf` channel = authorise handle
      | otherwise = pure (Just (Object H.empty))

    handle = Channel channel

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
  let Key key = appKey state
  sockID <- readTVarIO (socketId state)

  case (authURL, sockID) of
    (Just authURL', Just sockID') -> do
      authData <- liftIO (authorise' authURL' sockID')
      pure $ case authData of
        -- If authed, prepend the app key to the "auth" field.
        Just val -> Just (val & ix "auth" %~ prepend (key ++ ":"))
        _ -> Nothing
    _ -> pure Nothing

  where
    -- attempt to authorise against the server.
    authorise' authURL sockID = ignoreAll Nothing $ do
      man <- W.newManager W.tlsManagerSettings
      req <- W.parseUrl authURL
      let req' = W.setQueryString
                   [ ("channel_name", Just (encodeUtf8 channel))
                   , ("socket_id",    Just (encodeUtf8 sockID))
                   ] req
      resp <- W.httpLbs req' man
      pure . decode $ W.responseBody resp

    -- prepend a value to a JSON string.
    prepend s (String str) = String (pack s <> str)
    prepend _ val = val
