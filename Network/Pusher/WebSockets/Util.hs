{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-warnings-deprecations #-}

-- | General utility functions.
module Network.Pusher.WebSockets.Util where

-- 'base' imports
import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Exception (bracket_)
import Data.Version (Version(..), showVersion)

-- library imports
import Control.Monad.Trans.Reader (ReaderT(..))
import qualified Data.Set as S
import Data.Text (Text, unpack)
import Network.Socket (HostName, PortNumber)

-- local imports
import Network.Pusher.WebSockets.Internal
import Paths_pusher_ws (version)

-- | Fork a thread which will be killed when the connection is closed.
fork :: PusherClient () -> PusherClient ThreadId
fork (ReaderT action) = ReaderT (forkIO . run) where
  run s = bracket_ setup teardown (action s) where
    -- Add the thread ID to the list
    setup = do
      tid <- myThreadId
      strictModifyTVarIO (threadStore s) (S.insert tid)

    -- Remove the thread ID from the list
    teardown = do
      tid <- myThreadId
      strictModifyTVarIO (threadStore s) (S.delete tid)

-- | The hostname, port, and path (including querystring) to connect
-- to.
makeURL :: Options -> (HostName, PortNumber, String)
makeURL opts = case pusherURL opts of
  Just (host, port, path) -> (host, port, path ++ queryString)
  Nothing -> (defaultHost, defaultPort, defaultPath)

  where
    defaultHost
      -- The primary cluster has a different domain to all the others
      | cluster opts == MT1 = "ws.pusherapp.com"
      | otherwise = "ws-" ++ theCluster ++ ".pusher.com"

    theCluster = unpack . clusterName $ cluster opts

    defaultPort
      | encrypted opts = 443
      | otherwise = 80

    defaultPath = case appKey opts of
      AppKey k -> "/app/" ++ k ++ queryString

    queryString = "?client=haskell-pusher-ws&protocol=7&version="
               ++ showVersion semver

-- | Three-component semver of the library. This corresponds to the
-- first three components of the Haskell version, as the Pusher
-- servers don't like a four-component version number.
semver :: Version
semver = Version
  { versionBranch = take 3 (versionBranch version)
  , versionTags = []
  }

-- | The region name of a cluster.
clusterName :: Cluster -> Text
clusterName MT1 = "us-east-1"
clusterName EU  = "eu-west-1"
clusterName AP1 = "ap-southeast-1"

-- | The event name corresponding to a connection state. 'Initialized'
-- has the "initialized" event for consistency, but this event is
-- never emitted.
connectionEvent :: ConnectionState -> Text
connectionEvent Initialized      = "initialized"
connectionEvent Connecting       = "connecting"
connectionEvent Connected        = "connected"
connectionEvent Unavailable      = "unavailable"
connectionEvent (Disconnected _) = "disconnected"
