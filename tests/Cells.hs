{-# LANGUAGE DataKinds #-}
module Cells where


import Control.Concurrent
import Control.Concurrent.MVar

import Control.Monad.IO.Class

import Data.Monoid
import Data.Proxy
import Data.Text (pack)

import SimpleStore
import SimpleStore.Cell
import SimpleStore.Cell.Distributed
import System.Random
import System.Directory

import TestTypes


newtype TestEntry = TestEntry Int deriving (Eq, Ord, Show)

makeSimpleCell :: IO (SimpleCell Int () () () TestCellEntry (SimpleStore CellKeyStore))
makeSimpleCell = do
  name <- getName
  fmap (either (error . show) id) $ initializeSimpleCell (TestCellEntry (0, 0)) $ pack name
  where 
    getName = do
      name <- fmap show $ getStdRandom $ randomR (1 :: Int, 10 ^ 12 - 1) 
      nameExists <- doesFileExist name
      nameDirExists <- doesDirectoryExist name
      if nameExists || nameDirExists then
        getName
        else return name
  
cellSetups :: [CellSetup]
cellSetups =
  [ CellSetup (\act -> do 
                         simpleCell <- makeSimpleCell
                         withDistributedCell (DistributedCellSettings [] mempty simpleCell :: DistributedCellSettings '[] TestCellEntry) act) 
              "Simple Cell" ["simple"]
  , CellSetup (\act -> do
                         localCell <- makeSimpleCell
                         remoteCell <- makeSimpleCell
                         doneMVar <- newEmptyMVar
                         forkIO $ withDistributedCell (DistributedCellSettings [settingsFromBaseUrl $ BaseUrl Http "127.0.0.1" 5000 ] mempty remoteCell :: DistributedCellSettings '[] TestCellEntry) (liftIO $ takeMVar doneMVar)
                         withDistributedCell (DistributedCellSettings [] (Migration $ const $ Just $ MigrationHere Proxy) localCell :: DistributedCellSettings '[ '("127.0.0.1" , 5000) ] TestCellEntry) act
                         putMVar doneMVar ())

             "Migrate-Everything 2-Cell" ["migration", "2-cell"]
                         
  ]
