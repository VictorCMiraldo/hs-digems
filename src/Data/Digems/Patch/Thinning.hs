{-# LANGUAGE FlexibleContexts      #-}
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
module Data.Digems.Patch.Thinning where

import           Data.Proxy
import           Data.Type.Equality
import           Data.Functor.Const
import qualified Data.Map as M
import           Control.Monad.Writer
import           Control.Monad.Except
import           Control.Monad.State
---------------------------------------
import Generics.MRSOP.Util
import Generics.MRSOP.Base
import Generics.MRSOP.Holes
---------------------------------------
import           Data.Exists
import           Data.Digems.MetaVar
import           Data.Digems.Patch
import           Data.Digems.Change
import qualified Data.Digems.Change.Thinning as CT
import           Generics.MRSOP.Digems.Holes

thin :: (ShowHO ki , TestEquality ki, EqHO ki)
     => RawPatch ki codes at
     -> RawPatch ki codes at
     -> Either (CT.ThinningErr ki codes) (RawPatch ki codes at)
thin p q = holesMapM (uncurry' go) $ holesLCP p (q `withFreshNamesFrom` p)
  where
    go cp cq = let cp' = distrCChange cp
                   cq' = distrCChange cq 
                in CT.thin cp' (domain cq')

unsafeThin :: (ShowHO ki , TestEquality ki, EqHO ki)
           => RawPatch ki codes at
           -> RawPatch ki codes at
           -> RawPatch ki codes at
unsafeThin p q = either (error . show) id $ thin p q
