{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE TypeFamilies               #-}

-- | Deterministic traced execution of concurrent computations which
-- may do @IO@.
--
-- __Caution!__ Blocking on the action of another thread in 'liftIO'
-- cannot be detected! So if you perform some potentially blocking
-- action in a 'liftIO' the entire collection of threads may deadlock!
-- You should therefore keep @IO@ blocks small, and only perform
-- blocking operations with the supplied primitives, insofar as
-- possible.
module Test.DejaFu.Deterministic.IO
  ( -- * The @ConcIO@ Monad
    ConcIO
  , runConcIO
  , liftIO
  , fork
  , spawn

  -- * Communication: CVars
  , CVar
  , newEmptyCVar
  , putCVar
  , tryPutCVar
  , readCVar
  , takeCVar
  , tryTakeCVar

  -- * Execution traces
  , Trace
  , Decision
  , ThreadAction
  , showTrace

  -- * Scheduling
  , module Test.DejaFu.Deterministic.Schedule
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Monad.Cont (cont, runCont)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Test.DejaFu.Deterministic.Internal
import Test.DejaFu.Deterministic.Schedule

import qualified Control.Monad.Conc.Class as C
import qualified Control.Monad.IO.Class as IO

-- | The 'IO' variant of Test.DejaFu.Deterministic's @Conc@ monad.
newtype ConcIO t a = C { unC :: M IO IORef a } deriving (Functor, Applicative, Monad)

instance IO.MonadIO (ConcIO t) where
  liftIO = liftIO

instance C.MonadConc (ConcIO t) where
  type CVar (ConcIO t) = CVar t

  fork         = fork
  newEmptyCVar = newEmptyCVar
  putCVar      = putCVar
  tryPutCVar   = tryPutCVar
  readCVar     = readCVar
  takeCVar     = takeCVar
  tryTakeCVar  = tryTakeCVar

fixed :: Fixed ConcIO IO IORef t
fixed = F
  { newRef    = newIORef
  , readRef   = readIORef
  , writeRef  = writeIORef
  , liftN     = liftIO
  , getCont   = unC
  }

-- | The concurrent variable type used with the 'ConcIO' monad. These
-- behave the same as @Conc@'s @CVar@s
newtype CVar t a = V { unV :: R IORef a } deriving Eq

-- | Lift an 'IO' action into the 'ConcIO' monad.
liftIO :: IO a -> ConcIO t a
liftIO ma = C $ cont lifted where
  lifted c = ALift $ c <$> ma

-- | Run the provided computation concurrently, returning the result.
spawn :: ConcIO t a -> ConcIO t (CVar t a)
spawn = C.spawn

-- | Block on a 'CVar' until it is full, then read from it (without
-- emptying).
readCVar :: CVar t a -> ConcIO t a
readCVar cvar = C $ cont $ AGet $ unV cvar

-- | Run the provided computation concurrently.
fork :: ConcIO t () -> ConcIO t ()
fork (C ma) = C $ cont $ \c -> AFork (runCont ma $ const AStop) $ c ()

-- | Create a new empty 'CVar'.
newEmptyCVar :: ConcIO t (CVar t a)
newEmptyCVar = C $ cont lifted where
  lifted c = ANew $ c <$> newEmptyCVar'
  newEmptyCVar' = V <$> newIORef (Nothing, [])

-- | Block on a 'CVar' until it is empty, then write to it.
putCVar :: CVar t a -> a -> ConcIO t ()
putCVar cvar a = C $ cont $ \c -> APut (unV cvar) a $ c ()

-- | Put a value into a 'CVar' if there isn't one, without blocking.
tryPutCVar :: CVar t a -> a -> ConcIO t Bool
tryPutCVar cvar a = C $ cont $ ATryPut (unV cvar) a

-- | Block on a 'CVar' until it is full, then read from it (with
-- emptying).
takeCVar :: CVar t a -> ConcIO t a
takeCVar cvar = C $ cont $ ATake $ unV cvar

-- | Read a value from a 'CVar' if there is one, without blocking.
tryTakeCVar :: CVar t a -> ConcIO t (Maybe a)
tryTakeCVar cvar = C $ cont $ ATryTake $ unV cvar

-- | Run a concurrent computation with a given 'Scheduler' and initial
-- state, returning 'Just' if it terminates, and 'Nothing' if a
-- deadlock is detected. Also returned is the final state of the
-- scheduler, and an execution trace.
runConcIO :: Scheduler s -> s -> (forall t. ConcIO t a) -> IO (Maybe a, s, Trace)
-- Note: Don't eta-reduce, the forall t messes up type inference.
runConcIO sched s ma = runFixed fixed sched s ma