module Main where

import Test.Tasty
import TestTypes
import Cells
import Tests

main :: IO ()
main = do defaultMain $ allTests cellHUnits cellSetups
