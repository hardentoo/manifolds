-- |
-- Module      : Data.Manifold.Riemannian
-- Copyright   : (c) Justus Sagemüller 2015
-- License     : GPL v3
-- 
-- Maintainer  : (@) sagemueller $ geo.uni-koeln.de
-- Stability   : experimental
-- Portability : portable
-- 
-- Riemannian manifolds are manifolds equipped with a 'Metric' at each point.
-- That means, these manifolds aren't merely topological objects anymore, but
-- have a geometry as well. This gives, in particular, a notion of distance
-- and shortest paths (geodesics) along which you can interpolate.
-- 
-- Keep in mind that the types in this library are
-- generally defined in an abstract-mathematical spirit, which may not always
-- match the intuition if you think about manifolds as embedded in ℝ³.
-- (For instance, the torus inherits its geometry from the decomposition as
-- @'S¹' × 'S¹'@, not from the “doughnut” embedding; the cone over @S¹@ is
-- simply treated as the unit disk, etc..)

{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE ParallelListComp           #-}
{-# LANGUAGE UnicodeSyntax              #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}


module Data.Manifold.Riemannian  where


import Data.List hiding (filter, all, elem, sum)
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Vector as Arr
import Data.List.NonEmpty (NonEmpty(..))
import Data.List.FastNub
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
import Data.Ord (comparing)
import Control.DeepSeq

import Data.VectorSpace
import Data.LinearMap
import Data.LinearMap.HerMetric
import Data.LinearMap.Category
import Data.AffineSpace
import Data.Basis
import Data.Complex hiding (magnitude)
import Data.Void
import Data.Tagged
import Data.Proxy

import Data.Manifold.Types
import Data.Manifold.Types.Primitive ((^), embed, coEmbed)
import Data.Manifold.PseudoAffine
import Data.VectorSpace.FiniteDimensional
    
import Data.Embedding
import Data.CoNat

import qualified Prelude as Hask hiding(foldl, sum, sequence)
import qualified Control.Applicative as Hask
import qualified Control.Monad       as Hask hiding(forM_, sequence)
import Data.Functor.Identity
import Control.Monad.Trans.State
import Control.Monad.Trans.Writer
import Control.Monad.Trans.Class
import qualified Data.Foldable       as Hask
import Data.Foldable (all, elem, toList, sum)
import qualified Data.Traversable as Hask
import Data.Traversable (forM)

import qualified Numeric.LinearAlgebra.HMatrix as HMat

import Control.Category.Constrained.Prelude hiding
     ((^), all, elem, sum, forM, Foldable(..), Traversable)
import Control.Arrow.Constrained
import Control.Monad.Constrained hiding (forM)
import Data.Foldable.Constrained

import GHC.Generics (Generic)


class PseudoAffine x => Geodesic x where
  geodesicBetween :: s ~ Scalar (Needle x)
      => x -> x -> Option (D¹ -> x)



#define deriveAffineGD(x)                                         \
instance Geodesic x where {                                        \
  geodesicBetween a b = return $ alerp a b . (/2) . (+1) . xParamD¹ \
 }

deriveAffineGD (ℝ)

instance Geodesic (ZeroDim ℝ) where
  geodesicBetween Origin Origin = return $ \_ -> Origin

instance (Geodesic a, Geodesic b) => Geodesic (a,b) where
  geodesicBetween (a,b) (α,β) = liftA2 (&&&) (geodesicBetween a α) (geodesicBetween b β)

instance (Geodesic a, Geodesic b, Geodesic c) => Geodesic (a,b,c) where
  geodesicBetween (a,b,c) (α,β,γ)
      = liftA3 (\ia ib ic t -> (ia t, ib t, ic t))
           (geodesicBetween a α) (geodesicBetween b β) (geodesicBetween c γ)

instance (KnownNat n) => Geodesic (FreeVect n ℝ) where
  geodesicBetween (FreeVect v) (FreeVect w)
      = return $ \(D¹ t) -> let μv = (1-t)/2; μw = (t+1)/2
                            in FreeVect $ Arr.zipWith (\vi wi -> μv*vi + μw*wi) v w

instance (PseudoAffine v) => Geodesic (FinVecArrRep t v ℝ) where
  geodesicBetween (FinVecArrRep v) (FinVecArrRep w)
   | HMat.size v>0 && HMat.size w>0
      = return $ \(D¹ t) -> let μv = (1-t)/2; μw = (t+1)/2
                            in FinVecArrRep $ HMat.scale μv v + HMat.scale μw w

instance (Geodesic v, WithField ℝ HilbertSpace v)
             => Geodesic (Stiefel1 v) where
  geodesicBetween (Stiefel1 p') (Stiefel1 q')
      = (\f -> \(D¹ t) -> Stiefel1 . f . D¹ $ g * tan (ϑ*t))
            <$> geodesicBetween p q
   where p = normalized p'; q = normalized q'
         l = magnitude $ p^-^q
         ϑ = asin $ l/2
         g = sqrt $ 4/l^2 - 1


instance Geodesic S⁰ where
  geodesicBetween PositiveHalfSphere PositiveHalfSphere = return $ const PositiveHalfSphere
  geodesicBetween NegativeHalfSphere NegativeHalfSphere = return $ const NegativeHalfSphere
  geodesicBetween _ _ = Hask.empty

instance Geodesic S¹ where
  geodesicBetween (S¹ φ) (S¹ ϕ)
    | abs (φ-ϕ) < pi  = (>>> S¹) <$> geodesicBetween φ ϕ
    | φ > 0           = (>>> S¹ . \ψ -> signum ψ*pi - ψ)
                        <$> geodesicBetween (pi-φ) (-ϕ-pi)
    | otherwise       = (>>> S¹ . \ψ -> signum ψ*pi - ψ)
                        <$> geodesicBetween (-pi-φ) (pi-ϕ)


instance Geodesic (Cℝay S⁰) where
  geodesicBetween p q = (>>> fromℝ) <$> geodesicBetween (toℝ p) (toℝ q)
   where toℝ (Cℝay h PositiveHalfSphere) = h
         toℝ (Cℝay h NegativeHalfSphere) = -h
         fromℝ x | x>0        = Cℝay x PositiveHalfSphere
                 | otherwise  = Cℝay (-x) NegativeHalfSphere

instance Geodesic (CD¹ S⁰) where
  geodesicBetween p q = (>>> fromI) <$> geodesicBetween (toI p) (toI q)
   where toI (CD¹ h PositiveHalfSphere) = h
         toI (CD¹ h NegativeHalfSphere) = -h
         fromI x | x>0        = CD¹ x PositiveHalfSphere
                 | otherwise  = CD¹ (-x) NegativeHalfSphere

instance Geodesic (Cℝay S¹) where
  geodesicBetween p q = (>>> fromP) <$> geodesicBetween (toP p) (toP q)
   where fromP = fromInterior
         toP w = case toInterior w of {Option (Just i) -> i}

instance Geodesic (CD¹ S¹) where
  geodesicBetween p q = (>>> fromI) <$> geodesicBetween (toI p) (toI q)
   where toI (CD¹ h (S¹ φ)) = (h*cos φ, h*sin φ)
         fromI (x,y) = CD¹ (sqrt $ x^2+y^2) (S¹ $ atan2 y x)

instance Geodesic (Cℝay S²) where
  geodesicBetween p q = (>>> fromP) <$> geodesicBetween (toP p) (toP q)
   where fromP = fromInterior
         toP w = case toInterior w of {Option (Just i) -> i}

instance Geodesic (CD¹ S²) where
  geodesicBetween p q = (>>> fromI) <$> geodesicBetween (toI p) (toI q :: ℝ³)
   where toI (CD¹ h sph) = h *^ embed sph
         fromI v = CD¹ (magnitude v) (coEmbed v)

#define geoVSpCone(c,t)                                               \
instance (c) => Geodesic (Cℝay (t)) where {                            \
  geodesicBetween p q = (>>> fromP) <$> geodesicBetween (toP p) (toP q) \
   where { fromP (x,0) = Cℝay 0 x                                        \
         ; fromP (x,h) = Cℝay h (x^/h)                                    \
         ; toP (Cℝay h w) = ( h*^w, h ) } } ;                              \
instance (c) => Geodesic (CD¹ (t)) where {                                  \
  geodesicBetween p q = (>>> fromP) <$> geodesicBetween (toP p) (toP q)      \
   where { fromP (x,0) = CD¹ 0 x                                              \
         ; fromP (x,h) = CD¹ h (x^/h)                                          \
         ; toP (CD¹ h w) = ( h*^w, h ) } }

geoVSpCone ((), ℝ)
geoVSpCone ((), ZeroDim ℝ)
geoVSpCone ((WithField ℝ HilbertSpace a, WithField ℝ HilbertSpace b, Geodesic (a,b)), (a,b))
geoVSpCone (KnownNat n, FreeVect n ℝ)
geoVSpCone ((Geodesic v, WithField ℝ HilbertSpace v), FinVecArrRep t v ℝ)

