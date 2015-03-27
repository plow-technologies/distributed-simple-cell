{-# LANGUAGE RecordWildCards #-}     -- For picking apart DistributedCellSettings etc
{-# LANGUAGE RankNTypes #-}          -- For explicit foralls in CustomCell
{-# LANGUAGE ConstraintKinds #-}     -- For constraint tuples from simple-cell-types
{-# LANGUAGE TypeFamilies #-}        -- For type families from simple-cell-types
{-# LANGUAGE DataKinds #-}           -- For type level list of migration urls
{-# LANGUAGE TypeOperators #-}       -- For type level list of migration urls
{-# LANGUAGE GADTs #-}               -- For type level list of migration urls
{-# LANGUAGE ScopedTypeVariables #-} -- For type level list of migration urls
{-# LANGUAGE KindSignatures #-}      -- For type level list of migration urls
{-# LANGUAGE UndecidableInstances #-} -- For type level list of migration urls

module SimpleStore.Cell.Distributed.Types
       (
         UrlsConstraint
       , migrationIndexToBaseUrl
       , proxyToBaseUrl
       , UrlList(..)
       , MigrationIndex(..)
       , MigrationQueues(..)
       , Migration(..)
       , DistributedCellSettings(..)
       , DistributedCellM
       , DistributedHandlerM
       , SimpleCellConstraint
       , Distributed(..)
       , DistributedCellConstraint
       , MigrationBatchSize(..)
       , LocalStoreM (..)
       , LocalStore (..)
       , setSettingsBaseUrl
       , settingsFromBaseUrl
       ) where

import Control.Applicative
import Control.Concurrent.STM
import Control.Monad.Reader
import Control.Monad.Trans.Either (EitherT(..), bimapEitherT, left)
import Data.Aeson (FromJSON(), ToJSON())
import Data.Monoid (Monoid(..), First(..))
import Data.Proxy (Proxy(..))
import Data.String (IsString(..))
import DirectedKeys.Types
import GHC.TypeLits
import GHC.Exts (Constraint)
import Network.Wai.Handler.Warp (Settings, defaultSettings, setHost, setPort)
import SimpleStore
import SimpleStore.Cell.Types
import Servant.Common.BaseUrl

data MigrationIndex :: [(Symbol, Nat)] -> * where
  MigrationHere :: Proxy '((url :: Symbol), (port :: Nat)) -> MigrationIndex ('(url, port) ': rest)
  MigrationThere :: MigrationIndex rest -> MigrationIndex ('(url, port) ': rest)

proxyToBaseUrl :: forall (url :: Symbol) (port :: Nat) . (KnownSymbol url, KnownNat port) => Proxy '(url, port) -> BaseUrl
proxyToBaseUrl Proxy = BaseUrl Http (symbolVal (Proxy :: Proxy url)) (fromIntegral $ natVal (Proxy :: Proxy port))

type family UrlsConstraint (urls :: [(Symbol, Nat)]) :: Constraint where
  UrlsConstraint ('(url, port) ': rest) = (KnownSymbol url, KnownNat port, UrlsConstraint rest) 
  UrlsConstraint ('[]) = () 


migrationIndexToBaseUrl :: (UrlsConstraint urlports) => MigrationIndex urlports -> BaseUrl
migrationIndexToBaseUrl (MigrationHere proxy) = proxyToBaseUrl proxy
migrationIndexToBaseUrl (MigrationThere migrationIndexRest) = migrationIndexToBaseUrl migrationIndexRest

class UrlList (urlportlist :: [(Symbol, Nat)]) where
  proxyToBaseUrlList :: Proxy urlportlist -> [BaseUrl]

instance UrlList '[] where
  proxyToBaseUrlList Proxy = []

instance (urlport ~ '(url, port), KnownSymbol url, KnownNat port, UrlList rest) => UrlList (urlport ': rest) where
  proxyToBaseUrlList Proxy = proxyToBaseUrl (Proxy :: Proxy urlport) : proxyToBaseUrlList (Proxy :: Proxy rest)

-- | What things to migrate where
newtype Migration urllist st = Migration { checkMigration :: st -> Maybe (MigrationIndex urllist) }

instance Monoid (Migration urllist st) where
  mempty = Migration $ const Nothing
  mappend (Migration migrationPred1) (Migration migrationPred2) = Migration (\state -> getFirst $ (First $ migrationPred1 state) `mappend` (First $ migrationPred2 state))

-- | Settings for a distributed cell
data DistributedCellSettings urllist st =
  DistributedCellSettings
    { listeners :: [Settings] -- ^ Settings for Warp servers serving the REST api
    , migration :: Migration urllist st -- ^ Migration via the REST api
    , localCell :: SimpleCell (SimpleCellKey st) (SimpleCellSrc st) (SimpleCellDst st) (SimpleCellDateTime st) st (SimpleStore CellKeyStore) -- ^ Local storage
    }

data MigrationQueues :: [(Symbol, Nat)] -> * -> * where
  MigrationQueuesEmpty :: MigrationQueues '[] st
  MigrationQueuesCons  :: TVar [st] -> MigrationQueues rest st -> MigrationQueues ('(url, port) ': rest) st

-- | Monad in which to implement the distributed simple cell
type DistributedCellM urllist st a = ReaderT (DistributedCellSettings urllist st) IO a

-- | Monad in which to implement HTTP components of a distributed simple cell
type DistributedHandlerM urllist st a = ReaderT (DistributedCellSettings urllist st) (EitherT (Int, String) IO) a


-- | Constraint for SimpleCell
type SimpleCellConstraint cell k src dst tm st = (cell ~ SimpleCell k src dst tm st (SimpleStore CellKeyStore),
                                     CellConstraint k src dst tm st cell)

-- | Operation to force a store to be local for some operations
class Cell c => Distributed c where
  withLocalStore :: c -> CellLiveStateType c -> (SimpleStore (CellLiveStateType c) -> IO a) -> IO a

-- | Constraint on input to bracketed function for distributed cell
type DistributedCellConstraint cell k src dst tm st = (Distributed cell, CellConstraint k src dst tm st cell)

class MigrationBatchSize st where
  -- | How many of a thing to queue up before migrating them
  migrationBatchSize :: Proxy st -> Int

-- | Set the hostname and port for a Warp Settings record from a BaseUrl
setSettingsBaseUrl :: BaseUrl -> Settings -> Settings
setSettingsBaseUrl (BaseUrl {..}) = setHost (fromString baseUrlHost) . setPort baseUrlPort

-- | Create a default Warp Settings record with a hostname and port from a BaseUrl
settingsFromBaseUrl :: BaseUrl -> Settings
settingsFromBaseUrl = flip setSettingsBaseUrl defaultSettings

newtype LocalStoreM (stack :: [*]) urllist st a = LocalStoreM { unLocalStoreM :: DistributedCellM urllist st a }

instance Functor (LocalStoreM stack urllist st) where
  fmap f = LocalStoreM . fmap f . unLocalStoreM

instance Applicative (LocalStoreM stack urllist st) where
  pure = LocalStoreM . pure
  (<*>) (LocalStoreM f) (LocalStoreM x) = LocalStoreM $ f <*> x

instance Monad (LocalStoreM stack urllist st) where
  return = LocalStoreM . return
  (LocalStoreM action) >>= f = LocalStoreM $ action >>= unLocalStoreM . f

newtype LocalStore (stack :: [*]) st = LocalStore (SimpleStore st)


