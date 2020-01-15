{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications      #-}
{-# OPTIONS_GHC -Wno-missing-signatures                 #-}
{-# OPTIONS_GHC -Wno-missing-pattern-synonym-signatures #-}
module Languages.Lines where

import           Data.Type.Equality
import           Data.Text.Prettyprint.Doc (pretty)

import           Control.Monad.Except

import Generics.MRSOP.Base hiding (Infix)
import Generics.MRSOP.TH

-----------------------
-- * Parser

-- |We must have a dedicated type 'Line' to make sure
-- we duplicate lines. If we use just @Stmt [String]@ 
-- the content of the lines will be seen as an opaque type.
-- Opaque values are NOT shared by design.
data Stmt = Stmt [Line]

data Line = Line String

-- |Custom Opaque type
data WKon = WString 

-- |And their singletons.
--
--  Note we need instances of Eq1, Show1 and DigestibleHO
data W :: WKon -> * where
  W_String  :: String  -> W 'WString

deriving instance Show (W x)
deriving instance Eq (W x)

instance EqHO W where
  eqHO = (==)

instance ShowHO W where
  showHO = show

-- Now we derive the 'Family' instance
-- using 'W' for the constants.
deriveFamilyWithTy [t| W |] [t| Stmt |]

instance TestEquality W where
  testEquality (W_String _)  (W_String _)  = Just Refl

parseFile :: String -> ExceptT String IO Stmt
parseFile file =
  do program  <- lift $ readFile file
     return (Stmt $ map Line $ lines program)

