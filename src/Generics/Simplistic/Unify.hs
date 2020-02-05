{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module Generics.Simplistic.Unify
  ( -- * Substitution
    Subst , substEmpty , substInsert , substLkup , substApply
    -- * Unification
  , UnifyErr(..) , unify , unifyWith , minimize
  ) where

import           Data.List (sort)
import qualified Data.Map as M
import           Control.Monad.Except
import           Control.Monad.State
import           Control.Monad.Writer
import           Unsafe.Coerce

import Generics.Simplistic
import Generics.Simplistic.Util

-- |Unification can return succesfully or find either
-- a 'OccursCheck' failure or a 'SymbolClash' failure.
data UnifyErr fam prim phi :: * where
  -- |The occurs-check fails when the variable in question
  -- occurs within the term its supposed to be unified with.
  OccursCheck :: [Exists phi]
              -> UnifyErr fam prim phi
  -- |A symbol-clash is thrown when the head of the
  -- two terms is different and neither is a variabe.
  SymbolClash :: Holes    fam prim phi at
              -> Holes    fam prim phi at
              -> UnifyErr fam prim phi

-- |A substitution is but a map; the existential quantifiers are
-- necessary to ensure we can reuse from "Data.Map"
--
-- Note that we must be able to compare @Exists phi@. This
-- comparison needs to work heterogeneously and it must
-- return 'EQ' only when the contents are in fact equal.
-- Even though we only need this instance for "Data.Map"
--
-- A typical example for @phi@ is @Const Int at@, representing
-- a variable. The @Ord@ instance would then be:
--
-- > instance Ord (Exists (Const Int)) where
-- >   compare (Exists (Const x)) (Exists (Const y))
-- >     = compare x y
--
type Subst fam prim phi 
  = M.Map (Exists phi) (Exists (Holes fam prim phi))

-- |Empty substitution
substEmpty :: Subst fam prim phi
substEmpty = M.empty

-- |Looks a value up in a substitution, see 'substInsert'
substLkup :: (Ord (Exists phi))
          => Subst fam prim phi -- ^
          -> phi at
          -> Maybe (Holes fam prim phi at)
substLkup sigma var =
  case M.lookup (Exists var) sigma of
    Nothing         -> Nothing
    -- In case we found something, it must be of the same
    -- type as what we got because we only insert
    -- well-typed things.
    -- TODO: Use our sameTy method to remove the unsafeCoerce
    Just (Exists t) -> Just $ unsafeCoerce t

-- |Applies a substitution to a term; Variables not in the
-- support of the substitution are left untouched.
substApply :: (Ord (Exists phi))
           => Subst fam prim phi -- ^
           -> Holes fam prim phi at
           -> Holes fam prim phi at
substApply sigma = holesJoin
                 . holesMap (\v -> maybe (Hole v) (substApply sigma)
                                 $ substLkup sigma v)

-- |Inserts a point in a substitution. Note how the index of
-- @phi@ /must/ match the index of the term being inserted.
-- This is important when looking up terms because we must
-- 'unsafeCoerce' the existential type variables to return.
--
-- Please, always use this insertion function; or, if you insert
-- by hand, ensure thetype indices match.
substInsert :: (Ord (Exists phi))
            => Subst fam prim phi -- ^
            -> phi at
            -> Holes fam prim phi at
            -> Subst fam prim phi
substInsert sigma v x = M.insert (Exists v) (Exists x) sigma

-- |Unification is done in a monad.
type UnifyM fam prim phi
  = StateT (Subst fam prim phi) (Except (UnifyErr fam prim phi))

-- |Attempts to unify two 'Holes'
unify :: ( Ord (Exists phi) , EqHO phi)
      => Holes fam prim phi at -- ^
      -> Holes fam prim phi at
      -> Except (UnifyErr fam prim phi)
                (Subst fam prim phi)
unify = unifyWith substEmpty

-- |Attempts to unify two 'Holes' with an already existing
-- substitution
unifyWith :: ( Ord (Exists phi) , EqHO phi)
          => Subst fam prim phi -- ^ Starting subst
          -> Holes fam prim phi at
          -> Holes fam prim phi at
          -> Except (UnifyErr fam prim phi)
                    (Subst fam prim phi)
unifyWith sigma x y = execStateT (unifyM x y) sigma

-- Actual unification algorithm; In order to improve efficiency,
-- we first register all equivalences we need to satisfy,
-- then on 'mininize' we do the occurs-check.
unifyM :: forall fam prim phi at
        . (EqHO phi , Ord (Exists phi)) 
       => Holes fam prim phi at
       -> Holes fam prim phi at
       -> UnifyM fam prim phi ()
unifyM x y = do
  _ <- getEquivs x y
  s <- get
  case minimize s of
    Left vs  -> throwError (OccursCheck vs)
    Right s' -> put s'
  where
    getEquivs :: Holes fam prim phi b
              -> Holes fam prim phi b
              -> UnifyM fam prim phi ()
    getEquivs p q = void $ holesMapM (uncurry' getEq) (lcp p q)
    
    getEq :: Holes fam prim phi b
          -> Holes fam prim phi b
          -> UnifyM fam prim phi (Holes fam prim phi b)
    getEq p (Hole var)   = record_eq var p >> return p
    getEq p@(Hole var) q = record_eq var q >> return p
    getEq p q | eqHO p q   = return p
              | otherwise  = throwError (SymbolClash p q)
           
    -- Whenever we see a variable being matched against a term
    -- we record the equivalence. First we make sure we did not
    -- record such equivalence yet, otherwise, we recursively thin
    record_eq :: phi b -> Holes fam prim phi b -> UnifyM fam prim phi ()
    record_eq var q = do
      sigma <- get
      case substLkup sigma var of
        -- First time we see 'var', we instantiate it and get going.
        Nothing -> when (not $ eqHO q (Hole var))
                 $ modify (\s -> substInsert s var q)
        -- It's not the first time we thin 'var'; previously, we had
        -- that 'var' was supposed to be p'. We will check whether it
        -- is the same as q, if not, we will have to thin p' with q.
        Just q' -> unless (eqHO q' q)
                 $ void $ getEquivs q q'
          
-- |The minimization step performs the /occurs check/ and removes
--  unecessary steps. For example;
--
--  > sigma = fromList
--  >           [ (0 , bin 1 2)
--  >           , (1 , bin 4 4) ]
--
-- Then, @minimize sigma@ will return @fromList [(0 , bin (bin 4 4) 2) , (1 , bin 4 4)]@
-- This returns @Left vs@ if occurs-check fail for variables @vs@.
--
minimize :: forall fam prim phi . (Ord (Exists phi))
         => Subst fam prim phi -- ^
         -> Either [Exists phi] (Subst fam prim phi)
minimize sigma =
  let sigma' = M.foldrWithKey' insIfNotSimpleEq M.empty sigma
   in whileM sigma' [] $ \s _
    -> M.fromList <$> (mapM (secondF (exMapM (go sigma'))) (M.toList s))
  where
    -- Still only works for 2-cycles; we need to break all cycles from
    -- sigma while minimizing!
    insIfNotSimpleEq :: Exists phi -> Exists (Holes fam prim phi)
                     -> Subst fam prim phi -> Subst fam prim phi
    insIfNotSimpleEq k v@(Exists (Hole v')) curr =
      case M.lookup (Exists v') curr of
        Just (Exists (Hole k'))
          | k == Exists k' -> curr
        _                  -> M.insert k v curr
    insIfNotSimpleEq k v curr = M.insert k v curr
    
    
    secondF :: (Functor m) => (a -> m b) -> (x , a) -> m (x , b)
    secondF f (x , a) = (x,) <$> f a

    -- The actual engine of the 'minimize' function is thinning the
    -- variables that appear in the image of the substitution under production.
    -- We use the writer monad solely to let us know whether some variables have
    -- been substituted in this current term. After one iteration
    -- of the map where no variable is further refined, we are done.
    go :: Subst fam prim phi
       -> Holes fam prim phi at
       -> Writer [Exists phi] (Holes fam prim phi at)
    go ss = holesRefineVarsM $ \var -> do
           case substLkup ss var of
             Nothing       -> return (Hole var)
             Just r        -> tell [Exists var]
                           >> return r

    -- | Just like nub; but works on a sorted list
    mnub :: (Ord a) => [a] -> [a]
    mnub [] = []
    mnub [x] = [x]
    mnub (x:y:ys)
      | x == y    = mnub (y:ys)
      | otherwise = x : mnub (y:ys)

    -- We loop while there is work to be done or no progress
    -- was done.
    whileM :: (Ord (Exists phi))
           => a -> [Exists phi] -> (a -> [Exists phi] -> Writer [Exists phi] a)
           -> Either [Exists phi] a
    whileM a xs f = do
      let (x' , xs') = runWriter (f a xs)
      if null xs'
      then return x'
      else if (mnub (sort xs') == mnub (sort xs))
           then Left xs'
           else whileM x' xs' f
