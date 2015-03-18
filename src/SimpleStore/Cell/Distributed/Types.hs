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
         CustomCell(..)
       , UrlsConstraint
       , migrationIndexToBaseUrl
       , proxyToBaseUrl
       , proxyToBaseUrlList
       , MigrationIndex(..)
       , Migration(..)
       , DistributedCellSettings(..)
       , DistributedCellM
       , DistributedHandlerM
       , SimpleCellConstraint
       , Distributed(..)
       , DistributedCellConstraint
       , MigrationBatchSize(..)
       , setSettingsBaseUrl
       , settingsFromBaseUrl
       , Queryable(..)
       , DistributedCellAPIConstraint
       ) where

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

data CustomCell cell k src dst tm st =
  CustomCell
    { customInsertStore :: cell -> st -> IO (Either StoreError (SimpleStore st))
    , customGetStore :: cell -> st -> IO (Maybe (SimpleStore st))
    , customUpdateStore :: cell -> SimpleStore st -> st -> IO ()
    , customDeleteStore :: cell -> st -> IO ()
    , customFoldrStoreWithKey :: forall b . cell -> (CellKey k src dst tm st -> DirectedKeyRaw k src dst tm -> st -> IO b -> IO b) -> IO b -> IO b
    , customTraverseStoreWithKey_ :: cell -> (CellKey k src dst tm st -> DirectedKeyRaw k src dst tm -> st -> IO ()) -> IO ()
    , customCell :: cell }

instance (CellConstraint k src dst tm st cell) => Cell (CustomCell cell k src dst tm st) where
  type CellLiveStateType (CustomCell cell k src dst tm st) = CellLiveStateType cell
  type CellDormantStateType (CustomCell cell k src dst tm st) = CellDormantStateType cell
  insertStore (CustomCell {..}) = customInsertStore customCell
  updateStore (CustomCell {..}) = customUpdateStore customCell
  deleteStore (CustomCell {..}) = customDeleteStore customCell
  getStore    (CustomCell {..}) = customGetStore customCell
  foldrStoreWithKey (CustomCell {..}) = customFoldrStoreWithKey customCell
  traverseStoreWithKey_ (CustomCell {..}) = customTraverseStoreWithKey_ customCell

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
  MigrationQueuesCons  :: TVar [st] -> MigrationQueues ('(url, port) ': rest) st

-- | Monad in which to implement the distributed simple cell
type DistributedCellM urllist st a = ReaderT (DistributedCellSettings urllist st) IO a

-- | Monad in which to implement HTTP components of a distributed simple cell
type DistributedHandlerM urllist st a = ReaderT (DistributedCellSettings urllist st) (EitherT (Int, String) IO) a


-- | Constraint for SimpleCell
type SimpleCellConstraint cell k src dst tm st = (cell ~ SimpleCell k src dst tm st (SimpleStore CellKeyStore),
                                     CellConstraint k src dst tm st cell)

-- | Operation to force a store to be local for some operations
class Cell c => Distributed c where
  withLocalStore :: CellLiveStateType c -> (SimpleStore c -> IO a) -> IO a

-- | Constraint on input to bracketed function for distributed cell
type DistributedCellConstraint cell k src dst tm st = (Distributed cell, CellConstraint k src dst tm st cell)

class MigrationBatchSize st where
  -- | How many of a thing to queue up before migrating them
  migrationBatchSize :: Proxy st -> Int

-- | Type of queries on a state
class Queryable st where
  type QueryType st
  runQuery :: (Cell c, CellLiveStateType c ~ st) => c -> QueryType st -> IO [st]

-- | 
type DistributedCellAPIConstraint q st = (Queryable st, q ~ QueryType st, FromJSON st, ToJSON st, FromJSON q, ToJSON q)

-- | Set the hostname and port for a Warp Settings record from a BaseUrl
setSettingsBaseUrl :: BaseUrl -> Settings -> Settings
setSettingsBaseUrl (BaseUrl {..}) = setHost (fromString baseUrlHost) . setPort baseUrlPort

-- | Create a default Warp Settings record with a hostname and port from a BaseUrl
settingsFromBaseUrl :: BaseUrl -> Settings
settingsFromBaseUrl = flip setSettingsBaseUrl defaultSettings


