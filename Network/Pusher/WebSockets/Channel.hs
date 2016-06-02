{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.Pusher.WebSockets.Channel
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- Functions for subscribing to and querying channels.
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
import Control.Concurrent.Classy (MonadConc, readTVarConc)
import Control.Lens ((&), (%~), ix)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class (lift)
import Data.Aeson (Value(..), decode)
import qualified Data.HashMap.Strict as H
import Data.Text (Text, isPrefixOf, pack)
import Data.Text.Encoding (encodeUtf8)
import qualified Network.HTTP.Conduit as W

-- local imports
import Network.Pusher.WebSockets.Event
import Network.Pusher.WebSockets.Internal

-------------------------------------------------------------------------------

-- | Subscribe to a channel. If the channel name begins with \"private-\" or
-- \"presence-\", authorisation is performed automatically over HTTP, hence the
-- 'MonadIO' constraint in this type.
--
-- This returns immediately. You should wait for the
-- @"pusher:subscription_succeeded"@ event before attempting to use presence
-- channel functions like 'members' and 'whoami'.
--
-- If authorisation fails, this returns @Nothing@.
subscribe :: (MonadConc m, MonadIO m) => Text -> PusherClient m (Maybe Channel)
subscribe channel = do
  pusher <- ask
  data_ <- getSubscribeData
  case data_ of
    Just (Object o) -> do
      let channelData = Object (H.insert "channel" (String channel) o)
      lift (sendCommand pusher (Subscribe handle channelData))

      pure (Just handle)
    _ -> pure Nothing

  where
    getSubscribeData
      | "private-"  `isPrefixOf` channel = authorise handle
      | "presence-" `isPrefixOf` channel = authorise handle
      | otherwise = pure (Just (Object H.empty))

    handle = Channel channel

-- | Unsubscribe from a channel.
unsubscribe :: MonadConc m => Channel -> PusherClient m ()
unsubscribe channel = do
  -- Send the unsubscribe message
  triggerEvent "pusher:unsubscribe" (Just channel) Null

  -- Remove the presence channel
  pusher <- ask
  lift (strictModifyTVarConc (presenceChannels pusher) (H.delete channel))

-- | Return the list of all members in a presence channel.
--
-- If we have unsubscribed from this channel, or it is not a presence
-- channel, returns an empty map.
members :: MonadConc m => Channel -> PusherClient m (H.HashMap Text Value)
members channel = do
  pusher <- ask
  chan <- H.lookup channel <$> lift (readTVarConc (presenceChannels pusher))
  pure (maybe H.empty snd chan)

-- | Return information about the local user in a presence channel.
--
-- If we have unsubscribed from this channel, or it is not a presence
-- channel, returns @Null@.
whoami :: MonadConc m => Channel -> PusherClient m Value
whoami channel = do
  pusher <- ask

  chan <- H.lookup channel <$> lift (readTVarConc (presenceChannels pusher))
  pure (maybe Null fst chan)

-------------------------------------------------------------------------------

-- | Send a channel authorisation request
authorise :: (MonadConc m, MonadIO m) => Channel -> PusherClient m (Maybe Value)
authorise (Channel channel) = do
  pusher <- ask
  let authURL = authorisationURL (options pusher)
  let AppKey key = appKey (options pusher)
  sockID <- lift (readTVarConc (socketId pusher))

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
