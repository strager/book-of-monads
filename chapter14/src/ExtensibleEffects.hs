{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ExtensibleEffects where

import qualified Control.Exception
import qualified System.IO

import Freer

-- Section 14.3

data Union (rs :: [* -> *]) x where
  This :: f x -> Union (f : rs) x
  That :: Union rs x -> Union (f : rs) x

class Member f rs where
  inj :: f x -> Union rs x

instance Member f (f : rs) where
  inj = This

instance {-# overlappable #-} Member f rs => Member f (r : rs) where
  inj = That . inj

type Eff rs = Freer (Union rs)

data FS a where
  WriteFile :: FilePath -> String -> FS (Either IOError ())
  ReadFile :: FilePath -> FS (Either IOError String)

data RandomGen a where
  Random :: Int -> Int -> RandomGen Int

send :: Member f rs => f a -> Eff rs a
send x = Impure (inj x) Pure

writeFile :: Member FS rs => FilePath -> String -> Eff rs (Either IOError ())
writeFile = (send .) . WriteFile

readFile :: Member FS rs => FilePath -> Eff rs (Either IOError String)
readFile = send . ReadFile

random :: Member RandomGen rs => Int -> Int -> Eff rs Int
random = (send .) . Random

data Reader r x where
  Ask :: Reader r r

proj :: Union (f : rs) x -> Either (Union rs x) (f x)
proj (This t) = Right t
proj (That t) = Left t

runReader :: forall a r rs. r -> Eff (Reader r : rs) a -> Eff rs a
runReader r = runEffects runEffect Impure
  where
    runEffect :: forall b. Reader r b -> (b -> Eff rs a) -> Eff rs a
    runEffect Ask continue = continue r

run :: Eff '[] a -> a
run (Pure x) = x

-- freer-simple
-- runState :: s -> Eff (State s : rs) a -> Eff rs (a, s)
-- runError :: Eff (Error e : rs) a -> Eff rs (Either e a)
-- makeChoiceA :: Alternative f => Eff (NonDet : rs) a -> Eff rs (f a)

data State s x where
  Get :: State s s
  Put :: s -> State s ()

runReaderS :: forall a r rs. Eff (Reader r : rs) a -> Eff (State r : rs) a
runReaderS = runEffects runEffect runOp
  where
    runEffect :: forall b. Reader r b -> (b -> Eff (State r : rs) a) -> Eff (State r : rs) a
    runEffect Ask continue = Impure (inj Get) continue

    runOp :: forall c. Union rs c -> (c -> Eff (State r : rs) a) -> Eff (State r : rs) a
    runOp op continue = Impure (That op) continue

data Error e x where
  Error :: e -> Error e a

handleError :: forall a e rs. Eff (Error e : rs) a -> (e -> Eff rs a) -> Eff rs a
handleError m c = runEffects runEffect Impure m
  where
    runEffect :: forall b. Error e b -> (b -> Eff rs a) -> Eff rs a
    runEffect (Error e) _continue = c e

-- catchError :: Member (Error e) rs => Eff rs a -> (e -> Eff rs a) -> Eff rs a

-- runFS :: Eff (FS : rs) a -> IO (Eff rs a)
-- runFS = _a

newtype Lift m a = Lift (m a)

runFS :: forall a rs. Member (Lift IO) rs => Eff (FS : rs) a -> Eff rs a
runFS = runEffects runEffect Impure
  where
    runEffect :: forall b. FS b -> (b -> Eff rs a) -> Eff rs a
    runEffect effect continue = case effect of
      ReadFile fp -> injectIO (Control.Exception.try (System.IO.readFile fp)) `Impure` continue
      WriteFile fp contents -> injectIO (Control.Exception.try (System.IO.writeFile fp contents)) `Impure` continue

runEffects
  :: (forall b. effect b -> (b -> Eff rs' a) -> Eff rs' a) -- ^ runEffect
  -> (forall c. Union rs c -> (c -> Eff rs' a) -> Eff rs' a) -- ^ runOp
  -> Eff (effect : rs) a
  -> Eff rs' a
runEffects runEffect runOp = loop
  where
    loop (Pure x) = return x
    loop (Impure a k) = case proj a of
      Right effect -> runEffect effect continue
      Left op -> runOp op continue
      where continue = loop . k

injectIO :: (Member (Lift IO) rs) => IO a -> Union rs a
injectIO m = inj (Lift m)

runM :: Monad m => Eff (Lift m : '[]) a -> m a
runM = loop
  where
    loop (Pure x) = return x
    loop (Impure a k) = case proj a of
                          Right (Lift a') -> a' >>= loop . k
                          Left _ -> error "Not possible..."
