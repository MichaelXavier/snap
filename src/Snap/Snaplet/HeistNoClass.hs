{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE TypeSynonymInstances       #-}

{-|

This module implements the Heist snaplet without using type classes.  It is
provided mainly as an example of how snaplets can be written with and without
a type class for convenience.

-}
module Snap.Snaplet.HeistNoClass
  ( Heist
  , heistInit
  , heistInit'
  , clearHeistCache

  , addTemplates
  , addTemplatesAt
  , modifyHeistState
  , modifyHeistState'
  , withHeistState
  , withHeistState'
  , addSplices
  , addSplices'

  , addConfig
  , cRender
  , cRenderAs
  , cHeistServe
  , cHeistServeSingle

  , render
  , renderAs
  , heistServe
  , heistServeSingle
  , heistLocal
  , withSplices
  , renderWithSplices
  , heistLocal'
  , withSplices'
  , renderWithSplices'

  , SnapletHeist
  , SnapletISplice
  , SnapletCSplice
  , runSnapletSplice
  , liftHeist
  , liftWith
  , liftHandler
  , liftAppHandler
  , bindSnapletSplices
  ) where

import           Prelude hiding ((.), id)
import           Control.Arrow (second)
import           Control.Applicative
import           Control.Category
import           Control.Comonad
import           Control.Error
import           Control.Monad.CatchIO (MonadCatchIO)
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.UTF8 as U
import           Data.DList (DList)
import qualified Data.HashMap.Strict as Map
import           Data.IORef
import           Data.List
import           Data.Monoid
import           Data.Lens.Lazy
import           Data.Text (Text)
import qualified Data.Text as T
import           System.FilePath.Posix
import           Heist
import qualified Heist.Compiled as C
import qualified Heist.Interpreted as I
import           Heist.Splices.Cache

import           Snap.Snaplet
import           Snap.Core
import           Snap.Util.FileServe


------------------------------------------------------------------------------
-- | The state for the Heist snaplet.  To use the Heist snaplet in your app
-- include this in your application state and use 'heistInit' to initialize
-- it.  The type parameter b will typically be the base state type for your
-- application.
data Heist b = Configuring
                 { _heistConfig :: IORef (HeistConfig (Handler b b)) }
             | Running
                 { _heistState    :: HeistState (Handler b b)
                 , _heistCTS      :: CacheTagState
                 }


------------------------------------------------------------------------------
changeState :: (HeistState (Handler a a) -> HeistState (Handler a a))
            -> Heist a
            -> Heist a
changeState _ (Configuring _)  =
    error "changeState: HeistState has not been initialized"
changeState f (Running hs cts) = Running (f hs) cts


------------------------------------------------------------------------------
-- | Clears data stored by the cache tag.  The cache tag automatically reloads
-- its data when the specified TTL expires, but sometimes you may want to
-- trigger a manual reload.  This function lets you do that.
clearHeistCache :: Heist b -> IO ()
clearHeistCache = clearCacheTagState . _heistCTS


                         -----------------------------
                         -- SnapletSplice functions --
                         -----------------------------

------------------------------------------------------------------------------
-- | This instance is here because we don't want the heist package to depend
-- on anything from snap packages.
instance MonadSnap m => MonadSnap (HeistT m m) where
    liftSnap = lift . liftSnap


type HeistHandler b = HeistT (Handler b b) (Handler b b)

------------------------------------------------------------------------------
-- | Monad for working with Heist's API from within a snaplet.
newtype SnapletHeist b v a = SnapletHeist
    (ReaderT (Lens (Snaplet b) (Snaplet v)) (HeistHandler b) a)
  deriving ( Monad
           , Functor
           , Applicative
           , Alternative
           , MonadIO
           , MonadPlus
           , MonadReader (Lens (Snaplet b) (Snaplet v))
           , MonadCatchIO
           , MonadSnap
           )


------------------------------------------------------------------------------
-- | Type alias for convenience.
type SnapletISplice b v = SnapletHeist b v Template
type SnapletCSplice b v = SnapletHeist b v (DList (Chunk (Handler b b)))


------------------------------------------------------------------------------
-- | Runs the SnapletISplice.
runSnapletSplice :: (Lens (Snaplet b) (Snaplet v))
                 -> SnapletHeist b v a
                 -> HeistHandler b a
runSnapletSplice l (SnapletHeist m) = runReaderT m l


------------------------------------------------------------------------------
withSS :: (Lens (Snaplet b) (Snaplet v) -> Lens (Snaplet b) (Snaplet v'))
       -> SnapletHeist b v' a
       -> SnapletHeist b v a
withSS f (SnapletHeist m) = SnapletHeist $ withReaderT f m


------------------------------------------------------------------------------
-- | Lifts a HeistT action into SnapletHeist.  Use this with all the functions
-- from the Heist API.
liftHeist :: HeistT (Handler b b) (Handler b b) a -> SnapletHeist b v a
liftHeist = SnapletHeist . lift


------------------------------------------------------------------------------
-- | Common idiom for the combination of liftHandler and withTop.
liftWith :: (Lens (Snaplet b) (Snaplet v'))
         -> Handler b v' a
         -> SnapletHeist b v a
liftWith l = liftHeist . lift . withTop' l


------------------------------------------------------------------------------
-- | Lifts a Handler into SnapletHeist.
liftHandler :: Handler b v a -> SnapletHeist b v a
liftHandler m = do
    l <- ask
    liftWith l m


------------------------------------------------------------------------------
-- | Lifts a (Handler b b) into SnapletHeist.
liftAppHandler :: Handler b b a -> SnapletHeist b v a
liftAppHandler = liftHeist . lift


------------------------------------------------------------------------------
instance MonadState v (SnapletHeist b v) where
    get = do
        l <- ask
        b <- liftAppHandler getSnapletState
        return $ getL (snapletValue . l) b
    put s = do
        l <- ask
        b <- liftAppHandler getSnapletState
        liftAppHandler $ putSnapletState $ setL (snapletValue . l) s b


------------------------------------------------------------------------------
-- | MonadSnaplet instance gives us access to the snaplet infrastructure.
instance MonadSnaplet SnapletHeist where
    getLens = ask
    with' l = withSS (l .)
    withTop' l = withSS (const id) . with' l
    getOpaqueConfig = do
        l <- ask
        b <- liftAppHandler getSnapletState
        return $ getL (snapletConfig . l) b


------------------------------------------------------------------------------
-- | SnapletSplices version of bindSplices.
bindSnapletSplices :: (Lens (Snaplet b) (Snaplet v))
                   -> [(Text, SnapletISplice b v)]
                   -> HeistState (Handler b b)
                   -> HeistState (Handler b b)
bindSnapletSplices l splices =
    I.bindSplices $ map (second $ runSnapletSplice l) splices


                          ---------------------------
                          -- Initializer functions --
                          ---------------------------

------------------------------------------------------------------------------
-- | The 'Initializer' for 'Heist'. This function is a convenience wrapper
-- around `heistInit'` that uses defaultHeistState and sets up routes for all
-- the templates.
heistInit :: FilePath                 -- ^ Path to templates
          -> SnapletInit b (Heist b)
heistInit templateDir = do
    makeSnaplet "heist" "" Nothing $ do
        hs <- heistInitWorker templateDir defaultConfig
        addRoutes [ ("", heistServe) ]
        return hs
  where
    defaultConfig = mempty { hcLoadTimeSplices = defaultLoadTimeSplices }


------------------------------------------------------------------------------
-- | A lower level 'Initializer' for 'Heist'.  This initializer requires you
-- to specify the initial HeistConfig.  It also does not add any routes for
-- templates, allowing you complete control over which templates get routed.
heistInit' :: FilePath
           -- ^ Path to templates
           -> HeistConfig (Handler b b)
           -- ^ Initial HeistConfig
           -> SnapletInit b (Heist b)
heistInit' templateDir initialConfig =
    makeSnaplet "heist" "" Nothing $ heistInitWorker templateDir initialConfig


------------------------------------------------------------------------------
-- | Internal worker function used by variantsof heistInit.  This is necessary
-- because of the divide between SnapletInit and Initializer.
heistInitWorker :: FilePath
                -> HeistConfig (Handler b b)
                -> Initializer b (Heist b) (Heist b)
heistInitWorker templateDir initialConfig = do
    snapletPath <- getSnapletFilePath
    let tDir = snapletPath </> templateDir
    templates <- liftIO $ runEitherT (loadTemplates tDir) >>=
                          either (error . concat) return
    let config = initialConfig `mappend` mempty { hcTemplates = templates }
    printInfo $ T.pack $ unwords
        [ "...loaded"
        , (show $ Map.size templates)
        , "templates from"
        , tDir
        ]
    ref <- liftIO $ newIORef config
    addPostInitHook finalLoadHook
    return $ Configuring ref


------------------------------------------------------------------------------
-- | Hook that converts the Heist type from Configuring to Running at the end
-- of initialization.
finalLoadHook :: Heist b -> EitherT Text IO (Heist b)
finalLoadHook (Configuring ref) = do
    hc <- lift $ readIORef ref
    (hs,cts) <- toTextErrors $ initHeistWithCacheTag hc
    return $ Running hs cts
  where
    toTextErrors = mapEitherT (T.pack . intercalate "\n") id
finalLoadHook (Running _ _) = left "finalLoadHook called while running"


------------------------------------------------------------------------------
-- | Adds templates to the Heist HeistConfig.  Other snaplets should use
-- this function to add their own templates.  The templates are automatically
-- read from the templates directory in the current snaplet's filesystem root.
addTemplates :: Heist b
             -> ByteString
             -- ^ The url prefix for the template routes
             -> Initializer b (Heist b) ()
addTemplates h urlPrefix = do
    snapletPath <- getSnapletFilePath
    addTemplatesAt h urlPrefix (snapletPath </> "templates")


------------------------------------------------------------------------------
-- | Adds templates to the Heist HeistConfig, and lets you specify where
-- they are found in the filesystem.  Note that the path to the template
-- directory is an absolute path.  This allows you more flexibility in where
-- your templates are located, but means that you have to explicitly call
-- getSnapletFilePath if you want your snaplet to use templates within its
-- normal directory structure.
addTemplatesAt :: Heist b
               -> ByteString
               -- ^ URL prefix for template routes
               -> FilePath
               -- ^ Path to templates
               -> Initializer b (Heist b) ()
addTemplatesAt h urlPrefix templateDir = do
    rootUrl <- getSnapletRootURL
    let fullPrefix = U.toString rootUrl </> U.toString urlPrefix
        addPrefix = return . addTemplatePathPrefix (U.fromString fullPrefix)
    ts <- liftIO $ runEitherT (loadTemplates templateDir) >>=
                   either (error . concat) addPrefix
    printInfo $ T.pack $ unwords
        [ "...adding"
        , (show $ Map.size ts)
        , "templates from"
        , templateDir
        , "with route prefix"
        , fullPrefix ++ "/"
        ]
    liftIO $ atomicModifyIORef (_heistConfig h)
        (\hc -> (hc `mappend` mempty { hcTemplates = ts }, ()))


------------------------------------------------------------------------------
modifyHeistState' :: (Lens (Snaplet b) (Snaplet (Heist b)))
                  -> (HeistState (Handler b b) -> HeistState (Handler b b))
                  -> Initializer b v ()
modifyHeistState' heist f = do
    withTop' heist $ addPostInitHook $ return . changeState f


------------------------------------------------------------------------------
modifyHeistState :: (Lens b (Snaplet (Heist b)))
                 -> (HeistState (Handler b b) -> HeistState (Handler b b))
                 -> Initializer b v ()
modifyHeistState heist f = modifyHeistState' (subSnaplet heist) f


------------------------------------------------------------------------------
withHeistState' :: (Lens (Snaplet b) (Snaplet (Heist b)))
                -> (HeistState (Handler b b) -> a)
                -> Handler b v a
withHeistState' heist f = do
    hs <- withTop' heist $ gets _heistState
    return $ f hs


------------------------------------------------------------------------------
withHeistState :: (Lens b (Snaplet (Heist b)))
               -> (HeistState (Handler b b) -> a)
               -> Handler b v a
withHeistState heist f = withHeistState' (subSnaplet heist) f


------------------------------------------------------------------------------
-- | Adds more HeistConfig data using mappend with whatever is currently
-- there.  This is the preferred method for adding all four kinds of splices
-- as well as new
-- templates.
addConfig :: Snaplet (Heist b)
          -> HeistConfig (Handler b b)
          -> Initializer b v ()
addConfig h hc = case extract h of
    Configuring ref ->
        liftIO $ atomicModifyIORef ref (\hc1 -> (hc1 `mappend` hc, ()))
    Running _ _ -> do
        printInfo "finalLoadHook called while running"
        error "this shouldn't happen"


------------------------------------------------------------------------------
addSplices' :: (Lens (Snaplet b) (Snaplet (Heist b)))
            -> [(Text, SnapletISplice b v)]
            -> Initializer b v ()
addSplices' heist splices = do
    _lens <- getLens
    withTop' heist $ addPostInitHook $
        return . changeState (bindSnapletSplices _lens splices)


------------------------------------------------------------------------------
addSplices :: (Lens b (Snaplet (Heist b)))
           -> [(Text, SnapletISplice b v)]
           -> Initializer b v ()
addSplices heist splices = addSplices' (subSnaplet heist) splices


                            -----------------------
                            -- Handler functions --
                            -----------------------

------------------------------------------------------------------------------
-- | Internal helper function for rendering.
iRenderHelper :: Maybe MIMEType
             -> ByteString
             -> Handler b (Heist b) ()
iRenderHelper c t = do
    (Running hs _) <- get
    withTop' id $ I.renderTemplate hs t >>= maybe pass serve
  where
    serve (b, mime) = do
        modifyResponse $ setContentType $ fromMaybe mime c
        writeBuilder b


------------------------------------------------------------------------------
-- | Internal helper function for rendering.
cRenderHelper :: Maybe MIMEType
             -> ByteString
             -> Handler b (Heist b) ()
cRenderHelper c t = do
    (Running hs _) <- get
    withTop' id $ maybe pass serve $ C.renderTemplate hs t
  where
    serve (b, mime) = do
        modifyResponse $ setContentType $ fromMaybe mime c
        writeBuilder =<< b


------------------------------------------------------------------------------
render :: ByteString
       -- ^ Name of the template
       -> Handler b (Heist b) ()
render t = iRenderHelper Nothing t


------------------------------------------------------------------------------
renderAs :: ByteString
         -- ^ Content type
         -> ByteString
         -- ^ Name of the template
         -> Handler b (Heist b) ()
renderAs ct t = iRenderHelper (Just ct) t


------------------------------------------------------------------------------
cRender :: ByteString
       -- ^ Name of the template
       -> Handler b (Heist b) ()
cRender t = cRenderHelper Nothing t


------------------------------------------------------------------------------
cRenderAs :: ByteString
         -- ^ Content type
         -> ByteString
         -- ^ Name of the template
         -> Handler b (Heist b) ()
cRenderAs ct t = cRenderHelper (Just ct) t


------------------------------------------------------------------------------
heistServe :: Handler b (Heist b) ()
heistServe =
    ifTop (render "index") <|> (render . B.pack =<< getSafePath)


------------------------------------------------------------------------------
heistServeSingle :: ByteString
                 -> Handler b (Heist b) ()
heistServeSingle t =
    render t <|> error ("Template " ++ show t ++ " not found.")


------------------------------------------------------------------------------
cHeistServe :: Handler b (Heist b) ()
cHeistServe =
    ifTop (cRender "index") <|> (cRender . B.pack =<< getSafePath)


------------------------------------------------------------------------------
cHeistServeSingle :: ByteString
                 -> Handler b (Heist b) ()
cHeistServeSingle t =
    cRender t <|> error ("Template " ++ show t ++ " not found.")


------------------------------------------------------------------------------
heistLocal' :: (Lens (Snaplet b) (Snaplet (Heist b)))
            -> (HeistState (Handler b b) -> HeistState (Handler b b))
            -> Handler b v a
            -> Handler b v a
heistLocal' heist f m = do
    hs  <- withTop' heist get
    withTop' heist $ modify $ changeState f
    res <- m
    withTop' heist $ put hs
    return res


------------------------------------------------------------------------------
heistLocal :: (Lens b (Snaplet (Heist b)))
           -> (HeistState (Handler b b) -> HeistState (Handler b b))
           -> Handler b v a
           -> Handler b v a
heistLocal heist f m = heistLocal' (subSnaplet heist) f m


------------------------------------------------------------------------------
withSplices' :: (Lens (Snaplet b) (Snaplet (Heist b)))
             -> [(Text, SnapletISplice b v)]
             -> Handler b v a
             -> Handler b v a
withSplices' heist splices m = do
    _lens <- getLens
    heistLocal' heist (bindSnapletSplices _lens splices) m


------------------------------------------------------------------------------
withSplices :: (Lens b (Snaplet (Heist b)))
            -> [(Text, SnapletISplice b v)]
            -> Handler b v a
            -> Handler b v a
withSplices heist splices m = withSplices' (subSnaplet heist) splices m


------------------------------------------------------------------------------
renderWithSplices' :: (Lens (Snaplet b) (Snaplet (Heist b)))
                   -> ByteString
                   -> [(Text, SnapletISplice b v)]
                   -> Handler b v ()
renderWithSplices' heist t splices =
    withSplices' heist splices $ withTop' heist $ render t


------------------------------------------------------------------------------
renderWithSplices :: (Lens b (Snaplet (Heist b)))
                  -> ByteString
                  -> [(Text, SnapletISplice b v)]
                  -> Handler b v ()
renderWithSplices heist t splices =
    renderWithSplices' (subSnaplet heist) t splices


