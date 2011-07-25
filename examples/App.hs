{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
module Main where

import Data.Record.Label
import qualified Data.Text as T
import Snap.Http.Server.Config
import Snap.Types
import Snap.Util.FileServe

import Snap.Snaplet
import Snap.Snaplet.Heist
import Snap.Snaplet.Session
import Snap.Snaplet.Session.Backends.CookieSession
import Text.Templating.Heist

data App = App
    { _heist :: Snaplet (Heist App)
    , _session :: Snaplet SessionManager
    }

type AppHandler = Handler App App

mkLabels [''App]

instance HasHeist App App where
    heistLens = subSnaplet heist

helloHandler :: AppHandler ()
helloHandler = writeText "Hello world"

sessionTest :: AppHandler ()
sessionTest = withSession session $ do
  withChild session $ do
    curVal <- getFromSession "foo"
    case curVal of
      Nothing -> do
        setInSession "foo" "bar"
      Just _ -> return ()
  list <- withChild session $ (T.pack . show) `fmap` sessionToList
  csrf <- withChild session $ (T.pack . show) `fmap` csrfToken
  renderWithSplices "session"
    [ ("session", liftHeist $ textSplice list)
    , ("csrf", liftHeist $ textSplice csrf) ]

------------------------------------------------------------------------------
-- | 
app :: Initializer App App (Snaplet App)
app = makeSnaplet "app" "An snaplet example application." Nothing $ do
    h <- nestSnaplet "heist" $ heistInit "resources/templates"
    withChild heist $ addSplices
        [("mysplice", liftHeist $ textSplice "YAY, it worked")]
    s <- nestSnaplet "session" $ 
      initCookieSessionManager "config/site_key.txt" "_session" Nothing
    addRoutes [ ("/hello", helloHandler)
              , ("/aoeu", withChild heist $ heistServeSingle "foo")
              , ("", withChild heist heistServe)
              , ("", withChild heist $ serveDirectory "resources/doc")
              , ("/sessionTest", sessionTest)
              ]
    return $ App h s

main :: IO ()
main = serveSnaplet emptyConfig app
