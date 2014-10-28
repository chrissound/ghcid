{-# LANGUAGE RecordWildCards, DeriveDataTypeable, CPP, ScopedTypeVariables #-}
{-# OPTIONS_GHC -O2 #-} -- only here to test ticket #11

-- | The application entry point
module Ghcid(main, runGhcid) where

import Control.Applicative
import Control.Exception
import Control.Monad.Extra
import Data.List
import Data.Time.Clock
import Data.Version
import System.Console.CmdArgs
import System.Directory
import System.IO
import System.IO.Error
import System.Time.Extra

import Paths_ghcid
import Language.Haskell.Ghcid
import Language.Haskell.Ghcid.Terminal
import Language.Haskell.Ghcid.Types
import Language.Haskell.Ghcid.Util


-- | Command line options
data Options = Options
    {command :: String
    ,height :: Maybe Int
    ,topmost :: Bool
    }
    deriving (Data,Typeable,Show)

options :: Mode (CmdArgs Options)
options = cmdArgsMode $ Options
    {command = "" &= typ "COMMAND" &= help "Command to run (defaults to ghci or cabal repl)"
    ,height = Nothing &= help "Number of lines to show (defaults to console height)"
    ,topmost = False &= name "t" &= help "Set window topmost (Windows only)"
    } &= verbosity &=
    program "ghcid" &= summary ("Auto reloading GHCi daemon v" ++ showVersion version)


main :: IO ()
main = do
    opts@Options{..} <- cmdArgsRun options
    when topmost terminalTopmost
    height <- return $ case height of
        Nothing -> maybe 8 snd <$> terminalSize
        Just h -> return h
    command <- if command /= "" then return command else
               ifM (doesFileExist ".ghci") (return "ghci") (return "cabal repl")
    runGhcid command height $ \xs -> do
        outStr $ concatMap ('\n':) xs
        hFlush stdout -- must flush, since we don't finish with a newline


runGhcid :: String -> IO Int -> ([String] -> IO ()) -> IO ()
runGhcid command height output = do
    do height <- height; output $ "Loading..." : replicate (height - 1) ""
    (ghci,initLoad) <- startGhci command Nothing
    let fire load warnings = do
            load <- return $ filter (not . whitelist) load
            height <- height
            start <- getCurrentTime
            modsActive <- fmap (map snd) $ showModules ghci
            let modsLoad = nub $ map loadFile load
            whenLoud $ do
                outStrLn $ "%ACTIVE: " ++ show modsActive
                outStrLn $ "%LOAD: " ++ show load
            let warn = [w | w <- warnings, loadFile w `elem` modsActive, loadFile w `notElem` modsLoad]
            let outFill msg = output $ take height $ msg ++ replicate height ""
            outFill $ prettyOutput height $ filter isMessage load ++ warn
            reason <- awaitFiles start $ nub $ modsLoad ++ modsActive
            outFill $ "Reloading..." : map ("  " ++) reason
            load2 <- reload ghci
            fire load2 [m | m@Message{..} <- warn ++ load, loadSeverity == Warning]
    fire initLoad []


whitelist :: Load -> Bool
whitelist Message{loadSeverity=Warning, loadMessage=[_,x]}
    = x `elem` ["    -O conflicts with --interactive; -O ignored."]
whitelist _ = False


prettyOutput :: Int -> [Load] -> [String]
prettyOutput _ [] = [allGoodMessage]
prettyOutput height xs = take (max 3 $ height - (length msgs * 2)) msg1 ++ concatMap (take 2) msgs
    where (err, warn) = partition ((==) Error . loadSeverity) xs
          msg1:msgs = map loadMessage err ++ map loadMessage warn


-- | return a message about why you are continuing (usually a file name)
awaitFiles :: UTCTime -> [FilePath] -> IO [String]
awaitFiles base files = handle (\(e :: IOError) -> do sleep 0.1; return [show e]) $ do
    whenLoud $ outStrLn $ "%WAITING: " ++ unwords files
    new <- mapM mtime files
    case [x | (x,Just t) <- zip files new, t > base] of
        [] -> recheck files new
        xs -> return xs
    where
        recheck files' old = do
            sleep 0.1
            new <- mapM mtime files'
            case [x | (x,t1,t2) <- zip3 files' old new, t1 /= t2] of
                [] -> recheck files' new
                xs -> return xs

mtime :: FilePath -> IO (Maybe UTCTime)
mtime file = handleJust
    (\e -> if isDoesNotExistError e then Just () else Nothing)
    (\_ -> return Nothing)
    (fmap Just $ getModificationTime file)
