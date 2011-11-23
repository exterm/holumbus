-- ----------------------------------------------------------------------------



{- |

  A simple example of searching with Holumbus, providing a command line search with the

  default query language.



-}



-- ----------------------------------------------------------------------------



{-# OPTIONS -fno-warn-type-defaults  #-}



module W3WSimpleSearch where



import           Data.Function

import qualified Data.List              as L

import qualified Data.Map               as M

import qualified Data.IntMap            as IM

import           Holumbus.Index.Common

import           Holumbus.Query.Language.Grammar

import           Holumbus.Query.Language.Parser

import           Holumbus.Query.Processor

import           Holumbus.Query.Result

import           Holumbus.Query.Ranking

import           Holumbus.Query.Fuzzy

import           System.CPUTime

import           IndexTypes

import           PageInfo



-- ------------------------------------------------------------

-- | number of hits shown per page

hitsPerPage :: Int

hitsPerPage = 10



-- ------------------------------------------------------------

-- | max number of pages

maxPages :: Int

maxPages = 10





-- Representation of all Document-Hits and Word-Completions found

data SearchResult = SearchResult

  { srDocs              :: SearchResultDocs

  , srWords         :: SearchResultWords

  }



data SearchResultDocs = SearchResultDocs

  { srTime      :: Float

  , srDocCount  :: Int

  , srDocHits   :: [SRDocHit]

  } deriving Show



data SearchResultWords = SearchResultWords

  { srWordCount :: Int

  , srWordHits  :: [SRWordHit]

  }



data SRDocHit = SRDocHit

  { srTitle  :: String

  , srScore  :: Float

  , srPageInfo :: PageInfo

  , srUri    :: String

  , srContextMap  :: M.Map Context DocWordHits -- Context: "title", "keywords", "content", "dates", ...

                                               -- DocWordHits: Map Word Positions

  } deriving Show



data SRWordHit = SRWordHit

  { srWord :: String

  , srHits :: Int

  }



-- Ranking for different kinds of Contexts

type RankTable  = [(Context, Score)]



defaultRankTable :: RankTable

defaultRankTable

    = [ ("title", 1.0)

      , ("headlines", 1.0)

      , ("contentContext", 0.5)

      , ("uri", 0.1)

      , ("datesContext", 1.0)

      , ("calenderContext", 2.0)

      ]



defaultRankCfg :: RankConfig a

defaultRankCfg

    = RankConfig

      (docRankWeightedByCount  defaultRankTable)

      (wordRankWeightedByCount defaultRankTable)



-- ------------------------------------------------------------



-- | Just an alias with explicit type.

loadIndex       :: FilePath -> IO CompactInverted

loadIndex       = loadFromFile



-- | Just an alias with explicit type.

loadDocuments   :: FilePath -> IO (SmallDocuments PageInfo)

loadDocuments   = loadFromFile



-- ------------------------------------------------------------



-- | Create the configuration for the query processor.

processCfg :: ProcessConfig

processCfg = ProcessConfig (FuzzyConfig True True 1.0 germanReplacements) True 100 500



-- | Perform a query on a local index.

localQuery              :: CompactInverted -> SmallDocuments PageInfo -> (Query -> IO (Result PageInfo))

localQuery idx doc q    = return (processQuery processCfg idx doc q)



-- | get all Search Results

getAllSearchResults :: String -> (Query -> IO (Result PageInfo)) -> IO SearchResult

getAllSearchResults q f = do

  docs <- getIndexSearchResults q f

  _words <- getWordCompletions q f

  return $ SearchResult docs _words



-- | Insert the time needed for request into SearchResultDocs data type.

-- | Delete all elements in the list of search-results such that the list is uniq

-- | by the title of a found document.

-- | Shorten the search-result list to (hitsPerPage * maxPages) elements.

-- | Adapt the displayed number of docs found 

mkDocSearchResult :: Float -> SearchResultDocs -> SearchResultDocs

mkDocSearchResult requestTime searchResultDocs = SearchResultDocs requestTime dislayedNumOfHits _docHits

  where

    _docHits = take (hitsPerPage * maxPages) $ uniqByTitle $ srDocHits searchResultDocs

    -- not a good idea: (length $ uniqByTitle $ srDocHits searchResultDocs), since the whole list would be processed by the O(n^2) algorithm "uniqByTitle"

    dislayedNumOfHits = if (numElemsShortList == hitsPerPage * maxPages)

                           then numElemsLongList

                           else numElemsShortList

    numElemsShortList = length _docHits

    -- this is the length without filtering!

    numElemsLongList = srDocCount searchResultDocs



-- | helper for mkDocSearchResult:

-- | delete all elements in the list of search-results such that the list is uniq

-- | by the title of a found document.

-- | This is an O(n^2) algorithm but we truncate the result list of uniqByTitle to (hitsPerPage*maxPages) elements,

-- | so only these elements are computed due to lazy evaluation.

-- | This has proven to be the best method to get rid of many equal search results.

uniqByTitle :: [SRDocHit] -> [SRDocHit]

uniqByTitle []     = []

uniqByTitle (x:xs) = (x : uniqByTitle (deleteByTitle (srTitle x) xs) )

  where

    deleteByTitle _title = filter (\ listItem -> (srTitle listItem /= _title))



-- | get only Document Search Results (without Word-Completions)

getIndexSearchResults :: String -> (Query -> IO (Result PageInfo)) -> IO SearchResultDocs

getIndexSearchResults q f =

  answerThis q

  where

  answerThis _q = do

                 result <- either printError makeQuery pr

                 return result

                 where

                 pr = parseQuery _q

                 printError _ = do

                                  return $ SearchResultDocs 0.0 0 []

                 makeQuery pq = do

                                t1 <- getCPUTime

                                r <- f pq -- This is where the magic happens!

                                rr <- return (rank defaultRankCfg r)

                                docsSearchResult <- getDocHits (docHits rr)

                                t2 <- getCPUTime

                                d <- return ((fromIntegral (t2 - t1) / 1000000000000.0) :: Float)

                                return $ mkDocSearchResult d docsSearchResult



-- | get only Word-Completions (without Document Search Results)

getWordCompletions :: String -> (Query -> IO (Result PageInfo)) -> IO SearchResultWords

getWordCompletions q f =

  answerThis q

  where

  answerThis _q = do

                 result <- either printError makeQuery pr

                 return result

                 where

                 pr = parseQuery _q

                 printError _ = do

                                  return $ SearchResultWords 0 []

                 makeQuery pq = do

                                r <- f pq -- This is where the magic happens!

                                rr <- return (rank defaultRankCfg r)

                                getWordHits (wordHits rr)



-- | convert Document-Hits to SearchResult

getDocHits :: DocHits PageInfo -> IO SearchResultDocs

getDocHits h = do

  return $ SearchResultDocs 0.0 (IM.size h) (map docInfoToSRDocHit docData)

  where

  docData = (L.reverse $ L.sortBy (compare `on` (docScore . fst . snd)) $ IM.toList h)



docInfoToSRDocHit :: (DocId, (DocInfo PageInfo, DocContextHits)) -> SRDocHit

docInfoToSRDocHit (_, ((DocInfo (Document _title _uri Nothing) score), contextMap)) = SRDocHit _title score emptyPageInfo _uri contextMap

docInfoToSRDocHit (_, ((DocInfo (Document _title _uri (Just pageInfo)) score), contextMap)) = SRDocHit _title score pageInfo _uri contextMap





-- | convert Word-Completions to SearchResult

getWordHits :: WordHits -> IO SearchResultWords

getWordHits h = do

  return $ SearchResultWords (M.size h) (getWordHits' wordData)

  where

  wordData = (L.reverse $ L.sortBy (compare `on` snd) (map (\(c, (_, o)) -> (c, M.fold (\m r -> r + IM.size m) 0 o)) (M.toList h)))

  getWordHits' [] = []

  getWordHits' ((c,s):xs) = [ SRWordHit c s ] ++ (getWordHits' xs)

