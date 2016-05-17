{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Network.Pusher.WebSockets.Internal where

-- 'base' imports
import Control.Concurrent (ThreadId)
import Control.Exception (IOException, Exception, SomeException, catch, toException)
import qualified Control.Exception as E
import Data.String (IsString(..))
import Data.Word (Word16)

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
import Data.Time.Clock (UTCTime, getCurrentTime)
import Network.Socket (HostName, PortNumber)
import Network.WebSockets (ConnectionException, HandshakeException)

-------------------------------------------------------------------------------

-- | A convenience wrapper for 'Pusher' actions.
newtype PusherClient a = PusherClient (ReaderT Pusher IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Run a 'PusherClient'.
runPusherClient :: Pusher -> PusherClient a -> IO a
runPusherClient pusher (PusherClient action) = runReaderT action pusher

-- | Pusher connection handle.
--
-- If this is used after disconnecting, an exception will be thrown.
data Pusher = Pusher
  { commandQueue :: TQueue PusherCommand
  -- ^ Queue to send commands to the client thread.
  , connState :: TVar ConnectionState
  -- ^ The state of the connection.
  , options :: Options
  -- ^ Connection options
  , idleTimer :: TVar (Maybe Int)
  -- ^ Inactivity timeout before a ping should be sent. Set by Pusher
  -- on connect.
  , lastReceived :: TVar UTCTime
  -- ^ Time of receipt of last message.
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
data PusherCommand
  = SendMessage Value
  -- ^ Send a message over the network, not triggering event handlers.
  | SendLocalMessage Value
  -- ^ Do not send a message over the network, trigger event handlers.
  | Subscribe Channel Value
  -- ^ Send a channel subscription message and add to the
  -- 'allChannels' set.
  | Terminate
  -- ^ Gracefully close the connection.
  deriving (Eq, Show)

-- | An exception thrown to kill the client.
data TerminatePusher = TerminatePusher (Maybe Word16)
  deriving (Eq, Ord, Read, Show)

instance Exception TerminatePusher

-- | Thrown if attempting to communicate with Pusher after the
-- connection has been closed.
--
-- If the server closed the connection, the error code is
-- included. See the 4000-4099 error codes on
-- <https://pusher.com/docs/pusher_protocol>.
data PusherClosed = PusherClosed (Maybe Word16)
  deriving (Eq, Ord, Read, Show)

instance Exception PusherClosed

-- | The state of the connection. Events are sent when the state is
-- changed.
data ConnectionState
  = Initialized
  -- ^ Initial state. No event is emitted.
  | Connecting
  -- ^ Trying to connect. This state will also be entered when trying
  -- to reconnect after a connection failure.
  --
  -- Emits the @"connecting"@ event.
  | Connected
  -- ^ The connection is established and authenticated with your
  -- app.
  --
  -- Emits the @"connected"@ event.
  | Unavailable
  -- ^ The connection is temporarily unavailable. The network
  -- connection is down, the server is down, or something is blocking
  -- the connection.
  --
  -- Emits the @"unavailable"@ event and then enters the @Connecting@
  -- state again.
  | Disconnected (Maybe Word16)
  -- ^ The connection has been closed by the client, or the server
  -- indicated an error which cannot be resolved by reconnecting with
  -- the same settings.
  --
  -- If the server closed the connection, the error code is
  -- included. See the 4000-4099 error codes on
  -- <https://pusher.com/docs/pusher_protocol>.
  --
  -- Emits the @"disconnected"@ event and then kills all forked
  -- threads.
  deriving (Eq, Ord, Read, Show)

-- | State for a brand new connection.
defaultPusher :: Options -> IO Pusher
defaultPusher opts = do
  now <- getCurrentTime
  atomically $ do
    defCommQueue    <- newTQueue
    defConnState    <- newTVar Initialized
    defIdleTimer    <- newTVar Nothing
    defLastReceived <- newTVar now
    defSocketId     <- newTVar Nothing
    defThreadStore  <- newTVar S.empty
    defEHandlers    <- newTVar H.empty
    defBinding      <- newTVar (Binding 0)
    defAChannels    <- newTVar S.empty
    defPChannels    <- newTVar H.empty

    pure Pusher
      { commandQueue     = defCommQueue
      , connState        = defConnState
      , options          = opts
      , idleTimer        = defIdleTimer
      , lastReceived     = defLastReceived
      , socketId         = defSocketId
      , threadStore      = defThreadStore
      , eventHandlers    = defEHandlers
      , nextBinding      = defBinding
      , allChannels      = defAChannels
      , presenceChannels = defPChannels
      }

-- | Send a command to the queue. Throw a 'PusherClosed' exception if
-- the connection has been disconnected.
sendCommand :: Pusher -> PusherCommand -> IO ()
sendCommand pusher cmd = do
  cstate <- readTVarIO (connState pusher)
  case cstate of
    Disconnected ccode -> E.throwIO (PusherClosed ccode)
    _ -> atomically (writeTQueue (commandQueue pusher) cmd)

-------------------------------------------------------------------------------

data Options = Options
  { appKey :: AppKey
  -- ^ The application key.

  , encrypted :: Bool
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

  , pusherURL :: Maybe (HostName, PortNumber, String)
  -- ^ The host, port, and path to use instead of the standard Pusher
  -- servers. If set, the cluster is ignored. Defaults to @Nothing@.
  } deriving (Eq, Ord, Show)

instance NFData Options where
  rnf o = rnf ( appKey o
              , encrypted o
              , authorisationURL o
              , cluster o
              , mangle (pusherURL o)
              )
    where
      mangle Nothing = Nothing
      mangle (Just (h, p, s)) = p `seq` Just (h, s)

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
newtype AppKey = AppKey String
   deriving (Eq, Ord, Show, Read)

instance IsString AppKey where
  fromString = AppKey

instance NFData AppKey where
  rnf (AppKey k) = rnf k

-- | See 'Options' field documentation for what is set here.
defaultOptions :: AppKey -> Options
defaultOptions key = Options
  { appKey           = key
  , encrypted        = True
  , authorisationURL = Nothing
  , cluster          = MT1
  , pusherURL        = Nothing
  }

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
ask = PusherClient R.ask

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

-- | Run an action, starting again on connection and handshake
-- exception.
reconnecting :: IO a -> IO () -> IO a
reconnecting act prere = loop where
  loop = catchNetException act (const (prere >> loop))

-- | Catch all network exceptions.
catchNetException :: forall a. IO a -> (SomeException -> IO a) -> IO a
catchNetException act handler = E.catches act handlers where
  handlers = [ E.Handler (handler . toException :: IOException -> IO a)
             , E.Handler (handler . toException :: HandshakeException -> IO a)
             , E.Handler (handler . toException :: ConnectionException -> IO a)
             ]

-- | Catch all exceptions.
catchAll :: IO a -> (SomeException -> IO a) -> IO a
catchAll = catch
