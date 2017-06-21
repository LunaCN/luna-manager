{-# LANGUAGE TypeInType #-}

module Control.Monad.Raise where

-- FIXME FIXME FIXME FIXME FIXME FIXME FIXME FIXME FIXME FIXME 
-- FIXME [WD]: refactor the whole file out before the release

import Prelude
import Data.Kind

import Control.Lens.Utils
import Control.Exception   (Exception, SomeException, toException)
import Control.Monad.Catch (MonadThrow, throwM)

import Control.Monad              (join)
import Data.Constraint            (Constraint)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans        (MonadTrans, lift)


-------------------------------
-- === Exception raising === --
-------------------------------

-- === MonadException === --

type ExceptT' = ExceptT SomeException

class (Monad m, Exception e) => MonadException e m where
    raise :: forall a. e -> m a

type family MonadExceptions es m :: Constraint where
    MonadExceptions '[]       m = ()
    MonadExceptions (e ': es) m = (MonadException e m, MonadExceptions es m)


-- === Utils === --

handle :: Monad m => (e -> m a) -> ExceptT e m a -> m a
handle f = join . fmap (either f return) . runExceptT ; {-# INLINE handle #-}

handleAll :: Monad m => (SomeException -> m a) -> ExceptT' m a -> m a
handleAll = handle ; {-# INLINE handleAll #-}

rethrow :: (MonadThrow m, Exception e) => ExceptT e m a -> m a
rethrow = handle throwM ; {-# INLINE rethrow #-}

rethrowAll :: MonadThrow m => ExceptT' m a -> m a
rethrowAll = rethrow ; {-# INLINE rethrowAll #-}

tryAll :: ExceptT' m a -> m (Either SomeException a)
tryAll = runExceptT ; {-# INLINE tryAll #-}


-- === Throws === --

type family   Throws (e :: k) (m :: * -> *) :: Constraint
type instance Throws e m = MonadExceptions e m
type instance Throws e m = MonadException  e m


-- === Intsances === --

-- Default MonadException instances
instance {-# OVERLAPPABLE #-} (Monad m, Monad (t m), MonadTrans t, MonadException e m)
                                                     => MonadException e (t                     m) where raise = lift . raise         ; {-# INLINE raise #-}
instance {-# OVERLAPPABLE #-} (Monad m, Exception e) => MonadException e (ExceptT e             m) where raise = throwE               ; {-# INLINE raise #-}
instance {-# OVERLAPPABLE #-} (Monad m, Exception e) => MonadException e (ExceptT SomeException m) where raise = throwE . toException ; {-# INLINE raise #-}
instance                      (Monad m)              => MonadException SomeException (ExceptT SomeException m) where raise = throwE  ; {-# INLINE raise #-}



-- === Utils === --

tryJust :: MonadException e m => e -> Maybe a -> m a
tryJust e = maybe (raise e) return ; {-# INLINE tryJust #-}

tryRight :: MonadException e m => (l -> e) -> Either l r -> m r
tryRight f = \case
    Right r -> return r
    Left  l -> raise $ f l

tryRight' :: forall l m r. (MonadException SomeException m, Exception l) => Either l r -> m r
tryRight' = tryRight toException

raise' :: (MonadException SomeException m, Exception e) => forall a. e -> m a
raise' = raise . toException
