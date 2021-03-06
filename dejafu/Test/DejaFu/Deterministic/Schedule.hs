-- | Deterministic scheduling for concurrent computations.
module Test.DejaFu.Deterministic.Schedule
  ( Scheduler
  , ThreadId
  , NonEmpty(..)
  -- * Pre-emptive
  , randomSched
  , roundRobinSched
  -- * Non pre-emptive
  , randomSchedNP
  , roundRobinSchedNP
  -- * Utilities
  , makeNP
  , toList
  ) where

import Data.List.Extra
import System.Random (RandomGen, randomR)
import Test.DejaFu.Deterministic.Internal

-- | A simple random scheduler which, at every step, picks a random
-- thread to run.
randomSched :: RandomGen g => Scheduler g
randomSched g _ threads = (threads' !! choice, g') where
  (choice, g') = randomR (0, length threads' - 1) g
  threads' = map fst $ toList threads

-- | A random scheduler which doesn't pre-empt the running
-- thread. That is, if the last thread scheduled is still runnable,
-- run that, otherwise schedule randomly.
randomSchedNP :: RandomGen g => Scheduler g
randomSchedNP = makeNP randomSched

-- | A round-robin scheduler which, at every step, schedules the
-- thread with the next 'ThreadId'.
roundRobinSched :: Scheduler ()
roundRobinSched _ Nothing _ = (0, ())
roundRobinSched _ (Just (prior, _)) threads
  | prior >= maximum threads' = (minimum threads', ())
  | otherwise = (minimum $ filter (>prior) threads', ())

  where
    threads' = map fst $ toList threads

-- | A round-robin scheduler which doesn't pre-empt the running
-- thread.
roundRobinSchedNP :: Scheduler ()
roundRobinSchedNP = makeNP roundRobinSched

-- | Turn a potentially pre-emptive scheduler into a non-preemptive
-- one.
makeNP :: Scheduler s -> Scheduler s
makeNP sched = newsched where
  newsched s p@(Just (prior, _)) threads
    | prior `elem` map fst (toList threads) = (prior, s)
    | otherwise = sched s p threads
  newsched s Nothing threads = sched s Nothing threads
