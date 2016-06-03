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
  , httpAuth
  , mockAuth
  ) where

-- 'base' imports
import Data.Monoid ((<>))

-- library imports
import Control.Concurrent.Classy (MonadConc, readTVarConc)
import Control.Lens ((&), (%~), ix)
import Control.Monad.Catch (MonadCatch)
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
  sockID <- lift $ readTVarConc (socketId pusher)
  data_ <- lift $ getSubscribeData (authorise pusher sockID)
  case data_ of
    Just (Object o) -> do
      let channelData = Object (H.insert "channel" (String channel) o)
      lift (sendCommand pusher (Subscribe handle channelData))

      pure (Just handle)
    _ -> pure Nothing

  where
    getSubscribeData auth
      | "private-"  `isPrefixOf` channel = auth handle
      | "presence-" `isPrefixOf` channel = auth handle
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

-- | Perform channel authorisation over HTTP.
httpAuth :: (MonadCatch m, MonadIO m)
         => Maybe String
         -- ^ Authorisation URL. If @Nothing@ private and presence channels
         -- cannot be used.
         -> AppKey
         -- ^ Application key.
         -> Maybe Text
         -- ^ Socket ID.
         -> Channel
         -- ^ The channel to auth against.
         -> m (Maybe Value)
httpAuth Nothing _ _ _ = pure Nothing
httpAuth _ _ Nothing _ = pure Nothing
httpAuth (Just authURL) (AppKey key) (Just sockID) (Channel channel) =
  liftIO . ignoreAll Nothing $ do
    -- Attempt to authorise against the server.
    man <- W.newManager W.tlsManagerSettings
    req <- W.parseUrl authURL
    let req' = W.setQueryString
                 [ ("channel_name", Just (encodeUtf8 channel))
                 , ("socket_id",    Just (encodeUtf8 sockID))
                 ] req
    resp <- W.httpLbs req' man

    -- Return the authorisation response.
    pure $ case decode (W.responseBody resp) of
      -- If authed, prepend the app key to the "auth" field.
      Just authData -> Just (authData & ix "auth" %~ prepend (key ++ ":"))
      _ -> Nothing

  where
    -- prepend a value to a JSON string.
    prepend s (String str) = String (pack s <> str)
    prepend _ val = val

-- | A mock authorisation handler. Returns an empty object for channels which
-- evaluate to @True@.
mockAuth :: Applicative f
         => (Text -> Bool)
         -- ^ Authorisaton predicate: takes the channel name and returns
         -- @True@ if access is allowed.
         -> Text
         -- ^ The name of the channel.
         -> f (Maybe Value)
mockAuth authp channel = pure $
  if authp channel then Just (Object H.empty) else Nothing
