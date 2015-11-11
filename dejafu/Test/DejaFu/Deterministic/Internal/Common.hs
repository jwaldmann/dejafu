{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MagicHash                 #-}
{-# LANGUAGE RankNTypes                #-}

-- | Common types and utility functions for deterministic execution of
-- 'MonadConc' implementations.
module Test.DejaFu.Deterministic.Internal.Common where

import Control.DeepSeq (NFData(..))
import Control.Exception (Exception, MaskingState(..))
import Control.Monad.Primitive (PrimState)
import Data.IntMap.Strict (IntMap)
import Data.List.Extra
import Data.Primitive.Array (MutableArray)
import Data.Primitive.ByteArray (MutableByteArray)
import GHC.Prim (MutVar#)
import Test.DejaFu.Internal
import Test.DejaFu.STM (CTVarId)

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative(..))
#endif

--------------------------------------------------------------------------------
-- * The @Conc@ Monad

-- | The underlying monad is based on continuations over Actions.
newtype M n r s a = M { runM :: (a -> Action n r s) -> Action n r s }

instance Functor (M n r s) where
    fmap f m = M $ \ c -> runM m (c . f)

instance Applicative (M n r s) where
    pure x  = M $ \c -> AReturn $ c x
    f <*> v = M $ \c -> runM f (\g -> runM v (c . g))

instance Monad (M n r s) where
    return  = pure
    m >>= k = M $ \c -> runM m (\x -> runM (k x) c)

-- | The concurrent variable type used with the 'Conc' monad. One
-- notable difference between these and 'MVar's is that 'MVar's are
-- single-wakeup, and wake up in a FIFO order. Writing to a @CVar@
-- wakes up all threads blocked on reading it, and it is up to the
-- scheduler which one runs next. Taking from a @CVar@ behaves
-- analogously.
--
-- @CVar@s are represented as a unique numeric identifier, and a
-- reference containing a Maybe value.
newtype CVar r a = CVar (CVarId, r (Maybe a))

-- | The mutable non-blocking reference type. These are like 'IORef's.
--
-- @CRef@s are represented as a unique numeric identifier, and a
-- reference containing (a) any thread-local non-synchronised writes
-- (so each thread sees its latest write) and the current value
-- visible to all threads.
newtype CRef r a = CRef (CRefId, r (IntMap a, a))

-- | When performing compare-and-swaps, the ticket encapsulates proof
-- that a thread observed a specific previous value of a mutable
-- variable. It is provided in lieu of the \"old\" value to
-- compare-and-swap.
newtype Ticket a = Ticket a

-- | Dict of methods for implementations to override.
type Fixed n r s = Ref n r (M n r s)

-- | Construct a continuation-passing operation from a function.
cont :: ((a -> Action n r s) -> Action n r s) -> M n r s a
cont = M

-- | Run a CPS computation with the given final computation.
runCont :: M n r s a -> (a -> Action n r s) -> Action n r s
runCont = runM

--------------------------------------------------------------------------------
-- * Primitive Actions

-- | Scheduling is done in terms of a trace of 'Action's. Blocking can
-- only occur as a result of an action, and they cover (most of) the
-- primitives of the concurrency. 'spawn' is absent as it is
-- implemented in terms of 'newEmptyCVar', 'fork', and 'putCVar'.
data Action n r s =
    AFork  ((forall b. M n r s b -> M n r s b) -> Action n r s) (ThreadId -> Action n r s)
  | AMyTId (ThreadId -> Action n r s)

  | forall a. ANewVar     (CVar r a -> Action n r s)
  | forall a. APutVar     (CVar r a) a (Action n r s)
  | forall a. ATryPutVar  (CVar r a) a (Bool -> Action n r s)
  | forall a. AReadVar    (CVar r a) (a -> Action n r s)
  | forall a. ATakeVar    (CVar r a) (a -> Action n r s)
  | forall a. ATryTakeVar (CVar r a) (Maybe a -> Action n r s)

  | forall a.   ANewRef a (CRef r a -> Action n r s)
  | forall a.   AReadRef  (CRef r a) (a -> Action n r s)
  | forall a b. AModRef   (CRef r a) (a -> (a, b)) (b -> Action n r s)
  | forall a.   AWriteRef (CRef r a) a (Action n r s)

  | forall e.   Exception e => AThrow e
  | forall e.   Exception e => AThrowTo ThreadId e (Action n r s)
  | forall a e. Exception e => ACatching (e -> M n r s a) (M n r s a) (a -> Action n r s)
  | APopCatching (Action n r s)
  | forall a. AMasking MaskingState ((forall b. M n r s b -> M n r s b) -> M n r s a) (a -> Action n r s)
  | AResetMask Bool Bool MaskingState (Action n r s)

  | AKnowsAbout (Either CVarId CTVarId) (Action n r s)
  | AForgets    (Either CVarId CTVarId) (Action n r s)
  | AAllKnown   (Action n r s)

  | ALift (n (Action n r s))
  | APrim (n (Action n r s))

  | forall a. AReadForCAS (CRef r a) (Ticket a -> Action n r s)
  | forall a. ACasRef     (CRef r a) (Ticket a) a ((Bool, Ticket a) -> Action n r s)
  | forall a. ACasRef2    (CRef r a) (Ticket a) (Ticket a) ((Bool, Ticket a) -> Action n r s)

  | forall a b. AAtomicModifyRefCAS (CRef r a) (a -> (a, b)) (b -> Action n r s)

  | forall a. AReadMutVarForCAS (MutVar# (PrimState n) a) (Ticket a -> Action n r s)
  | forall a. ACasMutVar        (MutVar# (PrimState n) a) (Ticket a) a ((Bool, Ticket a) -> Action n r s)
  | forall a. ACasMutVar2       (MutVar# (PrimState n) a) (Ticket a) (Ticket a) ((Bool, Ticket a) -> Action n r s)

  | forall a. AReadArrayElem (MutableArray (PrimState n) a) Int (Ticket a -> Action n r s)
  | forall a. ACasArrayElem  (MutableArray (PrimState n) a) Int (Ticket a) a ((Bool, Ticket a) -> Action n r s)
  | forall a. ACasArrayElem2 (MutableArray (PrimState n) a) Int (Ticket a) (Ticket a) ((Bool, Ticket a) -> Action n r s)

  | ACasByteArrayInt (MutableByteArray (PrimState n)) Int Int Int (Int -> Action n r s)

  | AFetchModByteArray  (Int -> Int -> Int) (MutableByteArray (PrimState n)) Int Int (Int -> Action n r s)
  | AFetchModByteArray' (Int -> Int -> Int) (MutableByteArray (PrimState n)) Int Int (Int -> Action n r s)

  | AStoreLoadBarrier (Action n r s)
  | ALoadLoadBarrier (Action n r s)
  | AWriteBarrier (Action n r s)
  | ACommit ThreadId CRefId

  | forall a. AAtom (s a) (a -> Action n r s)
  | AYield  (Action n r s)
  | AReturn (Action n r s)
  | AStop

--------------------------------------------------------------------------------
-- * Identifiers

-- | Every live thread has a unique identitifer.
type ThreadId = Int

-- | Every 'CVar' has a unique identifier.
type CVarId = Int

-- | Every 'CRef' has a unique identifier.
type CRefId = Int

-- | The number of ID parameters was getting a bit unwieldy, so this
-- hides them all away.
data IdSource = Id { _nextCRId :: CRefId, _nextCVId :: CVarId, _nextCTVId :: CTVarId, _nextTId :: ThreadId }

-- | Get the next free 'CRefId'.
nextCRId :: IdSource -> (IdSource, CRefId)
nextCRId idsource = let newid = _nextCRId idsource + 1 in (idsource { _nextCRId = newid }, newid)

-- | Get the next free 'CVarId'.
nextCVId :: IdSource -> (IdSource, CVarId)
nextCVId idsource = let newid = _nextCVId idsource + 1 in (idsource { _nextCVId = newid }, newid)

-- | Get the next free 'CTVarId'.
nextCTVId :: IdSource -> (IdSource, CTVarId)
nextCTVId idsource = let newid = _nextCTVId idsource + 1 in (idsource { _nextCTVId = newid }, newid)

-- | Get the next free 'ThreadId'.
nextTId :: IdSource -> (IdSource, ThreadId)
nextTId idsource = let newid = _nextTId idsource + 1 in (idsource { _nextTId = newid }, newid)

-- | The initial ID source.
initialIdSource :: IdSource
initialIdSource = Id 0 0 0 0

--------------------------------------------------------------------------------
-- * Scheduling & Traces

-- | A @Scheduler@ maintains some internal state, @s@, takes the
-- 'ThreadId' of the last thread scheduled, or 'Nothing' if this is
-- the first decision, and the list of runnable threads along with
-- what each will do in the next steps (as far as can be
-- determined). It produces a 'ThreadId' to schedule, and a new state.
--
-- __Note:__ In order to prevent computation from hanging, the runtime
-- will assume that a deadlock situation has arisen if the scheduler
-- attempts to (a) schedule a blocked thread, or (b) schedule a
-- nonexistent thread. In either of those cases, the computation will
-- be halted.
type Scheduler s = s -> Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, NonEmpty Lookahead) -> (ThreadId, s)

-- | One of the outputs of the runner is a @Trace@, which is a log of
-- decisions made, alternative decisions (including what action would
-- have been performed had that decision been taken), and the action a
-- thread took in its step.
type Trace = [(Decision, [(Decision, Lookahead)], ThreadAction)]

-- | Like a 'Trace', but gives more lookahead (where possible) for
-- alternative decisions.
type Trace' = [(Decision, [(Decision, NonEmpty Lookahead)], ThreadAction)]

-- | Throw away information from a 'Trace'' to get just a 'Trace'.
toTrace :: Trace' -> Trace
toTrace = map go where
  go (_, alters, CommitRef t c) = (Commit, goA alters, CommitRef t c)
  go (dec, alters, act) = (dec, goA alters, act)

  goA = map $ \x -> case x of
    (_, WillCommitRef t c:|_) -> (Commit, WillCommitRef t c)
    (d, a:|_) -> (d, a)

-- | Pretty-print a trace.
showTrace :: Trace -> String
showTrace = trace "" 0 where
  trace prefix num ((Start tid,_,_):ds)    = thread prefix num ++ trace ("S" ++ show tid) 1 ds
  trace prefix num ((SwitchTo tid,_,_):ds) = thread prefix num ++ trace ("P" ++ show tid) 1 ds
  trace prefix num ((Continue,_,_):ds)     = trace prefix (num + 1) ds
  trace prefix num ((Commit,_,_):ds)       = thread prefix num ++ trace "C" 1 ds
  trace prefix num []                      = thread prefix num

  thread prefix num = prefix ++ replicate num '-'

-- | Scheduling decisions are based on the state of the running
-- program, and so we can capture some of that state in recording what
-- specific decision we made.
data Decision =
    Start ThreadId
  -- ^ Start a new thread, because the last was blocked (or it's the
  -- start of computation).
  | Continue
  -- ^ Continue running the last thread for another step.
  | SwitchTo ThreadId
  -- ^ Pre-empt the running thread, and switch to another.
  | Commit
  -- ^ Commit a 'CRef' write action so that every thread can see the
  -- result.
  deriving (Eq, Show)

instance NFData Decision where
  rnf (Start    tid) = rnf tid
  rnf (SwitchTo tid) = rnf tid
  rnf d = d `seq` ()

-- | All the actions that a thread can perform.
data ThreadAction =
    Fork ThreadId
  -- ^ Start a new thread.
  | MyThreadId
  -- ^ Get the 'ThreadId' of the current thread.
  | Yield
  -- ^ Yield the current thread.
  | NewVar CVarId
  -- ^ Create a new 'CVar'.
  | PutVar CVarId [ThreadId]
  -- ^ Put into a 'CVar', possibly waking up some threads.
  | BlockedPutVar CVarId
  -- ^ Get blocked on a put.
  | TryPutVar CVarId Bool [ThreadId]
  -- ^ Try to put into a 'CVar', possibly waking up some threads.
  | ReadVar CVarId
  -- ^ Read from a 'CVar'.
  | BlockedReadVar CVarId
  -- ^ Get blocked on a read.
  | TakeVar CVarId [ThreadId]
  -- ^ Take from a 'CVar', possibly waking up some threads.
  | BlockedTakeVar CVarId
  -- ^ Get blocked on a take.
  | TryTakeVar CVarId Bool [ThreadId]
  -- ^ Try to take from a 'CVar', possibly waking up some threads.
  | NewRef CRefId
  -- ^ Create a new 'CRef'.
  | ReadRef CRefId
  -- ^ Read from a 'CRef'.
  | ModRef CRefId
  -- ^ Modify a 'CRef'.
  | WriteRef CRefId
  -- ^ Write to a 'CRef' without synchronising.
  | CommitRef ThreadId CRefId
  -- ^ Commit the last write to the given 'CRef' by the given thread,
  -- so that all threads can see the updated value.
  | STM [ThreadId]
  -- ^ An STM transaction was executed, possibly waking up some
  -- threads.
  | FreshSTM
  -- ^ An STM transaction was executed, and all it did was create and
  -- write to new 'CTVar's, no existing 'CTVar's were touched.
  | BlockedSTM
  -- ^ Got blocked in an STM transaction.
  | Catching
  -- ^ Register a new exception handler
  | PopCatching
  -- ^ Pop the innermost exception handler from the stack.
  | Throw
  -- ^ Throw an exception.
  | ThrowTo ThreadId
  -- ^ Throw an exception to a thread.
  | BlockedThrowTo ThreadId
  -- ^ Get blocked on a 'throwTo'.
  | Killed
  -- ^ Killed by an uncaught exception.
  | SetMasking Bool MaskingState
  -- ^ Set the masking state. If 'True', this is being used to set the
  -- masking state to the original state in the argument passed to a
  -- 'mask'ed function.
  | ResetMasking Bool MaskingState
  -- ^ Return to an earlier masking state.  If 'True', this is being
  -- used to return to the state of the masked block in the argument
  -- passed to a 'mask'ed function.
  | ReadForCAS CRefId
  -- ^ Acquire a @Ticket@ from a 'CRef'.
  | CasRef CRefId Bool
  -- ^ Perform a compare-and-swap on a 'CRef'.
  | CasRef2 CRefId Bool
  -- ^ Perform a compare-and-swap on a 'CRef' using two tickets.
  | AtomicModifyRefCAS CRefId
  -- ^ Atomically modiy a 'CRef' using a compare-and-swap.
  | ReadMutVarForCAS
  -- ^ Acquire a @Ticket@ from a 'MutVar#'
  | CasMutVar Bool
  -- ^ Perform a compare-and-swap on a 'MutVar#'
  | CasMutVar2 Bool
  -- ^ Perform a compare-and-swap on a 'MutVar#' using two tickets.
  | ReadArrayElem
  -- ^ Acquire a @Ticket@ from a 'MutableArray'.
  | CasArrayElem Bool
  -- ^ Perform a compare-and-swap on a 'MutableArray'.
  | CasArrayElem2 Bool
  -- ^ Perform a compare-and-swap on a 'MutableArray' using two
  -- tickets.
  | CasByteArrayInt
  -- ^ Perform a compare-and-swap on word-sized chunks of a
  -- 'MutableByteArray', returning the old value. and enforce a full
  -- memory barrier.
  | FetchModByteArray
  -- ^ Modify a word in a 'MutableByteArray', returning the old value,
  -- and enforce a full memory barrier.
  | FetchModByteArray'
  -- ^ Modify a word in a 'MutableByteArray', returning the new value,
  -- and enforce a full memory barrier.
  | StoreLoadBarrier
  -- ^ Executed a store/load barrier. This commits all pending stores
  -- under TSO and PSO, and is a no-op under SQ.
  | LoadLoadBarrier
  -- ^ Executed a load/load barrier. This is a no-op under all
  -- supported memory models.
  | WriteBarrier
  -- ^ Executed a full write barrier. This commits all pending stored
  -- under TSO and PSO, and is a no-op under SQ.
  | Lift
  -- ^ Lift an action from the underlying monad. Note that the
  -- penultimate action in a trace will always be a @Lift@, this is an
  -- artefact of how the runner works.
  | Prim
  -- ^ Perform a primitive state-transformer action.
  | Return
  -- ^ A 'return' or 'pure' action was executed.
  | KnowsAbout
  -- ^ A '_concKnowsAbout' annotation was processed.
  | Forgets
  -- ^ A '_concForgets' annotation was processed.
  | AllKnown
  -- ^ A '_concALlKnown' annotation was processed.
  | Stop
  -- ^ Cease execution and terminate.
  deriving (Eq, Show)

instance NFData ThreadAction where
  rnf (Fork t) = rnf t
  rnf (NewVar c) = rnf c
  rnf (PutVar c ts) = rnf (c, ts)
  rnf (BlockedPutVar c) = rnf c
  rnf (TryPutVar c b ts) = rnf (c, b, ts)
  rnf (ReadVar c) = rnf c
  rnf (BlockedReadVar c) = rnf c
  rnf (TakeVar c ts) = rnf (c, ts)
  rnf (BlockedTakeVar c) = rnf c
  rnf (TryTakeVar c b ts) = rnf (c, b, ts)
  rnf (NewRef c) = rnf c
  rnf (ReadRef c) = rnf c
  rnf (ModRef c) = rnf c
  rnf (WriteRef c) = rnf c
  rnf (CommitRef t c) = rnf (t, c)
  rnf (STM ts) = rnf ts
  rnf (ThrowTo t) = rnf t
  rnf (BlockedThrowTo t) = rnf t
  rnf (SetMasking b m) = b `seq` m `seq` ()
  rnf (ResetMasking b m) = b `seq` m `seq` ()
  rnf (ReadForCAS c) = rnf c
  rnf (CasRef c b) = rnf (c, b)
  rnf (CasRef2 c b) = rnf (c, b)
  rnf (AtomicModifyRefCAS c) = rnf c
  rnf (CasMutVar b) = rnf b
  rnf (CasMutVar2 b) = rnf b
  rnf (CasArrayElem b) = rnf b
  rnf (CasArrayElem2 b) = rnf b
  rnf a = a `seq` ()

-- | A one-step look-ahead at what a thread will do next.
data Lookahead =
    WillFork
  -- ^ Will start a new thread.
  | WillMyThreadId
  -- ^ Will get the 'ThreadId'.
  | WillYield
  -- ^ Will yield the current thread.
  | WillNewVar
  -- ^ Will create a new 'CVar'.
  | WillPutVar CVarId
  -- ^ Will put into a 'CVar', possibly waking up some threads.
  | WillTryPutVar CVarId
  -- ^ Will try to put into a 'CVar', possibly waking up some threads.
  | WillReadVar CVarId
  -- ^ Will read from a 'CVar'.
  | WillTakeVar CVarId
  -- ^ Will take from a 'CVar', possibly waking up some threads.
  | WillTryTakeVar CVarId
  -- ^ Will try to take from a 'CVar', possibly waking up some threads.
  | WillNewRef
  -- ^ Will create a new 'CRef'.
  | WillReadRef CRefId
  -- ^ Will read from a 'CRef'.
  | WillModRef CRefId
  -- ^ Will modify a 'CRef'.
  | WillWriteRef CRefId
  -- ^ Will write to a 'CRef' without synchronising.
  | WillCommitRef ThreadId CRefId
  -- ^ Will commit the last write by the given thread to the 'CRef'.
  | WillSTM
  -- ^ Will execute an STM transaction, possibly waking up some
  -- threads.
  | WillCatching
  -- ^ Will register a new exception handler
  | WillPopCatching
  -- ^ Will pop the innermost exception handler from the stack.
  | WillThrow
  -- ^ Will throw an exception.
  | WillThrowTo ThreadId
  -- ^ Will throw an exception to a thread.
  | WillSetMasking Bool MaskingState
  -- ^ Will set the masking state. If 'True', this is being used to
  -- set the masking state to the original state in the argument
  -- passed to a 'mask'ed function.
  | WillResetMasking Bool MaskingState
  -- ^ Will return to an earlier masking state.  If 'True', this is
  -- being used to return to the state of the masked block in the
  -- argument passed to a 'mask'ed function.
  | WillReadForCAS CRefId
  -- ^ Will acquire a @Ticket@ from a 'CRef'.
  | WillCasRef CRefId
  -- ^ Will perform a compare-and-swap on a 'CRef'.
  | WillCasRef2 CRefId
  -- ^ Will perform a compare-and-swap on a 'CRef' using two tickets.
  | WillAtomicModifyRefCAS CRefId
  -- ^ Will atomically modiy a 'CRef' using a compare-and-swap.
  | WillReadMutVarForCAS
  -- ^ Will acquire a @Ticket@ from a 'MutVar#'
  | WillCasMutVar
  -- ^ Will perform a compare-and-swap on a 'MutVar#'
  | WillCasMutVar2
  -- ^ Will perform a compare-and-swap on a 'MutVar#' using two
  -- tickets.
  | WillReadArrayElem
  -- ^ Will acquire a @Ticket@ from a 'MutableArray'.
  | WillCasArrayElem
  -- ^ Will perform a compare-and-swap on a 'MutableArray'.
  | WillCasArrayElem2
  -- ^ Will perform a compare-and-swap on a 'MutableArray' using two
  -- tickets.
  | WillCasByteArrayInt
  -- ^ Will perform a compare-and-swap on word-sized chunks of a
  -- 'MutableByteArray', returning the old value. and enforce a full
  -- memory barrier.
  | WillFetchModByteArray
  -- ^ Will modify a word in a 'MutableByteArray', returning the old
  -- value, and enforce a full memory barrier.
  | WillFetchModByteArray'
  -- ^ Will modify a word in a 'MutableByteArray', returning the new
  -- value, and enforce a full memory barrier.
  | WillStoreLoadBarrier
  -- ^ Will execute a store/load barrier
  | WillLoadLoadBarrier
  -- ^ Will execute a load/load barrier.
  | WillWriteBarrier
  -- ^ Will execute a full write barrier.
  | WillLift
  -- ^ Will lift an action from the underlying monad. Note that the
  -- penultimate action in a trace will always be a @Lift@, this is an
  -- artefact of how the runner works.
  | WillPrim
  -- ^ Will perform a primitive state-transformer action.
  | WillReturn
  -- ^ Will execute a 'return' or 'pure' action.
  | WillKnowsAbout
  -- ^ Will process a '_concKnowsAbout' annotation.
  | WillForgets
  -- ^ Will process a '_concForgets' annotation.
  | WillAllKnown
  -- ^ Will process a '_concALlKnown' annotation.
  | WillStop
  -- ^ Will cease execution and terminate.
  deriving (Eq, Show)

instance NFData Lookahead where
  rnf (WillPutVar c) = rnf c
  rnf (WillTryPutVar c) = rnf c
  rnf (WillReadVar c) = rnf c
  rnf (WillTakeVar c) = rnf c
  rnf (WillTryTakeVar c) = rnf c
  rnf (WillReadRef c) = rnf c
  rnf (WillModRef c) = rnf c
  rnf (WillWriteRef c) = rnf c
  rnf (WillCommitRef t c) = rnf (t, c)
  rnf (WillThrowTo t) = rnf t
  rnf (WillSetMasking b m) = b `seq` m `seq` ()
  rnf (WillResetMasking b m) = b `seq` m `seq` ()
  rnf (WillReadForCAS c) = rnf c
  rnf (WillCasRef c) = rnf c
  rnf (WillCasRef2 c) = rnf c
  rnf (WillAtomicModifyRefCAS c) = rnf c
  rnf l = l `seq` ()

-- | A simplified view of the possible actions a thread can perform.
data ActionType =
    UnsynchronisedRead  CRefId
  -- ^ A 'readCRef'.
  | UnsynchronisedWrite CRefId
  -- ^ A 'writeCRef'.
  | UnsynchronisedOther
  -- ^ Some other action which doesn't require cross-thread
  -- communication.
  | SynchronisedModify  CRefId
  -- ^ An 'atomicModifyCRef'.
  | SynchronisedCommit  CRefId
  -- ^ A commit.
  | SynchronisedRead    CVarId
  -- ^ A 'readCVar' or 'takeCVar' (or @try@/@blocked@ variants).
  | SynchronisedWrite   CVarId
  -- ^ A 'putCVar' (or @try@/@blocked@ variant).
  | SynchronisedOther
  -- ^ Some other action which does require cross-thread
  -- communication.
  deriving (Eq, Show)

instance NFData ActionType where
  rnf (UnsynchronisedRead  r) = rnf r
  rnf (UnsynchronisedWrite r) = rnf r
  rnf (SynchronisedModify  r) = rnf r
  rnf (SynchronisedCommit  r) = rnf r
  rnf (SynchronisedRead    c) = rnf c
  rnf (SynchronisedWrite   c) = rnf c
  rnf a = a `seq` ()

-- | Check if an action imposes a write barrier.
isBarrier :: ActionType -> Bool
isBarrier (SynchronisedModify _) = True
isBarrier (SynchronisedRead   _) = True
isBarrier (SynchronisedWrite  _) = True
isBarrier SynchronisedOther = True
isBarrier _ = False

-- | Check if an action is synchronised.
isSynchronised :: ActionType -> Bool
isSynchronised (SynchronisedCommit _) = True
isSynchronised a = isBarrier a

-- | Get the 'CRef' affected.
crefOf :: ActionType -> Maybe CRefId
crefOf (UnsynchronisedRead  r) = Just r
crefOf (UnsynchronisedWrite r) = Just r
crefOf (SynchronisedModify  r) = Just r
crefOf (SynchronisedCommit  r) = Just r
crefOf _ = Nothing

-- | Get the 'CVar' affected.
cvarOf :: ActionType -> Maybe CVarId
cvarOf (SynchronisedRead  c) = Just c
cvarOf (SynchronisedWrite c) = Just c
cvarOf _ = Nothing

-- | Throw away information from a 'ThreadAction' and give a
-- simplified view of what is happening.
--
-- This is used in the SCT code to help determine interesting
-- alternative scheduling decisions.
simplify :: ThreadAction -> ActionType
-- TODO: Add new primops
simplify (PutVar c _)       = SynchronisedWrite c
simplify (BlockedPutVar _)  = SynchronisedOther
simplify (TryPutVar c _ _)  = SynchronisedWrite c
simplify (ReadVar c)        = SynchronisedRead c
simplify (BlockedReadVar _) = SynchronisedOther
simplify (TakeVar c _)      = SynchronisedRead c
simplify (BlockedTakeVar _) = SynchronisedOther
simplify (TryTakeVar c _ _) = SynchronisedRead c
simplify (ReadRef r)     = UnsynchronisedRead r
simplify (ModRef r)      = SynchronisedModify r
simplify (WriteRef r)    = UnsynchronisedWrite r
simplify (CommitRef _ r) = SynchronisedCommit r
simplify StoreLoadBarrier = SynchronisedOther
simplify WriteBarrier     = SynchronisedOther
simplify (STM _)            = SynchronisedOther
simplify BlockedSTM         = SynchronisedOther
simplify (ThrowTo _)        = SynchronisedOther
simplify (BlockedThrowTo _) = SynchronisedOther
simplify _ = UnsynchronisedOther

-- | Variant of 'simplify' that takes a 'Lookahead'.
simplify' :: Lookahead -> ActionType
-- TODO: Add new primops
simplify' WillStoreLoadBarrier = SynchronisedOther
simplify' WillWriteBarrier     = SynchronisedOther
simplify' (WillPutVar c)     = SynchronisedWrite c
simplify' (WillTryPutVar c)  = SynchronisedWrite c
simplify' (WillReadVar c)    = SynchronisedRead c
simplify' (WillTakeVar c)    = SynchronisedRead c
simplify' (WillTryTakeVar c) = SynchronisedRead c
simplify' (WillReadRef r)     = UnsynchronisedRead r
simplify' (WillModRef r)      = SynchronisedModify r
simplify' (WillWriteRef r)    = UnsynchronisedWrite r
simplify' (WillCommitRef _ r) = SynchronisedCommit r
simplify' WillSTM         = SynchronisedOther
simplify' (WillThrowTo _) = SynchronisedOther
simplify' _ = UnsynchronisedOther

--------------------------------------------------------------------------------
-- * Failures

-- | An indication of how a concurrent computation failed.
data Failure =
    InternalError
  -- ^ Will be raised if the scheduler does something bad. This should
  -- never arise unless you write your own, faulty, scheduler! If it
  -- does, please file a bug report.
  | Deadlock
  -- ^ The computation became blocked indefinitely on @CVar@s.
  | STMDeadlock
  -- ^ The computation became blocked indefinitely on @CTVar@s.
  | UncaughtException
  -- ^ An uncaught exception bubbled to the top of the computation.
  deriving (Eq, Show)

instance NFData Failure where
  rnf f = f `seq` () -- WHNF == NF

-- | Pretty-print a failure
showFail :: Failure -> String
showFail Deadlock          = "[deadlock]"
showFail STMDeadlock       = "[stm-deadlock]"
showFail InternalError     = "[internal-error]"
showFail UncaughtException = "[exception]"

--------------------------------------------------------------------------------
-- * Memory Models

-- | The memory model to use for non-synchronised 'CRef' operations.
data MemType =
    SequentialConsistency
  -- ^ The most intuitive model: a program behaves as a simple
  -- interleaving of the actions in different threads. When a 'CRef'
  -- is written to, that write is immediately visible to all threads.
  | TotalStoreOrder
  -- ^ Each thread has a write buffer. A thread sees its writes
  -- immediately, but other threads will only see writes when they are
  -- committed, which may happen later. Writes are committed in the
  -- same order that they are created.
  | PartialStoreOrder
  -- ^ Each 'CRef' has a write buffer. A thread sees its writes
  -- immediately, but other threads will only see writes when they are
  -- committed, which may happen later. Writes to different 'CRef's
  -- are not necessarily committed in the same order that they are
  -- created.
  deriving (Eq, Show, Read)

instance NFData MemType where
  rnf m = m `seq` () -- WHNF == NF
