-- |
-- Module      : Data.Manifold.PseudoAffine
-- Copyright   : (c) Justus Sagemüller 2015
-- License     : GPL v3
-- 
-- Maintainer  : (@) sagemueller $ geo.uni-koeln.de
-- Stability   : experimental
-- Portability : portable
-- 
-- This is the second prototype of a manifold class. It appears to give considerable
-- advantages over 'Data.Manifold.Manifold', so that class will probably soon be replaced
-- with the one we define here (though 'PseudoAffine' does not follow the standard notion
-- of a manifold very closely, it should work quite equivalently for pretty much all
-- Haskell types that qualify as manifolds).
-- 
-- Manifolds are interesting as objects of various categories, from continuous to
-- diffeomorphic. At the moment, we mainly focus on /region-wise differentiable functions/,
-- which are a promising compromise between flexibility of definition and provability of
-- analytic properties. In particular, they are well-suited for visualisation purposes.

{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE FunctionalDependencies   #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE TupleSections            #-}
{-# LANGUAGE ConstraintKinds          #-}
{-# LANGUAGE PatternGuards            #-}
{-# LANGUAGE TypeOperators            #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE CPP                      #-}


module Data.Manifold.PseudoAffine (
            -- * Manifold class
              PseudoAffine(..)
            -- * Regions within a manifold
            , Region
            -- * Hierarchy of manifold-categories
            , Differentiable
            , PWDiffable, RWDiffable
            -- * Helper constraints
            , RealDimension
            ) where
    


import Data.List
import Data.Maybe
import Data.Semigroup
import Data.Function (on)
import Data.Fixed

import Data.VectorSpace
import Data.LinearMap
import Data.LinearMap.HerMetric
import Data.MemoTrie (HasTrie)
import Data.AffineSpace
import Data.Basis
import Data.Complex hiding (magnitude)
import Data.Void
import Data.Tagged
import Data.Manifold.Types

import qualified Prelude

import Control.Category.Constrained.Prelude hiding ((^))
import Control.Arrow.Constrained
import Control.Monad.Constrained
import Data.Foldable.Constrained




infix 6 .-~.
infixl 6 .+~^, .-~^

-- | 'PseudoAffine' is intended as an alternative class for 'Data.Manifold.Manifold's.
--   The interface is almost identical to the better-known 'AffineSpace' class, but unlike
--   in the mathematical definition of affine spaces we don't require associativity 
--   of '.+~^' with '^+^' &#x2013; except in an asymptotic sense for small vectors.
--   
--   That innocent-looking change makes the class applicable to vastly more general types:
--   while an affine space is basically nothing but a vector space without particularly
--   designated origin, a pseudo-affine space can have nontrivial topology on the global
--   scale, and yet be used in practically the same way as an affine space. At least the
--   usual spheres and tori make good instances, perhaps the class is in fact equivalent to
--   /parallelisable manifolds/.
class (AdditiveGroup (PseudoDiff x)) => PseudoAffine x where
  type PseudoDiff x :: *
  -- | The &#x201c;way&#x201d; reaching from one point to another.
  --   Should only yield 'Nothing' if the points are on disjoint segments of a
  --   non&#x2013;path-connected manifold.
  (.-~.) :: x -> x -> Option (PseudoDiff x)
  
  -- | Go such a way as obtained from '.-~.', starting from some reference point.
  --   
  -- @
  -- p .+~^ (q.-~.p) &#x2261; q
  -- @
  --   
  --   This should hold exactly (at least up to floating-point precision limits).
  (.+~^) :: x -> PseudoDiff x -> x
  
  -- | Shorthand for @\\p v -> p .+~^ 'negateV' v@, which should obey the /asymptotic/ law
  --   
  -- @
  -- p .-~^ v .+~^ v &#x2245; p
  -- @
  --   
  --   Meaning: if @v@ is scaled down with sufficiently small factors /&#x3b7;/, then
  --   the difference @(p.-~^v.+~^v) .-~. p@ should scale down even faster:
  --   as /O/ (/&#x3b7;/&#xb2;).
  (.-~^) :: x -> PseudoDiff x -> x
  p .-~^ v = p .+~^ negateV v


type LocallyScalable s x = ( PseudoAffine x, (PseudoDiff x) ~ PseudoDiff x
                           , HasMetric (PseudoDiff x)
                           , DualSpace (PseudoDiff x) ~ DualSpace (PseudoDiff x)
                           , s ~ Scalar (PseudoDiff x) )
type LinearManifold s x = ( PseudoAffine x, PseudoDiff x ~ x
                          , HasMetric x
                          , s ~ Scalar x )
type RealDimension r = ( PseudoAffine r, PseudoDiff r ~ r
                       , HasMetric r, DualSpace r ~ r, Scalar r ~ r
                       , RealFloat r )



palerp :: (PseudoAffine x, VectorSpace (PseudoDiff x))
    => x -> x -> Option (Scalar (PseudoDiff x) -> x)
palerp p1 p2 = fmap (\v t -> p1 .+~^ t *^ v) $ p2 .-~. p1



#define deriveAffine(t)          \
instance PseudoAffine t where {   \
  type PseudoDiff t = Diff t;      \
  a.-~.b = pure (a.-.b);            \
  (.+~^) = (.+^)  }

deriveAffine(Double)
deriveAffine(Rational)

instance PseudoAffine (ZeroDim k) where
  type PseudoDiff (ZeroDim k) = ZeroDim k
  Origin .-~. Origin = pure Origin
  Origin .+~^ Origin = Origin
instance (PseudoAffine a, PseudoAffine b) => PseudoAffine (a,b) where
  type PseudoDiff (a,b) = (PseudoDiff a, PseudoDiff b)
  (a,b).-~.(c,d) = liftA2 (,) (a.-~.c) (b.-~.d)
  (a,b).+~^(v,w) = (a.+~^v, b.+~^w)
instance (PseudoAffine a, PseudoAffine b, PseudoAffine c) => PseudoAffine (a,b,c) where
  type PseudoDiff (a,b,c) = (PseudoDiff a, PseudoDiff b, PseudoDiff c)
  (a,b,c).-~.(d,e,f) = liftA3 (,,) (a.-~.d) (b.-~.e) (c.-~.f)
  (a,b,c).+~^(v,w,x) = (a.+~^v, b.+~^w, c.+~^x)


instance PseudoAffine S⁰ where
  type PseudoDiff S⁰ = ℝ⁰
  PositiveHalfSphere .-~. PositiveHalfSphere = pure Origin
  NegativeHalfSphere .-~. NegativeHalfSphere = pure Origin
  _ .-~. _ = Option Nothing
  p .+~^ Origin = p

instance PseudoAffine S¹ where
  type PseudoDiff S¹ = ℝ
  S¹ φ₁ .-~. S¹ φ₀
     | δφ > pi     = pure (δφ - 2*pi)
     | δφ < (-pi)  = pure (δφ + 2*pi)
     | otherwise   = pure δφ
   where δφ = φ₁ - φ₀
  S¹ φ₀ .+~^ δφ
     | φ' < 0     = S¹ $ φ' + tau
     | otherwise  = S¹ $ φ'
   where φ' = toS¹range $ φ₀ + δφ

instance PseudoAffine S² where
  type PseudoDiff S² = ℝ²
  S² ϑ₁ φ₁ .-~. S² ϑ₀ φ₀
     | ϑ₀ < pi/2  = pure ( ϑ₁*^embed(S¹ φ₁) ^-^ ϑ₀*^embed(S¹ φ₀) )
     | otherwise  = pure ( (pi-ϑ₁)*^embed(S¹ φ₁) ^-^ (pi-ϑ₀)*^embed(S¹ φ₀) )
  S² ϑ₀ φ₀ .+~^ δv
     | ϑ₀ < pi/2  = sphereFold PositiveHalfSphere $ ϑ₀*^embed(S¹ φ₀) ^+^ δv
     | otherwise  = sphereFold NegativeHalfSphere $ (pi-ϑ₀)*^embed(S¹ φ₀) ^+^ δv

sphereFold :: S⁰ -> ℝ² -> S²
sphereFold hfSphere v
   | ϑ₀ > pi     = S² (inv $ tau - ϑ₀) (toS¹range $ φ₀+pi)
   | otherwise  = S² (inv ϑ₀) φ₀
 where S¹ φ₀ = coEmbed v
       ϑ₀ = magnitude v `mod'` tau
       inv ϑ = case hfSphere of PositiveHalfSphere -> ϑ
                                NegativeHalfSphere -> pi - ϑ


instance PseudoAffine ℝP² where
  type PseudoDiff ℝP² = ℝ²
  ℝP² r₁ φ₁ .-~. ℝP² r₀ φ₀
   | r₀ > 1/2   = pure `id` case φ₁-φ₀ of
                          δφ | δφ > 3*pi/2  -> (  r₁ - r₀, δφ - 2*pi)
                             | δφ < -3*pi/2 -> (  r₁ - r₀, δφ + 2*pi)
                             | δφ > pi/2    -> (2-r₁ - r₀, δφ - pi  )
                             | δφ < -pi/2   -> (2-r₁ - r₀, δφ + pi  )
                             | otherwise    -> (  r₁ - r₀, δφ       )
   | otherwise  = pure ( r₁*^embed(S¹ φ₁) ^-^ r₀*^embed(S¹ φ₀) )
  ℝP² r₀ φ₀ .+~^ (δr, δφ)
   | r₀ > 1/2   = case r₀ + δr of
                   r₁ | r₁ > 1     -> ℝP² (2-r₁) (toS¹range $ φ₀+δφ+pi)
                      | otherwise  -> ℝP²    r₁  (toS¹range $ φ₀+δφ)
  ℝP² r₀ φ₀ .+~^ δxy = let v = r₀*^embed(S¹ φ₀) ^+^ δxy
                           S¹ φ₁ = coEmbed v
                           r₁ = magnitude v `mod'` 1
                       in ℝP² r₁ φ₁  


instance (PseudoAffine m, VectorSpace (PseudoDiff m), Scalar (PseudoDiff m) ~ ℝ)
             => PseudoAffine (CD¹ m) where
  type PseudoDiff (CD¹ m) = (PseudoDiff m, ℝ)
  CD¹ h₁ m₁ .-~. CD¹ h₀ m₀
     = fmap ( \δm -> (h₁*^δm, h₁-h₀) ) $ m₁.-~.m₀
  CD¹ h₀ m₀ .+~^ (h₁δm, δh)
      = let h₁ = min 1 . max 1e-300 $ h₀+δh; δm = h₁δm^/h₁
        in CD¹ h₁ (m₀.+~^δm)
                               



tau :: ℝ
tau = 2 * pi

toS¹range :: ℝ -> ℝ
toS¹range φ = (φ+pi)`mod'`tau - pi




type LinDevPropag d c = HerMetric (PseudoDiff c) -> HerMetric (PseudoDiff d)

dev_ε_δ :: RealDimension a
                => (a -> a) -> LinDevPropag a a
dev_ε_δ f d = let ε = 1 / metric d 1 in projector $ 1 / sqrt (f ε)

-- | The category of differentiable functions between manifolds over scalar @s@.
--   
--   As you might guess, these offer /automatic differentiation/ of sorts (basically,
--   simple forward AD), but that's in itself is not really the killer feature here.
--   More interestingly, we actually have the (à la Curry-Howard) /proof/
--   built in: the function /f/ has at /x/&#x2080; derivative /f'&#x2093;/&#x2080;,
--   if, for&#xb9; /&#x3b5;/>0, there exists /&#x3b4;/ such that
--   |/f/ /x/ &#x2212; (/f/ /x/&#x2080; + /x/&#x22c5;/f'&#x2093;/&#x2080;)| < /&#x3b5;/
--   for all |/x/ &#x2212; /x/&#x2080;| < /&#x3b4;/.
-- 
--   Observe that, though this looks quite similar to the standard definition
--   of differentiability, it is not equivalent thereto &#x2013; in fact it does
--   not prove any analytic properties at all. To make it equivalent, we need
--   a lower bound on /&#x3b4;/: simply /&#x3b4;/ gives us continuity, and for
--   continuous differentiability, /&#x3b4;/ must grow at least like &#x221a;/&#x3b5;/
--   for small /&#x3b5;/. Neither of these conditions are enforced by the type system,
--   but we do require them for any allowed values because these proofs are obviously
--   tremendously useful &#x2013; for instance, you can have a root-finding algorithm
--   and actually be sure you get /all/ solutions correctly, not just /some/ that are
--   (hopefully) the closest to some reference point you'd need to laborously define!
-- 
--   Unfortunately however, this also prevents doing any serious algebra etc. with the
--   category, because even something as simple as division necessary introduces singularities
--   where the derivatives must diverge.
--   Not to speak of many trigonometric e.g. trigonometric functions that
--   are undefined on whole regions. The 'PWDiffable' and 'RWDiffable' categories have explicit
--   handling for those issues built in; you may simply use these categories even when
--   you know the result will be smooth in your relevant domain (or must be, for e.g.
--   physics reasons).
--   
--   &#xb9;(The implementation does not deal with /&#x3b5;/ and /&#x3b4;/ as difference-bounding
--   reals, but rather as metric tensors that define a boundary by prohibiting the
--   overlap from exceeding one; this makes the concept actually work on general manifolds.)
newtype Differentiable s d c
   = Differentiable { runDifferentiable ::
                        d -> ( c, PseudoDiff d :-* PseudoDiff c, LinDevPropag d c ) }
type (-->) = Differentiable ℝ


instance (MetricScalar s) => Category (Differentiable s) where
  type Object (Differentiable s) o = LocallyScalable s o
  id = Differentiable $ \x -> (x, idL, const zeroV)
  Differentiable f . Differentiable g = Differentiable $
     \x -> let (y, g', devg) = g x
               (z, f', devf) = f y
               devfg δz = let δy = transformMetric f' δz
                              εy = devf δz
                          in transformMetric g' εy ^+^ devg δy ^+^ devg εy
           in (z, f'*.*g', devfg)


instance (MetricScalar s) => Cartesian (Differentiable s) where
  type UnitObject (Differentiable s) = ZeroDim s
  swap = Differentiable $ \(x,y) -> ((y,x), lSwap, const zeroV)
   where lSwap = linear swap
  attachUnit = Differentiable $ \x -> ((x, Origin), lAttachUnit, const zeroV)
   where lAttachUnit = linear $ \x ->  (x, Origin)
  detachUnit = Differentiable $ \(x, Origin) -> (x, lDetachUnit, const zeroV)
   where lDetachUnit = linear $ \(x, Origin) ->  x
  regroup = Differentiable $ \(x,(y,z)) -> (((x,y),z), lRegroup, const zeroV)
   where lRegroup = linear regroup
  regroup' = Differentiable $ \((x,y),z) -> ((x,(y,z)), lRegroup, const zeroV)
   where lRegroup = linear regroup'


instance (MetricScalar s) => Morphism (Differentiable s) where
  Differentiable f *** Differentiable g = Differentiable h
   where h (x,y) = ((fx, gy), lPar, devfg)
          where (fx, f', devf) = f x
                (gy, g', devg) = g y
                devfg δs = transformMetric lfst δx 
                           ^+^ transformMetric lsnd δy
                  where δx = devf $ transformMetric lcofst δs
                        δy = devg $ transformMetric lcosnd δs
                lPar = linear $ lapply f'***lapply g'
         lfst = linear fst; lsnd = linear snd
         lcofst = linear (,zeroV); lcosnd = linear (zeroV,)


instance (MetricScalar s) => PreArrow (Differentiable s) where
  terminal = Differentiable $ \_ -> (Origin, zeroV, const zeroV)
  fst = Differentiable $ \(x,_) -> (x, lfst, const zeroV)
   where lfst = linear fst
  snd = Differentiable $ \(_,y) -> (y, lsnd, const zeroV)
   where lsnd = linear snd
  Differentiable f &&& Differentiable g = Differentiable h
   where h x = ((fx, gx), lFanout, devfg)
          where (fx, f', devf) = f x
                (gx, g', devg) = g x
                devfg δs = (devf $ transformMetric lcofst δs)
                           ^+^ (devg $ transformMetric lcosnd δs)
                lFanout = linear $ lapply f'&&&lapply g'
         lcofst = linear (,zeroV); lcosnd = linear (zeroV,)


instance (MetricScalar s) => WellPointed (Differentiable s) where
  unit = Tagged Origin
  globalElement x = Differentiable $ \Origin -> (x, zeroV, const zeroV)
  const x = Differentiable $ \_ -> (x, zeroV, const zeroV)



type DfblFuncValue s = GenericAgent (Differentiable s)

instance (MetricScalar s) => HasAgent (Differentiable s) where
  alg = genericAlg
  ($~) = genericAgentMap
instance (MetricScalar s) => CartesianAgent (Differentiable s) where
  alg1to2 = genericAlg1to2
  alg2to1 = genericAlg2to1
  alg2to2 = genericAlg2to2
instance (MetricScalar s)
      => PointAgent (DfblFuncValue s) (Differentiable s) a x where
  point = genericPoint



actuallyLinear :: ( LinearManifold s x, LinearManifold s y )
            => (x:-*y) -> Differentiable s x y
actuallyLinear f = Differentiable $ \x -> (lapply f x, f, const zeroV)

actuallyAffine :: ( LinearManifold s x, LinearManifold s y )
            => y -> (x:-*y) -> Differentiable s x y
actuallyAffine y₀ f = Differentiable $ \x -> (y₀ ^+^ lapply f x, f, const zeroV)


dfblFnValsFunc :: ( LocallyScalable s c, LocallyScalable s c', LocallyScalable s d
                  , v ~ PseudoDiff c, v' ~ PseudoDiff c'
                  , ε ~ HerMetric v, ε ~ HerMetric v' )
             => (c' -> (c, v':-*v, ε->ε)) -> DfblFuncValue s d c' -> DfblFuncValue s d c
dfblFnValsFunc f = (Differentiable f $~)

dfblFnValsCombine :: forall d c c' c'' v v' v'' ε ε' ε'' s. 
         ( LocallyScalable s c,  LocallyScalable s c',  LocallyScalable s c''
         ,  LocallyScalable s d
         , v ~ PseudoDiff c, v' ~ PseudoDiff c', v'' ~ PseudoDiff c''
         , ε ~ HerMetric v  , ε' ~ HerMetric v'  , ε'' ~ HerMetric v'', ε~ε', ε~ε''  )
       => (  c' -> c'' -> (c, (v',v''):-*v, ε -> (ε',ε''))  )
         -> DfblFuncValue s d c' -> DfblFuncValue s d c'' -> DfblFuncValue s d c
dfblFnValsCombine cmb (GenericAgent (Differentiable f))
                      (GenericAgent (Differentiable g)) 
    = GenericAgent . Differentiable $
        \d -> let (c', f', devf) = f d
                  (c'', g', devg) = g d
                  (c, h', devh) = cmb c' c''
                  h'l = h' *.* lcofst; h'r = h' *.* lcosnd
              in ( c
                 , h' *.* linear (lapply f' &&& lapply g')
                 , \εc -> let εc' = transformMetric h'l εc
                              εc'' = transformMetric h'r εc
                              (δc',δc'') = devh εc 
                          in devf εc' ^+^ devg εc''
                               ^+^ transformMetric f' δc'
                               ^+^ transformMetric g' δc''
                 )
 where lcofst = linear(,zeroV)
       lcosnd = linear(zeroV,) 





instance (LinearManifold s v, LocallyScalable s a, Floating s)
    => AdditiveGroup (DfblFuncValue s a v) where
  zeroV = point zeroV
  (^+^) = dfblFnValsCombine $ \a b -> (a^+^b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (^+^)
  negateV = dfblFnValsFunc $ \a -> (negateV a, lNegate, const zeroV)
      where lNegate = linear negateV
  
instance (RealDimension n, LocallyScalable n a)
            => Num (DfblFuncValue n a n) where
  fromInteger i = point $ fromInteger i
  (+) = dfblFnValsCombine $ \a b -> (a+b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (+)
  (*) = dfblFnValsCombine $
          \a b -> ( a*b
                  , linear $ \(da,db) -> a*db + b*da
                  , \d -> let d¹₂ = sqrt d in (d¹₂,d¹₂)
                           -- ε δa δb = (a+δa)·(b+δb) - (a·b + (a·δa + b·δb)) 
                           --         = δa·δb
                           --   so choose δa = δb = √ε
                  )
  negate = dfblFnValsFunc $ \a -> (negate a, lNegate, const zeroV)
      where lNegate = linear negate
  abs = dfblFnValsFunc dfblAbs
   where dfblAbs a
          | a>0        = (a, idL, dev_ε_δ $ \ε -> a + ε/2) 
          | a<0        = (-a, negateV idL, dev_ε_δ $ \ε -> ε/2 - a)
          | otherwise  = (0, zeroV, (^/ sqrt 2))
  signum = dfblFnValsFunc dfblSgn
   where dfblSgn a
          | a>0        = (1, zeroV, dev_ε_δ $ const a)
          | a<0        = (-1, zeroV, dev_ε_δ $ \_ -> -a)
          | otherwise  = (0, zeroV, const $ projector 1)



-- VectorSpace instance is more problematic than you'd think: multiplication
-- requires the allowed-deviation backpropagators to be split as square
-- roots, but the square root of a nontrivial-vector-space metric requires
-- an eigenbasis transform, which we have not implemented yet.
-- 
-- instance (LinearManifold s v, LocallyScalable s a, Floating s)
--       => VectorSpace (DfblFuncValue s a v) where
--   type Scalar (DfblFuncValue s a v) = DfblFuncValue s a (Scalar v)
--   (*^) = dfblFnValsCombine $ \μ v -> (μ*^v, lScl, \ε -> (ε ^* sqrt 2, ε ^* sqrt 2))
--       where lScl = linear $ uncurry (*^)


-- | Important special operator needed to compute intersection of 'Region's.
minDblfuncs :: (LocallyScalable s m, RealDimension s)
     => Differentiable s m s -> Differentiable s m s -> Differentiable s m s
minDblfuncs (Differentiable f) (Differentiable g) = Differentiable h
 where h x
         | fx==gx   = ( fx, (f'^+^g')^/2
                      , \d -> devf d ^+^ devg d
                               ^+^ transformMetric (f'^-^g')
                                                   (projector $ metric d 1) )
         | fx < gx   = ( fx, f'
                       , \d -> devf d
                               ^+^ transformMetric (f'^-^g')
                                                   (projector $ metric d 1 + gx - fx) )
        where (fx, f', devf) = f x
              (gx, g', devg) = g x



-- | A pathwise connected subset of a manifold @m@, whose tangent space has scalar @s@.
data Region s m = Region { regionRefPoint :: m
                         , regionRDef :: PreRegion s m }

-- | A 'PreRegion' needs to be associated with a certain reference point ('Region'
--   includes that point) to define a connected subset of a manifold.
data PreRegion s m where
  GlobalRegion :: PreRegion s m
  PreRegion :: (Differentiable s m s) -- A function that is positive at reference point /p/,
                                      -- decreases and crosses zero at the region's
                                      -- boundaries. (If it goes positive again somewhere
                                      -- else, these areas shall /not/ be considered
                                      -- belonging to the (by definition connected) region.)
         -> PreRegion s m

-- | Set-intersection of regions would not be guaranteed to yield a connected result
--   or even have the reference point of one region contained in the other. This
--   combinator assumes (unchecked) that the references are in a connected
--   sub-intersection, which is used as the result.
unsafePreRegionIntersect :: (RealDimension s, LocallyScalable s a)
                  => PreRegion s a -> PreRegion s a -> PreRegion s a
unsafePreRegionIntersect GlobalRegion r = r
unsafePreRegionIntersect r GlobalRegion = r
unsafePreRegionIntersect (PreRegion ra) (PreRegion rb) = PreRegion $ minDblfuncs ra rb

-- | Cartesian product of two regions.
regionProd :: (RealDimension s, LocallyScalable s a, LocallyScalable s b)
                  => Region s a -> Region s b -> Region s (a,b)
regionProd (Region a₀ ra) (Region b₀ rb) = Region (a₀,b₀) (preRegionProd ra rb)

-- | Cartesian product of two pre-regions.
preRegionProd :: (RealDimension s, LocallyScalable s a, LocallyScalable s b)
                  => PreRegion s a -> PreRegion s b -> PreRegion s (a,b)
preRegionProd GlobalRegion GlobalRegion = GlobalRegion
preRegionProd GlobalRegion (PreRegion rb) = PreRegion $ rb . snd
preRegionProd (PreRegion ra) GlobalRegion = PreRegion $ ra . fst
preRegionProd (PreRegion ra) (PreRegion rb) = PreRegion $ minDblfuncs (ra.fst) (rb.snd)


positivePreRegion, negativePreRegion :: (RealDimension s) => PreRegion s s
positivePreRegion = PreRegion $ Differentiable prr
 where prr x = (1 - 1/xp1, (1/xp1²) *^ idL, dev_ε_δ δ )
                 -- ε = (1 − 1/(1+x)) + (-δ · 1/(x+1)²) − (1 − 1/(1+x−δ))
                 --   = 1/(1+x−δ) − 1/(1+x) − δ · 1/(x+1)²
                 -- ε·(1+x−δ) = 1 − (1+x−δ)/(1+x) − δ·(1+x-δ)/(x+1)²
                 -- ε + ε·x − ε·δ = 1 − 1/(1+x) − x/(1+x) + δ/(1+x) − δ/(x+1) + δ²/(x+1)²
                 --               = 1 − 1/(1+x) − x/(1+x) + δ²/(x+1)²
                 --               = (1+x − 1 − x)/(1+x) + δ²/(x+1)²
                 -- 0 = δ² + ε·(x+1)²·δ + ε·(x+1)³
                 -- δ = let mph = -ε·(x+1)²/2
                 --     in mph + sqrt(mph² - ε·(x+1)³)
        where δ ε = let mph = -ε*xp1²/2
                    in mph + sqrt(mph^2 - ε * xp1² * xp1)
              xp1 = (x+1)
              xp1² = xp1 ^ 2
negativePreRegion = PreRegion $ ppr . ngt
 where PreRegion ppr = positivePreRegion
       ngt = actuallyLinear $ linear negate

preRegionToInfFrom, preRegionFromMinInfTo :: RealDimension s => s -> PreRegion s s
preRegionToInfFrom xs = PreRegion $ ppr . trl
 where PreRegion ppr = positivePreRegion
       trl = actuallyAffine (-xs) idL
preRegionFromMinInfTo xe = PreRegion $ ppr . flp
 where PreRegion ppr = positivePreRegion
       flp = actuallyAffine (-xe) (linear negate)

intervalPreRegion :: RealDimension s => (s,s) -> PreRegion s s
intervalPreRegion (lb,rb) = PreRegion $ Differentiable prr
 where m = lb + radius; radius = (rb - lb)/2
       prr x = ( 1 - ((x-m)/radius)^2
               , (2*(m-x)/radius^2) *^ idL
               , dev_ε_δ $ (*radius) . sqrt )




-- | Category of functions that almost everywhere have an open region in
--   which they are continuously differentiable, i.e. /PieceWiseDiff'able/.
newtype PWDiffable s d c
   = PWDiffable {
        getDfblDomain :: d -> (PreRegion s d, Differentiable s d c) }



instance (RealDimension s) => Category (PWDiffable s) where
  type Object (PWDiffable s) o = LocallyScalable s o
  id = PWDiffable $ \x -> (GlobalRegion, id)
  PWDiffable f . PWDiffable g = PWDiffable h
   where h x₀ = case g x₀ of
                 (GlobalRegion, gr)
                  -> let (y₀,_,_) = runDifferentiable gr x₀
                     in case f y₀ of
                         (GlobalRegion, fr) -> (GlobalRegion, fr . gr)
                         (PreRegion ry, fr)
                               -> ( PreRegion $ ry . gr, fr . gr )
                 (PreRegion rx, gr)
                  -> let (y₀,_,_) = runDifferentiable gr x₀
                     in case f y₀ of
                         (GlobalRegion, fr) -> (PreRegion rx, fr . gr)
                         (PreRegion ry, fr)
                               -> ( PreRegion $ minDblfuncs (ry . gr) rx
                                  , fr . gr )
          where (rx, gr) = g x₀

globalDiffable :: Differentiable s a b -> PWDiffable s a b
globalDiffable f = PWDiffable $ const (GlobalRegion, f)

instance (RealDimension s) => EnhancedCat (PWDiffable s) (Differentiable s) where
  arr = globalDiffable
                
instance (RealDimension s) => Cartesian (PWDiffable s) where
  type UnitObject (PWDiffable s) = ZeroDim s
  swap = globalDiffable swap
  attachUnit = globalDiffable attachUnit
  detachUnit = globalDiffable detachUnit
  regroup = globalDiffable regroup
  regroup' = globalDiffable regroup'
  
instance (RealDimension s) => Morphism (PWDiffable s) where
  PWDiffable f *** PWDiffable g = PWDiffable h
   where h (x,y) = (preRegionProd rfx rgy, dff *** dfg)
          where (rfx, dff) = f x
                (rgy, dfg) = g y

instance (RealDimension s) => PreArrow (PWDiffable s) where
  PWDiffable f &&& PWDiffable g = PWDiffable h
   where h x = (unsafePreRegionIntersect rfx rgx, dff &&& dfg)
          where (rfx, dff) = f x
                (rgx, dfg) = g x
  terminal = globalDiffable terminal
  fst = globalDiffable fst
  snd = globalDiffable snd


instance (RealDimension s) => WellPointed (PWDiffable s) where
  unit = Tagged Origin
  globalElement x = PWDiffable $ \Origin -> (GlobalRegion, globalElement x)
  const x = PWDiffable $ \_ -> (GlobalRegion, const x)


type PWDfblFuncValue s = GenericAgent (PWDiffable s)

instance RealDimension s => HasAgent (PWDiffable s) where
  alg = genericAlg
  ($~) = genericAgentMap
instance RealDimension s => CartesianAgent (PWDiffable s) where
  alg1to2 = genericAlg1to2
  alg2to1 = genericAlg2to1
  alg2to2 = genericAlg2to2
instance (RealDimension s)
      => PointAgent (PWDfblFuncValue s) (PWDiffable s) a x where
  point = genericPoint

gpwDfblFnValsFunc
     :: ( RealDimension s
        , LocallyScalable s c, LocallyScalable s c', LocallyScalable s d
        , v ~ PseudoDiff c, v' ~ PseudoDiff c'
        , ε ~ HerMetric v, ε ~ HerMetric v' )
             => (c' -> (c, v':-*v, ε->ε)) -> PWDfblFuncValue s d c' -> PWDfblFuncValue s d c
gpwDfblFnValsFunc f = (PWDiffable (\_ -> (GlobalRegion, Differentiable f)) $~)

gpwDfblFnValsCombine :: forall d c c' c'' v v' v'' ε ε' ε'' s. 
         ( LocallyScalable s c,  LocallyScalable s c',  LocallyScalable s c''
         , LocallyScalable s d, RealDimension s
         , v ~ PseudoDiff c, v' ~ PseudoDiff c', v'' ~ PseudoDiff c''
         , ε ~ HerMetric v  , ε' ~ HerMetric v'  , ε'' ~ HerMetric v'', ε~ε', ε~ε''  )
       => (  c' -> c'' -> (c, (v',v''):-*v, ε -> (ε',ε''))  )
         -> PWDfblFuncValue s d c' -> PWDfblFuncValue s d c'' -> PWDfblFuncValue s d c
gpwDfblFnValsCombine cmb (GenericAgent (PWDiffable fpcs))
                         (GenericAgent (PWDiffable gpcs)) 
    = GenericAgent . PWDiffable $
        \d₀ -> let (rc', Differentiable f) = fpcs d₀
                   (rc'',Differentiable g) = gpcs d₀
               in (unsafePreRegionIntersect rc' rc'',) . Differentiable $
                    \d -> let (c', f', devf) = f d
                              (c'',g', devg) = g d
                              (c, h', devh) = cmb c' c''
                              h'l = h' *.* lcofst; h'r = h' *.* lcosnd
                          in ( c
                             , h' *.* linear (lapply f' &&& lapply g')
                             , \εc -> let εc' = transformMetric h'l εc
                                          εc'' = transformMetric h'r εc
                                          (δc',δc'') = devh εc 
                                      in devf εc' ^+^ devg εc''
                                           ^+^ transformMetric f' δc'
                                           ^+^ transformMetric g' δc''
                             )
 where lcofst = linear(,zeroV)
       lcosnd = linear(zeroV,) 


instance (LinearManifold s v, LocallyScalable s a, RealDimension s)
    => AdditiveGroup (PWDfblFuncValue s a v) where
  zeroV = point zeroV
  (^+^) = gpwDfblFnValsCombine $ \a b -> (a^+^b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (^+^)
  negateV = gpwDfblFnValsFunc $ \a -> (negateV a, lNegate, const zeroV)
      where lNegate = linear negateV

instance (RealDimension n, LocallyScalable n a)
            => Num (PWDfblFuncValue n a n) where
  fromInteger i = point $ fromInteger i
  (+) = gpwDfblFnValsCombine $ \a b -> (a+b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (+)
  (*) = gpwDfblFnValsCombine $
          \a b -> ( a*b
                  , linear $ \(da,db) -> a*db + b*da
                  , \d -> let d¹₂ = sqrt d in (d¹₂,d¹₂)
                  )
  negate = gpwDfblFnValsFunc $ \a -> (negate a, lNegate, const zeroV)
      where lNegate = linear negate
  abs = (PWDiffable absPW $~)
   where absPW a₀
          | a₀<0       = (negativePreRegion, desc)
          | otherwise  = (positivePreRegion, asc)
         desc = actuallyLinear $ linear negate
         asc = actuallyLinear idL
  signum = (PWDiffable sgnPW $~)
   where sgnPW a₀
          | a₀<0       = (negativePreRegion, const 1)
          | otherwise  = (positivePreRegion, const $ -1)

instance (RealDimension n, LocallyScalable n a)
            => Fractional (PWDfblFuncValue n a n) where
  fromRational i = point $ fromRational i
  recip = (PWDiffable rcipPW $~)
   where rcipPW a₀
          | a₀<0       = (negativePreRegion, Differentiable negp)
          | otherwise  = (positivePreRegion, Differentiable posp)
         negp x = (x'¹, (- x'¹^2) *^ idL, dev_ε_δ δ)
                 -- ε = 1/x − δ/x² − 1/(x+δ)
                 -- ε·x + ε·δ = 1 + δ/x − δ/x − δ²/x² − 1
                 --           = -δ²/x²
                 -- 0 = δ² + ε·x²·δ + ε·x³
                 -- δ = let mph = -ε·x²/2 in mph + sqrt (mph² − ε·x³)
          where δ ε = let mph = -ε*x^2/2 in mph + sqrt (mph^2 - ε*x^3)
                x'¹ = recip x
         posp x = (x'¹, (- x'¹^2) *^ idL, dev_ε_δ δ)
          where δ ε = let mph = -ε*x^2/2 in mph + sqrt (mph^2 + ε*x^3)
                x'¹ = recip x






-- | Category of functions that, where defined, have an open region in
--   which they are continuously differentiable. Hence /RegionWiseDiff'able/.
--   Basically these are the partial version of `PWDiffable`.
-- 
--   Though the possibility of undefined regions is of course not too nice
--   (we don't need Java to demonstrate this with its everywhere-looming @null@ values...),
--   this category will propably be the &#x201c;workhorse&#x201d; for most serious
--   calculus applications, because it contains all the usual trig etc. functions
--   and of course everything algebraic you can do in the reals.
-- 
--   The easiest way to define ordinary functions in this category is hence
--   with its 'AgentVal'ues, which have instances of the standard classes 'Num'
--   through 'Floating'. For instance, the following defines the /binary entropy/
--   as a differentiable function on the interval @]0,1[@: (it will
--   actually /know/ where it's defined and where not! &#x2013; and I don't mean you
--   need to exhaustively 'isNaN'-check all results...)
-- 
-- @
-- hb :: RWDiffable &#x211d; &#x211d; &#x211d;
-- hb = alg (\\p -> - p * logBase 2 p - (1-p) * logBase 2 (1-p) )
-- @
newtype RWDiffable s d c
   = RWDiffable {
        tryDfblDomain :: d -> (PreRegion s d, Option (Differentiable s d c)) }

notDefinedHere :: Option (Differentiable s d c)
notDefinedHere = Option Nothing



instance (RealDimension s) => Category (RWDiffable s) where
  type Object (RWDiffable s) o = LocallyScalable s o
  id = RWDiffable $ \x -> (GlobalRegion, pure id)
  RWDiffable f . RWDiffable g = RWDiffable h
   where h x₀ = case g x₀ of
                 (GlobalRegion, Option Nothing)
                  -> (GlobalRegion, notDefinedHere)
                 (GlobalRegion, Option (Just gr))
                  -> let (y₀,_,_) = runDifferentiable gr x₀
                     in case f y₀ of
                         (GlobalRegion, Option Nothing)
                               -> (GlobalRegion, notDefinedHere)
                         (GlobalRegion, Option (Just fr))
                               -> (GlobalRegion, pure (fr . gr))
                         (PreRegion ry, Option Nothing)
                               -> ( PreRegion $ ry . gr, Option Nothing )
                         (PreRegion ry, Option (Just fr))
                               -> ( PreRegion $ ry . gr, pure (fr . gr) )
                 (PreRegion rx, Option Nothing)
                  -> (PreRegion rx, notDefinedHere)
                 (PreRegion rx, Option (Just gr))
                  -> let (y₀,_,_) = runDifferentiable gr x₀
                     in case f y₀ of
                         (GlobalRegion, Option Nothing)
                               -> (PreRegion rx, notDefinedHere)
                         (GlobalRegion, Option (Just fr))
                               -> (PreRegion rx, pure (fr . gr))
                         (PreRegion ry, Option Nothing)
                               -> ( PreRegion $ minDblfuncs (ry . gr) rx
                                  , notDefinedHere )
                         (PreRegion ry, Option (Just fr))
                               -> ( PreRegion $ minDblfuncs (ry . gr) rx
                                  , pure (fr . gr) )
          where (rx, gr) = g x₀


globalDiffable' :: Differentiable s a b -> RWDiffable s a b
globalDiffable' f = RWDiffable $ const (GlobalRegion, pure f)

pwDiffable :: PWDiffable s a b -> RWDiffable s a b
pwDiffable (PWDiffable q) = RWDiffable $ \x₀ -> let (r₀,f₀) = q x₀ in (r₀, pure f₀)



instance (RealDimension s) => EnhancedCat (RWDiffable s) (Differentiable s) where
  arr = globalDiffable'
instance (RealDimension s) => EnhancedCat (RWDiffable s) (PWDiffable s) where
  arr = pwDiffable
                
instance (RealDimension s) => Cartesian (RWDiffable s) where
  type UnitObject (RWDiffable s) = ZeroDim s
  swap = globalDiffable' swap
  attachUnit = globalDiffable' attachUnit
  detachUnit = globalDiffable' detachUnit
  regroup = globalDiffable' regroup
  regroup' = globalDiffable' regroup'
  
instance (RealDimension s) => Morphism (RWDiffable s) where
  RWDiffable f *** RWDiffable g = RWDiffable h
   where h (x,y) = (preRegionProd rfx rgy, liftA2 (***) dff dfg)
          where (rfx, dff) = f x
                (rgy, dfg) = g y

instance (RealDimension s) => PreArrow (RWDiffable s) where
  RWDiffable f &&& RWDiffable g = RWDiffable h
   where h x = (unsafePreRegionIntersect rfx rgx, liftA2 (&&&) dff dfg)
          where (rfx, dff) = f x
                (rgx, dfg) = g x
  terminal = globalDiffable' terminal
  fst = globalDiffable' fst
  snd = globalDiffable' snd


instance (RealDimension s) => WellPointed (RWDiffable s) where
  unit = Tagged Origin
  globalElement x = RWDiffable $ \Origin -> (GlobalRegion, pure (globalElement x))
  const x = RWDiffable $ \_ -> (GlobalRegion, pure (const x))


type RWDfblFuncValue s = GenericAgent (RWDiffable s)

instance RealDimension s => HasAgent (RWDiffable s) where
  alg = genericAlg
  ($~) = genericAgentMap
instance RealDimension s => CartesianAgent (RWDiffable s) where
  alg1to2 = genericAlg1to2
  alg2to1 = genericAlg2to1
  alg2to2 = genericAlg2to2
instance (RealDimension s)
      => PointAgent (RWDfblFuncValue s) (RWDiffable s) a x where
  point = genericPoint

grwDfblFnValsFunc
     :: ( RealDimension s
        , LocallyScalable s c, LocallyScalable s c', LocallyScalable s d
        , v ~ PseudoDiff c, v' ~ PseudoDiff c'
        , ε ~ HerMetric v, ε ~ HerMetric v' )
             => (c' -> (c, v':-*v, ε->ε)) -> RWDfblFuncValue s d c' -> RWDfblFuncValue s d c
grwDfblFnValsFunc f = (RWDiffable (\_ -> (GlobalRegion, pure (Differentiable f))) $~)

grwDfblFnValsCombine :: forall d c c' c'' v v' v'' ε ε' ε'' s. 
         ( LocallyScalable s c,  LocallyScalable s c',  LocallyScalable s c''
         , LocallyScalable s d, RealDimension s
         , v ~ PseudoDiff c, v' ~ PseudoDiff c', v'' ~ PseudoDiff c''
         , ε ~ HerMetric v  , ε' ~ HerMetric v'  , ε'' ~ HerMetric v'', ε~ε', ε~ε''  )
       => (  c' -> c'' -> (c, (v',v''):-*v, ε -> (ε',ε''))  )
         -> RWDfblFuncValue s d c' -> RWDfblFuncValue s d c'' -> RWDfblFuncValue s d c
grwDfblFnValsCombine cmb (GenericAgent (RWDiffable fpcs))
                         (GenericAgent (RWDiffable gpcs)) 
    = GenericAgent . RWDiffable $
        \d₀ -> let (rc', fmay) = fpcs d₀
                   (rc'',gmay) = gpcs d₀
               in (unsafePreRegionIntersect rc' rc'',) $
                    case (fmay,gmay) of
                      (Option(Just(Differentiable f)), Option(Just(Differentiable g))) ->
                        pure . Differentiable $ \d
                         -> let (c', f', devf) = f d
                                (c'',g', devg) = g d
                                (c, h', devh) = cmb c' c''
                                h'l = h' *.* lcofst; h'r = h' *.* lcosnd
                            in ( c
                               , h' *.* linear (lapply f' &&& lapply g')
                               , \εc -> let εc' = transformMetric h'l εc
                                            εc'' = transformMetric h'r εc
                                            (δc',δc'') = devh εc 
                                        in devf εc' ^+^ devg εc''
                                             ^+^ transformMetric f' δc'
                                             ^+^ transformMetric g' δc''
                               )
                      _ -> notDefinedHere
 where lcofst = linear(,zeroV)
       lcosnd = linear(zeroV,) 



instance (LinearManifold s v, LocallyScalable s a, RealDimension s)
    => AdditiveGroup (RWDfblFuncValue s a v) where
  zeroV = point zeroV
  (^+^) = grwDfblFnValsCombine $ \a b -> (a^+^b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (^+^)
  negateV = grwDfblFnValsFunc $ \a -> (negateV a, lNegate, const zeroV)
      where lNegate = linear negateV

instance (RealDimension n, LocallyScalable n a)
            => Num (RWDfblFuncValue n a n) where
  fromInteger i = point $ fromInteger i
  (+) = grwDfblFnValsCombine $ \a b -> (a+b, lPlus, const zeroV)
      where lPlus = linear $ uncurry (+)
  (*) = grwDfblFnValsCombine $
          \a b -> ( a*b
                  , linear $ \(da,db) -> a*db + b*da
                  , \d -> let d¹₂ = sqrt d in (d¹₂,d¹₂)
                  )
  negate = grwDfblFnValsFunc $ \a -> (negate a, lNegate, const zeroV)
      where lNegate = linear negate
  abs = (RWDiffable absPW $~)
   where absPW a₀
          | a₀<0       = (negativePreRegion, pure desc)
          | otherwise  = (positivePreRegion, pure asc)
         desc = actuallyLinear $ linear negate
         asc = actuallyLinear idL
  signum = (RWDiffable sgnPW $~)
   where sgnPW a₀
          | a₀<0       = (negativePreRegion, pure (const 1))
          | otherwise  = (positivePreRegion, pure (const $ -1))

instance (RealDimension n, LocallyScalable n a)
            => Fractional (RWDfblFuncValue n a n) where
  fromRational i = point $ fromRational i
  recip = (RWDiffable rcipPW $~)
   where rcipPW a₀
          | a₀<0       = (negativePreRegion, pure (Differentiable negp))
          | otherwise  = (positivePreRegion, pure (Differentiable posp))
         negp x = (x'¹, (- x'¹^2) *^ idL, dev_ε_δ δ)
                 -- ε = 1/x − δ/x² − 1/(x+δ)
                 -- ε·x + ε·δ = 1 + δ/x − δ/x − δ²/x² − 1
                 --           = -δ²/x²
                 -- 0 = δ² + ε·x²·δ + ε·x³
                 -- δ = let mph = -ε·x²/2 in mph + sqrt (mph² − ε·x³)
          where δ ε = let mph = -ε*x^2/2 in mph + sqrt (mph^2 - ε*x^3)
                x'¹ = recip x
         posp x = (x'¹, (- x'¹^2) *^ idL, dev_ε_δ δ)
          where δ ε = let mph = -ε*x^2/2 in mph + sqrt (mph^2 + ε*x^3)
                x'¹ = recip x





-- Helper for checking ε-estimations in GHCi with dynamic-plot:
-- epsEst (f,f') εsgn δf (ViewXCenter xc) (ViewHeight h)
--    = let δfxc = δf xc
--      in tracePlot $ reverse [ (xc - δ, f xc - δ * f' xc + εsgn*ε) |
--                               ε <- [0, h/500 .. h], let δ = δfxc ε]
--                          ++ [ (xc + δ, f xc + δ * f' xc + εsgn*ε) |
--                               ε <- [0, h/500 .. h], let δ = δfxc ε] 
-- Golfed version:
-- epsEst(f,d)s φ(ViewXCenter ξ)(ViewHeight h)=let ζ=φ ξ in tracePlot$[(ξ-δ,f ξ-δ*d ξ+s*abs ε)|ε<-[-h,-0.998*h..h],let δ=ζ(abs ε)*signum ε]

instance (RealDimension n, LocallyScalable n a)
            => Floating (RWDfblFuncValue n a n) where
  pi = point pi
  
  exp = grwDfblFnValsFunc
    $ \x -> let ex = exp x
            in ( ex, ex *^ idL, dev_ε_δ $ \ε -> acosh(ε/(2*ex) + 1) )
                 -- ε = e^(x+δ) − eˣ − eˣ·δ 
                 --   = eˣ·(e^δ − 1 − δ) 
                 --   ≤ eˣ · (e^δ − 1 + e^(-δ) − 1)
                 --   = eˣ · 2·(cosh(δ) − 1)
                 -- cosh(δ) ≥ ε/(2·eˣ) + 1
                 -- δ ≥ acosh(ε/(2·eˣ) + 1)
  log = (RWDiffable lnRW $~)
   where lnRW x | x > 0      = (positivePreRegion, pure (Differentiable lnPosR))
                | otherwise  = (negativePreRegion, notDefinedHere)
         lnPosR x = ( log x, recip x *^ idL, dev_ε_δ $ \ε -> x * sqrt(1 - exp(-ε)) )
                 -- ε = ln x + (-δ)/x − ln(x−δ)
                 --   = ln (x / ((x−δ) · exp(δ/x)))
                 -- x/e^ε = (x−δ) · exp(δ/x)
                 -- let γ = δ/x ∈ [0,1[
                 -- exp(-ε) = (1−γ) · e^γ
                 --         ≥ (1−γ) · (1+γ)
                 --         = 1 − γ²
                 -- γ ≥ sqrt(1 − exp(-ε)) 
                 -- δ ≥ x · sqrt(1 − exp(-ε)) 
                    
  sqrt = (RWDiffable sqrtRW $~)
   where sqrtRW x | x > 0      = (positivePreRegion, pure (Differentiable sqrtPosR))
                  | otherwise  = (negativePreRegion, notDefinedHere)
         sqrtPosR x = ( sx, idL ^/ (2*sx), dev_ε_δ $
                          \ε -> 2 * (s2 * sqrt sx^3 * sqrt ε + signum (ε*2-sx) * sx * ε) )
          where sx = sqrt x; s2 = sqrt 2
                 -- Exact inverse of O(δ²) remainder.
  
  sin = grwDfblFnValsFunc sinDfb
   where sinDfb x = ( sx, cx *^ idL, dev_ε_δ δ )
          where sx = sin x; cx = cos x
                δ ε = let δ₀ = sqrt $ 2 * ε / (abs sx + abs cx/3)
                      in if δ₀ < 1 -- TODO: confirm selection of δ-definition range.
                          then δ₀
                          else max 1 $ (ε - abs sx - 1) / cos x
                 -- When sin x ≥ 0, cos x ≥ 0, δ ∈ [0,1[
                 -- ε = sin x + δ · cos x − sin(x+δ)
                 --   = sin x + δ · cos x − sin x · cos δ − cos x · sin δ
                 --   ≤ sin x + δ · cos x − sin x · (1−δ²/2) − cos x · (δ − δ³/6)
                 --   = sin x · δ²/2 + cos x · δ³/6
                 --   ≤ δ² · (sin x / 2 + cos x / 6)
                 -- δ ≥ sqrt(2 · ε / (sin x + cos x / 3))
                 -- For general δ≥0,
                 -- ε ≤ δ · cos x + sin x + 1
                 -- δ ≥ (ε − sin x − 1) / cos x
  cos = sin . (globalDiffable' (actuallyAffine (pi/2) idL) $~)
  
  sinh x = (exp x - exp (-x))/2
    {- = grwDfblFnValsFunc sinhDfb
   where sinhDfb x = ( sx, cx *^ idL, dev_ε_δ δ )
          where sx = sinh x; cx = cosh x
                δ ε = undefined -}
                 -- ε = sinh x + δ · cosh x − sinh(x+δ)
                 --   = ½ · ( eˣ − e⁻ˣ + δ · (eˣ + e⁻ˣ) − exp(x+δ) + exp(-x−δ) )
                 --                  = ½·e⁻ˣ · ( e²ˣ − 1 + δ · (e²ˣ + 1) − e²ˣ·e^δ + e^-δ )
                 --   = ½ · ( eˣ − e⁻ˣ + δ · (eˣ + e⁻ˣ) − exp(x+δ) + exp(-x−δ) )
  cosh x = (exp x + exp (-x))/2
  tanh x = (exp x - exp (-x)) / (exp x + exp (-x))

  atan = grwDfblFnValsFunc atanDfb
   where atanDfb x = ( atnx, idL ^/ (1+x^2), dev_ε_δ δ )
          where atnx = atan x
                c = (atnx*2/pi)^2
                p = 1 + abs x/(2*pi)
                δ ε = p * (sqrt ε + ε * c)
                 -- Semi-empirically obtained: with the epsEst helper,
                 -- it is observed that this function is (for xc≥0) a lower bound
                 -- to the arctangent. The growth of the p coefficient makes sense
                 -- and holds for arbitrarily large xc, because those move us linearly
                 -- away from the only place where the function is not virtually constant
                 -- (around 0).
   
  asin = (RWDiffable asinRW $~)
   where asinRW x | x < (-1)   = (preRegionFromMinInfTo (-1), notDefinedHere)  
                  | x > 1      = (preRegionToInfFrom 1, notDefinedHere)
                  | otherwise  = (intervalPreRegion (-1,1), pure (Differentiable asinDefdR))
         asinDefdR x = ( asinx, asin'x *^ idL, dev_ε_δ δ )
          where asinx = asin x; asin'x = recip (sqrt $ 1 - x^2)
                c = 1 - x^2 
                δ ε = sqrt ε * c
                 -- Empirical, with epsEst upper bound.

  acos = (RWDiffable acosRW $~)
   where acosRW x | x < (-1)   = (preRegionFromMinInfTo (-1), notDefinedHere)  
                  | x > 1      = (preRegionToInfFrom 1, notDefinedHere)
                  | otherwise  = (intervalPreRegion (-1,1), pure (Differentiable acosDefdR))
         acosDefdR x = ( acosx, acos'x *^ idL, dev_ε_δ δ )
          where acosx = acos x; acos'x = - recip (sqrt $ 1 - x^2)
                c = 1 - x^2
                δ ε = sqrt ε * c -- Like for asin – it's just a translation/reflection.

  asinh = grwDfblFnValsFunc asinhDfb
   where asinhDfb x = ( asinhx, idL ^/ sqrt(1+x^2), dev_ε_δ δ )
          where asinhx = asinh x
                δ ε = abs x * sqrt((1 - exp(-ε))*0.8 + ε^2/(3*abs x)) + sqrt(ε/(abs x+0.5))
                 -- Empirical, modified from log function (the area hyperbolic sine
                 -- resembles two logarithmic lobes), with epsEst-checked lower bound.
  
  acosh = (RWDiffable acoshRW $~)
   where acoshRW x | x > 0      = (positivePreRegion, pure (Differentiable acoshDfb))
                  | otherwise  = (negativePreRegion, notDefinedHere)
         acoshDfb x = ( acosh x, idL ^/ sqrt(x^2 - 2), dev_ε_δ δ )
          where δ ε = (2 - 1/sqrt x) * (s2 * sqrt sx^3 * sqrt(ε/s2) + signum (ε*s2-sx) * sx * ε/s2) 
                sx = sqrt(x-1)
                s2 = sqrt 2
                 -- Empirical, modified from sqrt function – the area hyperbolic cosine
                 -- strongly resembles \x -> sqrt(2 · (x-1)).
                    
  atanh = (RWDiffable atnhRW $~)
   where atnhRW x | x < (-1)   = (preRegionFromMinInfTo (-1), notDefinedHere)  
                  | x > 1      = (preRegionToInfFrom 1, notDefinedHere)
                  | otherwise  = (intervalPreRegion (-1,1), pure (Differentiable atnhDefdR))
         atnhDefdR x = ( atanh x, recip(1-x^2) *^ idL, dev_ε_δ $ \ε -> sqrt(tanh ε)*(1-abs x) )
                 -- Empirical, with epsEst upper bound.
  
  
  
