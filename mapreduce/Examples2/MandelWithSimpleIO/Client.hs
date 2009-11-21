module Main
(
   main
)
where

-- the mr facade
import Holumbus.Distribution.SimpleDMapReduceIO

-- mandel libs
import Examples2.MandelWithSimpleIO.DMandel
import Examples2.MandelWithSimpleIO.ImageTypes

-- system libs
import System.Environment
import Control.Parallel.Strategies
import Data.List

main :: IO ()
main = do 
  -- read command line arguments
  (filename : quartet : triplet : [] ) <- getArgs
  let (w,h,zmax,iterations) = read quartet
      ; (splitters,mappers,reducers) = read triplet
      ; list = partition' (pixels w h) [[]|_<-[1..splitters]]
    
  -- call map reduce
  result <- client mandelMap mandelReduce (w,h,zmax,iterations) (splitters,mappers,reducers) list
  
  -- make the image
  let pix = (concat . map snd . sortBy sortPixels) result
  saveImage (Geo w h) pix filename

  
{-
 generate the pixlist
-}
pixels :: Int -> Int -> [(Int,[Int])]
pixels w h
  = let t = [(y,[0..w-1])|y<-[0..h-1]] in rnf t`seq` t
  

{-
  order function the pixels 
-}
sortPixels :: (Ord k) => (k,v) -> (k,v) -> Ordering
sortPixels (k1,_) (k2,_) 
  | k1 > k2 = GT
  | k1 < k2 = LT
  | otherwise = EQ