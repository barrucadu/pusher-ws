module Network.Pusher.WebSockets.Internal where

-- 'base' imports
import Control.Concurrent (ThreadId)
import Control.Exception (SomeException, catch)
import Data.Maybe (fromMaybe)
import Data.String (IsString(..))

-- library imports
import Control.Concurrent.STM (STM, TVar, atomically, newTVar, modifyTVar')
import qualified Control.Concurrent.STM as STM
import Control.DeepSeq (NFData(..), force)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (Value(..))
import Data.Hashable (Hashable(..))
import qualified Data.HashMap.Strict as H
import Data.Text (Text, unpack)
import Network.Socket (HostName, PortNumber)
import Network.WebSockets (Connection)

-------------------------------------------------------------------------------

-- | A value of type @PusherClient a@ is a computation with access to
-- a connection to Pusher which, when executed, may perform
-- Pusher-specific actions such as subscribing to channels and
-- receiving events, as well as arbitrary I/O.
newtype PusherClient a = P { runClient :: ClientState -> IO a }

instance Functor PusherClient where
  fmap f (P a) = P (fmap f . a)

instance Applicative PusherClient where
  pure = P . const . pure

  (P f) <*> (P a) = P $ \s -> f s <*> a s

instance Monad PusherClient where
  (P a) >>= f = P $ \s -> do
    a' <- a s
    runClient (f a') s

instance MonadIO PusherClient where
  liftIO = P . const

-------------------------------------------------------------------------------

-- | Private state for the client.
data ClientState = S
  { connection :: Connection
  -- ^ Network connection
  , options :: Options
  -- ^ Connection options
  , idleTimer :: TVar (Maybe Int)
  -- ^ Inactivity timeout before a ping should be sent. Set by Pusher
  -- on connect.
  , socketId :: TVar (Maybe Text)
  -- ^ Identifier of the socket. Set by Pusher on connect.
  , threadStore :: TVar [ThreadId]
  -- ^ Currently live threads.
  , eventHandlers :: TVar (H.HashMap Binding Handler)
  -- ^ Event handlers.
  , nextBinding :: TVar Binding
  -- ^ Next free binding.
  , presenceChannels :: TVar (H.HashMap Channel (Value, H.HashMap Text Value))
  -- ^ Connected presence channels
  }

-- | State for a brand new connection.
defaultClientState :: Connection -> Options -> IO ClientState
defaultClientState conn opts = atomically $ do
  defIdleTimer   <- newTVar Nothing
  defSocketId    <- newTVar Nothing
  defThreadStore <- newTVar []
  defEHandlers   <- newTVar H.empty
  defBinding     <- newTVar (Binding 0)
  defPChannels   <- newTVar H.empty

  pure S
    { connection       = conn
    , options          = opts
    , idleTimer        = defIdleTimer
    , socketId         = defSocketId
    , threadStore      = defThreadStore
    , eventHandlers    = defEHandlers
    , nextBinding      = defBinding
    , presenceChannels = defPChannels
    }

-------------------------------------------------------------------------------

data Options = Options
  { encrypted :: Bool
  -- ^ If the connection should be made over an encrypted
  -- connection. Defaults to @True@.

  , authorisationURL :: Maybe String
  -- ^ The URL which will return the authentication signature needed
  -- for private and presence channels. If not given, private and
  -- presence channels cannot be used. Defaults to @Nothing@.

  , cluster :: Cluster
  -- ^ Allows connecting to a different cluster by setting up correct
  -- hostnames for the connection. This parameter is mandatory when
  -- the app is created in a different cluster to the default
  -- us-east-1. Defaults to @MT1@.

  , pusherURL :: Maybe (HostName, PortNumber, Key -> String)
  -- ^ The host, port, and path to use instead of the standard Pusher
  -- servers. If set, the cluster is ignored. Defaults to @Nothing@.
  }

-- | Clusters correspond to geographical regions where apps can be
-- assigned to.
data Cluster
  = MT1 -- ^ The us-east-1 cluster.
  | EU  -- ^ The eu-west-1 cluster.
  | AP1 -- ^ The ap-southeast-1 cluster.
  deriving (Eq, Ord, Bounded, Enum, Read, Show)

instance NFData Cluster where
  rnf c = c `seq` ()

-- | Your application's API key.
newtype Key = Key String
   deriving (Eq, Ord, Show, Read)

instance IsString Key where
  fromString = Key

instance NFData Key where
  rnf (Key k) = rnf k

-- | See 'Options' field documentation for what is set here.
defaultOptions :: Options
defaultOptions = Options
  { encrypted        = True
  , authorisationURL = Nothing
  , cluster          = MT1
  , pusherURL        = Nothing
  }

-- | The region name of a cluster.
clusterName :: Cluster -> String
clusterName MT1 = "us-east-1"
clusterName EU  = "eu-west-1"
clusterName AP1 = "ap-southeast-1"

-------------------------------------------------------------------------------

-- | Event handlers: event name -> channel name -> handler.
data Handler = Handler (Maybe Text) (Maybe Channel) (Value -> PusherClient ())

-- Cheats a bit.
instance NFData Handler where
  rnf (Handler e c _) = rnf (e, c)

-------------------------------------------------------------------------------

-- | Channel handle: a witness that we joined a channel, and is used
-- to subscribe to events.
--
-- If this is used when unsubscribed from a channel, nothing will
-- happen.
newtype Channel = Channel Text
  deriving Eq

instance NFData Channel where
  rnf (Channel c) = rnf c

instance Show Channel where
  show (Channel c) = unpack c

instance Hashable Channel where
  hashWithSalt salt (Channel c) = hashWithSalt salt c

-------------------------------------------------------------------------------

-- | Event binding handle: a witness that we bound an event handler, and is
-- used to unbind it.
--
-- If this is used after unbinding, nothing will happen.
newtype Binding = Binding Int
  deriving Eq

instance NFData Binding where
  rnf (Binding b) = rnf b

instance Show Binding where
  show (Binding b) = "<<binding " ++ show b ++ ">>"

instance Hashable Binding where
  hashWithSalt salt (Binding b) = hashWithSalt salt b

-------------------------------------------------------------------------------

-- | Get the current state.
ask :: PusherClient ClientState
ask = P pure

-- | Turn a @Maybe@ action into a @PusherClient@ action.
liftMaybe :: Maybe (PusherClient ()) -> PusherClient ()
liftMaybe = fromMaybe (pure ())

-- | Modify a @TVar@ strictly.
strictModifyTVar :: NFData a => TVar a -> (a -> a) -> STM ()
strictModifyTVar tvar = modifyTVar' tvar . force

-- | Modify a @TVar@ strictly in any @MonadIO@.
strictModifyTVarIO :: (MonadIO m, NFData a) => TVar a -> (a -> a) -> m ()
strictModifyTVarIO tvar = liftIO . atomically . strictModifyTVar tvar

-- | Read a @TVar@ inside any @MonadIO@.
readTVarIO :: MonadIO m => TVar a -> m a
readTVarIO = liftIO . STM.readTVarIO

-- | Ignore all exceptions by supplying a default value.
ignoreAll :: a -> IO a -> IO a
ignoreAll fallback act = catchAll act (const (pure fallback)) where
  catchAll :: IO a -> (SomeException -> IO a) -> IO a
  catchAll = catch
