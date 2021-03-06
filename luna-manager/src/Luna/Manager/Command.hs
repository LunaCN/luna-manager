module Luna.Manager.Command where

import Prologue

import qualified Control.Monad.State.Layered          as State
import qualified Luna.Manager.Command.CreatePackage   as CreatePackage
import qualified Luna.Manager.Command.Develop         as Develop
import qualified Luna.Manager.Command.Install         as Install
import qualified Luna.Manager.Command.NextVersion     as NextVersion
import qualified Luna.Manager.Command.Promote         as Promote
import qualified Luna.Manager.Command.Uninstall       as Uninstall
import qualified Luna.Manager.Command.Version         as Version

import Control.Monad.Exception              (MonadException)
import Luna.Manager.Command.Install         (InstallConfig)
import Luna.Manager.Command.Options
import Luna.Manager.Component.Analytics     (MPUserData)
import Luna.Manager.Component.PackageConfig (PackageConfig)
import Luna.Manager.Component.Repository
import Luna.Manager.Shell.Shelly            (MonadSh, MonadShControl)
import Luna.Manager.System.Env
import Luna.Manager.System.Host

chooseCommand :: (MonadIO m, MonadException SomeException m, State.Monad Options m, MonadSh m, MonadShControl m, MonadThrow m, MonadCatch m) => m ()
chooseCommand = do
    opts <- State.get @Options

    case opts ^. command of
        Install     opt -> evalDefHostConfigs @'[InstallConfig, EnvConfig, RepoConfig] $ State.evalT @MPUserData (Install.run opt) def
        MakePackage opt -> evalDefHostConfigs @'[PackageConfig, EnvConfig, RepoConfig]                        $ CreatePackage.run opt
        Develop     opt -> evalDefHostConfigs @'[Develop.DevelopConfig, EnvConfig, PackageConfig, RepoConfig] $ Develop.run       opt
        NextVersion opt -> evalDefHostConfigs @'[EnvConfig, RepoConfig]                                       $ NextVersion.run   opt
        Promote     opt -> evalDefHostConfigs @'[EnvConfig, RepoConfig, PackageConfig]                        $ Promote.run       opt
        Uninstall       -> evalDefHostConfigs @'[InstallConfig, EnvConfig]                                    $ Uninstall.run
        Version         -> Version.run
        a               -> putStrLn $ "Unimplemented option: " <> show a
        -- TODO: other commands
