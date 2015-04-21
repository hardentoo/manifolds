-- |
-- Module      : Data.VectorSpace.FiniteDimensional
-- Copyright   : (c) Justus Sagemüller 2015
-- License     : GPL v3
-- 
-- Maintainer  : (@) sagemueller $ geo.uni-koeln.de
-- Stability   : experimental
-- Portability : portable
-- 
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE ScopedTypeVariables        #-}




module Data.VectorSpace.FiniteDimensional (
    FiniteDimensional(..)
  , SmoothScalar 
  ) where
    

    

import Prelude hiding ((^))

import Data.VectorSpace
import Data.LinearMap
import Data.Basis
import Data.MemoTrie
import Data.Tagged
import Data.Void

import Control.Applicative
    
import Data.Manifold.Types.Primitive
import Data.CoNat

import qualified Data.Vector as Arr
import qualified Numeric.LinearAlgebra.HMatrix as HMat




-- | Constraint that a space's scalars need to fulfill so it can be used for efficient linear algebra.
--   Fulfilled pretty much only by the basic real and complex floating-point types.
type SmoothScalar s = ( VectorSpace s, HMat.Numeric s, HMat.Field s
                      , Num(HMat.Vector s), HMat.Indexable(HMat.Vector s)s
                      , HMat.Normed(HMat.Vector s) )


-- | Many linear algebra operations are best implemented via packed, dense 'HMat.Matrix'es.
--   For one thing, that makes common general vector operations quite efficient,
--   in particular on high-dimensional spaces.
--   More importantly, @hmatrix@ offers linear facilities
--   such as inverse and eigenbasis transformations, which aren't available in the
--   @vector-space@ library yet. But the classes from that library are strongly preferrable
--   to plain matrices and arrays, conceptually.
-- 
--   The 'FiniteDimensional' class is used to convert between both representations.
--   It would be nice not to have the requirement of finite dimension on 'HerMetric',
--   but it's probably not feasible to get rid of it in forseeable time.
class (HasBasis v, HasTrie (Basis v), SmoothScalar (Scalar v)) => FiniteDimensional v where
  dimension :: Tagged v Int
  basisIndex :: Tagged v (Basis v -> Int)
  -- | Index must be in @[0 .. dimension-1]@, otherwise this is undefined.
  indexBasis :: Tagged v (Int -> Basis v)
  completeBasis :: Tagged v [Basis v]
  completeBasis = liftA2 (\dim f -> f <$> [0 .. dim - 1]) dimension indexBasis
  
  asPackedVector :: v -> HMat.Vector (Scalar v)
  asPackedVector v = HMat.fromList $ snd <$> decompose v
  
  asPackedMatrix :: (FiniteDimensional w, Scalar w ~ Scalar v)
                       => (v :-* w) -> HMat.Matrix (Scalar v)
  asPackedMatrix = defaultAsPackedMatrix
   where defaultAsPackedMatrix :: forall v w s .
               (FiniteDimensional v, FiniteDimensional w, s~Scalar v, s~Scalar w)
                         => (v :-* w) -> HMat.Matrix s
         defaultAsPackedMatrix m = HMat.fromRows $ asPackedVector . atBasis m <$> cb
          where (Tagged cb) = completeBasis :: Tagged v [Basis v]
  
  fromPackedVector :: HMat.Vector (Scalar v) -> v
  fromPackedVector v = result
   where result = recompose $ zip cb (HMat.toList v)
         cb = witness completeBasis result

instance (SmoothScalar k) => FiniteDimensional (ZeroDim k) where
  dimension = Tagged 0
  basisIndex = Tagged absurd
  indexBasis = Tagged $ const undefined
  completeBasis = Tagged []
  asPackedVector Origin = HMat.fromList []
  fromPackedVector _ = Origin
instance FiniteDimensional ℝ where
  dimension = Tagged 1
  basisIndex = Tagged $ \() -> 0
  indexBasis = Tagged $ \0 -> ()
  completeBasis = Tagged [()]
  asPackedVector x = HMat.fromList [x]
  asPackedMatrix f = HMat.asRow . asPackedVector $ atBasis f ()
  fromPackedVector v = v HMat.! 0
instance (FiniteDimensional a, FiniteDimensional b, Scalar a~Scalar b)
            => FiniteDimensional (a,b) where
  dimension = tupDim
   where tupDim :: forall a b.(FiniteDimensional a,FiniteDimensional b)=>Tagged(a,b)Int
         tupDim = Tagged $ da+db
          where (Tagged da)=dimension::Tagged a Int; (Tagged db)=dimension::Tagged b Int
  basisIndex = basId
   where basId :: forall a b . (FiniteDimensional a, FiniteDimensional b)
                     => Tagged (a,b) (Either (Basis a) (Basis b) -> Int)
         basId = Tagged basId'
          where basId' (Left ba) = basIda ba
                basId' (Right bb) = da + basIdb bb
                (Tagged da) = dimension :: Tagged a Int
                (Tagged basIda) = basisIndex :: Tagged a (Basis a->Int)
                (Tagged basIdb) = basisIndex :: Tagged b (Basis b->Int)
  indexBasis = basId
   where basId :: forall a b . (FiniteDimensional a, FiniteDimensional b)
                     => Tagged (a,b) (Int -> Either (Basis a) (Basis b))
         basId = Tagged basId'
          where basId' i | i < da     = Left $ basIda i
                         | otherwise  = Right . basIdb $ i - da
                (Tagged da) = dimension :: Tagged a Int
                (Tagged basIda) = indexBasis :: Tagged a (Int->Basis a)
                (Tagged basIdb) = indexBasis :: Tagged b (Int->Basis b)
  completeBasis = cb
   where cb :: forall a b . (FiniteDimensional a, FiniteDimensional b)
                     => Tagged (a,b) [Either (Basis a) (Basis b)]
         cb = Tagged $ map Left cba ++ map Right cbb
          where (Tagged cba) = completeBasis :: Tagged a [Basis a]
                (Tagged cbb) = completeBasis :: Tagged b [Basis b]
  asPackedVector (a,b) = HMat.vjoin [asPackedVector a, asPackedVector b]
  fromPackedVector = fPV
   where fPV :: forall a b . (FiniteDimensional a, FiniteDimensional b, Scalar a~Scalar b)
                     => HMat.Vector (Scalar a) -> (a,b)
         fPV v = (fromPackedVector l, fromPackedVector r)
          where (Tagged da) = dimension :: Tagged a Int
                (Tagged db) = dimension :: Tagged b Int
                l = HMat.subVector 0 da v
                r = HMat.subVector da db v
              
  
instance (SmoothScalar x, KnownNat n) => FiniteDimensional (FreeVect n x) where
  dimension = freeVectDimension
  basisIndex = Tagged getInRange
  indexBasis = Tagged InRange
  asPackedVector (FreeVect arr) = Arr.convert arr
  fromPackedVector arr = FreeVect (Arr.convert arr)
  -- asPackedMatrix = _ -- could be done quite efficiently here!
                                                          

