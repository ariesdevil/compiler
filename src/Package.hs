{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
module Package where

import GHC.Generics hiding(packageName)
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as Char8
import Text.ParserCombinators.Parsec hiding (token)
import Data.Either
import System.Directory
import System.IO
import System.Exit
import System.Info
import System.Process
import Data.Aeson.Encode.Pretty
import Data.Aeson

type Version = String

data Purse = Purse {
    _os           :: String,
    _arch         :: String,
    _compiler     :: Version,
    _git          :: Version,
    _node         :: Version,
    _dependencies :: [Dependency]
} deriving (Show, Generic, Eq, Read)

instance ToJSON Purse where
instance FromJSON Purse where

data Dependency = Dependency {
    _url :: String,
    _tag :: String
} deriving (Show, Generic, Eq, Read)

instance ToJSON Dependency where
instance FromJSON Dependency where

createNewPackage :: String -> IO()
createNewPackage packageName = do
    putStrLn ("Creating package `" ++ packageName ++ "`")
    createDirectory packageName

    putStrLn ("Creating _src folder")
    createDirectory (packageName ++ "/_src")

    putStrLn ("Initializing purse.json")
    purse <- getPurse
    writeFile (packageName ++ "/_src/purse.json") (Char8.unpack (encodePretty purse))

    putStrLn ("Creating _test folder")
    createDirectory (packageName ++ "/_test")

    putStrLn ("Creating README file")
    writeFile (packageName ++ "/README.md") ("# " ++ packageName)

    putStrLn ("Creating LICENSE file")
    writeFile (packageName ++ "/LICENSE") ""

    putStrLn ("Creating .gitignore file")
    writeFile 
        (packageName ++ "/.gitignore") 
        (   "# ignore all folders\n" 
        ++  "/*\n\n"
        ++  "# except\n"
        ++  "!.gitignore\n"
        ++  "!README.md\n"
        ++  "!LICENSE\n"
        ++  "!_src/\n"
        ++  "!_test/\n")

    putStrLn ("Initializing as Git repository")

getPurse :: IO Purse
getPurse = do
    compilerVersion' <- readProcess "keli" ["version"] []   
    gitVersion       <- readProcess "git"  ["--version"] [] 
    nodeVersion      <- readProcess "node" ["--version"] []

    return Purse {
        _os           = os,
        _arch         = arch,
        _compiler     = init compilerVersion', -- init is used for removing the last newline character
        _node         = init nodeVersion,
        _git          = init gitVersion,
        _dependencies = []

    }

defaultPursePath :: String
defaultPursePath = "./_src/purse.json"

readPurse :: String -> IO (Maybe Purse)
readPurse pursePath = do
    purseFileExist <- doesPathExist pursePath
    if purseFileExist then do
        contents <- readFile pursePath
        return ((decode (Char8.pack contents)) :: Maybe Purse)
    else do
        hPutStrLn stderr ("Cannot locate the file named " ++ pursePath ++ ". Make sure you are in the package root.")
        return Nothing


addDependency :: String -> String -> IO()
addDependency gitRepoUrl tag = do
    let newDep = Dependency gitRepoUrl tag
    case toGitRepoUrl newDep of
        Left err ->
            hPutStrLn stderr (show err)
        Right{} -> do
            result <- readPurse defaultPursePath
            case result of
                Just purse -> do
                    let prevDeps = _dependencies purse 
                    if newDep `elem` prevDeps then
                        hPutStrLn stderr $ "The dependency you intended to add is already added previously."
                    else do
                        let newPurse = purse {_dependencies = prevDeps ++ [newDep]} 
                        putStrLn "Updating `dependencies` of `./_src/purse.json`"
                        writeFile defaultPursePath (Char8.unpack (encodePretty newPurse))
                        installDeps defaultPursePath

                Nothing ->
                    hPutStrLn stderr $
                        "Error:couldn't parse `./_src/purse.json`\n" ++ 
                        "Make sure it is in the correct format, " ++
                        "as defined at https://keli-language.gitbook.io/doc/specification/section-8-packages#8-4-manifest-file"

installDeps :: String -> IO()
installDeps pursePath = do
    putStrLn ("Installing dependencies, referring: " ++ pursePath)
    result <- readPurse pursePath
    case result of
        Nothing ->
            return ()
            
        Just purse -> do
            let dependencies = _dependencies purse
            let parseResults = map toGitRepoUrl dependencies
            let errors = lefts parseResults
            case errors of
                -- if no parse errors
                [] -> do
                    let grurls = rights parseResults
                    !_ <- forM 
                        grurls 
                        (\u -> do
                            let targetFolderName = _authorName u ++ "." ++ _repoName u ++ "." ++ _tagString u
                            alreadyDownloaded <- doesPathExist targetFolderName
                            if alreadyDownloaded then
                                -- skip the download for this grurl
                                return ()
                            else do
                                putStrLn ("--Installing " ++ targetFolderName)
                                -- clone the repository
                                -- ignore the git command stdout
                                !_ <- 
                                    readProcess 
                                        "git" 
                                        ["clone", "-b", _tagString u, "--single-branch", "--depth", "1", _fullUrl u, targetFolderName]
                                        []

                                -- restructure the folder
                                -- luckily, `mv` command works on both Windows and Linux
                                sourceFiles <- listDirectory (targetFolderName ++ "/_src")

                                exitCodes <- forM sourceFiles 
                                    (\name -> do
                                        mvHandle <- spawnProcess "mv" [targetFolderName ++ "/_src/" ++ name, targetFolderName]
                                        waitForProcess mvHandle)

                                -- if some files cannot be moved
                                if any (\e -> case e of ExitFailure{}->True; _->False) exitCodes then
                                    hPutStrLn stderr ("Error unpacking files from _src.")
                                else do
                                    -- remove unneeded files
                                    removeDirIfExists (targetFolderName ++ "/_src")
                                    removeDirIfExists (targetFolderName ++ "/_test")
                                    removeDirIfExists (targetFolderName ++ "/_.git")

                                    -- install its dependencies
                                    installDeps (targetFolderName ++ "/purse.json"))
                    return ()
                    
                -- if there are parse errors
                errors' -> do
                    -- display parse errors
                    !_ <- forM errors' (\e -> hPutStrLn stderr (show e))
                    return ()
                    


removeDirIfExists :: FilePath -> IO()
removeDirIfExists path = do
    yes <- doesPathExist path
    if yes then
        removeDirectoryRecursive path
    else
        return ()

data GitRepoUrl = GitRepoUrl {
    _fullUrl    :: String,
    _authorName :: String,
    _repoName   :: String,
    _tagString  :: String
}

toGitRepoUrl :: Dependency -> Either ParseError GitRepoUrl 
toGitRepoUrl dep = parse parser "" (_url dep)
    where 
        parser :: Parser GitRepoUrl
        parser = 
                (string "https://github.com/" <|> string "https://gitlab.com/") >>= \_ 
            ->  manyTill anyChar (char '/')       >>= \authorName
            ->  manyTill anyChar (string ".git")  >>= \repoName 
            ->  return (GitRepoUrl (_url dep) authorName repoName (_tag dep))