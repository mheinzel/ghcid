
-- | Test behavior of the executable, polling files for changes
module Test.Ghcid(ghcidTest) where

import Control.Concurrent
import Control.Exception.Extra
import Control.Monad
import Data.Char
import Data.List.Extra
import System.Directory.Extra
import System.IO.Extra
import System.Time.Extra

import Test.Tasty
import Test.Tasty.HUnit

import Ghcid
import Session
import Wait
import Language.Haskell.Ghcid.Util

ghcidTest :: TestTree
ghcidTest = testCase "Ghcid Test" $ withTempDir $ \dir -> withCurrentDirectory dir $ do
    ref <- newEmptyMVar
    let require predi = do
            res <- takeMVarDelay ref 5
            predi res
    writeFile "Main.hs" "main = print 1"
    writeFile ".ghci" ":set -fwarn-unused-binds \n:load Main"
    -- otherwise GHC warns about .ghci being accessible by others
    p <- getPermissions ".ghci"
    setPermissions ".ghci" $ setOwnerWritable False p

    let run = RunGhcid
            {runRestart = []
            ,runReload = []
            ,runCommand = "ghci"
            ,runOutput = []
            ,runTest = Nothing
            ,runTestWithWarnings = False
            ,runShowStatus = False
            ,runShowTitles = False}
    let output = putMVarNow ref . filter (/= "") . map snd
    withSession $ \session -> withWaiterNotify $ \waiter -> bracket
        (forkIO $ runGhcid session waiter (return (100, 50)) output run)
        killThread $ \_ -> do
            require requireAllGood
            testScript require
            outStrLn "\nSuccess"

putMVarNow :: MVar a -> a -> IO ()
putMVarNow ref x = do
    b <- tryPutMVar ref x
    unless b $ error "Had a message and a new one arrived"

takeMVarDelay :: MVar a -> Double -> IO a
-- using timeout makes the directory notification stuff block, so have to busy wait
takeMVarDelay _ i | i <= 0 = error "timed out"
takeMVarDelay x i = do
    b <- tryTakeMVar x
    case b of
        Nothing -> sleep 0.1 >> takeMVarDelay x (i-0.1)
        Just v -> return v


-- | The all good message, something like "All good (2 modules)"
requireAllGood :: [String] -> IO ()
requireAllGood got =
    all (allGoodMessage `isPrefixOf`) got @?
        "Expected all good message, got " ++ show got

-- | Since different versions of GHCi give different messages, we only try to find what we require anywhere in the obtained messages
requireSimilar :: [String] -> [String] -> IO ()
requireSimilar want got = do
    -- Spacing and quotes tend to be different on different GHCi versions
    let simple = lower . filter (\x -> isLetter x || isDigit x || x == ':')
        got2 = simple $ unwords got
    all (`isInfixOf` got2) (map simple got) @?
        "Expected " ++ show want ++ ", got " ++ show got


---------------------------------------------------------------------
-- ACTUAL TEST SUITE

testScript :: (([String] -> IO ()) -> IO ()) -> IO ()
testScript require = do
    writeFile <- return $ \name x -> do print ("writeFile",name,x); writeFile name x
    renameFile <- return $ \from to -> do print ("renameFile",from,to); renameFile from to

    writeFile "Main.hs" "x"
    require $ requireSimilar ["Main.hs:1:1"," Parse error: naked expression at top level"]
    writeFile "Util.hs" "module Util where"
    writeFile "Main.hs" "import Util\nmain = print 1"
    require requireAllGood
    writeFile "Util.hs" "module Util where\nx"
    require $ requireSimilar ["Util.hs:2:1","Parse error: naked expression at top level"]
    writeFile "Util.hs" "module Util() where\nx = 1"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]

    -- check warnings persist properly
    writeFile "Main.hs" "import Util\nx"
    require $ requireSimilar ["Main.hs:2:1","Parse error: naked expression at top level"
                             ,"Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Main.hs" "import Util\nmain = print 2"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Main.hs" "main = print 3"
    require requireAllGood
    writeFile "Main.hs" "import Util\nmain = print 4"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Util.hs" "module Util where"
    require requireAllGood

    -- check recursive modules work
    writeFile "Util.hs" "module Util where\nimport Main"
    require $ requireSimilar ["imports form a cycle","Main.hs","Util.hs"]
    writeFile "Util.hs" "module Util where"
    require requireAllGood

    -- check renaming files works
    -- note that due to GHC bug #9648 we can't save down a new file
    renameFile "Util.hs" "Util2.hs"
    require $ requireSimilar ["Main.hs:1:8:","Could not find module `Util'"]
    renameFile "Util2.hs" "Util.hs"
    require requireAllGood
    -- after this point GHC bugs mean nothing really works too much

