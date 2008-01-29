-- ----------------------------------------------------------------------------

{- |
  Module     : DiffListTest
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.1

  The some unit tests for the difference encoding of numbers.

-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -fno-warn-missing-signatures #-}

module DiffListTest (allTests, allProperties) where

import Data.List

import qualified Data.IntSet as IS

import qualified Holumbus.Data.DiffList as DL

import Test.HUnit
import Test.QuickCheck
import Test.QuickCheck.Batch

tests :: [(String, [Int])]
tests = 
  [ ("Simple sequence", [1,2,3,4,5,6,7,8,9])
  , ("Simple sequence with zero", [0,1,2,3,4,5,6,7,8,9])
  , ("Very long sequence", [1..100000])
  , ("Big gaps", [10000,20000,30000,40000,50000,60000,70000])
  , ("Big and small gaps", [10000,10001,20000,20002,30000,30003,40000,40004])
  , ("Random numbers", [3454,9874,21,6187,384,13,984,617,42,313])
  ]

specialTests :: Test
specialTests = TestList 
  [ TestCase (assertEqual "Negative elements will overflow"
    [65527,65528,65529,65530,65531,65532,65533,65534,65535]
    $ DL.toList . DL.fromList $ [(-1),(-2),(-3),(-4),(-5),(-6),(-7),(-8),(-9)])
    
  , TestCase (assertEqual "Equal elements"
    [1,2,3,3,4,4,5,5,6,6,7,7,8,9]
    $ DL.toList . DL.fromList $ [1,3,2,4,3,5,4,6,5,7,6,8,7,9])

  , TestCase (assertEqual "Exceeding range with first element"
    [0,1,2]
    $ DL.toList . DL.fromList $ [65536,65537,65538])

  , TestCase (assertEqual "Exceeding range with second element"
    [1,1,2]
    $ DL.toList . DL.fromList $ [1,65537,65538])
  ]
  
listTests :: Test
listTests = TestList $ map makeListTest tests
  where
  makeListTest (desc, values) = TestCase 
    (assertEqual desc (sort values) ((DL.toList . DL.fromList) values))
  
intSetTests :: Test
intSetTests = TestList $ map makeIntSetTest tests
  where
  makeIntSetTest (desc, values) = TestCase 
    (assertEqual desc (sort values) ((IS.toList . DL.toIntSet . DL.fromIntSet . IS.fromList) values))

valid :: (Ord a, Num a) => [a] -> Bool
valid [] = True
valid (x:xs) = (x <= 65535) && (x >= 0) && (valid xs)

prop_FromToList xs = valid xs ==> DL.toList (DL.fromList xs) == (sort xs)
prop_FromToIntSet xs = valid xs ==> DL.toIntSet (DL.fromIntSet (IS.fromList xs)) == (IS.fromList xs)
prop_EqListSet xs = valid xs ==> DL.toIntSet (DL.fromList $ nub xs) == IS.fromList xs

allProperties :: (String, [TestOptions -> IO TestResult])
allProperties = ("DiffList tests",
                [ run prop_FromToList
                , run prop_FromToIntSet
                , run prop_EqListSet
                ])

allTests :: Test  
allTests = TestLabel "DiffList tests" $ 
  TestList
  [ TestLabel "From/to List tests" listTests
  , TestLabel "From/to IntSet tests" intSetTests
  , TestLabel "Special cases" specialTests
  ]