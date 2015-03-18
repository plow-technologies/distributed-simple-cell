{-# LANGUAGE RecordWildCards #-}     -- For pulling apart settings records, urls, etc
{-# LANGUAGE RankNTypes #-}          -- For parametricity on the input to withDistributedCell
{-# LANGUAGE ConstraintKinds #-}     -- For constraint tuples from simple-cell-types
{-# LANGUAGE TypeFamilies #-}        -- For type families from simple-cell-types
{-# LANGUAGE DataKinds #-}           -- For type level list of migration urls
{-# LANGUAGE TypeOperators #-}       -- For type level list of migration urls
{-# LANGUAGE GADTs #-}               -- For type level list of migration urls
{-# LANGUAGE ScopedTypeVariables #-} -- For type level list of migration urls
{-# LANGUAGE KindSignatures #-}      -- For type level list of migration urls
{-# LANGUAGE UndecidableInstances #-} -- For type level list of migration urls

module SimpleStore.Cell.Distributed.Migration
       (
         setSettingsBaseUrl
       , settingsFromBaseUrl
       , migrationDestinations
       , doMigrations
       , runDistributedCellServer
       ) where

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (forkIO, ThreadId)
import Control.Concurrent.MVar
import Control.Monad.Error.Class (catchError)
import Control.Monad.Reader
import Control.Monad.Trans.Either (EitherT(..), bimapEitherT, left)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Aeson
import Data.MultiMap (fromList, assocs)
import Data.Maybe (mapMaybe)
import Network.Wai.Handler.Warp
import SimpleStore
import SimpleStore.Cell.Distributed.REST
import SimpleStore.Cell.Distributed.Types
import SimpleStore.Cell.Types
import Servant.Common.BaseUrl

-- | Partition things by migration URL
migrationDestinations :: (UrlsConstraint urllist) => Migration urllist st -> [st] -> [(BaseUrl, [st])]
migrationDestinations migration = assocs . fromList . mapMaybe (\state -> fmap (\url -> (url, state)) $ fmap migrationIndexToBaseUrl $ checkMigration migration state)


-- | Run the filter function over the store and migrate matching states
doMigrations :: (Show st, FromJSON st, ToJSON st, Eq st, SimpleCellConstraint cell k src dst tm st, UrlsConstraint urllist) => Migration urllist st -> DistributedCellM urllist st ()
doMigrations migration = do
  localCell <- asks localCell
  states <- liftIO $ foldrStoreWithKey
                       localCell
                       (\_ _ stLive statesAction -> fmap (stLive :) statesAction)
                       (return [])
  let migrationsWithDestinations = migrationDestinations migration states
  liftIO $ runEitherT (do mapM_ (uncurry migrateStoreState) migrationsWithDestinations
                          liftIO $ mapM_ (mapM_ (deleteStore localCell) . snd) migrationsWithDestinations)
           >>= either (const $ return ()) (const $ return ())

-- | Fork a thread in a Reader-IO monad stack
forkReader :: ReaderT r IO () -> ReaderT r IO ThreadId
forkReader readerThread = do
  r <- ask
  liftIO $ forkIO $ runReaderT readerThread r

-- | Fork a Warp server exposing the REST API for migration
forkDistributedCellServer :: (Eq st, FromJSON st, ToJSON st, SimpleCellConstraint cell k src dst tm st) => Settings -> DistributedCellM urllist st (DistributedCellM urllist st ())
forkDistributedCellServer warpSettings = do
  startStopMVar <- liftIO $ newEmptyMVar -- Unblocks on server start, server stops when contained action runs
  let warpSettings' = setInstallShutdownHandler (putMVar startStopMVar) warpSettings
  _ <- forkReader $ runDistributedCellServer warpSettings'
  fmap liftIO $ liftIO $ takeMVar startStopMVar

-- | Run a Warp server exposing the REST API for migration
runDistributedCellServer :: (Eq st, FromJSON st, ToJSON st, SimpleCellConstraint cell k src dst tm st) => Settings -> DistributedCellM urllist st ()
runDistributedCellServer warpSettings =
    (serveDistributedCellAPI
     <$> liftHandler handleMigrateStore
     <*> liftHandler handleRetrieveStore
     <*> liftHandler handleDeleteStore) >>= (liftIO . runSettings warpSettings)

-- | Propagates the settings from the DistributedCellM context to the DistributedHandlerM context,
--   and gives back an EitherT action which is suitable for passing to serveDistributedCellAPI
liftHandler :: (a -> DistributedHandlerM urllist st b) -> DistributedCellM urllist st (a -> EitherT (Int, String) IO b)
liftHandler handler = do
 distributedCellSettings <- ask
 return (\x -> runReaderT (handler x) distributedCellSettings)

-- | Make a handler from an EitherT with just strings, by adding in the Internal Server Error code
makeHandler :: EitherT String IO a -> DistributedHandlerM urlist st a
makeHandler = lift . bimapEitherT (\err -> (500, err)) id

-- | Insert a new store with a value, or overwrite the stored value if the value's key is already present in the cell
getOrInsertStore :: (SimpleCellConstraint cell k src dst tm st) => st -> DistributedHandlerM urllist st ()
getOrInsertStore state = do
  localCell <- asks localCell
  (liftIO $ getStore localCell state) >>=
    flip maybe (liftIO . flip putSimpleStore state) (void $ makeHandler $ bimapEitherT show id $ EitherT $ insertStore localCell state)

-- | Handler for migrations: Write or overwrite
handleMigrateStore :: (SimpleCellConstraint cell k src dst tm st) => [st] -> DistributedHandlerM urlist st [st]
handleMigrateStore states =
  mapM (\st -> getOrInsertStore st >> return st) states

-- | Handler for store gets
handleRetrieveStore :: (SimpleCellConstraint cell k src dst tm st) => [st] -> DistributedHandlerM urllist st (Maybe [st])
handleRetrieveStore keyStates = do
  localCell <- asks localCell
  runMaybeT $ mapM (MaybeT . liftIO . getStore localCell) keyStates >>= (liftIO . mapM getSimpleStore)

-- | Handler for store deletes
handleDeleteStore :: (Eq st, SimpleCellConstraint cell k src dst tm st) => [st] -> DistributedHandlerM urllist st ()
handleDeleteStore keyStates = do
  localCell <- asks localCell
  (runMaybeT $ do
     localStores <- mapM (MaybeT . liftIO . getStore localCell) keyStates
     localStates <- liftIO $ mapM getSimpleStore localStores
     if and $ zipWith (==) localStates keyStates
       then liftIO $ mapM_ (deleteStore localCell) keyStates
       else lift $ lift $ left (409, "Store state does not match, most likely not most recent state")) >>=
    maybe (lift $ left (404, "Store not found")) (return)

