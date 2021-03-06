
-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Distribution.DNode
  Copyright  : Copyright (C) 2009 Stefan Schmidt
  License    : MIT

  Maintainer : Stefan Schmidt (stefanschmidt@web.de)
  Stability  : experimental
  Portability: portable
  Version    : 0.1
  
  Public interface of the DNode datatype. See Holumbus.Distribution.DNode.Base
  for further documentation.
-}

-- ----------------------------------------------------------------------------
module Holumbus.Distribution.DNode
(
    DistributedException(..)
    
  , DNodeConfig(..)
  , defaultDNodeConfig
  
  , DNodeId
  , mkDNodeId
  , DNodeAddress
  , mkDNodeAddress
  
  , DHandlerId
      
  , initDNode
  , deinitDNode
  , addForeignDNode
  , delForeignDNode
  , checkForeignDNode
  , addForeignDNodeHandler
  , addForeignDResourceHandler
  , delForeignHandler
  
  , getDNodeData                  -- debug
)
where

import           Holumbus.Distribution.DNode.Base
