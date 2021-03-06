{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
--------------------------------------------------------------------------------
-- |
-- Module : Database.EventStore.Internal.Exec
-- Copyright : (C) 2017 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore.Internal.Exec
  ( Exec
  , Terminated(..)
  , newExec
  , execSettings
  , execWaitTillClosed
  ) where

--------------------------------------------------------------------------------
import Prelude (String)
import Data.Typeable

--------------------------------------------------------------------------------
import Database.EventStore.Internal.Communication
import Database.EventStore.Internal.Connection
import Database.EventStore.Internal.ConnectionManager
import Database.EventStore.Internal.Control
import Database.EventStore.Internal.Discovery
import Database.EventStore.Internal.Logger
import Database.EventStore.Internal.Prelude
import Database.EventStore.Internal.TimerService

--------------------------------------------------------------------------------
type ServicePendingInit = HashMap Service ()

--------------------------------------------------------------------------------
data Stage
  = Init
  | Available Publish
  | Errored String

--------------------------------------------------------------------------------
newtype Terminated = Terminated String deriving (Show, Typeable)

--------------------------------------------------------------------------------
instance Exception Terminated

--------------------------------------------------------------------------------
data Exec =
  Exec { execSettings       :: Settings
       , _execPub           :: STM Publish
       , _internal          :: Internal
       , execWaitTillClosed :: IO ()
       }

--------------------------------------------------------------------------------
data Internal =
  Internal { _initRef   :: IORef ServicePendingInit
           , _finishRef :: IORef ServicePendingInit
           , _stageVar  :: TVar Stage
           }

--------------------------------------------------------------------------------
instance Pub Exec where
  publishSTM e a = do
    pub     <- _execPub e
    handled <- publishSTM pub a
    unless handled $
      throwSTM $ Terminated "Connection Closed."

    return handled

--------------------------------------------------------------------------------
stageSTM :: TVar Stage -> STM Publish
stageSTM var = do
  stage <- readTVar var
  case stage of
    Init          -> retrySTM
    Available pub -> return pub
    Errored msg   -> throwSTM $ Terminated msg

--------------------------------------------------------------------------------
errored :: TVar Stage -> String -> STM ()
errored var err = do
  stage <- readTVar var
  case stage of
    Errored _ -> return ()
    _         -> writeTVar var (Errored err)

--------------------------------------------------------------------------------
initServicePending :: ServicePendingInit
initServicePending = foldMap (\svc -> singletonMap svc ()) [minBound..]

--------------------------------------------------------------------------------
newExec :: Settings -> Bus -> ConnectionBuilder -> Discovery -> IO Exec
newExec setts mainBus builder disc = do

  internal <- Internal <$> newIORef initServicePending
                       <*> newIORef initServicePending
                       <*> newTVarIO Init

  let stagePub = stageSTM $ _stageVar internal
      exe      = Exec setts stagePub internal (busProcessedEverything mainBus)
      hub      = asHub mainBus

  timerService hub
  connectionManager setts builder disc hub

  subscribe mainBus (onInit internal)
  subscribe mainBus (onInitFailed internal)
  subscribe mainBus (onFatal internal)
  subscribe mainBus (onTerminated internal)
  subscribe mainBus (onShutdown internal)

  publishWith mainBus SystemInit

  return exe

--------------------------------------------------------------------------------
onInit :: Internal -> Initialized -> EventStore ()
onInit Internal{..} (Initialized svc) = do
  $logInfo [i|Service #{svc} initialized|]
  initialized <- atomicModifyIORef' _initRef $ \m ->
    let m' = deleteMap svc m in
    (m', null m')

  when initialized $ do
    $logInfo "Entire system initialized properly"
    pub <- publisher
    atomically $ writeTVar _stageVar (Available pub)

--------------------------------------------------------------------------------
onInitFailed :: Internal -> InitFailed -> EventStore ()
onInitFailed Internal{..} (InitFailed svc) = do
  atomically $ errored _stageVar "Driver failed to initialized"
  $logError [i|Service #{svc} failed to initialize.|]
  stopBus
  $logError "System can't start."

--------------------------------------------------------------------------------
onFatal :: Internal -> FatalException -> EventStore ()
onFatal self@Internal{..} situation = do
  case situation of
    FatalException e ->
      $(logOther "Fatal") [i|Fatal exception: #{e}|]
    FatalCondition msg ->
      $(logOther "Fatal") [i|Driver is in unrecoverable state: #{msg}.|]

  shutdown self

--------------------------------------------------------------------------------
onTerminated :: Internal -> ServiceTerminated -> EventStore ()
onTerminated Internal{..} (ServiceTerminated svc) = do
  $logInfo [i|Service #{svc} terminated.|]
  terminated <- atomicModifyIORef' _finishRef $ \m ->
    let m' = deleteMap svc m in
    (m', null m')

  when terminated $ do
    $logInfo "Entire system shutdown properly"
    stopBus

--------------------------------------------------------------------------------
onShutdown :: Internal -> SystemShutdown -> EventStore ()
onShutdown Internal{..} _ =
  atomically $ writeTVar _stageVar (Errored "Connection closed")

--------------------------------------------------------------------------------
shutdown :: Internal -> EventStore ()
shutdown Internal{..} = do
  atomically $ writeTVar _stageVar (Errored "Connection closed")
  publish SystemShutdown
