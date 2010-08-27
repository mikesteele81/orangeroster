{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies #-}
module OR
    ( OR (..)
    , ORRoute (..)
    , resourcesOR
    , Static
    , reqUserId
    , clearUserId
    , addUnverified'
    , Handler
    ) where

import Yesod
import Yesod.Mail
import Yesod.Helpers.Auth
import Yesod.Helpers.Static
import Yesod.Form.Jquery
import qualified Settings
import System.Directory
import qualified Data.ByteString.Lazy as L
import Yesod.WebRoutes
import Database.Persist.GenericSql
import Model
import StaticFiles
import Data.Maybe (isJust)
import Settings
import Control.Monad (join)

data OR = OR
    { getStatic :: Static
    , connPool :: Settings.ConnectionPool
    }

type Handler = GHandler OR OR

mkYesodData "OR" [$parseRoutes|
/ RootR GET
/home HomeR GET POST
/profile/#UserId ProfileR GET
/display-name DisplayNameR POST

/share ShareR POST
/share/#UserId ShareUserR POST
/share/#UserId/stop StopShareUserR POST

/entries EntriesR POST
/entry/#EntryId EntryR GET POST
/entry/#EntryId/name EntryNameR POST
/entry/#EntryId/delete DeleteEntryR POST

/static StaticR Static getStatic
/favicon.ico FaviconR GET
/auth AuthR Auth getAuth

/note/#NoteId/close NoteCloseR POST
|]

instance Yesod OR where
    approot _ = Settings.approot
    defaultLayout w = do
        u <- maybeUserId
        let user = fmap (userDisplayName . snd) u
        mmsg <- getMessage
        pc <- widgetToPageContent w
        hamletToRepHtml $(Settings.hamletFile "default-layout")
    urlRenderOverride a (StaticR s) =
        Just $ uncurry (joinPath a Settings.staticroot) $ format s
      where
        format = formatPathSegments ss
        ss :: Site StaticRoute (String -> Maybe (GHandler Static OR ChooseRep))
        ss = getSubSite
    urlRenderOverride _ _ = Nothing
    authRoute _ = Just RootR
    addStaticContent ext' _ content = do
        let fn = base64md5 content ++ '.' : ext'
        let statictmp = Settings.staticdir ++ "/tmp/"
        liftIO $ createDirectoryIfMissing True statictmp
        liftIO $ L.writeFile (statictmp ++ fn) content
        return $ Just $ Right (StaticR $ StaticRoute ["tmp", fn] [], [])

instance YesodPersist OR where
    type YesodDB OR = SqlPersist
    runDB db = fmap connPool getYesod >>= Settings.runConnectionPool db

instance YesodAuth OR where
    type AuthEntity OR = User
    type AuthEmailEntity OR = Email

    defaultDest _ = HomeR
    getAuthId c _ =
        case (credsAuthType c, credsDisplayName c, credsEmail c) of
            (AuthFacebook, Just dn, Just email) -> do
                let ci = credsIdent c
                x <- runDB $ getBy $ UniqueFacebook ci
                me <- runDB $ getBy $ UniqueEmail email
                uid <- case fmap (facebookCredUser . snd) x of
                            Just uid -> return uid
                            Nothing -> runDB $ do
                                uid <-
                                    case me of
                                        Just (_, Email (Just uid) _ _) -> return uid
                                        Just (eid, Email Nothing _ _) -> do
                                            uid <- newUser dn
                                            update eid [EmailOwner $ Just uid]
                                            return uid
                                        Nothing -> do
                                            uid <- newUser dn
                                            _ <- insert $ Email (Just uid) email Nothing
                                            return uid
                                _ <- insert $ FacebookCred uid ci
                                return uid
                setUserId uid
                runDB $ claimShares uid email
                return $ Just uid
            (AuthEmail, _, Just email) -> do
                uid <- runDB $ do
                    me <- getBy $ UniqueEmail email
                    uid <- case me of
                        -- FIXME maybe this should never happen?
                        Nothing -> do
                            uid <- newUser email
                            _ <- insert $ Email (Just uid) email Nothing
                            return uid
                        Just (_, Email (Just uid) _ _) -> return uid
                        Just (eid, Email Nothing _ _) -> do
                            uid <- newUser email
                            update eid [EmailOwner $ Just uid]
                            return uid
                    claimShares uid email
                    return uid
                setUserId uid
                return $ Just uid
            _ -> return Nothing

    emailSettings _ = Just emailSettings'
    facebookSettings _ =
        Just $ FacebookSettings
            facebookKey
            facebookSecret
            ["email"]

userKey :: String
userKey = "USER"

intstring :: Integral i => i -> String
intstring i = show (fromIntegral i :: Int)

stringint :: Integral i => String -> Maybe i
stringint s = case reads s of
                (i, _):_ -> Just $ fromIntegral (i :: Int)
                [] -> Nothing

setUserId :: UserId -> GHandler s m ()
setUserId = setSession userKey . intstring

clearUserId :: GHandler s m ()
clearUserId = deleteSession userKey

maybeUserId :: GHandler s OR (Maybe (UserId, User))
maybeUserId = do
    muid <- maybe Nothing stringint `fmap` lookupSession userKey
    case muid of
        Nothing -> return Nothing
        Just uid -> do
            mu <- runDB $ get uid
            case mu of
                Nothing -> return Nothing
                Just u -> return $ Just (uid, u)

reqUserId :: GHandler s OR (UserId, User)
reqUserId = do
    uid <- maybeUserId
    case uid of
        Just x -> return x
        Nothing -> do
            setMessage $ string "Please log in."
            setUltDest'
            redirect RedirectTemporary RootR

instance YesodJquery OR where
    urlJqueryJs _ = Left $ StaticR jquery_js
    urlJqueryUiJs _ = Left $ StaticR jquery_ui_js
    urlJqueryUiCss _ = Left $ StaticR jquery_ui_css

addUnverified' :: String -> String -> SqlPersist (GHandler s OR) EmailId
addUnverified' email verkey = insert $ Email Nothing email (Just verkey)

emailSettings' :: EmailSettings OR
emailSettings' = EmailSettings
    { addUnverified = \x -> runDB . addUnverified' x
    , sendVerifyEmail = \email verkey verurl -> do
        render <- getUrlRenderParams
        tm <- getRouteToMaster
        let lbs = renderHamlet render $(hamletFile "verify")
        liftIO $ renderSendMail Mail
            { mailHeaders =
                [ ("To", email)
                , ("From", "reply@orangeroster.com")
                , ("Subject", "OrangeRoster: Verify your email address")
                ]
            , mailPlain = verurl
            , mailParts =
                [ Part
                    { partType = "text/html; charset=utf-8"
                    , partEncoding = None
                    , partDisposition = Inline
                    , partContent = lbs
                    }
                ]
            }
    , getVerifyKey = \emailid -> runDB $ do
        x <- get $ fromIntegral emailid
        return $ maybe Nothing emailVerkey x
    , setVerifyKey = \emailid verkey -> runDB $
        update (fromIntegral emailid) [EmailVerkey $ Just verkey]
    , verifyAccount = \emailid' -> runDB $ do
        let emailid = fromIntegral emailid'
        x <- get emailid
        uid <-
            case x of
                Nothing -> return Nothing
                Just (Email (Just uid) _ _) -> return $ Just uid
                Just (Email Nothing email _) -> do
                    uid <- newUser email
                    update emailid [EmailOwner $ Just uid]
                    return $ Just uid
        update emailid [EmailVerkey Nothing]
        return uid
    , getPassword = runDB . fmap (join . fmap userPassword) . get
    , setPassword = \emailid' password -> runDB $ do
        let emailid = fromIntegral emailid'
        x <- get emailid
        case x of
            Just (Email (Just uid) _ _) -> do
                update uid [UserPassword $ Just password]
                update emailid [EmailVerkey Nothing]
            _ -> return ()
    , getEmailCreds = \email -> runDB $ do
        x <- getBy $ UniqueEmail email
        case x of
            Nothing -> return Nothing
            Just (eid, e) ->
                return $ Just EmailCreds
                    { emailCredsId = fromIntegral eid
                    , emailCredsAuthId = emailOwner e
                    , emailCredsStatus = isJust $ emailOwner e
                    , emailCredsVerkey = emailVerkey e
                    }
    , getEmail = \emailid -> runDB $ do
        x <- get $ fromIntegral emailid
        return $ fmap emailEmail x
    }
