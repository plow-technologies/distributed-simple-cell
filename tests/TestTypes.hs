{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
module TestTypes where

import GHC.Generics (Generic)
import Data.Aeson (FromJSON(..), ToJSON(..))
import Data.List (union)
import Data.Serialize
import Data.Text (pack, unpack)
import DirectedKeys.Types 

import Test.Tasty
import Test.Tasty.HUnit

import SimpleStore.Cell.Types
import SimpleStore.Cell.Distributed


newtype TestCellEntry = TestCellEntry (Int, Int) deriving (Eq, Show, Ord, Generic)

instance Serialize TestCellEntry where
  put (TestCellEntry (k, v)) = put k >> put v
  get = do k <- get
           v <- get
           return $ TestCellEntry (k, v)

instance SimpleCellState TestCellEntry where
  type SimpleCellKey TestCellEntry = Int
  type SimpleCellSrc TestCellEntry = ()
  type SimpleCellDst TestCellEntry = ()
  type SimpleCellDateTime TestCellEntry = ()
  simpleCellKey = CellKey { getKey = (\(TestCellEntry (k, _)) -> DKeyRaw k () () ())
                          , codeCellKeyFilename = (\(DKeyRaw k () () ()) -> pack $ show k)
                          , decodeCellKeyFilename = (\t -> Right $ DKeyRaw (read $ unpack t) () () ()) }


instance ToJSON TestCellEntry where

instance FromJSON TestCellEntry where
  

data CellHUnit = CellHUnit
  { cellHUnitRun :: forall urllist . (UrlList urllist) => LocalStoreM '[] urllist TestCellEntry ()
  , cellHUnitName :: String
  }

data CellSetup = forall urllist . (UrlList urllist) => CellSetup
  { cellSetup :: LocalStoreM '[] urllist TestCellEntry () -> IO ()
  , cellName :: String
  , cellTags :: [String]
  }

hunitCell :: CellHUnit -> CellSetup -> TestTree
hunitCell (CellHUnit {..}) (CellSetup {..}) = testCase (cellHUnitName ++ " - " ++ cellName) $ cellSetup cellHUnitRun

hunitCells :: CellHUnit -> [CellSetup] -> TestTree
hunitCells cellHUnit@(CellHUnit {..}) cellSetups = testGroup cellHUnitName $ map (hunitCell cellHUnit) cellSetups

allTests :: [CellHUnit] -> [CellSetup] -> TestTree
allTests cellHUnits cellSetups = testGroup "All tests" $ map (flip hunitCells cellSetups) cellHUnits

