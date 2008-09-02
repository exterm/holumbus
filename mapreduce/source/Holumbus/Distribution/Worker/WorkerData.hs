-- ----------------------------------------------------------------------------
{- |
  Module     : Holumbus.Distribution.Worker.WorkerData
  Copyright  : Copyright (C) 2008 Stefan Schmidt
  License    : MIT

  Maintainer : Stefan Schmidt (stefanschmidt@web.de)
  Stability  : experimental
  Portability: portable
  Version    : 0.1


-}
-- ----------------------------------------------------------------------------

module Holumbus.Distribution.Worker.WorkerData
(
-- * Datatypes
  WorkerData
  
-- * creation and destruction
, newWorker
)
where


import           Control.Concurrent
import qualified Control.Exception as E

import           Data.Maybe

import           System.Log.Logger

import           Holumbus.Common.Debug
import qualified Holumbus.FileSystem.FileSystem as FS
-- import           Holumbus.Network.Site
-- import           Holumbus.Network.Port
-- import           Holumbus.Network.Messages
import           Holumbus.Network.Communication
import           Holumbus.MapReduce.Types
import qualified Holumbus.MapReduce.TaskProcessor as TP
import qualified Holumbus.Distribution.Messages as M
import qualified Holumbus.Distribution.Master.MasterPort as MP
import qualified Holumbus.Distribution.Master as MC
import           Holumbus.Distribution.Worker
-- import           Holumbus.Common.Utils

localLogger :: String
localLogger = "Holumbus.Distribution.Worker.WorkerData"



data WorkerData = WorkerData {
    wd_Client         :: Client
--    wd_WorkerId       :: MVar (Maybe M.WorkerId)
--  , wd_SiteId         :: ! SiteId
--  , wd_ServerThreadId :: MVar (Maybe ThreadId)
--  , wd_OwnStream      :: ! M.WorkerRequestStream
--  , wd_OwnPort        :: ! M.WorkerRequestPort
--  , wd_MasterPort     :: MVar MP.MasterPort
  , wd_TaskProcessor  :: TP.TaskProcessor   
  }
  
  


newWorker :: FS.FileSystem -> ActionMap -> StreamName -> Maybe SocketId -> IO WorkerData
newWorker fs am sn soid
  = do
    -- initialise the client
    w <- newEmptyMVar
    client <- newClient sn soid (dispatch w)

    mp <- MP.newMasterPort sn soid
    mpMVar  <- newMVar mp
    
    -- configure the TaskProcessor
    tp <- TP.newTaskProcessor
    TP.setFileSystemToTaskProcessor fs tp
    TP.setActionMap am tp
    TP.setTaskCompletedHook (sendTaskCompleted mpMVar) tp
    TP.setTaskErrorHook (sendTaskError mpMVar) tp
    TP.startTaskProcessor tp
    
    let wd = (WorkerData client tp)

    putMVar w wd

    return wd


dispatch 
  :: MVar WorkerData
  -> M.WorkerRequestMessage 
  -> IO (Maybe M.WorkerResponseMessage)
dispatch w msg
  = do
    wd <- readMVar w
    case msg of
      (M.WReqStartTask td) ->
        do
        startTask td wd
        return $ Just $ M.WRspSuccess
      (M.WReqStopTask tid) ->
        do
        stopTask tid wd
        return $ Just $ M.WRspSuccess
      (M.WReqStopAllTasks) ->
        do
        stopAllTasks wd
        return $ Just $ M.WRspSuccess
      _ -> return Nothing


-- ----------------------------------------------------------------------------
--
-- ----------------------------------------------------------------------------

{-
registerWorker :: WorkerData -> IO (WorkerData)
registerWorker wd
  = do
    debugM localLogger "registering at controller"
    let sid = (wd_SiteId wd)
    let np = (wd_OwnPort wd)
    as <- TP.getActionNames (wd_TaskProcessor wd)
    -- get the new nid
    nid <- withMVar (wd_MasterPort wd) $
      \mp ->
      do  
      (nid, _) <- MC.registerWorker sid np as mp
      return (Just nid)
    -- write the new nodeId in the record
    modifyMVar (wd_WorkerId wd) (\_ -> return (nid,wd)) 
        

unregisterWorker :: WorkerData -> IO (WorkerData)
unregisterWorker wd
  = do
    debugM localLogger "unregistering at controller"
    nid <- readMVar (wd_WorkerId wd)
    unregister nid
    modifyMVar (wd_WorkerId wd) (\_ -> return (Nothing,wd))
    where
      unregister Nothing = return ()
      unregister (Just i)
        = do        
          withMVar (wd_MasterPort wd) $
            \cp -> MC.unregisterWorker i cp
          return ()
-}


-- ----------------------------------------------------------------------------
--
-- ----------------------------------------------------------------------------


sendTaskCompleted :: MVar MP.MasterPort -> TaskData -> IO Bool
sendTaskCompleted mvmp td
  = E.handle (\_ -> return False) $
      modifyMVar mvmp $
        \mp ->
        do
        debugM localLogger $ "completed Task" ++ show (td_TaskId td)
        MC.receiveTaskCompleted td mp
        return (mp, True)


sendTaskError :: MVar MP.MasterPort -> TaskData -> IO Bool
sendTaskError mvmp td
  = E.handle (\_ -> return False) $
      modifyMVar mvmp $
        \mp ->
        do
        debugM localLogger $ "error Task" ++ show (td_TaskId td)
        MC.receiveTaskError td mp
        return (mp, True)


-- ----------------------------------------------------------------------------
--
-- ----------------------------------------------------------------------------



instance WorkerClass WorkerData where

  closeWorker wd
    = do
      closeClient (wd_Client wd)
      return ()
  
  
  startTask td wd
    = do
      let tp = (wd_TaskProcessor wd)
      debugM localLogger $ "executing Task" ++ show (td_TaskId td)
      TP.startTask td tp
      return wd
  
  
  stopTask tid wd
    = do
      let tp = (wd_TaskProcessor wd)
      debugM localLogger $ "stopping Task" ++ show tid      
      TP.stopTask tid tp
      return wd
    

  stopAllTasks wd
    = do
      let tp = (wd_TaskProcessor wd)
      debugM localLogger "stopping all Tasks"
      TP.stopAllTasks tp
      return wd

  
instance Debug WorkerData where
  printDebug wd
    = do
      putStrLn "Worker-Object (full)"
      printDebug (wd_Client wd)
      tp <- TP.printTaskProcessor (wd_TaskProcessor wd)
      putStrLn "TaskProcessor:"
      putStrLn tp
