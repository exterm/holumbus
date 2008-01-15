-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Query.Processor
  Copyright  : Copyright (C) 2007 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.2

  The Holumbus query processor. Supports exact word or phrase queries as well
  as fuzzy word and case-insensitive word and phrase queries. Boolean
  operators like AND, OR and NOT are supported. Context specifiers and
  priorities are supported, too.

-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -farrows #-}

module Holumbus.Query.Processor 
  (
  -- * Processor types
  ProcessConfig (..)
  
  -- * Processing
  , processQuery
  )
where

import Data.Maybe

import qualified Data.IntMap as IM
import qualified Data.IntSet as IS

import Holumbus.Index.Common
import Holumbus.Index.Combined

import Holumbus.Query.Syntax

import Holumbus.Query.Fuzzy (FuzzyScore, FuzzyConfig)
import qualified Holumbus.Query.Fuzzy as F

import Holumbus.Query.Result (Result)
import qualified Holumbus.Query.Result as R

-- | The configuration for the query processor.
data ProcessConfig = ProcessConfig { queryServers  :: [String]
                                   , fuzzyConfig   :: FuzzyConfig
                                   }

-- | The internal state of the query processor.
data ProcessState = ProcessState { config  :: ProcessConfig
                                 , context :: Context
                                 , index   :: AnyIndex
                                 }

-- | Get the fuzzy config out of the process state.
getFuzzyConfig :: ProcessState -> FuzzyConfig
getFuzzyConfig = fuzzyConfig . config

-- | Set the current context in the state.
setContext :: Context -> ProcessState -> ProcessState
setContext c (ProcessState cfg _ i) = ProcessState cfg c i

-- | Initialize the state of the processor.
initState :: ProcessConfig -> AnyIndex -> ProcessState
initState cfg i = ProcessState cfg (head $ contexts i) i

-- | Just everything.
allDocuments :: ProcessState -> Result
allDocuments s = R.fromList "" (context s) (allWords (context s) (index s))

-- | Process a query on a index with a list of contexts (should default to all contexts).
processQuery :: ProcessConfig -> AnyIndex -> Query -> Result
processQuery cfg i q = processContexts (initState cfg i) (contexts i) q

-- | Process a query for different contexts.
processContexts :: ProcessState -> [Context] -> Query -> Result
processContexts s cs q = foldr R.union R.emptyResult (map (\c -> process (setContext c s) q) cs)

-- | Continue processing a query by deciding what to do depending on the current query element.
process :: ProcessState -> Query -> Result
process s (Word w)           = processWord s w
process s (Phrase w)         = processPhrase s w
process s (CaseWord w)       = processCaseWord s w
process s (CasePhrase w)     = processCasePhrase s w
process s (FuzzyWord w)      = processFuzzyWord s w
process s (Negation q)       = processNegation s q
process s (BinQuery o q1 q2) = processBin s o q1 q2
process s (Specifier cs q)   = processContexts s cs q

-- | Process a single, case-insensitive word by finding all documents which contain the word as prefix.
processWord :: ProcessState -> String -> Result
processWord s q = R.fromList q (context s) (prefixNoCase (context s) (index s) q)

-- | Process a single, case-sensitive word by finding all documents which contain the word as prefix.
processCaseWord :: ProcessState -> String -> Result
processCaseWord s q = R.fromList q (context s) (prefixCase (context s) (index s) q)

-- | Process a phrase case-insensitive.
processPhrase :: ProcessState -> String -> Result
processPhrase = processPhraseInternal lookupNoCase

-- | Process a phrase case-sensitive.
processCasePhrase :: ProcessState -> String -> Result
processCasePhrase = processPhraseInternal lookupCase

-- | Process a phrase query by searching for every word of the phrase and comparing their positions.
processPhraseInternal :: (Context -> AnyIndex -> String -> [Occurrences]) -> ProcessState -> String -> Result
processPhraseInternal f s q = let
  w = words q 
  m = mergeOccurrences $ f (context s) (index s) (head w) in
  if m == IM.empty then R.emptyResult
  else R.Result (R.createDocHits (context s) [(q, processPhrase' (tail w) 1 m)]) R.emptyWordHits
  where
  processPhrase' :: [String] -> Int -> Occurrences -> Occurrences
  processPhrase' [] _ o = o
  processPhrase' (x:xs) p o = processPhrase' xs (p+1) (IM.filterWithKey (nextWord $ f (context s) (index s) x) o)
    where
    nextWord :: [Occurrences] -> Int -> Positions -> Bool
    nextWord [] _ _  = False
    nextWord no d np = maybe False hasSuccessor (IM.lookup d (mergeOccurrences no))
      where
      hasSuccessor :: Positions -> Bool
      hasSuccessor w = IS.fold (\cp r -> r || (IS.member (cp + p) w)) False np

-- | Process a single word and try some fuzzy alternatives if nothing was found.
processFuzzyWord :: ProcessState -> String -> Result
processFuzzyWord s oq = processFuzzyWord' (F.toList $ F.fuzz (getFuzzyConfig s) oq) (processWord s oq)
  where
  processFuzzyWord' :: [(String, FuzzyScore)] -> Result -> Result
  processFuzzyWord' []     r = r
  processFuzzyWord' (q:qs) r = if R.null r then processFuzzyWord' qs (processWord s (fst q)) else r

-- | Process a negation by getting all documents and substracting the result of the negated query.
processNegation :: ProcessState -> Query -> Result
processNegation s q = R.difference (allDocuments s) (process s q)

-- | Process a binary operator by caculating the union or the intersection of the two subqueries.
processBin :: ProcessState -> BinOp -> Query -> Query -> Result
processBin s And q1 q2    = R.intersection (process s q1) (process s q2)
processBin s Or q1 q2     = R.union (process s q1) (process s q2)
processBin s Filter q1 q2 = R.difference (process s q1) (process s q2)

-- | Merge occurrences
mergeOccurrences :: [Occurrences] -> Occurrences
mergeOccurrences = IM.unionsWith IS.union
