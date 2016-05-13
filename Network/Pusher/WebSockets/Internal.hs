module Network.Pusher.WebSockets.Internal where

-- 'base' imports
import Control.Concurrent (ThreadId)
import Control.Exception (Exception, SomeException, catch)
import Data.Maybe (fromMaybe)
import Data.String (IsString(..))

-- library imports
import Control.Concurrent.STM (STM, TVar, atomically, newTVar, modifyTVar')
import Control.Concurrent.STM.TQueue
import qualified Control.Concurrent.STM as STM
import Control.DeepSeq (NFData(..), force)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import qualified Control.Monad.Trans.Reader as R
import Data.Aeson (Value(..))
import Data.Hashable (Hashable(..))
import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import Data.Text (Text, unpack)
import Network.Socket (HostName, PortNumber)
import Network.WebSockets (ConnectionException)

-------------------------------------------------------------------------------

-- | A convenience wrapper for 'Pusher' actions.
type PusherClient = ReaderT Pusher IO

-- | Run a 'PusherClient'.
runPusherClient :: Pusher -> PusherClient a -> IO a
runPusherClient = flip runReaderT

-- | Pusher connection handle.
--
-- If this is used after disconnecting, nothing will happen. (todo:
-- signal an error condition indicating a cause: we closed it, server
-- closed it, could not connect)
data Pusher = Pusher
  { commandQueue :: TQueue PusherCommand
  -- ^ Queue to send commands to the client thread.
  , appKey :: Key
  -- ^ The application key.
  , options :: Options
  -- ^ Connection options
  , idleTimer :: TVar (Maybe Int)
  -- ^ Inactivity timeout before a ping should be sent. Set by Pusher
  -- on connect.
  , socketId :: TVar (Maybe Text)
  -- ^ Identifier of the socket. Set by Pusher on connect.
  , threadStore :: TVar (S.Set ThreadId)
  -- ^ Currently live threads.
  , eventHandlers :: TVar (H.HashMap Binding Handler)
  -- ^ Event handlers.
  , nextBinding :: TVar Binding
  -- ^ Next free binding.
  , allChannels :: TVar (S.Set Channel)
  -- ^ All subscribed channels.
  , presenceChannels :: TVar (H.HashMap Channel (Value, H.HashMap Text Value))
  -- ^ Connected presence channels
  }

-- | A command to the Pusher thread.
data PusherCommand = SendMessage Value | Subscribe Value | Terminate
  deriving (Eq, Read, Show)

-- | An exception thrown to kill the client.
data TerminatePusher = TerminatePusher
  deriving (Eq, Ord, Enum, Bounded, Read, Show)

instance Exception TerminatePusher

-- | State for a brand new connection.
defaultPusher :: Key -> Options -> IO Pusher
defaultPusher key opts = atomically $ do
  defCommQueue   <- newTQueue
  defIdleTimer   <- newTVar Nothing
  defSocketId    <- newTVar Nothing
  defThreadStore <- newTVar S.empty
  defEHandlers   <- newTVar H.empty
  defBinding     <- newTVar (Binding 0)
  defAChannels   <- newTVar S.empty
  defPChannels   <- newTVar H.empty

  pure Pusher
    { commandQueue     = defCommQueue
    , appKey           = key
    , options          = opts
    , idleTimer        = defIdleTimer
    , socketId         = defSocketId
    , threadStore      = defThreadStore
    , eventHandlers    = defEHandlers
    , nextBinding      = defBinding
    , allChannels      = defAChannels
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
newtype Channel = Channel { unChannel :: Text }
  deriving (Eq, Ord)

instance NFData Channel where
  rnf (Channel c) = rnf c

instance Show Channel where
  show (Channel c) = "<<channel " ++ unpack c ++ ">>"

instance Hashable Channel where
  hashWithSalt salt (Channel c) = hashWithSalt salt c

-------------------------------------------------------------------------------

-- | Event binding handle: a witness that we bound an event handler, and is
-- used to unbind it.
--
-- If this is used after unbinding, nothing will happen.
newtype Binding = Binding { unBinding :: Int }
  deriving (Eq, Ord)

instance NFData Binding where
  rnf (Binding b) = rnf b

instance Show Binding where
  show (Binding b) = "<<binding " ++ show b ++ ">>"

instance Hashable Binding where
  hashWithSalt salt (Binding b) = hashWithSalt salt b

-------------------------------------------------------------------------------

-- | Get the current state.
ask :: PusherClient Pusher
ask = R.ask

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

-------------------------------------------------------------------------------

-- | Ignore all exceptions by supplying a default value.
ignoreAll :: a -> IO a -> IO a
ignoreAll fallback act = catchAll act (const (pure fallback))

-- | Run an action, starting again on connection exception.
reconnecting :: IO a -> IO a
reconnecting act = catchConnException act (const (reconnecting act))

-- | Catch connection failure exceptions.
catchConnException :: IO a -> (ConnectionException -> IO a) -> IO a
catchConnException = catch

-- | Catch all exceptions.
catchAll :: IO a -> (SomeException -> IO a) -> IO a
catchAll = catch
