{-# LANGUAGE OverloadedStrings #-} -- For Aeson fields
{-# LANGUAGE DataKinds #-} -- For type-level literals in Servant API definition
{-# LANGUAGE TypeOperators #-} -- For the operators in Servant API definition
{-# LANGUAGE RecordWildCards #-} -- To help with Aeson instance definitions
{-# LANGUAGE TypeFamilies #-} -- To permit equality constraints

module SimpleStore.Cell.Distributed.REST 
  (
    getStoreState
  , postStoreState
  , migrateStoreState
  )
  where

import Control.Monad.Trans.Either
import Crypto.Hash.SHA512 (hashlazy)
import Data.Aeson 
import Data.ByteString.Lazy (ByteString, fromStrict)
import Data.Serialize (Serialize())
import Control.Applicative ((<$>))
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text.Encoding as TS (decodeUtf8)
import qualified Data.Text.Lazy.Encoding as TL (encodeUtf8, decodeUtf8)
import DirectedKeys (encodeKey)
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
type DistributedCellAPI st = "migrate" :> ReqBody [st] :> Post [StHash]
                        :<|> "store" :> QueryParam "stkey" Text :> Get (Maybe st)
                        :<|> "store" :> ReqBody st :> Post (Maybe StHash)

distributedCellAPI :: Proxy (DistributedCellAPI st)
distributedCellAPI = Proxy



-------------------------------------------------------------------------------
-- The following ugliness is necessitated by how HM languages handle type    --
-- variables. We can't use a top-level pattern match here :(                 --
-------------------------------------------------------------------------------

-- | Given a base URL, send the given
--   store states to the remote distributed store at the base URL, and
--   receive hashes of them if they are successfully stored
migrateStoreStateREST :: (FromJSON st, ToJSON st) => [st] -> BaseUrl -> EitherT String IO [StHash] 
migrateStoreStateREST = getRSSR $ client distributedCellAPI
  where
    getRSSR (rssr :<|> _ :<|> _) = rssr

-- | Retrieve a stored state, possibly through several layers of indirection
getStoreStateREST :: (FromJSON st, ToJSON st) => Maybe Text -> BaseUrl -> EitherT String IO (Maybe st)
getStoreStateREST = getGSSR $ client distributedCellAPI
  where
    getGSSR (_ :<|> gssr :<|> _) = gssr

-- | Write to a stored state, possibly through several layers of indirection
postStoreStateREST :: (FromJSON st, ToJSON st) => st -> BaseUrl -> EitherT String IO (Maybe StHash)
postStoreStateREST = getPSSR $ client distributedCellAPI
  where
    getPSSR (_ :<|> _ :<|> pssr) = pssr



-- | Replicate store states to a remote server
migrateStoreState :: (FromJSON st, ToJSON st, Show st)
                  => BaseUrl              -- ^ The URL of the distributed cell to migrate to
                  -> [st]                 -- ^ The states to migrate
                  -> EitherT String IO () -- ^ Unit if successful, error message if unsuccessful
migrateStoreState url sts = do
  storeHashes <- migrateStoreStateREST sts url
  if length storeHashes == length sts
    then let unmatchedHashes = filter (uncurry checkStHash) $ zip sts storeHashes
         in if null unmatchedHashes
              then right ()
              else left $ "Some hashes did not match: " ++ show unmatchedHashes
    else left $ "Number of returned hashes did not match number of sent states: " ++ (show . length) sts ++ " states vs. " ++ (show . length) storeHashes ++ " hashes."

-- | Get a store state from a remote server
getStoreState :: ( FromJSON st
                 , ToJSON st
                 , SimpleCellState st
                 , key ~ SimpleCellKey st
                 , src ~ SimpleCellSrc st
                 , dst ~ SimpleCellDst st
                 , tm  ~ SimpleCellDateTime st 
                 , Serialize key
                 , Serialize src
                 , Serialize dst
                 , Serialize tm)
              => BaseUrl -- ^ URL for distributed cell to get from
              -> st      -- ^ Instance of state type with key matching desired state's key
              -> EitherT String IO (Maybe st) -- ^ Left if there were errors with the request, Right Nothing if the key was not found, Right Just if the state was found
getStoreState url st = 
  let
    stKey = Just $ TS.decodeUtf8 $ encodeKey $ getKey simpleCellKey st
  in getStoreStateREST stKey url

-- | Update a store state on a remote server
postStoreState :: (FromJSON st, ToJSON st, Show st)
               => BaseUrl                -- ^ URL for the distributed cell to post to
               -> st                     -- ^ State to update
               -> EitherT String IO Bool -- ^ Left on error, Right False if no matching state was found to update, Right True if the update was successful
postStoreState url st = 
  postStoreStateREST st url >>=
  maybe (right False) (\storeHash -> if checkStHash st storeHash then right True else left $ "Hash does not match: " ++ show (st, storeHash))
