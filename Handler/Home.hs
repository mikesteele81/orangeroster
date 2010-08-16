{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.Home where

import Yesod
import App
import Settings
import Model
import Control.Applicative

entryFormlet :: Formlet s m (String, String)
entryFormlet p = fieldsToTable $ (,)
           <$> stringField "Name" (fmap fst p)
           <*> stringField "Value" (fmap snd p)

getHomeR :: Handler OR RepHtml
getHomeR = do
    (uid, u) <- reqUserId
    profile <- runDB $ getMainProfile uid >>= loadEntry
    emails <- runDB $ selectList [EmailOwnerEq uid] [] 0 0
    (_, wform, enctype) <- runFormGet $ entryFormlet Nothing
    shares <- runDB $ selectList [ShareDestEq uid] [] 0 0 >>= mapM (\(_, Share srcid _) -> do
        src <- get404 srcid
        return (srcid, src)
        )
    applyLayoutW $ do
        setTitle "Homepage"
        form <- extractBody wform
        addBody $(hamletFile "home")

postHomeR :: Handler OR RepHtml
postHomeR = do
    (uid, _) <- reqUserId
    eid <- runDB $ getMainProfile uid
    (x, wform, enctype) <- runFormPost $ entryFormlet Nothing
    case x of
        FormSuccess (k, v) -> do
            _ <- runDB $ insert $ EntryData eid k v
            setMessage "Data added to profile"
            redirect RedirectTemporary HomeR
        _ -> return ()
    applyLayoutW $ do
        setTitle "Add to profile"
        form <- extractBody wform
        addBody [$hamlet|
%form!method=post!enctype=$enctype$
    %table
        ^form^
        %tr
            %td!colspan=2
                %input!type=submit!value=Add
|]
