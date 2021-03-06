{-# LANGUAGE GADTs              #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE StandaloneDeriving #-}
--------------------------------------------------------------------------------
-- |
-- Module    :  Database.EventStore.Streaming
-- Copyright :  (C) 2018 Yorick Laupa
-- License   :  (see the file LICENSE)
-- Maintainer:  Yorick Laupa <yo.eight@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------------------
module Database.EventStore.Streaming
    ( ReadError(..)
    , Fetch(..)
    , ReadResultHandler(..)
    , readThroughForward
    , readThroughBackward
    , throwOnError
    , defaultReadResultHandler
    , onRegularStream
    , readThrough
    ) where

--------------------------------------------------------------------------------
import Control.Exception (Exception, throwIO)
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Typeable (Typeable)
import Prelude

--------------------------------------------------------------------------------
import           Control.Concurrent.Async.Lifted (wait)
import           Control.Monad.Except (ExceptT, throwError, runExceptT)
import           Data.Text (Text)
import           Streaming
import qualified Streaming.Prelude as Streaming

--------------------------------------------------------------------------------
import qualified Database.EventStore as ES

--------------------------------------------------------------------------------
data ReadError t where
    StreamDeleted :: ES.StreamName -> ReadError ES.EventNumber
    ReadError :: Maybe Text -> ReadError t
    AccessDenied :: ES.StreamId t -> ReadError t
    NoStream :: ReadError ES.EventNumber

--------------------------------------------------------------------------------
deriving instance Show (ReadError t)

--------------------------------------------------------------------------------
instance (Show t, Typeable t) => Exception (ReadError t)

--------------------------------------------------------------------------------
data Fetch t = FetchError !(ReadError t) | Fetch !(ES.Slice t)

--------------------------------------------------------------------------------
newtype ReadResultHandler =
  ReadResultHandler
  { runReadResultHandler :: forall t. ES.StreamId t -> ES.BatchResult t -> Fetch t }

--------------------------------------------------------------------------------
defaultReadResultHandler :: ReadResultHandler
defaultReadResultHandler = ReadResultHandler go
  where
    go :: ES.StreamId t -> ES.BatchResult t -> Fetch t
    go ES.StreamName{} = toFetch
    go ES.All          = Fetch

    toFetch ES.ReadNoStream          = Fetch ES.emptySlice
    toFetch ES.ReadNotModified       = Fetch ES.emptySlice
    toFetch (ES.ReadStreamDeleted n) = FetchError (StreamDeleted n)
    toFetch (ES.ReadError e)         = FetchError (ReadError e)
    toFetch (ES.ReadAccessDenied n)  = FetchError (AccessDenied n)
    toFetch (ES.ReadSuccess s)       = Fetch s

--------------------------------------------------------------------------------
onRegularStream :: (ES.ReadResult ES.EventNumber (ES.Slice ES.EventNumber) -> Fetch ES.EventNumber)
                -> ReadResultHandler
onRegularStream callback = ReadResultHandler go
  where
    go :: ES.StreamId t -> ES.BatchResult t -> Fetch t
    go ES.StreamName{} = callback
    go ES.All          = Fetch

--------------------------------------------------------------------------------
data State t = Need t | Fetched ![ES.ResolvedEvent] !(Maybe t)

--------------------------------------------------------------------------------
streaming :: (t -> IO (Fetch t))
          -> t
          -> Stream (Of ES.ResolvedEvent) (ExceptT (ReadError t) IO) ()
streaming iteratee = Streaming.unfoldr go . Need
  where
      go (Fetched buffer next) =
          case buffer of
            e:rest -> pure (Right (e, Fetched rest next))
            []     -> maybe stop (go . Need) next
      go (Need pos) = do
          liftIO (iteratee pos) >>= \case
              FetchError e -> throwError e
              Fetch s      ->
                  case s of
                      ES.SliceEndOfStream -> stop
                      ES.Slice xs next    -> go (Fetched xs next)

      stop = pure (Left ())

--------------------------------------------------------------------------------
-- | Returns an iterator able to consume a stream entirely. When reading forward,
--   the iterator ends when the last stream's event is reached.
readThroughForward :: ES.Connection
                   -> ES.StreamId t
                   -> ES.ResolveLink
                   -> t
                   -> Maybe Int32
                   -> Maybe ES.Credentials
                   -> Stream (Of ES.ResolvedEvent) (ExceptT (ReadError t) IO) ()
readThroughForward conn = readThrough conn defaultReadResultHandler ES.Forward

--------------------------------------------------------------------------------
-- | Returns an iterator able to consume a stream entirely. When reading backward,
--   the iterator ends when the first stream's event is reached.
readThroughBackward :: ES.Connection
                    -> ES.StreamId t
                    -> ES.ResolveLink
                    -> t
                    -> Maybe Int32
                    -> Maybe ES.Credentials
                    -> Stream (Of ES.ResolvedEvent) (ExceptT (ReadError t) IO) ()
readThroughBackward conn = readThrough conn defaultReadResultHandler ES.Backward

--------------------------------------------------------------------------------
-- | Throws an exception in case 'ExceptT' is a 'Left'.
throwOnError :: (Show t, Typeable t)
             => Stream (Of a) (ExceptT (ReadError t) IO) ()
             -> Stream (Of a) IO ()
throwOnError = hoist go
  where
    go action =
        runExceptT action >>= \case
            Left e  -> throwIO e
            Right a -> pure a

--------------------------------------------------------------------------------
-- | Returns an iterator able to consume a stream entirely.
readThrough :: ES.Connection
            -> ReadResultHandler
            -> ES.ReadDirection
            -> ES.StreamId t
            -> ES.ResolveLink
            -> t
            -> Maybe Int32
            -> Maybe ES.Credentials
            -> Stream (Of ES.ResolvedEvent) (ExceptT (ReadError t) IO) ()
readThrough conn handler dir streamId lnk from sizMay cred = streaming iteratee from
  where
    batchSize = fromMaybe 500 sizMay

    iteratee =
        case dir of
            ES.Forward  -> readForward conn handler streamId batchSize lnk cred
            ES.Backward -> readBackward conn handler streamId batchSize lnk cred

--------------------------------------------------------------------------------
readForward :: ES.Connection
            -> ReadResultHandler
            -> ES.StreamId t
            -> Int32
            -> ES.ResolveLink
            -> Maybe ES.Credentials
            -> t
            -> IO (Fetch t)
readForward conn handler streamId siz lnk creds start =
    fmap (runReadResultHandler handler streamId) . wait =<<
        ES.readEventsForward conn streamId start siz lnk creds

--------------------------------------------------------------------------------
readBackward :: ES.Connection
             -> ReadResultHandler
             -> ES.StreamId t
             -> Int32
             -> ES.ResolveLink
             -> Maybe ES.Credentials
             -> t
             -> IO (Fetch t)
readBackward conn handler streamId siz lnk creds start =
    fmap (runReadResultHandler handler streamId) . wait =<<
        ES.readEventsBackward conn streamId start siz lnk creds
