{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE CPP                   #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
-- |Illustrates the usage of MRSOP with a custom
--  opaque type universe and the use of HDiff to
--  compute diffs over various languages.
--
module Main (main) where

import System.IO
import System.Exit
import Control.Monad
import Control.DeepSeq
import System.CPUTime
import Options.Applicative

import Generics.Simplistic
import Generics.Simplistic.Util

import           Data.Type.Equality

import qualified Data.HDiff.Base         as D
import qualified Data.HDiff.Apply        as D
import qualified Data.HDiff.Diff         as D
import qualified Data.HDiff.Merge        as D
import           Data.HDiff.Show

import           Languages.Interface
import           HDiff.Options

instance NFData (D.Chg prim x) where
  rnf (D.Chg d i) = rnf d `seq` rnf i
  
time :: (NFData a) => IO a -> IO (Double, a)
time act = do
    t1 <- getCPUTime
    result <- act
    let !res = result `deepseq` result
    t2 <- getCPUTime
    let t :: Double
        t = fromIntegral (t2-t1) * 1e-12
    return (t, res)

main :: IO ()
main = execParser hdiffOpts >>= \(verb , pars, opts)
    -> case optionMode opts of
         OptAST     -> mainAST     verb pars opts
         OptDiff    -> mainDiff    verb pars opts
         OptMerge   -> mainMerge   verb pars opts
    >>= exitWith

putStrLnErr :: String -> IO ()
putStrLnErr = hPutStrLn stderr

-- * Generic interface

mainAST :: Verbosity -> Maybe String -> Options -> IO ExitCode
mainAST v sel opts = withParsed1 sel mainParsers (optFileA opts)
  $ \_ fa -> do
    unless (v == Quiet) $ putStrLn (show fa)
    return ExitSuccess

-- |Applies a patch to an element and either checks it is equal to
--  another element, or returns the result.
tryApply :: (LangCnstr prim ix)
         => Verbosity
         -> D.Patch prim ix
         -> SFix prim ix
         -> Maybe (SFix prim ix)
         -> IO (Maybe (SFix prim ix))
tryApply v patch fa fb
  = case D.patchApply patch fa of
      Nothing -> hPutStrLn stderr "!! apply failed"
              >> when (v == Loud)
                  (hPutStrLn stderr (show fa))
              >> exitWith (ExitFailure 2)
      Just b' -> return $ maybe (Just b') (testEq b') fb
 where
   testEq :: SFix prim ix -> SFix prim ix -> Maybe (SFix prim ix)
   testEq x y = if eqHO x y then Just x else Nothing

-- |Runs our diff algorithm with particular options parsed
-- from the CLI options.
diffWithOpts :: (LangCnstr prim ix) 
             => Options
             -> SFix prim ix
             -> SFix prim ix
             -> IO (D.Patch prim ix)
diffWithOpts opts fa fb = do
  let localopts = D.DiffOptions (minHeight opts) (opqHandling opts) (diffMode opts) 
  return (D.diffOpts localopts fa fb)

mainDiff :: Verbosity -> Maybe String -> Options -> IO ExitCode
mainDiff v sel opts = withParsed2 sel mainParsers (optFileA opts) (optFileB opts)
  $ \_ fa fb -> do
    (secs , patch) <- time (diffWithOpts opts fa fb)
    unless (v == Quiet || withStats opts)
      $ hPutStrLn stdout (show patch)
    when (testApply opts) $ void (tryApply v patch fa (Just fb))
    when (withStats opts) $ 
      putStrLn . unwords $
        [ "time(s):" ++ show secs
        , "n+m:" ++ show (holesSize fa + holesSize fb)
        , "cost:" ++ show (D.cost patch)
        ]
    return ExitSuccess

mainMerge :: Verbosity -> Maybe String -> Options -> IO ExitCode
mainMerge v sel opts = withParsed3 sel mainParsers (optFileA opts) (optFileO opts) (optFileB opts)
  $ \pp fa fo fb -> do
    patchOA <- diffWithOpts opts fo fa
    patchOB <- diffWithOpts opts fo fb
    let omc = D.diff3 patchOA patchOB
    case D.noConflicts omc of
      Nothing -> putStrLnErr " !! Conflicts O->A O->B !!"
              >> return (ExitFailure 1)
      Just om -> do
        when (v == Loud) (putStrLnErr "!! apply om o")
        mtgt <- sequence (fmap pp (optFileRes opts))
        res  <- tryApply v om fo mtgt
        case res of
          Just _  -> return ExitSuccess
          Nothing -> return (ExitFailure 3)
          