{-# LANGUAGE GADTs, KindSignatures, TypeOperators, PatternGuards
           , ScopedTypeVariables, TypeFamilies, FlexibleInstances
           , MultiParamTypeClasses, FlexibleContexts
  #-}
{-# OPTIONS_GHC -Wall -fno-warn-missing-methods -fno-warn-missing-signatures #-}

-- Example of data-treify for a first pass of CSE on a simple typed
-- language representation.

module Exp where

import Data.Kind (Type)

import Control.Applicative (pure,(<$>),(<*>))
import qualified Data.IntMap as I
import Data.Maybe (fromMaybe) -- ,fromJust

-- package ty
import Data.Type.Equality

-- Import one of the following but not both
--import Data.Ty
import Typed

import Data.TReify (MuRef(..),ShowF(..),V(..),Graph(..),Bind(..),Id,reifyGraph)

{--------------------------------------------------------------------
    Expressions
--------------------------------------------------------------------}

data Op :: Type -> Type where
  Add :: Op (a -> a -> a)
  Mul :: Op (a -> a -> a)
  Lit :: Show a => a -> Op a

instance ShowF Op where
  showF Add = "Add"
  showF Mul = "Mul"
  showF (Lit a) = show a

instance Show (Op a) where show = showF

-- Expressions, parameterized by variable type (constructor) and
-- expression type.
data E :: Type -> Type where
  Op   :: Op a -> E a
  (:$) :: (Typed a, Typed b) =>
          E (a -> b) -> E a -> E b
--  Let  :: v a -> E v a -> E v b -> E v b
--  Var  :: v a -> E v a

data N :: (Type -> Type) -> Type -> Type where
  ON  :: Op a -> N v a
  App :: (Typed a, Typed b) =>
         v (a -> b) -> v a -> N v b

instance ShowF v => ShowF (N v) where
  showF (ON o)    = unwords ["ON" ,showF o]
  showF (App a b) = unwords ["App",showF a,showF b]

-- instance Show (E (V Ty) a) where
--   show (Op o) = show o
--   show (u :^ v) = parens $ unwords [show u,show v]
--   show (Let v a b) = unwords ["let",show v,"=",show a,"in",show b]
--   show (Var v) = show v

instance Show (E a) where
  show (Op o) = show o
  show (u :$ v) = parens $ unwords [show u,show v]
  -- show (Let v a b) = unwords ["let",showF v,"=",show a,"in",show b]
  -- show (Var v) = showF v

parens :: String -> String
parens = ("(" ++) . (++ ")")

-- TODO: showsPrec with infix and minimal parens


instance MuRef Ty E where
  type DeRef E = N

  mapDeRef _ _ (Op o)   = pure $ ON  o
  mapDeRef k _ (f :$ a) = App <$> k ty f <*> k ty a
  -- mapDeRef _ _ Let{}    = notSupp "Let"
  -- mapDeRef _ _ Var{}    = notSupp "Var"


-- TODO: Consider splitting Let/Var off from E.  Then E wouldn't need the
-- v parameter.
--
-- I could use N and Mu to define an E without Let & Var and then use a
-- standard MuRef instance and a standard extension to include Let & Var.
-- Wouldn't be as convenient for simplification rules, because of the
-- explicit Mu constructors.  Consider it, however, since it makes a
-- simple type distinction between the input to CSE and the output.  Oh,
-- and I could have different ways to embed Let.  For C-like languages, I
-- could restrict the lets to be on the outside (odd for conditionals,
-- though).


-- nodeE :: N v a -> E v a
-- nodeE (ON o)    = Op o
-- nodeE (App u v) = Var u :^ Var v

-- unGraph :: Typeable a => Graph Ty N a -> E (V Ty) a
-- unGraph (Graph binds root) =
--   foldr (\ (Bind v n) -> Let v (nodeE n)) (Var root) (reverse binds)


-- Convert expressions to simple SSA forms
-- ssa :: Typeable a => E (V Ty) a -> IO (E (V Ty) a)
-- ssa = fmap unGraph . reifyGraph ty



children :: N (V Ty) a -> [Id]
children (ON  _)   = []
children (App (V a _) (V b _)) = [a,b]

childrenB :: Bind Ty N -> [Id]
childrenB (Bind _ n) = children n


-- Number of references for each node.  Important: partially apply, so
-- that the binding list can be converted just once into an efficiently
-- searchable representation.
uses :: [Bind Ty N] -> (Id -> Int)
uses = fmap (fromMaybe 0) .
       flip I.lookup .
       histogram .
       concatMap childrenB

-- histogram :: Ord k => [k] -> I.Map k Int
-- histogram = foldr (\ k -> I.insertWith (+) k 1) I.empty

histogram :: [Int] -> I.IntMap Int
histogram = foldr (\ k -> I.insertWith (+) k 1) I.empty

-- bindsF :: [Bind v] -> (Ty a -> v a -> N v a)
-- bindsF = undefined

-- Slow version
bindsF' :: [Bind Ty N] -> (V Ty a -> N (V Ty) a)
bindsF' [] _ = error "bindsF: ran out of bindings"
bindsF' (Bind (V i a) n : binds') v@(V i' a')
  | Just Refl <- a `tyEq` a', i == i' = n
  | otherwise                         = bindsF' binds' v

-- Fast version, using an IntMap.  Important: partially apply.
bindsF :: forall n a. [Bind Ty n] -> (V Ty a -> n (V Ty) a)
bindsF binds = \ (V i' a') -> extract a' (I.lookup i' m)
 where
   m :: I.IntMap (Bind Ty n)
   m = I.fromList [(i,b) | b@(Bind (V i _) _) <- binds]
   extract :: Ty a' -> Maybe (Bind Ty n) -> n (V Ty) a'
   extract _ Nothing            = error "bindsF: variable not found"
   extract a' (Just (Bind (V _ a) n))
     | Just Refl <- a `tyEq` a' = n
     | otherwise                = error "bindsF: wrong type"


-- TODO: generalize unGraph2 from V.



{--------------------------------------------------------------------
    Utilities for convenient expression building
--------------------------------------------------------------------}

op2 :: (Typed a, Typed b, Typed c) =>
       Op (a -> b -> c) -> E a -> E b -> E c
op2 h a b = Op h :$ a :$ b



instance (Typed a, Show a, Num a) => Num (E a) where
  fromInteger x = Op (Lit (fromInteger x))
  (+) = op2 Add
  (*) = op2 Mul

plus :: Typed a => E a -> E a -> E a
plus = op2 Add


sqr :: Num a => a -> a
sqr x = x * x

{--------------------------------------------------------------------
    Testing
--------------------------------------------------------------------}

-- type-specialize
reify :: (MuRef Ty h, Typed a) => h a -> IO (Graph Ty (DeRef h) a)
reify = reifyGraph ty

-- test expressions
e1 = plus 3 5 :: E Integer
e2 = e1 * e1 * e1
e3 = 3 + 3 :: E Integer


{-
  > e1
  ((Add 3) 5)
  > reify e1
  let [x0 = App x1 x4,x4 = ON 5,x1 = App x2 x3,x3 = ON 3,x2 = ON Add] in x0
  > ssa e1
  let x2 = Add in let x3 = 3 in let x1 = (x2 x3) in let x4 = 5 in let x0 = (x1 x4) in x0
  > cse e1
  ((Add 3) 5)

  > e2
  ((Mul ((Add 3) 5)) ((Add 3) 5))
  > reify e2
  let [x0 = App x1 x3,x1 = App x2 x3,x3 = App x4 x7,x7 = ON 5,x4 = App x5 x6,x6 = ON 3,x5 = ON Add,x2 = ON Mul] in x0
  > ssa e2
  let x2 = Mul in let x5 = Add in let x6 = 3 in let x4 = (x5 x6) in let x7 = 5 in let x3 = (x4 x7) in let x1 = (x2 x3) in let x0 = (x1 x3) in x0
  > cse e2
  let x3 = ((Add 3) 5) in ((Mul x3) x3)

  > e3
  ((Add 3) 3)
  > reify e3
  let [x0 = App x1 x3,x1 = App x2 x3,x3 = ON 3,x2 = ON Add] in x0
  >
  > ssa e3
  let x2 = Add in let x3 = 3 in let x1 = (x2 x3) in let x0 = (x1 x3) in x0
  > cse e3
  ((Add 3) 3)
-}

test :: Int -> E Integer
test n = iterate sqr e1 !! n

{-
  > test 2
  ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))
  > reify (test 2)
  let [x0 = App x1 x3,x1 = App x2 x3,x3 = App x4 x6,x4 = App x5 x6,x6 = App x7 x10,x10 = ON 5,x7 = App x8 x9,x9 = ON 3,x8 = ON Add,x5 = ON Mul,x2 = ON Mul] in x0
  > ssa (test 2)
  let x2 = Mul in let x5 = Mul in let x8 = Add in let x9 = 3 in let x7 = (x8 x9) in let x10 = 5 in let x6 = (x7 x10) in let x4 = (x5 x6) in let x3 = (x4 x6) in let x1 = (x2 x3) in let x0 = (x1 x3) in x0
  > cse (test 2)
  let x6 = ((Add 3) 5) in let x3 = ((Mul x6) x6) in ((Mul x3) x3)

  > test 5
  ((Mul ((Mul ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5))))) ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))))) ((Mul ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5))))) ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5))))))
  > reify (test 5)
  let [x0 = App x1 x3,x1 = App x2 x3,x3 = App x4 x6,x4 = App x5 x6,x6 = App x7 x9,x7 = App x8 x9,x9 = App x10 x12,x10 = App x11 x12,x12 = App x13 x15,x13 = App x14 x15,x15 = App x16 x19,x19 = ON 5,x16 = App x17 x18,x18 = ON 3,x17 = ON Add,x14 = ON Mul,x11 = ON Mul,x8 = ON Mul,x5 = ON Mul,x2 = ON Mul] in x0
  > ssa (test 5)
  let x2 = Mul in let x5 = Mul in let x8 = Mul in let x11 = Mul in let x14 = Mul in let x17 = Add in let x18 = 3 in let x16 = (x17 x18) in let x19 = 5 in let x15 = (x16 x19) in let x13 = (x14 x15) in let x12 = (x13 x15) in let x10 = (x11 x12) in let x9 = (x10 x12) in let x7 = (x8 x9) in let x6 = (x7 x9) in let x4 = (x5 x6) in let x3 = (x4 x6) in let x1 = (x2 x3) in let x0 = (x1 x3) in x0
  > cse (test 5)
  let x15 = ((Add 3) 5) in let x12 = ((Mul x15) x15) in let x9 = ((Mul x12) x12) in let x6 = ((Mul x9) x9) in let x3 = ((Mul x6) x6) in ((Mul x3) x3)
-}

e4 = e1 ^ (29 :: Integer)

{-
  > e4
  ((Mul ((Mul ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5))))) ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))))) ((Mul ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5))))) ((Mul ((Mul ((Mul ((Add 3) 5)) ((Add 3) 5))) ((Mul ((Add 3) 5)) ((Add 3) 5)))) ((Add 3) 5))))
  > reify e4
  let [x0 = App x1 x20,x20 = App x21 x23,x23 = App x24 x15,x24 = App x25 x9,x25 = ON Mul,x21 = App x22 x6,x22 = ON Mul,x1 = App x2 x3,x3 = App x4 x6,x4 = App x5 x6,x6 = App x7 x9,x7 = App x8 x9,x9 = App x10 x12,x10 = App x11 x12,x12 = App x13 x15,x13 = App x14 x15,x15 = App x16 x19,x19 = ON 5,x16 = App x17 x18,x18 = ON 3,x17 = ON Add,x14 = ON Mul,x11 = ON Mul,x8 = ON Mul,x5 = ON Mul,x2 = ON Mul] in x0
  > ssa e4
  let x2 = Mul in let x5 = Mul in let x8 = Mul in let x11 = Mul in let x14 = Mul in let x17 = Add in let x18 = 3 in let x16 = (x17 x18) in let x19 = 5 in let x15 = (x16 x19) in let x13 = (x14 x15) in let x12 = (x13 x15) in let x10 = (x11 x12) in let x9 = (x10 x12) in let x7 = (x8 x9) in let x6 = (x7 x9) in let x4 = (x5 x6) in let x3 = (x4 x6) in let x1 = (x2 x3) in let x22 = Mul in let x21 = (x22 x6) in let x25 = Mul in let x24 = (x25 x9) in let x23 = (x24 x15) in let x20 = (x21 x23) in let x0 = (x1 x20) in x0
  > cse e4
  let x15 = ((Add 3) 5) in let x12 = ((Mul x15) x15) in let x9 = ((Mul x12) x12) in let x6 = ((Mul x9) x9) in ((Mul ((Mul x6) x6)) ((Mul x6) ((Mul x9) x15)))
-}
