-- ----------------------------------------------------------------------------

{- |
  Module     : WebSearch
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (tbh@holumbus.org)
  Stability  : experimental
  Portability: portable
  Version    : 0.3

  An example of how Holumbus can be used together with the Janus application
  server to create a web service.
 
-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -fglasgow-exts -farrows -fno-warn-type-defaults #-}

module Network.Server.Janus.Shader.WebSearch where

import Data.Function
import Data.Maybe

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.IntMap as IM

import Network.HTTP (urlDecode)

import Text.XML.HXT.Arrow
import Text.XML.HXT.DOM.Unicode

import Holumbus.Index.Inverted (Inverted)
import Holumbus.Index.Documents (Documents)
import Holumbus.Index.Common

import Holumbus.Query.Language.Grammar
import Holumbus.Query.Language.Parser
import Holumbus.Query.Processor
import Holumbus.Query.Result
import Holumbus.Query.Ranking
import Holumbus.Query.Fuzzy

import Network.Server.Janus.Core (Shader, ShaderCreator)
import qualified Network.Server.Janus.Core as J
import Network.Server.Janus.XmlHelper
import Network.Server.Janus.JanusPaths

import System.Time

import Control.Concurrent  -- For the global MVar

-- Status information of query processing.
type StatusResult = (String, Result Int)

-- | The place where the filename of the index file is stored in the server configuration XML file.
_shader_config_index :: JanusPath
_shader_config_index = jp "/shader/config/@index"

-- | The place where the filename of the documents file is stored in the server configuration XML file.
_shader_config_documents :: JanusPath
_shader_config_documents = jp "/shader/config/@documents"

-- | Just an alias with explicit type.
loadIndex :: FilePath -> IO Inverted
loadIndex = loadFromFile

-- | Just an alias with explicit type.
loadDocuments :: FilePath -> IO (Documents Int)
loadDocuments = loadFromFile

-- | Creates the websearch shader. Basically the configuration values are read from the server
-- configuration and the index and documents files are loaded.
websearchShader :: ShaderCreator
websearchShader = J.mkDynamicCreator $ proc (conf, _) -> do
  -- Load the files and create the indexes.
  idx <- (arrIO $ loadIndex) <<< (getValDef _shader_config_index "") -< conf
  doc <- (arrIO $ loadDocuments) <<< (getValDef _shader_config_documents "") -< conf
  -- Store the data in MVar's to allow shared access.
  mix <- arrIO $ newMVar -< idx
  moc <- arrIO $ newMVar -< doc
  -- Return the shader.
  returnA -< websearchService mix moc

-- | The websearch shader. Processes incoming search requests.
websearchService :: (HolIndex i, HolDocuments d Int) => MVar i -> MVar (d Int) -> Shader
websearchService mix moc = proc inTxn -> do
  -- Because index access is read only, the MVar's are just read to make them avaliable again.
  idx      <- arrIO $ readMVar                                                   -< mix
  doc      <- arrIO $ readMVar                                                   -< moc
  -- Extract the query from the incoming transaction and log it to stdout.
  request  <- getValDef (_transaction_http_request_cgi_ "@query") ""             -< inTxn
  start    <- readDef 0 <<< getValDef (_transaction_http_request_cgi_ "@start") "" -< inTxn
  -- Output some information about the request.
  arrLogRequest                                                                  -< inTxn
  -- Parse the query and generate a result or an error depending on the parse result.
  response <- writeString start <<< (genError ||| genResult) <<< arrParseQuery   -<< (request, (idx, doc))
  -- Put the response value into the transaction.
  setVal _transaction_http_response_body response                                -<< inTxn    
    where
    -- Transforms the result and the status information to HTML by pickling it using the XML picklers.
    writeString s = pickleStatusResult s >>> (writeDocumentToString [(a_no_xml_pi, v_1), (a_output_encoding, utf8)])
    pickleStatusResult s = xpickleVal (xpStatusResult s)
    readDef d = arr $ fromMaybe d . readM

-- | Enable handling of parse errors from 'read'.
readM :: (Read a, Monad m) => String -> m a
readM s = case reads s of
            [(x, "")] -> return x
            _         -> fail "No parse"

-- | Tries to parse the search string and returns either the parsed query or an error message.
arrParseQuery :: (HolIndex i, HolDocuments d Int, ArrowXml a) => 
                 a (String, (i, d Int)) (Either (String, (i, d Int)) (Query, (i, d Int)))
arrParseQuery =  (first arrDecode)
                 >>>
                 (arr $ (\(r, ind) -> either (\m -> Left (m, ind)) (\q -> Right (q, ind)) (parseQuery r)))

-- | Decode any URI encoded entities and transform to unicode.
arrDecode :: Arrow a => a String String
arrDecode = arr $ fst . utf8ToUnicode . urlDecode

-- | Log a request to stdout.
arrLogRequest :: JanusArrow J.Context XmlTree ()
arrLogRequest = proc inTxn -> do
  -- Extract remote host and the search string from the incoming transaction.
  remHost <- getValDef (_transaction_tcp_remoteHost) ""                -< inTxn
  rawRequest <- getValDef (_transaction_http_request_cgi_ "@query") "" -< inTxn
  start <- getValDef (_transaction_http_request_cgi_ "@start") "0"     -< inTxn
  -- Decode URI encoded entities in the search string.
  decodedRequest <- arrDecode                                          -< rawRequest
  -- Get the current date and time.
  unixTime <- arrIO $ (\_ -> getClockTime)                             -< ()
  currTime <- arr $ calendarTimeToString . toUTCTime                   -< unixTime
  -- Output all the collected information from above to stdout.
  arrIO $ putStrLn -< (currTime ++ " - " ++ remHost ++ " - " ++ rawRequest ++ " - " ++ decodedRequest ++ " - " ++ start)

-- | This is the core arrow where the request is finally processed.
genResult :: (HolIndex i, HolDocuments d Int, ArrowXml a) => a (Query, (i, d Int)) (String, Result Int)
genResult = let 
              rankCfg = RankConfig (docRankWeightedByCount weights) wordRankByCount
              weights = [("title", 0.8), ("keywords", 0.6), ("headlines", 0.4), ("content", 0.2)]
            in
            -- Check for a minimal term length of two character to avoid very large results.
            ifP (\(q, _) -> checkWith ((> 1) . length) q)
              ((arr $ (\(q, ind) -> (makeQuery ind q, ind))) -- Execute the query
              >>>
              (first $ arr $ rank rankCfg)                   -- Perform ranking of the results
              >>>
              (arr $ (\(r, _) -> (msgSuccess r , r))))       -- Include a success message in the status
              
              -- Tell the user to enter more characters if the search terms are too short.
              (arr $ (\(_, _) -> ("Please enter some more characters.", emptyResult)))

-- | Generate a success status response from a query result.
msgSuccess :: Result Int -> String
msgSuccess r = if sd == 0 then "Nothing found yet." 
               else "Found " ++ (show sd) ++ " " ++ ds ++ " and " ++ (show sw) ++ " " ++ cs ++ "."
                 where
                 sd = sizeDocHits r
                 sw = sizeWordHits r
                 ds = if sd == 1 then "document" else "documents"
                 cs = if sw == 1 then "completion" else "completions"

-- | This is where the magic happens! This helper function really calls the 
-- processing function which executes the query.
makeQuery :: (HolIndex i, HolDocuments d Int) => (i, d Int) -> Query -> Result Int
makeQuery (i, d) q = processQuery cfg i d (optimize q)
                       where
                       cfg = ProcessConfig (FuzzyConfig True True 1.0 germanReplacements) True 100

-- | Generate an error message in case the query could not be parsed.
genError :: (HolIndex i, HolDocuments d Int, ArrowXml a) => a (String, (i, d Int)) (String, Result Int)
genError = arr $ (\(msg, _) -> (msg, emptyResult))

-- | The combined pickler for the status response and the result.
xpStatusResult :: Int -> PU StatusResult
xpStatusResult s = xpElem "div" $ xpAddFixedAttr "id" "result" $ xpPair xpStatus (xpResultHtml s)

-- | Enclose the status message in a <div> tag.
xpStatus :: PU String
xpStatus = xpDivId "status" xpText

-- | The HTML Result pickler. Extracts the maximum word score for proper scaling in the cloud.
xpResultHtml :: Int -> PU (Result Int)
xpResultHtml s = xpWrap (\((_, wh), (_, dh)) -> Result dh wh, \r -> ((maxScoreWordHits r, wordHits r), (sizeDocHits r, docHits r))) 
                 (xpPair xpWordHitsHtml (xpDocHitsHtml s))

-- | Wrapping something in a <div> element with id attribute.
xpDivId :: String -> PU a -> PU a
xpDivId i p = xpElem "div" (xpAddFixedAttr "id" i p)

-- | Wrapping something in a <div> element with class attribute.
xpDivClass :: String -> PU a -> PU a
xpDivClass c p = xpElem "div" (xpAddFixedAttr "class" c p)

-- | Set the class of the surrounding element.
xpClass :: String -> PU a -> PU a
xpClass c p = xpAddFixedAttr "class" c p

-- | Append some text after pickling something else.
xpAppend :: String -> PU a -> PU a
xpAppend t p = xpWrap (\(v, _) -> v, \v -> (v, t)) (xpPair p xpText)

-- | Prepend some text before pickling something else.
xpPrepend :: String -> PU a -> PU a
xpPrepend t p = xpWrap (\(_, v) -> v, \v -> (t, v)) (xpPair xpText p)

-- | The HTML pickler for the document hits. Will be sorted by score. Also generates the navigation.
xpDocHitsHtml :: Int -> PU (Int, DocHits Int)
xpDocHitsHtml s = xpWrap (\(d, n) -> (n, d) ,\(n, d) -> (d, n)) (xpPair xpDocs (xpPager s))
  where
  xpDocs = xpDivId "documents" (xpWrap (IM.fromList, toListSorted) (xpList xpDocHitHtml))
  toListSorted = take pageLimit . drop s . reverse . L.sortBy (compare `on` (docScore . fst . snd)) . IM.toList -- Sort by score
  xpDocHitHtml = xpDivClass "document" $ xpDocInfoHtml

xpPager :: Int -> PU Int
xpPager s = xpDivId "pager" (xpWrap (\_ -> 0, makePager s pageLimit) xpickle)

xpDocInfoHtml :: PU (DocId, (DocInfo Int, DocContextHits))
xpDocInfoHtml = xpWrap (docFromHtml, docToHtml) (xpTriple xpTitleHtml xpContextsHtml xpURIHtml)
  where
  docToHtml (_, (DocInfo (Document t u _) _, dch)) = ((u, t), dch, u)
  docFromHtml ((u, t), dch, _) = (0, (DocInfo (Document t u Nothing) 0.0, dch))
  xpTitleHtml = xpDivClass "title" $ xpElem "a" $ xpClass "link" $ (xpPair (xpAttr "href" xpText) xpText)
  xpContextsHtml = xpDivClass "contexts" $ xpWrap (M.fromList, M.toList) (xpList xpContextHtml)
  xpContextHtml = xpPair (xpElem "span" $ xpClass "context" $ xpAppend ": " $ xpText) xpWordsHtml
  xpWordsHtml = xpWrap (M.fromList, M.toList) (xpList (xpPair (xpAppend " " $ xpText) xpZero))
  xpURIHtml = xpDivClass "uri" $ xpText

xpWordHitsHtml :: PU (Score, WordHits)
xpWordHitsHtml = xpDivId "words" $ xpElem "p" $ xpClass "cloud" $ xpWrap (fromListSorted, toListSorted) (xpList xpWordHitHtml)
  where
  fromListSorted _ = (0.0, M.empty)
  toListSorted (s, wh) = map (\a -> (s, a)) $ L.sortBy (compare `on` fst) $ M.toList wh -- Sort by word
  xpWordHitHtml = xpWrap (wordFromHtml, wordToHtml) (xpWordHtml)
    where
    wordToHtml (m, (w, (WordInfo ts s, _))) = ((head ts, w), ((s, m), w))
    wordFromHtml ((t, _), ((s, m), w)) = (m, (w, (WordInfo [t] s, M.empty)))
    xpWordHtml = xpAppend " " $ xpElem "a" $ xpClass "cloud" $ xpPair xpLink xpScore

xpLink :: PU (String, Word)
xpLink = xpAttr "href" $ xpPair (xpPrepend "javascript:replaceInQuery('" $ xpAppend "','" xpText) (xpAppend "')" $ xpText)

xpScore :: PU ((Score, Score), Word)
xpScore = xpElem "span" $ xpPair (xpAttr "class" $ xpWrap (scoreFromHtml, scoreToHtml) xpText) xpText
  where
  scoreToHtml (v, top) = "cloud" ++ (show $ round (weightScore 1 9 top v))
  scoreFromHtml _ = (0.0, 0.0)
  weightScore mi ma to v = ma - ((to - v) / to) * (ma - mi)

pageLimit :: Int
pageLimit = 10

data Pager = Pager 
  { prevPage  :: Maybe Int -- == last predPages
  , predPages :: [(Int, Int)]
  , currPage  :: Int
  , succPages :: [(Int, Int)]
  , nextPage  :: Maybe Int -- == head succPages
  }

instance XmlPickler Pager where
  xpickle = xpWrap convert (xp5Tuple xpPrevPage xpPages xpCurrPage xpPages xpNextPage)
    where
    convert = (\(pv, pd, c, sc, nt) -> Pager pv pd c sc nt, \(Pager pv pd c sc nt) -> (pv, pd, c, sc, nt))
    xpPrevPage = xpOption $ xpElem "a" $ xpClass "previous" $ xpAppend "<" $ xpAttr "href" xpShowPage
    xpCurrPage = xpElem "span" $ xpClass "current" $ xpPrim
    xpNextPage = xpOption $ xpElem "a" $ xpClass "next" $ xpAppend ">" $ xpAttr "href" xpShowPage
    xpPages = xpList $ xpElem "a" $ xpClass "page" $ xpPair (xpAttr "href" $ xpPrepend "javascript:showPage(" $ xpAppend ")" $ xpPrim) xpPrim
    xpShowPage = xpPrepend "javascript:showPage(" $ xpAppend ")" $ xpPrim

-- Start element (counting from zero), elements per page, total number of elements.
makePager :: Int -> Int -> Int -> Pager
makePager s p n = Pager pv pd (length pd + 1) sc nt
  where
  pv = if s < p then Nothing else Just (s - p)
  nt = if s + p >= n then Nothing else Just (s + p)
  pd = map (\x -> (x, x `div` p + 1)) $ genPred s []
    where
    genPred rp tp = let np = rp - p in if np < 0 then tp else genPred np (np:tp)
  sc = map (\x -> (x, x `div` p + 1)) $ genSucc s []
    where
    genSucc rs ts = let ns = rs + p in if ns >= n then ts else genSucc ns (ts ++ [ns])
