{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
module Tests where

import Control.Monad (void)
import Control.Monad.IO.Class

import SimpleStore
import SimpleStore.Cell.Types
import SimpleStore.Cell.Distributed
import System.Random
import Test.Tasty.HUnit
import TestTypes

cellHUnits :: [CellHUnit]
cellHUnits = [testInsertGet, testInsertGetSpaced, testInsertLotsGet]

testInsertGet :: CellHUnit
testInsertGet = CellHUnit testInsertGet' "Insert/Get"

testInsertGet' :: (UrlList urllist) => LocalStoreM '[] urllist TestCellEntry ()

testInsertGet' = do
   entry <- liftIO $ makeRandomTestCellEntry
   eResult <- withStore entry $ \_lifter store -> do
     entry' <- getLocalStore store
     liftIO $ entry @=? entry'
   either (liftIO . assertFailure) (const $ return ()) eResult

testInsertGetSpaced :: CellHUnit
testInsertGetSpaced = CellHUnit testInsertGetSpaced' "Insert/Get Spaced"

testInsertGetSpaced' :: (UrlList urllist) => LocalStoreM '[] urllist TestCellEntry ()
testInsertGetSpaced' = do
  entry <- liftIO $ makeRandomTestCellEntry
  void $ withStore entry (const $ const $ return ())
  eResult <- withStore (unvalueTestCellEntry entry) $ \_lifter store -> do
    entry' <- getLocalStore store
    liftIO $ entry @=? entry'
  either (liftIO . assertFailure) (const $ return ()) eResult

testInsertLotsGet :: CellHUnit
testInsertLotsGet = CellHUnit testInsertLotsGet' "Insert Lots/Get"

testInsertLotsGet' :: (UrlList urllist) => LocalStoreM '[] urllist TestCellEntry ()
testInsertLotsGet' = do
  entries <- liftIO $ mapM (const makeRandomTestCellEntry) [1..100]
  entryIdx <- liftIO $ getStdRandom $ randomR (0, length entries - 1)
  let entry = entries !! entryIdx
  void $ withStores entries (const $ const $ return ())
  eResult <- withStore (unvalueTestCellEntry $ entry) $ \_lifter store -> do
    entry' <- getLocalStore store
    liftIO $ entry @=? entry'
  either (liftIO . assertFailure) (const $ return ()) eResult

unvalueTestCellEntry :: TestCellEntry -> TestCellEntry
unvalueTestCellEntry (TestCellEntry (k,_)) = TestCellEntry (k,0)
     
makeRandomTestCellEntry = do
  k <- getStdRandom $ random
  if k == 0 
    then makeRandomTestCellEntry
    else do
      v <- getStdRandom $ random
      return $ TestCellEntry (k, v)
