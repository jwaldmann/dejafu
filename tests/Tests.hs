module Main (main) where

import Test.DejaFu
import System.Exit (exitFailure, exitSuccess)

import qualified Tests.Cases  as C
import qualified Tests.Logger as L

andM :: (Functor m, Monad m) => [m Bool] -> m Bool
andM = fmap and . sequence

runTests :: IO Bool
runTests =
  andM [dejafu  C.simple2Deadlock ("Simple 2-Deadlock", deadlocksSometimes)
       ,dejafu (C.philosophers 2) ("2 Philosophers",    deadlocksSometimes)
       ,dejafu (C.philosophers 3) ("3 Philosophers",    deadlocksSometimes)
       ,dejafu (C.philosophers 4) ("4 Philosophers",    deadlocksSometimes)
       ,dejafu  C.thresholdValue  ("Threshold Value",   notAlwaysSame)
       ,dejafu  C.forgottenUnlock ("Forgotten Unlock",  deadlocksAlways)
       ,dejafu  C.simple2Race     ("Simple 2-Race",     notAlwaysSame)
       ,dejafu  C.raceyStack      ("Racey Stack",       notAlwaysSame)
       ,dejafus L.badLogger      [("Logger (Valid)",    L.validResult)
                                 ,("Logger (Good)",     L.isGood)
                                 ,("Logger (Bad",       L.isBad)]]

main :: IO ()
main = do
  success <- runTests
  if success then exitSuccess else exitFailure