{-# LANGUAGE OverloadedStrings #-} -- For Aeson fields
{-# LANGUAGE DataKinds #-} -- For type-level literals in Servant API definition
{-# LANGUAGE TypeOperators #-} -- For the operators in Servant API definition
{-# LANGUAGE RecordWildCards #-} -- To help with Aeson instance definitions
{-# LANGUAGE TypeFamilies #-} -- To permit equality constraints
{-# LANGUAGE ConstraintKinds #-} -- For DistributedCellAPIConstraint

module SimpleStore.Cell.Distributed.REST
  (
  -- * Client
    retrieveStoreState
  , deleteStoreState
  , migrateStoreState
  -- * Server
  , serveDistributedCellAPI
  )
  where

import Control.Monad.Trans.Either
import Crypto.Hash.SHA512 (hashlazy)
import Data.Aeson
import Data.ByteString.Lazy (ByteString, fromStrict, toStrict)
import Data.Serialize (Serialize())
import Control.Applicative ((<$>))
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text.Encoding as TS (decodeUtf8, encodeUtf8)
import qualified Data.Text.Lazy.Encoding as TL (encodeUtf8, decodeUtf8)
import DirectedKeys (encodeKey)
import Network.Wai (Application)
import Servant.API
import Servant.Server
import Servant.Client
import SimpleStore.Cell.Types (CellKey(..), SimpleCellState(..), )

-- | A hash of a stored type
data StHash = StHash { stHash :: ByteString } deriving (Eq, Show, Ord)

instance FromJSON StHash where
  parseJSON = withObject "StHash must be an Object"
              (\obj -> StHash . TL.encodeUtf8 <$> obj .: "sthash")

instance ToJSON StHash where
  toJSON (StHash {..}) = object [ "sthash" .= TL.decodeUtf8 stHash ]

-- | Hash a value
makeStHash :: (ToJSON st) => st -> StHash
makeStHash = StHash . fromStrict . hashlazy . encode

-- | Check the hash of a value
checkStHash :: (ToJSON st) => st -> StHash -> Bool
checkStHash st (StHash {..}) = (== stHash) $ fromStrict $ hashlazy $ encode st

-- | The Servant API type of our body
type DistributedCellAPI st = "migrate"  :> ReqBody [st]           :> Post [StHash]
                        :<|> "retrieve" :> ReqBody [st]           :> Post (Maybe [st])
                        :<|> "delete"   :> ReqBody [st]           :> Post ()

-- | Proxy for the distributed cell API
distributedCellAPI :: Proxy (DistributedCellAPI st)
distributedCellAPI = Proxy

-------------------------------------------------------------------------------
-- The following ugliness is necessitated by how HM languages handle type    --
-- variables. We can't use a top-level pattern match here :(                 --
-------------------------------------------------------------------------------

-- | Given a base URL, send the given
--   store states to the remote distributed store at the base URL, and
--   receive hashes of them if they are successfully stored
migrateStoreStateREST :: (Eq st, ToJSON st, FromJSON st) => [st] -> BaseUrl -> EitherT String IO [StHash]
migrateStoreStateREST = getMSSR $ client distributedCellAPI
  where
    getMSSR (mssr :<|> _ :<|> _) = mssr

-- | Retrieve a stored state, possibly through several layers of indirection
retrieveStoreStateREST :: (Eq st, ToJSON st, FromJSON st) => [st] -> BaseUrl -> EitherT String IO (Maybe [st])
retrieveStoreStateREST = getRSSR $ client distributedCellAPI
  where
    getRSSR (_ :<|> rssr :<|> _) = rssr

-- | Write to a stored state, possibly through several layers of indirection
deleteStoreStateREST :: (Eq st, ToJSON st, FromJSON st) => [st] -> BaseUrl -> EitherT String IO ()
deleteStoreStateREST = getDSSR $ client distributedCellAPI
  where
    getDSSR (_ :<|> _ :<|> dssr) = dssr

-- | Replicate store states to a remote server
migrateStoreState :: (Show st, Eq st, ToJSON st, FromJSON st) 
                  => BaseUrl              -- ^ The URL of the distributed cell to migrate to
                  -> [st]                 -- ^ The states to migrate
                  -> EitherT String IO () -- ^ Unit if successful, error message if unsuccessful
migrateStoreState url sts = do
  storeHashes <- migrateStoreStateREST sts url
  if length storeHashes == length sts
    then let unmatchedHashes = filter (not . uncurry checkStHash) $ zip sts storeHashes
         in if null unmatchedHashes
              then right ()
              else left $ "Some hashes did not match: " ++ show unmatchedHashes
    else left $ "Number of returned hashes did not match number of sent states: " ++ (show . length) sts ++ " states vs. " ++ (show . length) storeHashes ++ " hashes."

-- | Retrieve a store state from a remote server
retrieveStoreState :: (Eq st, ToJSON st, FromJSON st)
                   => BaseUrl                        -- ^ URL for distributed cell to get from
                   -> [st]                           -- ^ Instance of state type with key matching desired state's key
                   -> EitherT String IO (Maybe [st]) -- ^ Left if there were errors with the request, Right Nothing if the key was not found, Right Just if the state was found
retrieveStoreState url st = retrieveStoreStateREST st url

-- | Delete a store state on a remote server, proving you have the latest version
deleteStoreState :: (Eq st, ToJSON st, FromJSON st)
                 => BaseUrl              -- ^ URL for the distributed cell to post to
                 -> [st]                 -- ^ State to update
                 -> EitherT String IO () -- ^ Left on error, Right False if no matching state was found to update, Right True if the update was successful
deleteStoreState url st = deleteStoreStateREST st url

-- | Low level WAI application for serving the api
serveDistributedCellAPIREST ::  (Eq st, ToJSON st, FromJSON st)
                            => ([st] -> EitherT (Int, String) IO [StHash])
                            -> ([st] -> EitherT (Int, String) IO (Maybe [st]))
                            -> ([st] -> EitherT (Int, String) IO ())
                            -> Application
serveDistributedCellAPIREST migrateHandler retrieveHandler deleteHandler = serve distributedCellAPI $ migrateHandler :<|> retrieveHandler :<|>  deleteHandler

-- | WAI application for serving the api
serveDistributedCellAPI :: (Eq st, FromJSON st, ToJSON st)
                        => ([st] -> EitherT (Int, String) IO [st]) -- ^ Handler for migrations. Should return list of successfully stored states in the same order as input list of states
                        -> ([st] -> EitherT (Int, String) IO (Maybe [st])) -- ^ Handler for store retrieval. Should return the store state if the store is present, or Nothing otherwise.
                        -> ([st] -> EitherT (Int, String) IO ()) -- ^ Handler for store deletes.
                        -> Application
serveDistributedCellAPI migrateHandler retrieveHandler deleteHandler =
  serveDistributedCellAPIREST
    (fmap (map makeStHash) . migrateHandler) -- Hash the states for return
    retrieveHandler
    deleteHandler

