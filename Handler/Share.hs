{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.Share where

import Yesod
import Yesod.Mail
import Yesod.Helpers.Auth
import App
import Model
import Settings
import Data.Time (getCurrentTime)

--startShare :: UserId -> UserId -> Handle
startShare :: UserId -> User -> UserId -> Handler OR ()
startShare uid u dest = do
    runDB $ do
        _ <- insert $ Share uid dest
        let msg = userDisplayName u ++ " is now sharing with you."
        now <- liftIO getCurrentTime
        _ <- insert $ Note dest (string msg) now
        return ()
    setMessage "Sharing initiated"

postShareR :: Handler OR ()
postShareR = do
    (uid, u) <- reqUserId
    (res, _, _) <- runFormPost $ emailInput "email"
    case res of
        FormSuccess email -> do
            x <- runDB $ getBy $ UniqueEmail email
            case x of
                Just (_, Email (Just dest) _ _) -> startShare uid u dest
                _ -> runDB $ do
                    _ <- insertBy $ ShareOffer uid email
                    lift $ setMessage "Sharing offer initiated"
                    y <- lift getYesod
                    verkey <- liftIO $ randomKey y
                    emailid <- addUnverified' email verkey
                    let url = AuthR $ EmailVerifyR emailid verkey
                    render <- lift getUrlRenderParams
                    let lbs = renderHamlet render $(hamletFile "invite")
                    liftIO $ renderSendMail Mail
                        { mailHeaders =
                            [ ("To", email)
                            , ("From", "noreply@orangeroster.com")
                            , ("Subject", "Invitation to OrangeRoster")
                            ]
                        , mailPlain = render url []
                        , mailParts =
                            [ Part
                                { partType = "text/html; charset=utf8"
                                , partEncoding = None
                                , partDisposition = Inline
                                , partContent = lbs
                                }
                            ]
                        }
        _ -> setMessage "Invalid email address submitted"
    redirect RedirectTemporary HomeR

postShareUserR :: UserId -> Handler OR ()
postShareUserR dest = do
    (uid, u) <- reqUserId
    startShare uid u dest
    redirect RedirectTemporary HomeR

postStopShareUserR :: UserId -> Handler OR ()
postStopShareUserR dest = do
    (uid, _) <- reqUserId
    runDB $ deleteBy $ UniqueShare uid dest
    setMessage "No longer sharing"
    redirect RedirectTemporary HomeR
