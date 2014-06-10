{-# LANGUAGE BangPatterns #-}

{-| Implementation of configuration reader with watching support.

-}

{-

Copyright (C) 2011, 2012, 2013 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Ganeti.ConfigReader
  ( ConfigReader
  , initConfigReader
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad (liftM, unless)
import Data.IORef
import System.Posix.Files
import System.Posix.Types
import System.INotify

import Ganeti.BasicTypes
import Ganeti.Objects
import Ganeti.Confd.Utils
import Ganeti.Config
import Ganeti.Logging
import qualified Ganeti.Constants as C
import qualified Ganeti.Path as Path
import Ganeti.Utils

-- | A type for functions that can return the configuration when
-- executed.
type ConfigReader = IO (Result ConfigData)

-- | File stat identifier.
type FStat = (EpochTime, FileID, FileOffset)

-- | Null 'FStat' value.
nullFStat :: FStat
nullFStat = (-1, -1, -1)

-- | Reload model data type.
data ReloadModel = ReloadNotify      -- ^ We are using notifications
                 | ReloadPoll Int    -- ^ We are using polling
                   deriving (Eq, Show)

-- | Server state data type.
data ServerState = ServerState
  { reloadModel  :: ReloadModel
  , reloadTime   :: Integer      -- ^ Reload time (epoch) in microseconds
  , reloadFStat  :: FStat
  }

-- | Maximum no-reload poll rounds before reverting to inotify.
maxIdlePollRounds :: Int
maxIdlePollRounds = 3

-- | Reload timeout in microseconds.
watchInterval :: Int
watchInterval = C.confdConfigReloadTimeout * 1000000

-- | Ratelimit timeout in microseconds.
pollInterval :: Int
pollInterval = C.confdConfigReloadRatelimit

-- | Ratelimit timeout in microseconds, as an 'Integer'.
reloadRatelimit :: Integer
reloadRatelimit = fromIntegral C.confdConfigReloadRatelimit

-- | Initial poll round.
initialPoll :: ReloadModel
initialPoll = ReloadPoll 0

-- | Reload status data type.
data ConfigReload = ConfigToDate    -- ^ No need to reload
                  | ConfigReloaded  -- ^ Configuration reloaded
                  | ConfigIOError   -- ^ Error during configuration reload
                    deriving (Eq)

-- * Configuration handling

-- ** Helper functions

-- | Helper function for logging transition into polling mode.
moveToPolling :: String -> INotify -> FilePath -> (Result ConfigData -> IO ())
              -> MVar ServerState -> IO ReloadModel
moveToPolling msg inotify path save_fn mstate = do
  logInfo $ "Moving to polling mode: " ++ msg
  let inotiaction = addNotifier inotify path save_fn mstate
  _ <- forkIO $ onPollTimer inotiaction path save_fn mstate
  return initialPoll

-- | Helper function for logging transition into inotify mode.
moveToNotify :: IO ReloadModel
moveToNotify = do
  logInfo "Moving to inotify mode"
  return ReloadNotify

-- ** Configuration loading

-- | (Re)loads the configuration.
updateConfig :: FilePath -> (Result ConfigData -> IO ()) -> IO ()
updateConfig path save_fn = do
  newcfg <- loadConfig path
  let !newdata = case newcfg of
                   Ok !cfg -> Ok cfg
                   Bad msg -> Bad $ "Cannot load configuration from " ++ path
                                    ++ ": " ++ msg
  save_fn newdata
  case newcfg of
    Ok cfg -> logInfo ("Loaded new config, serial " ++
                       show (configSerial cfg))
    Bad msg -> logError $ "Failed to load config: " ++ msg
  return ()

-- | Wrapper over 'updateConfig' that handles IO errors.
safeUpdateConfig :: FilePath -> FStat -> (Result ConfigData -> IO ())
                 -> IO (FStat, ConfigReload)
safeUpdateConfig path oldfstat save_fn =
  Control.Exception.catch
        (do
          nt <- needsReload oldfstat path
          case nt of
            Nothing -> return (oldfstat, ConfigToDate)
            Just nt' -> do
                    updateConfig path save_fn
                    return (nt', ConfigReloaded)
        ) (\e -> do
             let msg = "Failure during configuration update: " ++
                       show (e::IOError)
             save_fn $ Bad msg
             return (nullFStat, ConfigIOError)
          )

-- | Computes the file cache data from a FileStatus structure.
buildFileStatus :: FileStatus -> FStat
buildFileStatus ofs =
    let modt = modificationTime ofs
        inum = fileID ofs
        fsize = fileSize ofs
    in (modt, inum, fsize)

-- | Wrapper over 'buildFileStatus'. This reads the data from the
-- filesystem and then builds our cache structure.
getFStat :: FilePath -> IO FStat
getFStat p = liftM buildFileStatus (getFileStatus p)

-- | Check if the file needs reloading
needsReload :: FStat -> FilePath -> IO (Maybe FStat)
needsReload oldstat path = do
  newstat <- getFStat path
  return $ if newstat /= oldstat
             then Just newstat
             else Nothing

-- ** Watcher threads

-- $watcher
-- We have three threads/functions that can mutate the server state:
--
-- 1. the long-interval watcher ('onWatcherTimer')
--
-- 2. the polling watcher ('onPollTimer')
--
-- 3. the inotify event handler ('onInotify')
--
-- All of these will mutate the server state under 'modifyMVar' or
-- 'modifyMVar_', so that server transitions are more or less
-- atomic. The inotify handler remains active during polling mode, but
-- checks for polling mode and doesn't do anything in this case (this
-- check is needed even if we would unregister the event handler due
-- to how events are serialised).

-- | Long-interval reload watcher.
--
-- This is on top of the inotify-based triggered reload.
onWatcherTimer :: IO Bool -> FilePath -> (Result ConfigData -> IO ())
               -> MVar ServerState -> IO ()
onWatcherTimer inotiaction path save_fn state = do
  threadDelay watchInterval
  logDebug "Watcher timer fired"
  modifyMVar_ state (onWatcherInner path save_fn)
  _ <- inotiaction
  onWatcherTimer inotiaction path save_fn state

-- | Inner onWatcher handler.
--
-- This mutates the server state under a modifyMVar_ call. It never
-- changes the reload model, just does a safety reload and tried to
-- re-establish the inotify watcher.
onWatcherInner :: FilePath -> (Result ConfigData -> IO ()) -> ServerState
               -> IO ServerState
onWatcherInner path save_fn state  = do
  (newfstat, _) <- safeUpdateConfig path (reloadFStat state) save_fn
  return state { reloadFStat = newfstat }

-- | Short-interval (polling) reload watcher.
--
-- This is only active when we're in polling mode; it will
-- automatically exit when it detects that the state has changed to
-- notification.
onPollTimer :: IO Bool -> FilePath -> (Result ConfigData -> IO ())
            -> MVar ServerState -> IO ()
onPollTimer inotiaction path save_fn state = do
  threadDelay pollInterval
  logDebug "Poll timer fired"
  continue <- modifyMVar state (onPollInner inotiaction path save_fn)
  if continue
    then onPollTimer inotiaction path save_fn state
    else logDebug "Inotify watch active, polling thread exiting"

-- | Inner onPoll handler.
--
-- This again mutates the state under a modifyMVar call, and also
-- returns whether the thread should continue or not.
onPollInner :: IO Bool -> FilePath -> (Result ConfigData -> IO ())
            -> ServerState -> IO (ServerState, Bool)
onPollInner _ _ _ state@(ServerState { reloadModel = ReloadNotify } ) =
  return (state, False)
onPollInner inotiaction path save_fn
            state@(ServerState { reloadModel = ReloadPoll pround } ) = do
  (newfstat, reload) <- safeUpdateConfig path (reloadFStat state) save_fn
  let state' = state { reloadFStat = newfstat }
  -- compute new poll model based on reload data; however, failure to
  -- re-establish the inotifier means we stay on polling
  newmode <- case reload of
               ConfigToDate ->
                 if pround >= maxIdlePollRounds
                   then do -- try to switch to notify
                     result <- inotiaction
                     if result
                       then moveToNotify
                       else return initialPoll
                   else return (ReloadPoll (pround + 1))
               _ -> return initialPoll
  let continue = case newmode of
                   ReloadNotify -> False
                   _            -> True
  return (state' { reloadModel = newmode }, continue)

-- the following hint is because hlint doesn't understand our const
-- (return False) is so that we can give a signature to 'e'
{-# ANN addNotifier "HLint: ignore Evaluate" #-}
-- | Setup inotify watcher.
--
-- This tries to setup the watch descriptor; in case of any IO errors,
-- it will return False.
addNotifier :: INotify -> FilePath -> (Result ConfigData -> IO ())
            -> MVar ServerState -> IO Bool
addNotifier inotify path save_fn mstate =
  Control.Exception.catch
        (addWatch inotify [CloseWrite] path
            (onInotify inotify path save_fn mstate) >> return True)
        (\e -> const (return False) (e::IOError))

-- | Inotify event handler.
onInotify :: INotify -> String -> (Result ConfigData -> IO ())
          -> MVar ServerState -> Event -> IO ()
onInotify inotify path save_fn mstate Ignored = do
  logDebug "File lost, trying to re-establish notifier"
  modifyMVar_ mstate $ \state -> do
    result <- addNotifier inotify path save_fn mstate
    (newfstat, _) <- safeUpdateConfig path (reloadFStat state) save_fn
    let state' = state { reloadFStat = newfstat }
    if result
      then return state' -- keep notify
      else do
        mode <- moveToPolling "cannot re-establish inotify watch" inotify
                  path save_fn mstate
        return state' { reloadModel = mode }

onInotify inotify path save_fn mstate _ =
  modifyMVar_ mstate $ \state ->
    if reloadModel state == ReloadNotify
       then do
         ctime <- getCurrentTimeUSec
         (newfstat, _) <- safeUpdateConfig path (reloadFStat state) save_fn
         let state' = state { reloadFStat = newfstat, reloadTime = ctime }
         if abs (reloadTime state - ctime) < reloadRatelimit
           then do
             mode <- moveToPolling "too many reloads" inotify path save_fn
                                   mstate
             return state' { reloadModel = mode }
           else return state'
      else return state

initConfigReader :: (Result ConfigData -> a) -> IORef a -> IO ()
initConfigReader cfg_transform ioref = do
  let save_fn = writeIORef ioref . cfg_transform

  -- Inotify setup
  inotify <- initINotify
  -- try to load the configuration, if possible
  conf_file <- Path.clusterConfFile
  (fstat, reloaded) <- safeUpdateConfig conf_file nullFStat save_fn
  ctime <- getCurrentTime
  statemvar <- newMVar $ ServerState ReloadNotify ctime fstat
  let inotiaction = addNotifier inotify conf_file save_fn statemvar
  has_inotify <- if reloaded == ConfigReloaded
                   then inotiaction
                   else return False
  if has_inotify
    then logInfo "Starting up in inotify mode"
    else do
      -- inotify was not enabled, we need to update the reload model
      logInfo "Starting up in polling mode"
      modifyMVar_ statemvar
        (\state -> return state { reloadModel = initialPoll })
  -- fork the timeout timer
  _ <- forkIO $ onWatcherTimer inotiaction conf_file save_fn statemvar
  -- fork the polling timer
  unless has_inotify $ do
    _ <- forkIO $ onPollTimer inotiaction conf_file save_fn statemvar
    return ()
