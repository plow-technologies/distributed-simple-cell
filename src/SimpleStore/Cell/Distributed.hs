{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
module SimpleStore.Cell.Distributed (withDistributedCell, withStore, withStores, DistributedCellSettings(..), LocalStoreM(), LocalStore(), putLocalStore, getLocalStore, UrlList(), MigrationIndex(..), Migration(..), setSettingsBaseUrl, settingsFromBaseUrl, BaseUrl(..), Scheme(..)) where

import Control.Exception (bracket)
import Control.Monad (mplus)
import Control.Monad.Reader (runReaderT, ask, asks, liftIO, lift)
import Control.Monad.Trans.Either (EitherT(..), runEitherT)
import Data.Aeson (FromJSON(), ToJSON())
import Data.Maybe (listToMaybe)
import Network.Wai.Handler.Warp (Settings())
import Servant.Common.BaseUrl
import SimpleStore
import SimpleStore.Cell.Types
import SimpleStore.Cell.Distributed.Types
import SimpleStore.Cell.Distributed.Migration
import qualified STMContainers.Set as STMSet

withDistributedCell :: (SimpleCellConstraint c k src dst tm st, ToJSON st, FromJSON st, Eq st, Show st) => DistributedCellSettings urllist st -> LocalStoreM '[] urllist st a -> IO a
withDistributedCell cellSettings (LocalStoreM cellAction) = 
  flip runReaderT cellSettings $ bracketServers $ cellAction

withStore :: (SimpleCellConstraint c k src dst tm st, ToJSON st, FromJSON st, Eq st, Show st, UrlList urllist) => st -> (forall (phantom :: *) . (LocalStoreM stack urllist st a -> LocalStoreM (phantom ': stack) urllist st a) -> LocalStore (phantom ': stack) st -> LocalStoreM (phantom ': stack) urllist st a) -> LocalStoreM stack urllist st (Either String a) 
withStore state storeAction = LocalStoreM $ do
  localCell <- asks localCell
  runEitherT $ do
    stateStore <-
              (EitherT $ liftIO $ fmap (maybe (Left "Store not found locally") Right)
                       $ getStore localCell state)
      `mplus` (EitherT $ tryRetrieveStore state 
                         (\storeState -> liftIO $ insertStore localCell storeState 
                                                  >>= either (return . Left . show) (return . Right)))
      `mplus` (EitherT $ liftIO $ fmap (either (Left . show) Right)
                       $ insertStore localCell state)
    lift $ unLocalStoreM $ storeAction (LocalStoreM . unLocalStoreM) $ LocalStore stateStore

withStores :: (SimpleCellConstraint c k src dst tm st, ToJSON st, FromJSON st, Eq st, Show st, UrlList urllist) => [st] ->
  (forall (phantom :: *)  . (LocalStoreM stack urllist st a -> LocalStoreM (phantom ': stack) urllist st a) -> [(st, LocalStore (phantom ': stack) st)] -> LocalStoreM (phantom ': stack) urllist st a) -> LocalStoreM stack urllist st (Either String a)
withStores states storesAction = LocalStoreM $ do
  localCell <- asks localCell
  runEitherT $ do
    stateStores <- mapM (\state -> 
                                  (EitherT $ liftIO $ fmap (maybe (Left "Store not found locally") Right)
                                           $ getStore localCell state)
                          `mplus` (EitherT $ tryRetrieveStore state 
                                             (\storeState -> liftIO $ insertStore localCell storeState 
                                                                      >>= either (return . Left . show) (return . Right)))
                          `mplus` (EitherT $ liftIO $ fmap (either (Left . show) Right)
                                           $ insertStore localCell state)) states

    lift $ unLocalStoreM $ storesAction (LocalStoreM . unLocalStoreM) $ zip states $ map LocalStore stateStores

getLocalStore :: LocalStore stack st -> LocalStoreM stack urllist st st
getLocalStore (LocalStore st) = liftIO $ getSimpleStore st

putLocalStore :: LocalStore stack st -> st -> LocalStoreM stack urllist st ()
putLocalStore (LocalStore st) x = liftIO $ putSimpleStore st x

bracketServers :: (SimpleCellConstraint c k src dst tm st, ToJSON st, FromJSON st, Eq st, Show st) => DistributedCellM urllist st a -> DistributedCellM urllist st a
bracketServers action = do
  listeners <- asks listeners
  foldr bracketServer action listeners

-- | Run a distributed cell server for the duration of the given IO action, kill it after
bracketServer :: (SimpleCellConstraint c k src dst tm st, ToJSON st, FromJSON st, Eq st, Show st) => Settings -> DistributedCellM urllist st a -> DistributedCellM urllist st a
bracketServer serverSettings action = do
    cellSettings <- ask
    liftIO
      $ bracket
          (flip runReaderT cellSettings $ forkDistributedCellServer serverSettings)
          (\stopAction -> runReaderT stopAction cellSettings)
          (const $ runReaderT action cellSettings)

