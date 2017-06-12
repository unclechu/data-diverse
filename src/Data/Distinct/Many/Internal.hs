{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-# LANGUAGE NoMonomorphismRestriction #-}

module Data.Distinct.Many.Internal where

import Control.Lens
import Data.Distinct.Catalog
import Data.Distinct.TypeLevel
import Data.Kind
import Data.Proxy
import GHC.Prim (Any)
import GHC.TypeLits
import Unsafe.Coerce
import Data.Typeable

-- | A Many is an anonymous sum type (also known as a polymorphic variant, or co-record)
-- that has only distincs types in the list of possible types.
-- That is, there are no duplicates types in the possibilities of this type.
-- This means labels are not required, since the type itself (with type annotations or -XTypeApplications)
-- can be used to try values in the Many.
-- This is essentially a typed version of 'Data.Dynamic'
-- Mnemonic: It doesn't contain one of Any type, it contains one of of Many types.
--
-- Encoding: The variant contains a value whose type is at the given position in the type list.
-- This is similar to the encoding as Haskus.Util.Many and HList (which used Int instead of Word)
-- but with a different api.
-- See https://github.com/haskus/haskus-utils/blob/master/src/lib/Haskus/Utils/Many.hs
-- and https://hackage.haskell.org/package/HList-0.4.1.0/docs/src/Data-HList-Many.html
--
-- Not using GADTs with the Distinct constraint as it gets in the way when I know something is Distinct,
-- but I don't know how to prove it to GHC. Eg a subset of something Distinct is also Distinct...
data Many (xs :: [Type]) = Many {-# UNPACK #-} !Word Any
-- data Many (xs :: [Type]) where
--     Many :: (Distinct xs) => {-# UNPACK #-} !Word -> Any -> Many xs

-- | Just like Haskus and HList versions, inferred type is phamtom which is wrong
-- NB. nominal is required for GADTs with constraints
type role Many representational

----------------------------------------------

-- | Lift a value into a Many of possibly other types.
-- NB. forall used to specify xs first, so TypeApplications can be used to specify xs.
pick :: forall xs x. (Distinct xs, Member x xs) => x -> Many xs
pick = Many (fromIntegral (natVal @(IndexOf x xs) Proxy)) . unsafeCoerce

-- | A variation of 'pick' into a Many of a single type
pick' :: x -> Many '[x]
pick' = pick

-- | Internal function to create a many without bothering with the 'Distinct' constraint
-- This is useful when we know something is Distinct, but I don't know how (or can't be bothered)
-- to prove it to GHC.
-- Eg. a subset of something Distinct is also Distinct.
-- unsafeToMany :: forall x xs. (Member x xs) => x -> Many xs
-- unsafeToMany = Many (fromIntegral (natVal @(IndexOf x xs) Proxy)) . unsafeCoerce

-- | Retrieving the value out of a 'Many' of one type is always successful.
-- Mnemonic: A 'Many' with one type is 'notMany' at all.
notMany :: Many '[a] -> a
notMany (Many _ v) = unsafeCoerce v

-- | For a specified or inferred type, deconstruct a Many into a Maybe value of that type.
trial :: forall x xs. (Member x xs) => Many xs -> Maybe x
trial (Many n v) = if n == fromIntegral (natVal @(IndexOf x xs) Proxy)
            then Just (unsafeCoerce v)
            else Nothing

-- | A version of 'trial'' which trys the first type in the type list.
trial' :: Many (x ': xs) -> Maybe x
trial' (Many n v) = if n == 0
            then Just (unsafeCoerce v)
            else Nothing

-- | 'trial' a value out of a Many, and get Either the Right value or the Left-over possibilities.
trialEither
    :: forall x xs.
       (Member x xs)
    => Many xs -> Either (Many (Without x xs)) x
trialEither (Many n v) = let i = fromIntegral (natVal @(IndexOf x xs) Proxy)
                  in if n == i
                     then Right (unsafeCoerce v)
                     else if n > i
                          then Left (Many (n - 1) v)
                          else Left (Many n v)

-- | A version of 'trialEither' which trys the first type in the type list.
trialEither' :: Many (x ': xs) -> Either (Many xs) x
trialEither' (Many n v) = if n == 0
           then Right (unsafeCoerce v)
           else Left (Many (n - 1) v)

-------------------------------------------

-- | A switch/case statement for Many.
-- There is only one instance of this class which visits through the possibilities in Many,
-- delegating work to 'CaseMany', ensuring termination when Many only contains one type.
-- Uses 'Case' instances like 'Cases' to apply a 'Catalog' of functions to a variant of values.
-- Or 'TypeableCase' to apply a polymorphic function that work on all 'Typeables'.
-- Or you may use your own custom instance of 'Case'.
class Switch xs handler r where
    switch :: Many xs -> handler xs r -> r

-- | 'trial' each type in a Many, and either delegate the handling of the value discovered, or loop
-- trying the next type in the type list.
-- This code will be efficiently compiled into a single case statement in GHC 8.2.1
-- See http://hsyl20.fr/home/posts/2016-12-12-control-flow-in-haskell-part-2.html
instance (Case c (x ': x' ': xs) r, Switch (x' ': xs) c r) =>
         Switch (x ': x' ': xs) c r where
    switch v c =
        case trialEither' v of
            Right a -> delegate c a
            Left v' -> switch v' (remaining c)

-- | Terminating instead of the loop, ensuring that a instance of @Switch '[]@
-- with an empty typelist is not required.
instance (Case c '[x] r) => Switch '[x] c r where
    switch v c = case notMany v of
            a -> delegate c a

-- | Catamorphism for many. This is @flip switch@. See 'Switch'
many :: Switch xs handler r => handler xs r -> Many xs -> r
many = flip switch

-------------------------------------------

-- | This class allows storing polymorphic functions with extra constraints that is used on each iteration of 'Switch'.
-- An instance of this knows how to construct a handler of the first type in the 'xs' typelist, or
-- how to construct the remaining 'Case's for the rest of the types in the type list.
class Case c xs r where
    -- | The remaining cases without the type x.
    remaining :: c xs r -> c (Tail xs) r
    -- | Return the handler/continuation when x is observed.
    delegate :: c xs r -> (Head xs -> r)

-------------------------------------------

-- | Contains a 'Catalog' of handlers/continuations for all thypes in the 'xs' typelist.
newtype Cases fs (xs :: [Type]) r = Cases (Catalog fs)

-- | An instance of 'Case' that can be 'Switch'ed where it contains a 'Catalog' of handlers/continuations
-- for all thypes in the 'xs' typelist.
instance (Item (Head xs -> r) (Catalog fs)) => Case (Cases fs) xs r where
    remaining (Cases s) = Cases s
    delegate (Cases s) = s ^. item

-- | Create Cases for handling 'switch' from a tuple.
-- This function imposes additional constraints than using 'Cases' constructor directly:
-- * SameLength constraints to prevent human confusion with unusable cases.
-- * Outcome fs ~ r constraints to ensure that the Catalog only continutations that return r.
-- Example: @switch a $ cases (f, g, h)@
cases :: (SameLength fs xs, Outcome fs ~ r, Cataloged fs, fs ~ TypesOf (TupleOf fs)) => TupleOf fs -> Cases fs xs r
cases = Cases . catalog

-------------------------------------------

-- | This handler stores a polymorphic function for all Typeables.
data TypeableCase (xs :: [Type]) r = TypeableCase (forall x. Typeable x => x -> r)

instance Typeable (Head xs) => Case TypeableCase xs r where
    remaining (TypeableCase f) = TypeableCase f
    delegate (TypeableCase f) = f

-------------------------------------------

-- | Convert a Many to another Many that may include other possibilities.
-- That is, xs is equal or is a subset of ys.
-- Can be used to rearrange the order of the types in the Many.
-- NB. forall used to specify ys first, so TypeApplications can be used to specify ys.
-- The Switch constraint is fulfilled with
-- (Distinct ys, forall x (in xs). Member x xs)
diversify :: forall ys xs. Switch xs (DiversifyCase ys) (Many ys) => Many xs -> Many ys
diversify = many (DiversifyCase @ys)

data DiversifyCase (ys :: [Type]) (xs :: [Type]) r = DiversifyCase

instance (Member (Head xs) ys, Distinct ys) => Case (DiversifyCase ys) xs (Many ys) where
    remaining DiversifyCase = DiversifyCase
    delegate DiversifyCase = pick

-------------------------------------------

-- | Convert a Many into possibly another Many with a totally different typelist.
-- NB. forall used to specify ys first, so TypeApplications can be used to specify ys.
-- The Switch constraint is fulfilled with
-- (Distinct ys, forall x (in xs). (MaybeMember x ys)
reinterpret :: forall ys xs. Switch xs (ReinterpretCase ys) (Maybe (Many ys)) => Many xs -> Maybe (Many ys)
reinterpret = many (ReinterpretCase @ys)

data ReinterpretCase (ys :: [Type]) (xs :: [Type]) r = ReinterpretCase

instance (MaybeMember (Head xs) ys, Distinct ys) => Case (ReinterpretCase ys) xs (Maybe (Many ys)) where
    remaining ReinterpretCase = ReinterpretCase
    delegate ReinterpretCase a = case fromIntegral (natVal @(PositionOf (Head xs) ys) Proxy) of
                                     0 -> Nothing
                                     i -> Just $ Many (i - 1) (unsafeCoerce a)


-- | Like reinterpret, but return the Complement (the parts of xs not in ys) in the case of failure.
-- The Switch constraints is fulfilled with
-- (Distinct ys, forall x (in xs). (MaybeMember x ys, Member x (Complement xs ys)))
reinterpretEither
    :: forall ys xs.
       ( Switch xs (DiversifyCase (Complement xs ys)) (Many (Complement xs ys))
       , Switch xs (ReinterpretCase ys) (Maybe (Many ys))
       )
    => Many xs -> Either (Many (Complement xs ys)) (Many ys)
reinterpretEither v = case reinterpret v of
    Nothing -> Left (diversify v)
    Just v' -> Right v'

-------------------------------------------

-- | A Many has a prism to an the inner type.
-- That is, a value can be 'pick'ed into a Many or mabye 'trial'ed out of a Many.
-- | Use TypeApplication to specify the smaller type of the prism.
-- Example: @facet \@[Int, Bool]@
class Facet leaf branch where
    -- Example: @facet \@Int@
    facet :: Prism' branch leaf

-- | UndecidableInstance due to xs appearing more often in the constraint.
-- Safe because xs will not expand to @Many xs@ or bigger.
instance (Distinct xs, Member a xs) => Facet a (Many xs) where
    facet = prism' pick trial
    {-# INLINE facet #-}

-------------------------------------------

-- | Injection.
-- A Many can be 'diversify'ed to contain more types or 'reinterpret'ed into possibly another Many type.
-- This typeclass looks like 'Facet' but is used for different purposes. Also it has the type params reversed,
-- so that TypeApplications can be used to specify the larger Many type.
-- Use TypeApplication to specify the larger type of the prism.
-- Example: @inject \@[Int, Bool]@
class Inject tree branch where
    -- | Enlarge number of or change order of types in the variant.
    -- Use TypeApplication to specify the destination type.
    -- Example: @inject \@(Many '[Int, String])@
    inject :: Prism' tree branch

instance ( (Switch branch (DiversifyCase tree) (Many tree))
         , (Switch tree (ReinterpretCase branch) (Maybe (Many branch)))
         ) =>
         Inject (Many tree) (Many branch) where
    inject = prism' diversify reinterpret
    {-# INLINE inject #-}

-- | Utilites

-- TODO:

-- Show and Read instances

-- Eq instance?
