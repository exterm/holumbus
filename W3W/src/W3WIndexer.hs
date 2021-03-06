{-# OPTIONS #-}

-- ------------------------------------------------------------

module Main
where

import           Codec.Compression.BZip ( compress, decompress )

import           Control.Monad.Reader

import           Data.Binary
import           Data.Char
import           Data.Function.Selector
import           Data.Maybe

import           IndexConfig
import           IndexTypes
import           PageInfo

import           URIConfig

import           Holumbus.Crawler
import           Holumbus.Crawler.CacheCore
import           Holumbus.Crawler.IndexerCore
import           Holumbus.Crawler.PdfToText

import           System.Console.GetOpt
import           System.Environment
import           System.Exit
import           System.IO

import           Text.XML.HXT.Core
import           Text.XML.HXT.Cache
import           Text.XML.HXT.Curl

-- ------------------------------------------------------------

data AppAction
    = BuildIx | BuildCache | MergeIx
      deriving (Eq, Show)

data AppOpts
    = AO
      { ao_progname  :: String
      , ao_index     :: String
      , ao_ixout     :: String
      , ao_ixsearch  :: String
      , ao_xml       :: String
      , ao_help      :: Bool
      , ao_action    :: AppAction
      , ao_defrag    :: Bool
      , ao_partix    :: Bool
      , ao_resume    :: Maybe String
      , ao_msg       :: String
      , ao_crawlDoc  :: (Int, Int, Int)
      , ao_crawlSav  :: Int
      , ao_crawlSfn  :: String
      , ao_crawlLog  :: (Priority, Priority)
      , ao_crawlPar  :: SysConfig
      , ao_crawlFct  :: W3WIndexerConfig    -> W3WIndexerConfig
      , ao_crawlCch  :: CacheCrawlerConfig  -> CacheCrawlerConfig
      , ao_uriConfig :: UriConfig
      }

-- ------------------------------------------------------------

initAppOpts :: AppOpts
initAppOpts
    = AO
      { ao_progname = "w3wIndexer"
      , ao_index    = ""
      , ao_ixout    = ""
      , ao_ixsearch = ""
      , ao_xml      = ""
      , ao_help     = False
      , ao_action   = BuildIx
      , ao_defrag   = False
      , ao_partix   = False
      , ao_resume   = Nothing
      , ao_msg      = ""
      , ao_crawlDoc = (25000, 1024, 1)                                      -- max docs, max par docs, max threads: no parallel threads, but 1024 docs are indexed before results are inserted
      , ao_crawlSav = 5000                                                      -- save intervall
      , ao_crawlSfn = "./tmp/ix-"                                               -- save path
      , ao_crawlLog = (DEBUG, NOTICE)                                       -- log cache and hxt
      , ao_crawlPar = withCache' (60 * 60 * 24 * 1)                         -- set cache dir, cache remains valid 1 day, 404 pages are cached
                      >>>
                      withCompression (compress, decompress)                -- compress cache files
                      >>>
                      withStrictDeserialize yes                             -- strict input of cache files
                      >>>
                      withAcceptedMimeTypes [ text_html
                                            , application_xhtml
                                            , application_pdf
                                            ]
                      >>>
                      withCurl [ (curl_location,             v_1)            -- automatically follow redirects
                               , (curl_max_redirects,        "3")            -- but limit # of redirects to 3
                               ]
                      >>>
                      withRedirect no
                      >>>
                      withInputOption curl_max_filesize (show (1024 * 1024 * 3 `div` 2 ::Int))
                                                                             -- this limit excludes automtically generated pages, sometimes > 1.5 Mbyte
                      >>>
                      withParseHTML no
                      >>>
                      withParseByMimeType yes
                      >>>
                      withMimeTypeHandler application_pdf extractPdfText

      , ao_crawlFct = ( editPackageURIs                                     -- configure URI rewriting
                        >>>
                        disableRobotsTxt                                    -- for w3w robots.txt is not needed
                      )
      , ao_crawlCch = ( editPackageURIs                                     -- configure URI rewriting
                        >>>
                        disableRobotsTxt                                    -- for w3w robots.txt is not needed
                      )
      , ao_uriConfig = UCFullIndex
      }
    where
      editPackageURIs
          = chgS theProcessRefs (>>> arr editTilde)

withCache'                      :: Int -> XIOSysState -> XIOSysState
withCache' sec                  = withCache "./cache" sec yes

-- ------------------------------------------------------------

type HIO = ReaderT AppOpts IO

main :: IO ()
main
    = do pn   <- getProgName
         args <- getArgs
         runReaderT main2 (evalOptions pn args)

-- ------------------------------------------------------------

main2 :: HIO ()
main2
    = do (h, pn) <- asks (ao_help &&& ao_progname)
         if h
            then do msg <- asks ao_msg
                    liftIO $ do hPutStrLn stderr (msg ++ "\n" ++ usageInfo pn w3wOptDescr)
                                if null msg
                                   then exitSuccess
                                   else exitFailure
            else do asks (snd . ao_crawlLog) >>= setLogLevel ""
                    a <- asks ao_action
                    case a of
                      BuildCache -> mainCache
                      BuildIx    -> mainIndex
                      MergeIx    -> mainMerge
                    liftIO $ exitSuccess

-- ------------------------------------------------------------

mainIndex :: HIO ()
mainIndex
    = action
    where
      action
          = do rs <- asks ao_resume
               if isJust rs
                  then notice ["resume haddock document indexing"]
                  else return ()
               indexPkg >>= writePartialRes

mainMerge :: HIO ()
mainMerge
    = loadPartialIx >>= mergeAndWritePartialRes
    where
      loadPartialIx :: HIO [Int]
      loadPartialIx
          = local
            (\ o -> o { ao_action   = BuildIx })
            (snd `fmap` indexPkg)

indexPkg :: HIO (W3WIndexerState, [Int])
indexPkg
    = do notice ["indexing all w3w pages"]
         getS (theResultAccu .&&&. theListOfDocsSaved) `fmap` w3wIndexer

mainCache :: HIO ()
mainCache
    = do rs <- asks ao_resume
         notice $ if isJust rs
                  then ["resume cache update"]
                  else ["cache w3w pages"]
         w3wCacher >>= writeResults

-- ------------------------------------------------------------

w3wIndexer :: HIO W3WIndexerCrawlerState
w3wIndexer
    = do o <- ask
         liftIO $ stdIndexer
                    (config o)
                    (ao_resume o)
                    (w3wStart $ ao_uriConfig o)
                    emptyW3WState
    where
    config0 o
        = indexCrawlerConfig
          (ao_crawlPar o)
          (w3wRefs $ ao_uriConfig o)
          Nothing
          (Just $ checkDocumentStatus >>> checkTransferStatus >>> preDocumentFilter)
          (Just $ w3wGetTitle)
          (Just $ w3wGetPageInfo)
          (w3wIndexConfig)
                                  
    config o
        = ao_crawlFct o $
          setCrawlerTraceLevel ct ht $
          setCrawlerSaveConf si sp   $
          setCrawlerSaveAction partA $
          setCrawlerMaxDocs md mp mt $
          config0                    $ o
        where
          xout              = ao_xml      o
          (ct, ht)          = ao_crawlLog o
          si                = ao_crawlSav o
          sp                = ao_crawlSfn o
          (md, mp, mt)      = ao_crawlDoc o
          partA
              | ao_partix o = writePartialIndex (not . null $ xout)
              | otherwise   = const $ return ()

-- ------------------------------------------------------------

checkTransferStatus :: IOSArrow XmlTree XmlTree
checkTransferStatus
    = ( ( getAttrValue transferStatus
          >>>
          isA (== "200")
        )
        `guards` this
      )

-- ------------------------------------------------------------

preDocumentFilter :: IOSArrow XmlTree XmlTree
preDocumentFilter
    = choiceA
      [ isHtmlContents  :-> this                  -- do nothing
      , isPdfContents   :-> this                  -- extractPdfText is already done in readDocument
   -- , isPdfContents   :-> extractPdfText        -- extract the text from a pdf
      , this            :-> replaceChildren none  -- throw away any contents
      ]

extractPdfText :: IOSArrow XmlTree XmlTree
extractPdfText
    = traceDoc "Indexer: extractPdfText: start"
      >>>
      processChildren ( deep getText >>> pdfToTextA >>> mkText )
      >>>
      traceDoc "Indexer: extractPdfText: result"
        

-- ------------------------------------------------------------

w3wCacher :: HIO CacheCrawlerState
w3wCacher
    = do o <- ask
         liftIO $ stdCacher
                    (ao_crawlDoc o)
                    (ao_crawlSav o, ao_crawlSfn o)
                    (ao_crawlLog o)
                    (ao_crawlPar o)
                    (ao_crawlCch o)
                    (ao_resume o)
                    (w3wStart $ ao_uriConfig o)
                    (w3wRefs  $ ao_uriConfig o)

-- ------------------------------------------------------------

writePartialRes :: (W3WIndexerState, [Int]) -> HIO ()
writePartialRes (s, ps)
    = do part <- asks ao_partix
         if part
            then mergeAndWritePartialRes ps
            else writeRes s
    where
      writeRes s'
          = writeSearchBin' s' >> writeResults s'

      writeSearchBin' s'
          = do out <- asks ao_ixsearch
               writeSearchBin out s'

mergeAndWritePartialRes :: [Int] -> HIO ()
mergeAndWritePartialRes ps
    = do pxs <- (\ fn -> map (mkTmpFile 10 fn) ps) `fmap` asks ao_crawlSfn
         out <- asks ao_ixsearch
         mergeAndWritePartialRes' id' pxs out
    where
      id' :: SmallDocuments PageInfo -> SmallDocuments PageInfo
      id' = id

-- ------------------------------------------------------------

writeResults :: (XmlPickler a, Binary a) => a -> HIO ()
writeResults v
    = do (xf, of') <- asks (ao_xml &&& (ao_ixout &&& ao_index))
         writeXml xf  v
         writeBin (out of') v
    where
      out (bf, bi)
          | null bf     = bi
          | otherwise   = bf

-- ------------------------------------------------------------

notice :: MonadIO m => [String] -> m ()
notice = noticeC "w3w"

-- ------------------------------------------------------------

evalOptions :: String -> [String] -> AppOpts
evalOptions pn args
    = foldl (.) (ef1 . ef2) opts $
      initAppOpts { ao_progname = pn }
    where
    (opts, ns, es)   = getOpt Permute w3wOptDescr args
    ef1
        | null es    = id
        | otherwise  = \ x -> x { ao_help   = True
                                , ao_msg = concat es
                                }
        | otherwise  = id
    ef2
        | null ns    = id
        | otherwise  = \ x -> x { ao_help   = True
                                , ao_msg = "wrong program arguments: " ++ unwords ns
                                }

-- ------------------------------------------------------------

w3wOptDescr :: [OptDescr (AppOpts -> AppOpts)]
w3wOptDescr
    = [ Option "h?" ["help"]
        ( NoArg $
          \ x -> x { ao_help = True }
        )
        "usage info"

      , Option "" ["build-index"]
        ( NoArg $
          \ x -> x { ao_crawlSfn = "./tmp/ix-" }
        )
        "build W3W index (default)"

      , Option "" ["build-cache"]
        ( NoArg $
          \ x -> x { ao_action = BuildCache }
        )
        "update the W3W cache"

      , Option "" ["test-index"]
        ( NoArg $
          \ x -> x { ao_uriConfig = UCTestIndex }
        )
        "build a small sub index of the fhw pages for testing"

      , Option "" ["debug-index"]
        ( NoArg $
          \ x -> x { ao_uriConfig = UCDebugIndex }
        )
        "build a small sub index of the fhw pages for testing"

      , Option "i" ["index"]
        ( ReqArg
          (\ f x -> x { ao_index = f })
          "INDEX"
        )
        "index input file (binary format) to be operated on"

      , Option "n" ["new-index"]
        ( ReqArg
          (\ f x -> x { ao_ixout = f })
          "NEW-INDEX"
        )
        "new index file (binary format) to be generatet, default is index file"

      , Option "s" ["new-search"]
        ( ReqArg
          (\ f x -> x { ao_ixsearch = f })
          "SEARCH-INDEX"
        )
        "new search index files (binary format) ready to be used by W3W! search"

      , Option "x" ["xml-output"]
        ( ReqArg
          (\ f x -> x { ao_xml = f })
          "XML-FILE"
        )
        "output of final crawler state in xml format, \"-\" for stdout"

      , Option "r" ["resume"]
        ( ReqArg
          (\ s x -> x { ao_resume = Just s})
          "FILE"
        )
        "resume program with file containing saved intermediate state"

      , Option "" ["maxdocs"]
        ( ReqArg
          (setOption parseInt (\ x i -> x { ao_crawlDoc = setMaxDocs i $
                                                          ao_crawlDoc x }))
          "NUMBER"
        )
        "maximum # of docs to be processed"

      , Option "" ["maxthreads"]
        ( ReqArg
          (setOption parseInt (\ x i -> x { ao_crawlDoc = setMaxThreads i $
                                                          ao_crawlDoc x }))
          "NUMBER"
        )
        ( "maximum # of parallel threads, 0: sequential, 1: " ++
          "single thread with binary merge, else real parallel threads, default: 1" )

      , Option "" ["maxpar"]
        ( ReqArg
          (setOption parseInt (\ x i -> x { ao_crawlDoc = setMaxParDocs i $
                                                          ao_crawlDoc x }))
          "NUMBER"
        )
        "maximum # of docs indexed at once before the results are inserted into index, default: 1024"

      , Option "" ["valid"]
        ( ReqArg
          (setOption parseTime (\ x t -> x { ao_crawlPar = setDocAge t $
                                                           ao_crawlPar x }))
          "DURATION"
        )
        ( "validate cache for pages older than given time, format: " ++
          "10sec, 5min, 20hours, 3days, 5weeks, 1month, default is 1month" )

      , Option "" ["partition"]
        ( ReqArg
          (setOption parseInt (\ x i -> x { ao_partix    = True
                                          , ao_crawlSav  = i }))
          "NUMBER"
        )
        ( "partition the index into smaller chunks of given # of docs" ++
          " and write the index part by part" )

      , Option "" ["merge"]
        ( ReqArg
          (\ s x -> x { ao_action     = MergeIx
                      , ao_resume     = Just s})
          "FILE"
        )
        "merge chunks into final index, resume with latest crawler state"

      , Option "" ["save"]
        ( ReqArg
          (setOption parseInt (\ x i -> x { ao_crawlSav  = i }))
          "NUMBER"
        )
        "save intermediate results of index, default is 5000"
      ]
    where
      setOption parse f s x
          = either (\ e -> x { ao_msg  = e
                             , ao_help = True
                             }
                   ) (f x) . parse $ s

-- ------------------------------------------------------------

parseInt                                :: String -> Either String Int
parseInt s
    | match "[0-9]+" s                  = Right $ read s
    | otherwise                         = Left  $ "number expected in option arg"

parseTime                               :: String -> Either String Int
parseTime s
    | match "[0-9]+(s(ec)?)?"      s    = Right $ t
    | match "[0-9]+(m(in)?)?"      s    = Right $ t * 60
    | match "[0-9]+(h(our(s)?)?)?" s    = Right $ t * 60 * 60
    | match "[0-9]+(d(ay(s)?)?)?"  s    = Right $ t * 60 * 60 * 24
    | match "[0-9]+(w(eek(s)?)?)?" s    = Right $ t * 60 * 60 * 24 * 7
    | match "[0-9]+(m(onth(s)?)?)?" s   = Right $ t * 60 * 60 * 24 * 30
    | match "[0-9]+(y(ear(s)?)?)?" s    = Right $ t * 60 * 60 * 24 * 30 * 365
    | otherwise                         = Left  $ "error in duration format in option arg"
    where
    t                                   = read . filter isDigit $ s

-- ------------------------------------------------------------

setMaxDocs                              :: Int -> (Int, Int, Int) -> (Int, Int, Int)
setMaxDocs    md (_md, mp, mt)          = (md, md `min` mp, mt)

setMaxParDocs                           :: Int -> (Int, Int, Int) -> (Int, Int, Int)
setMaxParDocs mp (md, _mp, mt)          = (md, mp, mt)

setMaxThreads                           :: Int -> (Int, Int, Int) -> (Int, Int, Int)
setMaxThreads mt (md, mp, _mt)          = (md, mp, mt)

setDocAge                               :: Int -> SysConfig -> SysConfig
setDocAge d                             = (>>> withCache' d)

-- ------------------------------------------------------------
