-- ------------------------------------------------------------

mapFoldBinary			:: (a -> b) -> (b -> b -> b) -> [a] -> b
mapFoldBinary m f xs0		= fst $ mapLeft (1::Int) $ map1 xs0
    where
    -- map1			:: [a] -> (b, [a])
    map1 (x:xs)			= (m x, xs)
    map1 []			= error "mapFoldBinary with empty list"

    -- mapLeft			:: Int -> (b, [a]) -> (b, [a])
    mapLeft n (r1, xs1)
	| null xs1		= (r1, [])
	| null xs2		= (r,  [])
	| otherwise		= mapLeft (n + 1) (r, xs2)
	where
	(r2, xs2)		= mapRight n xs1
	r			= f r1 r2

    -- mapRight			:: Int -> [a] -> (b, [a])
    mapRight 1 xs		= map1 xs
    mapRight n xs
	| null xs1		= (r1,      [] )
	| otherwise		= (f r1 r2, xs2)
	where
	(r1, xs1)		= mapRight (n - 1) xs
	(r2, xs2)		= mapRight (n - 1) xs1

-- ------------------------------------------------------------

t1	:: [Int] -> String
t1 = mapFoldBinary show (\ x y -> "(" ++ x ++ "+" ++ y ++ ")")

-- ------------------------------------------------------------

mapFoldBinaryM			:: (Monad m) =>
				   (a -> m b) -> (b -> b -> m b) -> [a] -> m b
mapFoldBinaryM m f xs0		= do
				  r0 <- map1 xs0
				  rn <- mapLeft (1::Int) r0
				  return (fst rn)
    where
    -- map1			:: [a] -> m (b, [a])
    map1 (x:xs)			= do
				  r1 <- m x
				  return (r1, xs)
    map1 []			= error "mapFoldBinary with empty list"

    -- mapLeft			:: Int -> (b, [a]) -> m (b, [a])
    mapLeft n r@(r1, xs1)
	| null xs1		= return r
	| otherwise		= do
				  (r2, xs2) <- mapRight n xs1
				  res       <- f r1 r2
				  ( if null xs2
				    then return
				    else mapLeft (n + 1) ) (res, xs2)

    -- mapRight			:: Int -> [a] -> m (b, [a])
    mapRight 1 xs		= map1 xs
    mapRight n xs		= do
				  r@(r1, xs1) <- mapRight (n - 1) xs
				  if null xs1
				     then return r
				     else do
					  (r2, xs2) <- mapRight (n - 1) xs1
					  res       <- f r1 r2
					  return (res, xs2)

-- ------------------------------------------------------------

t1m	:: [Int] -> IO String
t1m = mapFoldBinaryM ( \ x -> ( do
				print x
				return (show x)
			      )
		     ) ( \ x y -> ( do
				    putStrLn $ "(" ++ x ++ "+" ++ y ++ ")"
				    return $ "(" ++ x ++ "+" ++ y ++ ")"
				  )
		       )

-- ------------------------------------------------------------
