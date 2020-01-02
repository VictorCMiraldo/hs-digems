{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE GADTs                 #-}
module Data.HDiff.Diff
  ( diffOpts'
  , diffOpts
  , diff
  , DiffMode(..)
  , module Data.HDiff.Diff.Types
  ) where

import           Data.Void
import           Data.Functor.Const
import           Data.Functor.Sum

import           Control.Monad.State

import           Generics.MRSOP.Base
import           Generics.MRSOP.Holes
import           Generics.MRSOP.HDiff.Digest

import qualified Data.WordTrie as T
import           Data.HDiff.Diff.Types
import           Data.HDiff.Diff.Modes
import           Data.HDiff.Diff.Preprocess
import           Data.HDiff.Base
import           Data.HDiff.MetaVar

-- * Diffing
--

-- |Given a merkelized fixpoint, builds a trie of hashes of
--  every subtree, as long as they are taller than
--  minHeight. This trie keeps track of the arity, so
--  we can later annotate the trees that can be propper shares.
buildArityTrie :: DiffOptions -> PrepFix a ki codes phi ix -> T.Trie Int
buildArityTrie opts df = go df T.empty
  where
    ins :: Digest -> T.Trie Int -> T.Trie Int
    ins = T.insertWith 1 (+1) . toW64s

    minHeight = doMinHeight opts
    
    go :: PrepFix a ki codes phi ix -> T.Trie Int -> T.Trie Int
    go (HOpq (Const prep) _) t
      -- We only populat the sharing map if opaques are supposed
      -- to be handled as recursive trees
      | doOpaqueHandling opts == DO_AsIs = ins (treeDigest prep) t
      | otherwise                        = t
    -- TODO: think about holes. I'm posponing this until
    -- we actually use diffing things holes.
    go (Hole (Const  _)    _) t = t
    go (HPeel (Const prep) _ p) t
      | treeHeight prep <= minHeight = t
      | otherwise
      = ins (treeDigest prep) $ getConst
      $ cataNP (\af -> Const . go af . getConst) (Const t) p
   
-- |Given two merkelized trees, returns the trie that indexes
--  the subtrees that belong in both, ie,
--
--  @forall t . t `elem` buildSharingTrie x y
--        ==> t `subtree` x && t `subtree` y@
--
--  Moreover, we keep track of both the metavariable supposed
--  to be associated with a tree and the tree's arity.
--
buildSharingTrie :: DiffOptions
                 -> PrepFix a ki codes phi ix
                 -> PrepFix a ki codes phi ix
                 -> (Int , IsSharedMap)
buildSharingTrie opts x y
  = T.mapAccum (\i ar -> (i+1 , MAA i ar) ) 0
  $ T.zipWith (+) (buildArityTrie opts x)
                  (buildArityTrie opts y)

-- |Given two treefixes, we will compute the longest path from
--  the root that they overlap and will factor it out.
--  This is somehow analogous to a @zipWith@. Moreover, however,
--  we also copy the opaque values present in the spine by issuing
--  /"copy"/ changes
extractSpine :: forall ki codes phi at
              . (EqHO ki)
             => DiffOpaques
             -> (forall ix . phi ix -> MetaVar ix)
             -> Int
             -> Holes ki codes phi at
             -> Holes ki codes phi at
             -> Holes ki codes (Chg ki codes) at
extractSpine dopq meta maxI dx dy
  = holesMap (uncurry' Chg)
  $ issueOpqCopiesSpine
  $ holesLCP dx dy
 where
   issueOpqCopiesSpine :: Holes ki codes (Holes2 ki codes phi) at
                       -> Holes ki codes (Holes2 ki codes MetaVar) at
   issueOpqCopiesSpine
     = flip evalState maxI
     . holesRefineAnnM (\_ (x :*: y) -> return $ Hole' $ holesMap meta x
                                                     :*: holesMap meta y)
                       (const $ if dopq == DO_OnSpine
                                then doCopy
                                else noCopy)

   noCopy :: ki k -> State Int (Holes ki codes (Holes2 ki codes MetaVar) ('K k))
   noCopy kik = return (HOpq' kik)
                        
   doCopy :: ki k -> State Int (Holes ki codes (Holes2 ki codes MetaVar) ('K k))
   doCopy _ki = do
     i <- get
     put (i+1)
     let ann = Const i
     return $ Hole' (Hole' ann :*: Hole' ann)


-- |Diffs two generic merkelized structures.
--  The outline of the process is:
--
--    i)   Annotate each tree with the info we need (digest and height)
--    ii)  Build the sharing trie
--    iii) Identify the proper shares
--    iv)  Substitute the proper shares by a metavar in
--         both the source and deletion context
--    v)   Extract the spine and compute the closure.
--
diffOpts' :: forall ki codes phi at
           . (EqHO ki , DigestibleHO ki , DigestibleHO phi)
          => DiffOptions
          -> Holes ki codes phi at
          -> Holes ki codes phi at
          -> (Int , Delta (Holes ki codes (Sum phi MetaVar)) at)
diffOpts' opts x y
  = let dx      = preprocess x
        dy      = preprocess y
        (i, sh) = buildSharingTrie opts dx dy
        dx'     = tagProperShare sh dx
        dy'     = tagProperShare sh dy
        delins  = extractHoles (doMode opts) mkCanShare sh (dx' :*: dy')
     in (i , delins)
 where
   mkCanShare :: forall a ix
               . PrepFix a ki codes phi ix
              -> Bool
   mkCanShare (HOpq _ _)
     = doOpaqueHandling opts == DO_AsIs
   mkCanShare pr
     = doMinHeight opts < treeHeight (getConst $ holesAnn pr)

-- |When running the diff for two fixpoints, we can
-- cast the resulting deletion and insertion context into
-- an actual patch.
diffOpts :: (EqHO ki , DigestibleHO ki , IsNat ix)
         => DiffOptions
         -> Fix ki codes ix
         -> Fix ki codes ix
         -> Patch ki codes ('I ix)
diffOpts opts x y
  = let (i , del :*: ins) = diffOpts' opts (na2holes $ NA_I x)
                                           (na2holes $ NA_I y)
     in extractSpine (doOpaqueHandling opts) cast i del ins
 where 
   cast :: Sum (Const Void) f i -> f i
   cast (InR fi) = fi
   cast (InL _)  = error "impossible"

diff :: forall (ki :: kon -> *) (codes :: [[[Atom kon]]]) (ix :: Nat)
      . (EqHO ki , DigestibleHO ki , IsNat ix)
     => MinHeight
     -> Fix ki codes ix
     -> Fix ki codes ix
     -> Patch ki codes ('I ix)
diff h = diffOpts (diffOptionsDefault { doMinHeight = h})
