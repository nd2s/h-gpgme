module Crypto.Gpgme.Key (
      getKey
    , listKeys
      -- * Information about keys
    , UserId (..)
    , KeyUserId (..)
    , keyUserIds
    ) where

import Bindings.Gpgme
import Control.Applicative
import qualified Data.ByteString as BS
import Foreign
import Foreign.C.String
import System.IO.Unsafe

import Crypto.Gpgme.Types
import Crypto.Gpgme.Internal

-- | Returns a list of known 'Key's from the @context@.
listKeys :: Ctx            -- ^ context to operate in
         -> IncludeSecret  -- ^ fingerprint
         -> IO [Key]
listKeys (Ctx ctxPtr _) secret = do
    peek ctxPtr >>= \ctx ->
        c'gpgme_op_keylist_start ctx nullPtr (fromSecret secret) >>= checkError "listKeys"
    let eof = 16383
        go accum = do
            key <- allocKey
            ret <- peek ctxPtr >>= \ctx ->
                withKeyPtr key $ c'gpgme_op_keylist_next ctx
            code <- c'gpgme_err_code ret
            case ret of
                _ | ret == noError -> go (key : accum)
                  | code == eof    -> return accum
                  | otherwise      -> checkError "listKeys" ret >> return []
    go []

-- | Returns a 'Key' from the @context@ based on its @fingerprint@.
--   Returns 'Nothing' if no 'Key' with this 'Fpr' exists.
getKey :: Ctx           -- ^ context to operate in
       -> Fpr           -- ^ fingerprint
       -> IncludeSecret -- ^ whether to include secrets when searching for the key
       -> IO (Maybe Key)
getKey (Ctx ctxPtr _) fpr secret = do
    key <- allocKey
    ret <- BS.useAsCString fpr $ \cFpr ->
        peek ctxPtr >>= \ctx ->
            withKeyPtr key $ \keyPtr ->
                c'gpgme_get_key ctx cFpr keyPtr (fromSecret secret)
    if ret == noError
        then return . Just $ key
        else return Nothing

-- | A user ID consisting of a name, comment, and email address.
data UserId = UserId { userId         :: String
                     , userName       :: String
                     , userEmail      :: String
                     , userComment    :: String
                     }
            deriving (Ord, Eq, Show)

-- | A user ID
data KeyUserId = KeyUserId { keyuserValidity   :: Validity
                           , keyuserId         :: UserId
                           }

peekList :: Storable a => (a -> Ptr a) -> Ptr a -> IO [a]
peekList nextFunc = go []
  where
    go accum p
      | p == nullPtr  = return accum
      | otherwise     = do v <- peek p
                           go (v : accum) (nextFunc v)

keyUserIds' :: Key -> IO [KeyUserId]
keyUserIds' key = withForeignPtr (unKey key) $ \keyPtr -> do
    readUserIds keyPtr >>= mapM readKeyUserId
  where
    readUserIds :: Ptr C'gpgme_key_t -> IO [C'_gpgme_user_id]
    readUserIds keyPtr = do
        key' <- peek keyPtr >>= peek
        peekList c'_gpgme_user_id'next (c'_gpgme_key'uids key')

    readKeyUserId :: C'_gpgme_user_id -> IO KeyUserId
    readKeyUserId uid =
        KeyUserId <$> pure (toValidity $ c'_gpgme_user_id'validity uid)
                  <*> userId'
      where
        userId' :: IO UserId
        userId' =
            UserId <$> peekCString (c'_gpgme_user_id'uid uid)
                   <*> peekCString (c'_gpgme_user_id'name uid)
                   <*> peekCString (c'_gpgme_user_id'email uid)
                   <*> peekCString (c'_gpgme_user_id'comment uid)

keyUserIds :: Key -> [KeyUserId]
keyUserIds = unsafePerformIO . keyUserIds'
