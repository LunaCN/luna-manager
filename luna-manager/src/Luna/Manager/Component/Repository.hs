module Luna.Manager.Component.Repository where

import Prologue hiding (FilePath)

import qualified Luna.Manager.Logger         as Logger
import qualified Control.Lens.Aeson          as LensJSON
import qualified Control.Monad.State.Layered as State

import qualified Data.Aeson                  as JSON
import qualified Data.ByteString             as BS
import qualified Data.Map                    as Map
import qualified Data.Text                   as Text
import qualified Data.Yaml                   as Yaml

import Control.Monad.Exception     (MonadException, fromRight')
import Data.Aeson                  (FromJSON, ToJSON, parseJSON)
import Data.List                   (sort)
import Data.Map                    (Map)
import Filesystem.Path.CurrentOS   (FilePath, encodeString)
import Luna.Manager.Command.Options
import Luna.Manager.Component.Pretty
import Luna.Manager.Component.Version
import Luna.Manager.Network
import Luna.Manager.Shell.Shelly      (toTextIgnore)
import Luna.Manager.System.Env
import Luna.Manager.System.Host
import Luna.Manager.System.Path


------------------------
-- === Errors === --
------------------------

data UndefinedPackageError = UndefinedPackageError deriving (Show)
instance Exception UndefinedPackageError where
    displayException err = "Undefined package: " <> show err

undefinedPackageError :: SomeException
undefinedPackageError = toException UndefinedPackageError

data MissingPackageDescriptionError = MissingPackageDescriptionError Version deriving (Show)
instance Exception MissingPackageDescriptionError where
    displayException (MissingPackageDescriptionError v) = "No package for version: " <> show v

data UnresolvedDepError = UnresolvedDepError deriving (Show)
makeLenses ''UnresolvedDepError

instance Exception UnresolvedDepError where
    displayException err = "Following dependencies were unable to be resolved: " <> show err

unresolvedDepError :: SomeException
unresolvedDepError = toException UnresolvedDepError

------------------------
-- === Repository === --
------------------------
-- FIXME: Features for luna-manager 1.1:
--        - We should also keep sha of every package to be sure we downloaded valid one.
--        - We should keep sha of whole yaml and keep it separate on server, so yamls could be cached locally and we can check if they are up to date with VERY low bandwich

-- === Definition === --
data AppType = BatchApp | GuiApp | Lib deriving (Show, Generic, Eq)

-- TODO change _apps to _visibleApps
-- Core
data Repo          = Repo          { _packages :: Map Text Package , _apps     :: [Text]                            } deriving (Show, Generic, Eq)
data Package       = Package       { _synopsis :: Text             , _appType  :: AppType , _versions :: VersionMap } deriving (Show, Generic, Eq)
data PackageDesc   = PackageDesc   { _deps     :: [PackageHeader]  , _path     :: Text                              } deriving (Show, Generic, Eq)
data PackageHeader = PackageHeader { _name     :: Text             , _version  :: Version                     } deriving (Show, Generic, Eq)
type VersionMap    = Map Version (Map SysDesc PackageDesc)

-- Helpers
data ResolvedPackage = ResolvedPackage { _header :: PackageHeader, _desc :: PackageDesc, _resolvedAppType :: AppType } deriving (Show, Generic, Eq)

data ResolvedApplication  = ResolvedApplication { _resolvedApp :: ResolvedPackage
                                                , _pkgsToPack  :: [ResolvedPackage]
                                                } deriving (Show)

makeLenses ''Repo
makeLenses ''Package
makeLenses ''PackageDesc
makeLenses ''PackageHeader
makeLenses ''ResolvedPackage
makeLenses ''ResolvedApplication

-- === Utils === --

lookupPackage :: Repo -> PackageHeader -> Maybe ResolvedPackage
lookupPackage repo h = do
    des <- repo ^? packages . ix (h ^. name) . versions . ix (h ^. version) . ix currentSysDesc
    apptype <- repo ^? packages . ix (h ^. name) . appType
    pure $ ResolvedPackage h des apptype

resolveSingleLevel :: Repo -> PackageDesc -> ([PackageHeader], [ResolvedPackage])
resolveSingleLevel repo desc = partitionEithers $ zipWith combine directSubDeps directSubPkgs where
    directSubDeps  = desc ^. deps
    directSubPkgs  = lookupPackage repo <$> directSubDeps
    combine h      = maybe (Left h) Right

resolve :: Repo -> PackageDesc -> ([PackageHeader], [ResolvedPackage])
resolve repo pkg = (errs <> subErrs, oks <> subOks) where
    (errs, oks)  = resolveSingleLevel repo pkg
    subDescs     = view desc <$> oks
    subRes       = resolve repo <$> subDescs
    subErrs      = concat $ fst <$> subRes
    subOks       = concat $ snd <$> subRes

versionsMap :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m) => Repo -> Text -> m VersionMap
versionsMap repo appName = do
    appPkg <- Logger.tryJustWithLog "Repo.versionsMap" unresolvedDepError $ Map.lookup appName $ repo ^. packages
    pure $ appPkg ^. versions

getFullVersionsList :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m) => Repo -> Text -> m [Version]
getFullVersionsList repo appName = do
    vmap <- versionsMap repo appName
    pure $ reverse . sort . Map.keys $ vmap

getVersionsList :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m, Logger.LoggerMonad m) => Repo -> Text -> m [Version]
getVersionsList repo appName = do
    vmap <- versionsMap repo appName
    let filteredVmap = Map.filter (Map.member currentSysDesc) vmap
    pure $ reverse . sort . Map.keys $ filteredVmap

-- Gets versions grouped by type (dev, nightly, release)
getGroupedVersionsList :: (MonadIO m, MonadException SomeException m, Logger.LoggerMonad m) => Repo -> Text -> m ([Version], [Version], [Version])
getGroupedVersionsList repo appName = do
    versions <- getVersionsList repo appName
    let appendVersion (ds, ns, rs) v = if isDev v then (v:ds, ns, rs)
                                       else if isNightly v then (ds, v:ns, rs)
                                       else (ds, ns, v:rs)
        groupedVersions = foldl' appendVersion ([], [], []) versions
        reversed = groupedVersions & over _1 reverse . over _2 reverse . over _3 reverse
    pure reversed

resolvePackageApp :: (MonadIO m, MonadException SomeException m, Logger.LoggerMonad m) => Repo -> Text -> m ResolvedApplication
resolvePackageApp repo appName = do
    appPkg       <- Logger.tryJustWithLog "Repo.resolvePackageApp" undefinedPackageError $ Map.lookup appName (repo ^. packages)
    versionsList <- getVersionsList repo appName
    Logger.logObject "[resolvePackageApp] versionsList" versionsList
    let version         = unsafeHead versionsList -- FIXME
        applicationType = appPkg ^. appType
    Logger.logObject "[resolvePackageApp] version" version
    desc <- Logger.tryJustWithLog "Repo.resolvePackageApp" (toException UnresolvedDepError) $ Map.lookup version $ appPkg ^. versions
    Logger.logObject "[resolvePackageApp] desc" desc
    appDesc <- Logger.tryJustWithLog "Repo.resolvePackageApp" (toException $ MissingPackageDescriptionError version) $ Map.lookup currentSysDesc desc
    Logger.logObject "[resolvePackageApp] appDesc" appDesc
    pure $ ResolvedApplication (ResolvedPackage (PackageHeader appName version) appDesc applicationType) (snd $ resolve repo appDesc)

getSynopis :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m) => Repo -> Text -> m Text
getSynopis repo appName = do
    appPkg <- Logger.tryJustWithLog "Repo.getSynopsis" undefinedPackageError $ Map.lookup appName (repo ^. packages)
    pure $ appPkg ^. synopsis

generatePackage :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m) => Repo -> Maybe FilePath -> ResolvedPackage -> m (Text, Package)
generatePackage repo repoPath resPkg = do
    let pkgName = resPkg ^. header . name
    pkgSynopsis <- getSynopis repo pkgName
    pkgDesc <- case repoPath of
        Just p  -> pure $ (resPkg & desc . path .~ (toTextIgnore p)) ^. desc
        Nothing -> pure $ resPkg ^. desc

    let sysDescMap = Map.singleton currentSysDesc pkgDesc
        versionMap = Map.singleton (resPkg ^. header . version) sysDescMap
    pure $ (pkgName, Package pkgSynopsis (resPkg ^. resolvedAppType) versionMap)


addPackageToMap :: Map Text Package -> (Text, Package) -> Map Text Package
addPackageToMap pkgMap pkg = Map.insert (fst pkg) (snd pkg) pkgMap

emptyMapPkgs :: Map Text Package
emptyMapPkgs = Map.empty

generateYaml :: (Logger.LoggerMonad m, MonadIO m, MonadException SomeException m) => Repo -> ResolvedApplication -> FilePath -> m ()
generateYaml repo resolvedApplication filePath = do
    let appName = resolvedApplication ^. resolvedApp . header . name
    pkg <- generatePackage repo (Just ".") $ resolvedApplication ^. resolvedApp
    deps <- mapM (generatePackage repo Nothing) (resolvedApplication ^. pkgsToPack)

    let defpkgs = foldl addPackageToMap emptyMapPkgs $ pkg : deps
    liftIO $ BS.writeFile (encodeString filePath) $ Yaml.encode $ Repo defpkgs [appName]

repoUnion :: Repo -> Repo -> Repo
repoUnion r1 r2 = r1 & packages .~ Map.unionWith packageUnion (r1 ^. packages) (r2 ^. packages) where
    packageUnion :: Package -> Package -> Package
    packageUnion p1 p2 = p1 & versions .~ Map.unionWith Map.union (p1 ^. versions) (p2 ^. versions)

saveYamlToFile :: (MonadIO m) => Repo -> FilePath -> m ()
saveYamlToFile repo configFile = liftIO $ BS.writeFile (encodeString configFile) $ Yaml.encode $ repo

generateConfigYamlWithNewPackage :: (MonadIO m, MonadException SomeException m) => Repo -> Repo -> FilePath-> m ()
generateConfigYamlWithNewPackage repo packageYaml = saveYamlToFile $ repoUnion repo packageYaml

-- === Instances === --

-- JSON
instance ToJSON   AppType        where toEncoding = LensJSON.toEncodingDropUnary; toJSON = LensJSON.toJSONDropUnary
instance ToJSON   Repo           where toEncoding = LensJSON.toEncodingDropUnary; toJSON = LensJSON.toJSONDropUnary
instance ToJSON   Package        where toEncoding = LensJSON.toEncodingDropUnary; toJSON = LensJSON.toJSONDropUnary
instance ToJSON   PackageDesc    where toEncoding = LensJSON.toEncodingDropUnary; toJSON = LensJSON.toJSONDropUnary
instance ToJSON   PackageHeader  where toEncoding = JSON.toEncoding . showPretty; toJSON = JSON.toJSON . showPretty
instance FromJSON AppType        where parseJSON  = LensJSON.parseDropUnary
instance FromJSON Repo           where parseJSON  = LensJSON.parseDropUnary
instance FromJSON Package        where parseJSON  = LensJSON.parseDropUnary
instance FromJSON PackageDesc    where parseJSON  = LensJSON.parseDropUnary
instance FromJSON PackageHeader  where parseJSON  = either (fail . convert) pure . readPretty <=< parseJSON

-- Show
instance Pretty PackageHeader where
    showPretty (PackageHeader n v) = n <> "-" <> showPretty v
    readPretty t = mapLeft (const "Conversion error") $ PackageHeader s <$> readPretty ss where
        (s,ss) = Text.breakOnEnd "-" t & _1 %~ Text.init



-----------------------------------
-- === Repository management === --
-----------------------------------

-- === Definition === --

data RepoConfig = RepoConfig { _repoPath   :: URIPath
                             , _cachedRepo :: Maybe Repo
                             }
makeLenses ''RepoConfig


-- === Utils === --

type MonadRepo m = (State.Getter Options m, State.Monad RepoConfig m, State.Monad EnvConfig m, MonadNetwork m)

parseConfig :: (MonadIO m, MonadException SomeException m) => FilePath -> m Repo
parseConfig cfgPath =  fromRight' =<< liftIO (Yaml.decodeFileEither $ encodeString cfgPath)

downloadRepo :: MonadNetwork m => URIPath -> m FilePath
downloadRepo address = downloadFromURL address "Downloading repository configuration file"

getRepo :: MonadRepo m => m Repo
getRepo = State.gets @RepoConfig (view repoPath) >>= downloadRepo >>= parseConfig

updateConfig :: Repo -> ResolvedApplication -> Repo
updateConfig config resolvedApplication =
    let app        = resolvedApplication ^. resolvedApp
        appDesc    = app ^. desc
        appHeader  = app ^. header
        appName    = appHeader ^. name
        mainPackagePath = "https://github.com/luna/"
        applicationPartPackagePath = appName <> "/releases/download/" <> showPretty (view version appHeader) <> "/" <> appName <> "-" <> showPretty currentHost <> "-" <> showPretty (view version appHeader)
        extension = case currentHost of
            Linux   -> ".AppImage"
            Darwin  -> ".tar.gz"
            Windows -> ".7z"
        githubReleasePath = mainPackagePath <> applicationPartPackagePath <> extension
        updatedVersionCfg = config & packages . ix appName . versions %~ Map.mapKeys (\_ -> (view version appHeader))
        updatedConfig     = updatedVersionCfg & packages . ix appName . versions . ix (view version appHeader) . ix currentSysDesc . path .~ githubReleasePath
        filteredConfig    = updatedConfig & packages . ix appName . versions . ix (view version appHeader)  %~ Map.filterWithKey (\k _ -> k == currentSysDesc   )
    in filteredConfig


-- === Instances === --

instance {-# OVERLAPPABLE #-} MonadIO m => MonadHostConfig RepoConfig sys arch m where
    defaultHostConfig = pure $ RepoConfig { _repoPath   = "http://packages.luna-lang.org/config.yaml"
                                            , _cachedRepo = Nothing
                                            }
