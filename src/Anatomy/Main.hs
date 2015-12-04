{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Anatomy.Main where

import           Anatomy

import           Control.Monad.IO.Class
import           Control.Monad.Trans.Either

import           Data.String (String)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Github.Data

import           Options.Applicative

import           P

import           System.IO
import           System.Exit
import           System.Posix.Env (getEnv)

import           X.Options.Applicative hiding (VersionCommand)

data Command =
    VersionCommand
  | ReportCommand
  | SyncCommand
  | SyncNewCommand
  | RefreshGithubCommand
  | RefreshJenkinsCommand
  deriving (Eq, Show)

anatomyMain ::
     String -- ^ Build version
  -> (a -> Maybe GithubTemplate) -- ^ a function that takes the class of a project and decides which template to apply, if any at all...
  -> Org -- ^ GitHub organisation
  -> Team -- ^ A team of people to add as Collaborators on the new repo.
  -> Team -- ^ A team of everyone in your organisation
  -> [Project a b] -- ^ List of projects
  -> IO ()
anatomyMain buildInfoVersion templates org owners everyone projects = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

  dispatch anatomy >>= \sc ->
    case sc of
      VersionCommand ->
        (putStrLn $ "anatomy: " <> buildInfoVersion) >> exitSuccess

      -- done
      ReportCommand -> orDie renderReportError $ do
        github <- (GithubOAuth . T.unpack) <$> env "GITHUB_OAUTH"
        rs <- report github org projects
        liftIO $ forM_ rs $ \r ->
          case (reportProject r, reportGithub r) of
            (Nothing, Nothing) ->
              pure ()
            (Just p, Just _) ->
              putStrLn $ "[OK] " <> (T.unpack . renderName . name) p
            (Just p, Nothing) ->
              putStrLn $ "[KO] no github repository found for " <> (T.unpack . renderName . name) p
            (Nothing, Just g) ->
              putStrLn $ "[KO] no anatomy metadata found for " <> repoName g

      -- done
      SyncNewCommand -> orDie renderSyncError $ do
        github <- (GithubOAuth . T.unpack) <$> env "GITHUB_OAUTH"
        hookz <- HooksUrl <$> env "JENKINS_HOOKS"
        token <- HipchatToken <$> env "HIPCHAT_TOKEN"
        room <- liftIO $ (HipchatRoom . T.pack . fromMaybe "ci") <$> getEnv "HIPCHAT_ROOM_GITHUB"
        conf <- getJenkinsConfiguration

        r <- bimapEitherT SyncReportError id $
          report github org projects
        let n = newprojects r
        bimapEitherT SyncGithubError id $
          syncRepositories github templates org owners everyone n
        bimapEitherT SyncCreateError id $
          syncHooks github token room org hookz n
        bimapEitherT SyncBuildError id $
          syncBuilds conf n
        forM_ n $
          liftIO . T.putStrLn . renderProjectReport

      -- done
      SyncCommand -> orDie renderSyncError $ do
        github <- (GithubOAuth . T.unpack) <$> env "GITHUB_OAUTH"
        hookz <- HooksUrl <$> env "JENKINS_HOOKS"
        token <- HipchatToken <$> env "HIPCHAT_TOKEN"
        room <- liftIO $ (HipchatRoom . T.pack . fromMaybe "ci") <$> getEnv "HIPCHAT_ROOM_GITHUB"
        conf <- getJenkinsConfiguration

        r <- bimapEitherT SyncReportError id $
          report github org projects
        bimapEitherT SyncGithubError id .
          syncRepositories github templates org owners everyone $ newprojects r
        -- Assume all projects
        bimapEitherT SyncCreateError id $
          syncHooks github token room org hookz projects
        bimapEitherT SyncBuildError id $
          syncBuilds conf projects
        forM_ (newprojects r) $
          liftIO . T.putStrLn . renderProjectReport


      -- done
      RefreshGithubCommand -> orDie renderSyncError $ do
        github <- (GithubOAuth . T.unpack) <$> env "GITHUB_OAUTH"
        hookz <- HooksUrl <$> env "JENKINS_HOOKS"
        token <- HipchatToken <$> env "HIPCHAT_TOKEN"
        room <- liftIO $ (HipchatRoom . T.pack . fromMaybe "ci") <$> getEnv "HIPCHAT_ROOM_GITHUB"

        -- Creating report here is only safe way to ensure hooks does not fail.
        r <- bimapEitherT SyncReportError id $
          report github org projects
        bimapEitherT SyncCreateError id .
          syncHooks github token room org hookz $ hookable r

      -- done
      RefreshJenkinsCommand -> orDie renderBuildError $ do
        conf <- getJenkinsConfiguration
        syncBuilds conf projects

getJenkinsConfiguration :: MonadIO m => m JenkinsConfiguration
getJenkinsConfiguration = liftIO $ do
  jenkins <- JenkinsAuth <$> env "JENKINS_AUTH"
  user <- JenkinsUser <$> env "JENKINS_USER"
  host <- JenkinsUrl <$> env "JENKINS_HOST"
  pure $ JenkinsConfiguration user jenkins host

env :: MonadIO m => Text -> m Text
env var =
  liftIO (getEnv (T.unpack var) >>= \t ->
    case t of
      Nothing ->
        T.hPutStrLn stderr ("Need to specify $" <> var) >>
          exitFailure
      Just a ->
        pure $ T.pack a)

anatomy :: Parser Command
anatomy =
  versionP <|> commandP

commandP :: Parser Command
commandP =  subparser $
     command' "report"
              "Report on all projects, highlighting undocumented ones."
              (pure ReportCommand)
  <> command' "sync-new"
              "Create repositories, hooks and jobs for new projects ."
              (pure SyncNewCommand)
  <> command' "sync"
              "Create new projects, update all hooks and jenkins configs."
              (pure SyncCommand)
  <> command' "refresh-github-hooks"
              "Update all github hooks."
              (pure RefreshGithubCommand)
  <> command' "refresh-jenkins-jobs"
              "Update all jenkins configs."
              (pure RefreshJenkinsCommand)

versionP :: Parser Command
versionP =
  flag' VersionCommand $
       short 'v'
    <> long "version"
    <> help "Display the version for the anatomy executable."
