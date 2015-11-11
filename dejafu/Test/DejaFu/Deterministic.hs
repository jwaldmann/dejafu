{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- | Deterministic traced execution of concurrent computations.
--
-- This works by executing the computation on a single thread, calling
-- out to the supplied scheduler after each step to determine which
-- thread runs next.
module Test.DejaFu.Deterministic
  ( -- * The @Conc@ Monad
    Conc
  , ConcST
  , ConcIO

  -- * Executing computations
  , Failure(..)
  , MemType(..)
  , runConcST
  , runConcIO
  , runConcST'
  , runConcIO'

  -- * Execution traces
  , Trace
  , Trace'
  , Decision(..)
  , ThreadAction(..)
  , Lookahead(..)
  , CVarId
  , CRefId
  , MaskingState(..)
  , toTrace
  , showTrace
  , showFail

  -- * Scheduling
  , module Test.DejaFu.Deterministic.Schedule
  ) where

import Control.Exception (MaskingState(..))
import Control.Monad.ST (ST, runST)
import Data.Bits
import Data.IORef (IORef)
import Data.Primitive.ByteArray (MutableByteArray)
import Data.STRef (STRef)
import Test.DejaFu.Deterministic.Internal
import Test.DejaFu.Deterministic.Schedule
import Test.DejaFu.Internal (refST, refIO)
import Test.DejaFu.STM (STMLike, STMIO, STMST, runTransactionIO, runTransactionST)
import Test.DejaFu.STM.Internal (CTVar(..))

import qualified Control.Monad.Catch as Ca
import qualified Control.Monad.Conc.Class as C
import qualified Control.Monad.IO.Class as IO
import qualified Control.Monad.Primitive as Pr
import qualified Data.Atomics.Class as A

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative(..), (<$>))
#endif

{-# ANN module ("HLint: ignore Avoid lambda" :: String) #-}
{-# ANN module ("HLint: ignore Use const"    :: String) #-}

newtype Conc n r s a = C { unC :: M n r s a } deriving (Functor, Applicative, Monad)

-- | A 'MonadConc' implementation using @ST@, this should be preferred
-- if you do not need 'liftIO'.
type ConcST t = Conc (ST t) (STRef t) (STMST t)

-- | A 'MonadConc' implementation using @IO@.
type ConcIO = Conc IO IORef STMIO

toConc :: ((a -> Action n r s) -> Action n r s) -> Conc n r s a
toConc = C . cont

wrap :: (M n r s a -> M n r s a) -> Conc n r s a -> Conc n r s a
wrap f = C . f . unC

instance IO.MonadIO ConcIO where
  liftIO ma = toConc (\c -> ALift (fmap c ma))

instance Pr.PrimMonad n => Pr.PrimMonad (Conc n r s) where
  type PrimState (Conc n r s) = Pr.PrimState n

  primitive pa = toConc (\c -> APrim (fmap c (Pr.primitive pa)))

instance A.MonadAtomic n => A.MonadAtomic (Conc n r s) where
  type Ref    (Conc n r s) = CRef r
  type Ticket (Conc n r s) = Ticket

  readForCAS r = toConc $ AReadForCAS r

  casRef  r t  a  = toConc $ ACasRef  r t a
  casRef2 r t1 t2 = toConc $ ACasRef2 r t1 t2

  atomicModifyRefCAS r f = toConc $ AAtomicModifyRefCAS r f

  readMutVarForCAS v = toConc $ AReadMutVarForCAS v

  casMutVar  m t  a  = toConc $ ACasMutVar  m t a
  casMutVar2 m t1 t2 = toConc $ ACasMutVar2 m t1 t2

  casArrayElem  arr i t  a  = toConc $ ACasArrayElem  arr i t  a
  casArrayElem2 arr i t1 t2 = toConc $ ACasArrayElem2 arr i t1 t2

  readArrayElem arr i = toConc $ AReadArrayElem arr i

  casByteArrayInt arr off old new = toConc $ ACasByteArrayInt arr off old new

  fetchAddIntArray     = fetchModByteArray (+)
  fetchSubIntArray     = fetchModByteArray (-)
  fetchAndIntArray     = fetchModByteArray (.&.)
  fetchNandIntArray    = fetchModByteArray $ \x y -> complement (x .&. y)
  fetchOrIntArray      = fetchModByteArray (.|.)
  fetchXorIntArray     = fetchModByteArray xor
  fetchAddByteArrayInt = fetchModByteArray' (+)

  storeLoadBarrier = toConc $ \c -> AStoreLoadBarrier $ c ()
  loadLoadBarrier  = toConc $ \c -> ALoadLoadBarrier  $ c ()
  writeBarrier     = toConc $ \c -> AWriteBarrier     $ c ()

-- | Modify a word in a 'MutableByteArray' and return the old value,
-- this imposes no memory barrier.
fetchModByteArray :: (Int -> Int -> Int) -> MutableByteArray (Pr.PrimState (Conc n r s)) -> Int -> Int -> Conc n r s Int
fetchModByteArray op arr off i = toConc $ AFetchModByteArray op arr off i

-- | Modify a word in a 'MutableByteArray' and return the new value,
-- this imposes no memory barrier.
fetchModByteArray' :: (Int -> Int -> Int) -> MutableByteArray (Pr.PrimState (Conc n r s)) -> Int -> Int -> Conc n r s Int
fetchModByteArray' op arr off i = toConc $ AFetchModByteArray' op arr off i

instance Ca.MonadCatch (Conc n r s) where
  catch ma h = toConc (ACatching (unC . h) (unC ma))

instance Ca.MonadThrow (Conc n r s) where
  throwM e = toConc (\_ -> AThrow e)

instance Ca.MonadMask (Conc n r s) where
  mask                mb = toConc (AMasking MaskedInterruptible   (\f -> unC $ mb $ wrap f))
  uninterruptibleMask mb = toConc (AMasking MaskedUninterruptible (\f -> unC $ mb $ wrap f))

instance (A.MonadAtomic n, A.Ref (Conc n r (STMLike n r)) ~ CRef r) => C.MonadConc (Conc n r (STMLike n r)) where
  type CVar     (Conc n r (STMLike n r)) = CVar r
  type CRef     (Conc n r (STMLike n r)) = CRef r
  type STMLike  (Conc n r (STMLike n r)) = STMLike n r
  type ThreadId (Conc n r (STMLike n r)) = Int

  -- ----------

  forkWithUnmask  ma = toConc (AFork (\umask -> runCont (unC $ ma $ wrap umask) (\_ -> AStop)))
  forkOnWithUnmask _ = C.forkWithUnmask

  -- This implementation lies and always returns 2. There is no way to
  -- verify in the computation that this is a lie, and will
  -- potentially avoid special-case behaviour for 1 capability, so it
  -- seems a sane choice.
  getNumCapabilities = return 2

  myThreadId = toConc AMyTId

  yield = toConc (\c -> AYield (c ()))

  -- ----------

  newCRef a = toConc (\c -> ANewRef a c)

  readCRef   ref   = toConc (AReadRef ref)
  writeCRef  ref a = toConc (\c -> AWriteRef ref a (c ()))
  modifyCRef ref f = toConc (AModRef ref f)

  -- ----------

  newEmptyCVar = toConc (\c -> ANewVar c)

  putCVar  var a = toConc (\c -> APutVar var a (c ()))
  readCVar var   = toConc (AReadVar var)
  takeCVar var   = toConc (ATakeVar var)

  tryPutCVar  var a = toConc (ATryPutVar  var a)
  tryTakeCVar var   = toConc (ATryTakeVar var)

  -- ----------

  throwTo tid e = toConc (\c -> AThrowTo tid e (c ()))

  -- ----------

  atomically = toConc . AAtom

  -- ----------

  _concKnowsAbout (Left  (CVar  (cvarid,  _))) = toConc (\c -> AKnowsAbout (Left  cvarid)  (c ()))
  _concKnowsAbout (Right (CTVar (ctvarid, _))) = toConc (\c -> AKnowsAbout (Right ctvarid) (c ()))

  _concForgets (Left  (CVar  (cvarid,  _))) = toConc (\c -> AForgets (Left  cvarid)  (c ()))
  _concForgets (Right (CTVar (ctvarid, _))) = toConc (\c -> AForgets (Right ctvarid) (c ()))

  _concAllKnown = toConc (\c -> AAllKnown (c ()))

-- | Run a concurrent computation with a given 'Scheduler' and initial
-- state, returning a failure reason on error. Also returned is the
-- final state of the scheduler, and an execution trace.
--
-- Note how the @t@ in 'Conc' is universally quantified, what this
-- means in practice is that you can't do something like this:
--
-- > runConc roundRobinSched SequentialConsistency () newEmptyCVar
--
-- So mutable references cannot leak out of the 'Conc' computation. If
-- this is making your head hurt, check out the \"How @runST@ works\"
-- section of
-- <https://ocharles.org.uk/blog/guest-posts/2014-12-18-rank-n-types.html>
runConcST :: Scheduler s -> MemType -> s -> (forall t. ConcST t a) -> (Either Failure a, s, Trace)
runConcST sched memtype s ma =
  let (r, s', t') = runConcST' sched memtype s ma
  in  (r, s', toTrace t')

-- | Variant of 'runConcST' which produces a 'Trace''.
runConcST' :: Scheduler s -> MemType -> s -> (forall t. ConcST t a) -> (Either Failure a, s, Trace')
runConcST' sched memtype s ma = runST $ runFixed fixed runTransactionST sched memtype s $ unC ma where
  fixed = refST $ \mb -> cont (\c -> ALift $ c <$> mb)

-- | Run a concurrent computation in the @IO@ monad with a given
-- 'Scheduler' and initial state, returning a failure reason on
-- error. Also returned is the final state of the scheduler, and an
-- execution trace.
--
-- __Warning:__ Blocking on the action of another thread in 'liftIO'
-- cannot be detected! So if you perform some potentially blocking
-- action in a 'liftIO' the entire collection of threads may deadlock!
-- You should therefore keep @IO@ blocks small, and only perform
-- blocking operations with the supplied primitives, insofar as
-- possible.
runConcIO :: Scheduler s -> MemType -> s -> ConcIO a -> IO (Either Failure a, s, Trace)
runConcIO sched memtype s ma = do
  (r, s', t') <- runConcIO' sched memtype s ma
  return (r, s', toTrace t')

-- | Variant of 'runConcIO' which produces a 'Trace''.
runConcIO' :: Scheduler s -> MemType -> s -> ConcIO a -> IO (Either Failure a, s, Trace')
runConcIO' sched memtype s ma = runFixed fixed runTransactionIO sched memtype s $ unC ma where
  fixed = refIO $ \mb -> cont (\c -> ALift $ c <$> mb)
