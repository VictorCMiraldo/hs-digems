{-# LANGUAGE PolyKinds        #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE GADTs            #-}
module Data.HDiff.ClassifySpec (spec) where

import Generics.MRSOP.Holes

import Data.HDiff.Classify
import Languages.RTree
import Languages.RTree.Diff

import Test.Hspec

--------------------------------------------
-- ** Change Classification Unit Tests

changeClassDual :: ChangeClass -> ChangeClass
changeClassDual CDel = CIns
changeClassDual CIns = CDel
changeClassDual x    = x

mustClassifyAs :: String ->  RTree -> RTree -> [ChangeClass] -> SpecWith (Arg Bool)
mustClassifyAs lbl a b cls = do
  xit (lbl ++ ": change class") $ do
    let patch = hdiffRTree a b
     in cls == holesGetHolesAnnWith' changeClassify patch
     
  
----------------
-- Example 1

a1 , b1 :: RTree
a1 = "a" :>: [ "b" :>: []
             , "c" :>: []
             , "d" :>: []
             ]

b1 = "a" :>: [ "b'" :>: []
             , "d" :>: []
             ]


---------------
-- Example 2

a2 , b2 :: RTree
a2 = "x" :>: [ "k" :>: [] , "u" :>: []]
b2 = "x" :>: [ "u" :>: [] , "k" :>: []]


---------------
-- Example 3

a3 , b3 :: RTree
a3 = "x" :>: [ "k" :>: [ "a" :>: [] ] ]
b3 = "x" :>: [ "k" :>: [] , "a" :>: [] ]

----------------
-- Example 4

a4 , b4 :: RTree
a4 = "x" :>: [ "a" :>: [ "b" :>: [] ] , "c" :>: [] ]
b4 = "x" :>: [ "a" :>: [ "b" :>: ["c" :>: []]]]

----------------
-- Example 5

a5 , b5 :: RTree
a5 = "x" :>: [ "a" :>: [] , "b" :>: [] ]
b5 = "x" :>: [ "a" :>: [] , "new" :>: [] , "b" :>: [] ]

----------------
-- Example 6

a6 , b6 :: RTree
a6 = "x" :>: [ "a" :>: [] , "b" :>: [ "k" :>: [] ] ]
b6 = "x" :>: [ "a" :>: [] , "new" :>: [] , "b'" :>: [ "k" :>: [] ] ]

----------------
-- Example 7

a7 , b7 :: RTree
a7 = "x" :>: [ "a" :>: [ "aa" :>: [] , "ab" :>: []] , "b" :>: [ "bb" :>: [] ] ]
b7 = "x" :>: [ "a" :>: [ "aa" :>: [] , "ab" :>: [] , "bb" :>: [] ] , "bb" :>: [] ]

----------------
-- Example 8

a8 , b8 :: RTree
a8 = "x" :>: [ "y" :>: [] ] 
b8 = "a" :>: [ "b" :>: [] , "x" :>: [ "y" :>: [] ] , "c" :>: [] ]


spec :: Spec
spec = do
  describe "changeClassify: manual examples" $ do
    mustClassifyAs "1" a1 b1 [CDel , CMod , CId]
    mustClassifyAs "2" a2 b2 [CPerm , CId]
    mustClassifyAs "3" a3 b3 [CPerm , CId]
    mustClassifyAs "4" a4 b4 [CPerm , CId]
    mustClassifyAs "5" a5 b5 [CIns , CId , CId]
    mustClassifyAs "6" a6 b6 [CMod , CId , CId]
    mustClassifyAs "7" a7 b7 [CMod , CId]
    mustClassifyAs "8" a8 b8 [CIns]
