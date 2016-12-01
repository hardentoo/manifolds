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
-- 
-- The classes in this module are mostly aimed at manifolds /without boundary/.
-- Manifolds with boundary (which we call @MWBound@, never /manifold/!)
-- are more or less treated as a disjoint sum of the interior and the boundary.
-- To understand how this module works, best first forget about boundaries – in this case,
-- @'Interior' x ~ x@, 'fromInterior' and 'toInterior' are trivial, and
-- '.+~|', '|-~.' and 'betweenBounds' are irrelevant.
-- The manifold structure of the boundary itself is not considered at all here.

{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE FunctionalDependencies   #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE LiberalTypeSynonyms      #-}
{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE StandaloneDeriving       #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE TupleSections            #-}
{-# LANGUAGE ConstraintKinds          #-}
{-# LANGUAGE DefaultSignatures        #-}
{-# LANGUAGE PatternGuards            #-}
{-# LANGUAGE TypeOperators            #-}
{-# LANGUAGE UnicodeSyntax            #-}
{-# LANGUAGE MultiWayIf               #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE CPP                      #-}


module Data.Manifold.PseudoAffine (
            -- * Manifold class
              Manifold
            , Semimanifold(..), Needle'
            , PseudoAffine(..)
            -- * Type definitions
            -- ** Needles
            , Local(..)
            -- ** Metrics
            , Metric, Metric', euclideanMetric
            , RieMetric, RieMetric'
            -- ** Constraints
            , SemimanifoldWitness(..)
            , PseudoAffineWitness(..)
            , DualNeedleWitness 
            , RealDimension, AffineManifold
            , LinearManifold
            , WithField
            , HilbertManifold
            , EuclidSpace
            , LocallyScalable
            -- ** Local functions
            , LocalLinear, LocalAffine
            -- * Misc
            , alerpB, palerp, palerpB, LocallyCoercible(..), CanonicalDiffeomorphism(..)
            , ImpliesMetric(..), coerceMetric, coerceMetric'
            ) where
    


import Data.Maybe
import Data.Semigroup
import Data.Fixed

import Data.VectorSpace
import Linear.V0
import Linear.V1
import Linear.V2
import Linear.V3
import Linear.V4
import qualified Linear.Affine as LinAff
import Data.Embedding
import Data.LinearMap
import Math.LinearMap.Category
import Data.AffineSpace
import Data.Tagged
import Data.Manifold.Types.Primitive

import Data.CoNat

import qualified Prelude
import qualified Control.Applicative as Hask

import Control.Category.Constrained.Prelude hiding ((^))
import Control.Arrow.Constrained
import Control.Monad.Constrained
import Data.Foldable.Constrained

import GHC.Exts (Constraint)



-- | This is the reified form of the property that the interior of a semimanifold
--   is a manifold. These constraints would ideally be expressed directly as
--   superclass constraints, but that would require the @UndecidableSuperclasses@
--   extension, which is not reliable yet.
-- 
-- Also, if all those equality constraints are in scope, GHC tends to infer needlessly
-- complicated types like @'Interior' ('Interior' ('Needle' ('Interior' x)))@, which is
-- the same as just @'Needle' x@.
data SemimanifoldWitness x where
  SemimanifoldWitness ::
      ( Semimanifold (Interior x), Semimanifold (Needle x)
      , Interior (Interior x) ~ Interior x, Needle (Interior x) ~ Needle x
      , Interior (Needle x) ~ Needle x )
     => SemimanifoldWitness x

data PseudoAffineWitness x where
  PseudoAffineWitness ::
      ( PseudoAffine (Interior x), PseudoAffine (Needle x) )
     => PseudoAffineWitness x

infix 6 .-~., .-~!
infixl 6 .+~^, .-~^

class AdditiveGroup (Needle x) => Semimanifold x where
  {-# MINIMAL ((.+~^) | fromInterior), toInterior, translateP #-}
  -- | The space of &#x201c;natural&#x201d; ways starting from some reference point
  --   and going to some particular target point. Hence,
  --   the name: like a compass needle, but also with an actual length.
  --   For affine spaces, 'Needle' is simply the space of
  --   line segments (aka vectors) between two points, i.e. the same as 'Diff'.
  --   The 'AffineManifold' constraint makes that requirement explicit.
  -- 
  --   This space should be isomorphic to the tangent space (and is in fact
  --   used somewhat synonymously).
  type Needle x :: *
  
  -- | Manifolds with boundary are a bit tricky. We support such manifolds,
  --   but carry out most calculations only in “the fleshy part” – the
  --   interior, which is an “infinite space”, so you can arbitrarily scale paths.
  -- 
  --   The default implementation is @'Interior' x = x@, which corresponds
  --   to a manifold that has no boundary to begin with.
  type Interior x :: *
  type Interior x = x
  
  -- | Generalised translation operation. Note that the result will always also
  --   be in the interior; scaling up the needle can only get you ever /closer/
  --   to a boundary.
  (.+~^) :: Interior x -> Needle x -> x
  (.+~^) = addvp
   where addvp :: ∀ x . Semimanifold x => Interior x -> Needle x -> x
         addvp p = fromInterior . tp p
          where (Tagged tp) = translateP :: Tagged x (Interior x -> Needle x -> Interior x)
    
  -- | 'id' sans boundary.
  fromInterior :: Interior x -> x
  fromInterior p = p .+~^ zeroV 
  
  toInterior :: x -> Option (Interior x)
  
  -- | The signature of '.+~^' should really be @'Interior' x -> 'Needle' x -> 'Interior' x@,
  --   only, this is not possible because it only consists of non-injective type families.
  --   The solution is this tagged signature, which is of course rather unwieldy. That's
  --   why '.+~^' has the stronger, but easier usable signature. Without boundary, these
  --   functions should be equivalent, i.e. @translateP = Tagged (.+~^)@.
  translateP :: Tagged x (Interior x -> Needle x -> Interior x)
  
  -- | Shorthand for @\\p v -> p .+~^ 'negateV' v@, which should obey the /asymptotic/ law
  --   
  -- @
  -- p .-~^ v .+~^ v &#x2245; p
  -- @
  --   
  --   Meaning: if @v@ is scaled down with sufficiently small factors /&#x3b7;/, then
  --   the difference @(p.-~^v.+~^v) .-~. p@ should scale down even faster:
  --   as /O/ (/&#x3b7;/&#xb2;). For large vectors, it will however behave differently,
  --   except in flat spaces (where all this should be equivalent to the 'AffineSpace'
  --   instance).
  (.-~^) :: Interior x -> Needle x -> x
  p .-~^ v = p .+~^ negateV v
  
  semimanifoldWitness :: SemimanifoldWitness x
  default semimanifoldWitness ::
      ( Semimanifold (Interior x), Semimanifold (Needle x)
      , Interior (Interior x) ~ Interior x, Needle (Interior x) ~ Needle x
      , Interior (Needle x) ~ Needle x )
     => SemimanifoldWitness x
  semimanifoldWitness = SemimanifoldWitness

  
-- | This is the class underlying manifolds. ('Manifold' only precludes boundaries
--   and adds an extra constraint that would be circular if it was in a single
--   class. You can always just use 'Manifold' as a constraint in your signatures,
--   but you must /define/ only 'PseudoAffine' for manifold types &#x2013;
--   the 'Manifold' instance follows universally from this, if @'Interior x ~ x@.)
--   
--   The interface is (boundaries aside) almost identical to the better-known
--   'AffineSpace' class, but we don't require associativity of '.+~^' with '^+^'
--   &#x2013; except in an /asymptotic sense/ for small vectors.
--   
--   That innocent-looking change makes the class applicable to vastly more general types:
--   while an affine space is basically nothing but a vector space without particularly
--   designated origin, a pseudo-affine space can have nontrivial topology on the global
--   scale, and yet be used in practically the same way as an affine space. At least the
--   usual spheres and tori make good instances, perhaps the class is in fact equivalent to
--   manifolds in their usual maths definition (with an atlas of charts: a family of
--   overlapping regions of the topological space, each homeomorphic to the 'Needle'
--   vector space or some simply-connected subset thereof).
class Semimanifold x => PseudoAffine x where
  {-# MINIMAL (.-~.) | (.-~!) #-}
  -- | The path reaching from one point to another.
  --   Should only yield 'Nothing' if
  -- 
  --   * The points are on disjoint segments of a non&#x2013;path-connected space.
  -- 
  --   * Either of the points is on the boundary. Use '|-~.' to deal with this.
  -- 
  --   On manifolds, the identity
  --   
  -- @
  -- p .+~^ (q.-~.p) &#x2261; q
  -- @
  --   
  --   should hold, at least save for floating-point precision limits etc..
  -- 
  --   '.-~.' and '.+~^' only really work in manifolds without boundary. If you consider
  --   the path between two points, one of which lies on the boundary, it can't really
  --   be possible to scale this path any longer – it would have to reach “out of the
  --   manifold”. To adress this problem, these functions basically consider only the
  --   /interior/ of the space.
  (.-~.) :: x -> Interior x -> Option (Needle x)
  p.-~.q = return $ p.-~!q
  
  -- | Unsafe version of '.-~.'. If the two points lie in disjoint regions,
  --   the behaviour is undefined.
  (.-~!) :: x -> Interior x -> Needle x
  p.-~!q = case p.-~.q of
      Option (Just v) -> v
  
  pseudoAffineWitness :: PseudoAffineWitness x
  default pseudoAffineWitness ::
      ( PseudoAffine (Interior x), PseudoAffine (Needle x) )
     => PseudoAffineWitness x
  pseudoAffineWitness = PseudoAffineWitness
  

  
  
  

-- | See 'Semimanifold' and 'PseudoAffine' for the methods.
class (PseudoAffine m, LinearManifold (Needle m), Interior m ~ m) => Manifold m
instance (PseudoAffine m, LinearManifold (Needle m), Interior m ~ m) => Manifold m



-- | Instances of this class must be diffeomorphic manifolds, and even have
--   /canonically isomorphic/ tangent spaces, so that
--   @'fromPackedVector' . 'asPackedVector' :: 'Needle' x -> 'Needle' ξ@
--   defines a meaningful “representational identity“ between these spaces.
class ( Semimanifold x, Semimanifold ξ, LSpace (Needle x), LSpace (Needle ξ)
      , Scalar (Needle x) ~ Scalar (Needle ξ) )
         => LocallyCoercible x ξ where
  -- | Must be compatible with the isomorphism on the tangent spaces, i.e.
  -- @
  -- locallyTrivialDiffeomorphism (p .+~^ v)
  --   ≡ locallyTrivialDiffeomorphism p .+~^ 'coerceNeedle' v
  -- @
  locallyTrivialDiffeomorphism :: x -> ξ
  coerceNeedle :: Functor p (->) (->) => p (x,ξ) -> (Needle x -+> Needle ξ)
  coerceNeedle' :: Functor p (->) (->) => p (x,ξ) -> (Needle' x -+> Needle' ξ)
  oppositeLocalCoercion :: CanonicalDiffeomorphism ξ x
  default oppositeLocalCoercion :: LocallyCoercible ξ x => CanonicalDiffeomorphism ξ x
  oppositeLocalCoercion = CanonicalDiffeomorphism
  interiorLocalCoercion :: Functor p (->) (->) 
                  => p (x,ξ) -> CanonicalDiffeomorphism (Interior x) (Interior ξ)
  default interiorLocalCoercion :: LocallyCoercible (Interior x) (Interior ξ)
                  => p (x,ξ) -> CanonicalDiffeomorphism (Interior x) (Interior ξ)
  interiorLocalCoercion _ = CanonicalDiffeomorphism

#define identityCoercion(c,t)                   \
instance (c) => LocallyCoercible (t) (t) where { \
  locallyTrivialDiffeomorphism = id;              \
  coerceNeedle _ = id;                             \
  coerceNeedle' _ = id;                             \
  oppositeLocalCoercion = CanonicalDiffeomorphism;   \
  interiorLocalCoercion _ = CanonicalDiffeomorphism }
identityCoercion(NumberManifold s, ZeroDim s)
identityCoercion(NumberManifold s, V0 s)
identityCoercion((), ℝ)
identityCoercion(NumberManifold s, V1 s)
identityCoercion((), (ℝ,ℝ))
identityCoercion(NumberManifold s, V2 s)
identityCoercion((), (ℝ,(ℝ,ℝ)))
identityCoercion((), ((ℝ,ℝ),ℝ))
identityCoercion(NumberManifold s, V3 s)
identityCoercion(NumberManifold s, V4 s)


data CanonicalDiffeomorphism a b where
  CanonicalDiffeomorphism :: LocallyCoercible a b => CanonicalDiffeomorphism a b

-- | A point on a manifold, as seen from a nearby reference point.
newtype Local x = Local { getLocalOffset :: Needle x }
deriving instance (Show (Needle x)) => Show (Local x)

type LocallyScalable s x = ( PseudoAffine x
                           , LSpace (Needle x)
                           , s ~ Scalar (Needle x)
                           , s ~ Scalar (Needle' x)
                           , Num' s )

type LocalLinear x y = LinearMap (Scalar (Needle x)) (Needle x) (Needle y)
type LocalAffine x y = (Needle y, LocalLinear x y)

-- | Basically just an &#x201c;updated&#x201d; version of the 'VectorSpace' class.
--   Every vector space is a manifold, this constraint makes it explicit.
type LinearManifold x = ( AffineManifold x, Needle x ~ x, LSpace x )

type LinearManifold' x = ( PseudoAffine x, AffineSpace x, Diff x ~ x
                         , Interior x ~ x, Needle x ~ x, LSpace x )

-- | Require some constraint on a manifold, and also fix the type of the manifold's
--   underlying field. For example, @WithField &#x211d; 'HilbertManifold' v@ constrains
--   @v@ to be a real (i.e., 'Double'-) Hilbert space.
--   Note that for this to compile, you will in
--   general need the @-XLiberalTypeSynonyms@ extension (except if the constraint
--   is an actual type class (like 'Manifold'): only those can always be partially
--   applied, for @type@ constraints this is by default not allowed).
type WithField s c x = ( c x, s ~ Scalar (Needle x), s ~ Scalar (Needle' x) )

-- | The 'RealFloat' class plus manifold constraints.
type RealDimension r = ( PseudoAffine r, Interior r ~ r, Needle r ~ r, r ~ ℝ)

-- | The 'AffineSpace' class plus manifold constraints.
type AffineManifold m = ( PseudoAffine m, Interior m ~ m, AffineSpace m
                        , Needle m ~ Diff m, LinearManifold' (Diff m) )

-- | A Hilbert space is a /complete/ inner product space. Being a vector space, it is
--   also a manifold.
-- 
--   (Stricly speaking, that doesn't have much to do with the completeness criterion;
--   but since 'Manifold's are at the moment confined to finite dimension, they are in
--   fact (trivially) complete.)
type HilbertManifold x = ( LinearManifold x, InnerSpace x
                         , Interior x ~ x, Needle x ~ x, DualVector x ~ x
                         , Floating (Scalar x) )

-- | An euclidean space is a real affine space whose tangent space is a Hilbert space.
type EuclidSpace x = ( AffineManifold x, InnerSpace (Diff x)
                     , DualVector (Diff x) ~ Diff x, Floating (Scalar (Diff x)) )

type NumberManifold n = ( Num' n, Manifold n, Interior n ~ n, Needle n ~ n
                        , LSpace n, DualVector n ~ n, Scalar n ~ n )

euclideanMetric :: EuclidSpace x => proxy x -> Metric x
euclideanMetric _ = euclideanNorm


-- | A co-needle can be understood as a “paper stack”, with which you can measure
--   the length that a needle reaches in a given direction by counting the number
--   of holes punched through them.
type Needle' x = DualVector (Needle x)


-- | The word &#x201c;metric&#x201d; is used in the sense as in general relativity.
--   Actually this is just the type of scalar products on the tangent space.
--   The actual metric is the function @x -> x -> Scalar (Needle x)@ defined by
--
-- @
-- \\p q -> m '|$|' (p.-~!q)
-- @
type Metric x = Norm (Needle x)
type Metric' x = Variance (Needle x)

-- | A Riemannian metric assigns each point on a manifold a scalar product on the tangent space.
--   Note that this association is /not/ continuous, because the charts/tangent spaces in the bundle
--   are a priori disjoint. However, for a proper Riemannian metric, all arising expressions
--   of scalar products from needles between points on the manifold ought to be differentiable.
type RieMetric x = x -> Metric x
type RieMetric' x = x -> Metric' x


coerceMetric :: ∀ x ξ . (LocallyCoercible x ξ, LSpace (Needle ξ))
                             => RieMetric ξ -> RieMetric x
coerceMetric = case ( dualSpaceWitness :: DualNeedleWitness x
                    , dualSpaceWitness :: DualNeedleWitness ξ ) of
   (DualSpaceWitness, DualSpaceWitness)
       -> \m x -> case m $ locallyTrivialDiffeomorphism x of
              Norm sc -> Norm $ bw . sc . fw
 where fw = coerceNeedle ([]::[(x,ξ)])
       bw = case oppositeLocalCoercion :: CanonicalDiffeomorphism ξ x of
              CanonicalDiffeomorphism -> coerceNeedle' ([]::[(ξ,x)])
coerceMetric' :: ∀ x ξ . (LocallyCoercible x ξ, LSpace (Needle ξ))
                             => RieMetric' ξ -> RieMetric' x
coerceMetric' = case ( dualSpaceWitness :: DualNeedleWitness x
                     , dualSpaceWitness :: DualNeedleWitness ξ ) of
   (DualSpaceWitness, DualSpaceWitness)
       -> \m x -> case m $ locallyTrivialDiffeomorphism x of
              Norm sc -> Norm $ bw . sc . fw
 where fw = coerceNeedle' ([]::[(x,ξ)])
       bw = case oppositeLocalCoercion :: CanonicalDiffeomorphism ξ x of
              CanonicalDiffeomorphism -> coerceNeedle ([]::[(ξ,x)])


-- | Interpolate between points, approximately linearly. For
--   points that aren't close neighbours (i.e. lie in an almost
--   flat region), the pathway is basically undefined – save for
--   its end points.
-- 
--   A proper, really well-defined (on global scales) interpolation
--   only makes sense on a Riemannian manifold, as 'Data.Manifold.Riemannian.Geodesic'.
palerp :: ∀ x. Manifold x
    => Interior x -> Interior x -> Option (Scalar (Needle x) -> x)
palerp p1 p2 = case (fromInterior p2 :: x) .-~. p1 of
  Option (Just v) -> return $ \t -> p1 .+~^ t *^ v
  _ -> empty

-- | Like 'palerp', but actually restricted to the interval between the points,
--   with a signature like 'Data.Manifold.Riemannian.geodesicBetween'
--   rather than 'Data.AffineSpace.alerp'.
palerpB :: ∀ x. WithField ℝ Manifold x => Interior x -> Interior x -> Option (D¹ -> x)
palerpB p1 p2 = case (fromInterior p2 :: x) .-~. p1 of
  Option (Just v) -> return $ \(D¹ t) -> p1 .+~^ ((t+1)/2) *^ v
  _ -> empty

-- | Like 'alerp', but actually restricted to the interval between the points.
alerpB :: ∀ x. (AffineSpace x, VectorSpace (Diff x), Scalar (Diff x) ~ ℝ)
                   => x -> x -> D¹ -> x
alerpB p1 p2 = case p2 .-. p1 of
  v -> \(D¹ t) -> p1 .+^ ((t+1)/2) *^ v



hugeℝVal :: ℝ
hugeℝVal = 1e+100

#define deriveAffine(c,t)               \
instance (c) => Semimanifold (t) where { \
  type Needle (t) = Diff (t);             \
  fromInterior = id;                       \
  toInterior = pure;                        \
  translateP = Tagged (.+^);                 \
  (.+~^) = (.+^) };                           \
instance (c) => PseudoAffine (t) where {       \
  a.-~.b = pure (a.-.b);      }

deriveAffine((),Double)
deriveAffine((),Rational)
deriveAffine(Num s, V1 s)
deriveAffine(Num s, V2 s)
deriveAffine(Num s, V3 s)
deriveAffine(Num s, V4 s)
deriveAffine(KnownNat n, FreeVect n ℝ)

instance (NumberManifold s) => LocallyCoercible (ZeroDim s) (V0 s) where
  locallyTrivialDiffeomorphism Origin = V0
  coerceNeedle _ = LinearFunction $ \Origin -> V0
  coerceNeedle' _ = LinearFunction $ \Origin -> V0
instance (NumberManifold s) => LocallyCoercible (V0 s) (ZeroDim s) where
  locallyTrivialDiffeomorphism V0 = Origin
  coerceNeedle _ = LinearFunction $ \V0 -> Origin
  coerceNeedle' _ = LinearFunction $ \V0 -> Origin
instance LocallyCoercible ℝ (V1 ℝ) where
  locallyTrivialDiffeomorphism = V1
  coerceNeedle _ = LinearFunction V1
  coerceNeedle' _ = LinearFunction V1
instance LocallyCoercible (V1 ℝ) ℝ where
  locallyTrivialDiffeomorphism (V1 n) = n
  coerceNeedle _ = LinearFunction $ \(V1 n) -> n
  coerceNeedle' _ = LinearFunction $ \(V1 n) -> n
instance LocallyCoercible (ℝ,ℝ) (V2 ℝ) where
  locallyTrivialDiffeomorphism = uncurry V2
  coerceNeedle _ = LinearFunction $ uncurry V2
  coerceNeedle' _ = LinearFunction $ uncurry V2
instance LocallyCoercible (V2 ℝ) (ℝ,ℝ) where
  locallyTrivialDiffeomorphism (V2 x y) = (x,y)
  coerceNeedle _ = LinearFunction $ \(V2 x y) -> (x,y)
  coerceNeedle' _ = LinearFunction $ \(V2 x y) -> (x,y)
instance LocallyCoercible ((ℝ,ℝ),ℝ) (V3 ℝ) where
  locallyTrivialDiffeomorphism ((x,y),z) = V3 x y z
  coerceNeedle _ = LinearFunction $ \((x,y),z) -> V3 x y z
  coerceNeedle' _ = LinearFunction $ \((x,y),z) -> V3 x y z
instance LocallyCoercible (ℝ,(ℝ,ℝ)) (V3 ℝ) where
  locallyTrivialDiffeomorphism (x,(y,z)) = V3 x y z
  coerceNeedle _ = LinearFunction $ \(x,(y,z)) -> V3 x y z
  coerceNeedle' _ = LinearFunction $ \(x,(y,z)) -> V3 x y z
instance LocallyCoercible (V3 ℝ) ((ℝ,ℝ),ℝ) where
  locallyTrivialDiffeomorphism (V3 x y z) = ((x,y),z)
  coerceNeedle _ = LinearFunction $ \(V3 x y z) -> ((x,y),z)
  coerceNeedle' _ = LinearFunction $ \(V3 x y z) -> ((x,y),z)
instance LocallyCoercible (V3 ℝ) (ℝ,(ℝ,ℝ)) where
  locallyTrivialDiffeomorphism (V3 x y z) = (x,(y,z))
  coerceNeedle _ = LinearFunction $ \(V3 x y z) -> (x,(y,z))
  coerceNeedle' _ = LinearFunction $ \(V3 x y z) -> (x,(y,z))
instance LocallyCoercible ((ℝ,ℝ),(ℝ,ℝ)) (V4 ℝ) where
  locallyTrivialDiffeomorphism ((x,y),(z,w)) = V4 x y z w
  coerceNeedle _ = LinearFunction $ \((x,y),(z,w)) -> V4 x y z w
  coerceNeedle' _ = LinearFunction $ \((x,y),(z,w)) -> V4 x y z w
instance LocallyCoercible (V4 ℝ) ((ℝ,ℝ),(ℝ,ℝ)) where
  locallyTrivialDiffeomorphism (V4 x y z w) = ((x,y),(z,w))
  coerceNeedle _ = LinearFunction $ \(V4 x y z w) -> ((x,y),(z,w))
  coerceNeedle' _ = LinearFunction $ \(V4 x y z w) -> ((x,y),(z,w))

instance Semimanifold (ZeroDim k) where
  type Needle (ZeroDim k) = ZeroDim k
  fromInterior = id
  toInterior = pure
  Origin .+~^ Origin = Origin
  Origin .-~^ Origin = Origin
  translateP = Tagged (.+~^)
instance PseudoAffine (ZeroDim k) where
  Origin .-~. Origin = pure Origin
instance Num k => Semimanifold (V0 k) where
  type Needle (V0 k) = V0 k
  fromInterior = id
  toInterior = pure
  V0 .+~^ V0 = V0
  V0 .-~^ V0 = V0
  translateP = Tagged (.+~^)
instance Num k => PseudoAffine (V0 k) where
  V0 .-~. V0 = pure V0

instance ∀ a b . (Semimanifold a, Semimanifold b) => Semimanifold (a,b) where
  type Needle (a,b) = (Needle a, Needle b)
  type Interior (a,b) = (Interior a, Interior b)
  (a,b).+~^(v,w) = (a.+~^v, b.+~^w)
  (a,b).-~^(v,w) = (a.-~^v, b.-~^w)
  fromInterior (i,j) = (fromInterior i, fromInterior j)
  toInterior (a,b) = fzip (toInterior a, toInterior b)
  translateP = Tagged $ \(a,b) (v,w) -> (ta a v, tb b w)
   where Tagged ta = translateP :: Tagged a (Interior a -> Needle a -> Interior a)
         Tagged tb = translateP :: Tagged b (Interior b -> Needle b -> Interior b)
  semimanifoldWitness = case ( semimanifoldWitness :: SemimanifoldWitness a
                             , semimanifoldWitness :: SemimanifoldWitness b ) of
             (SemimanifoldWitness, SemimanifoldWitness) -> SemimanifoldWitness
instance (PseudoAffine a, PseudoAffine b) => PseudoAffine (a,b) where
  (a,b).-~.(c,d) = liftA2 (,) (a.-~.c) (b.-~.d)
  pseudoAffineWitness = case ( pseudoAffineWitness :: PseudoAffineWitness a
                             , pseudoAffineWitness :: PseudoAffineWitness b ) of
             (PseudoAffineWitness, PseudoAffineWitness) -> PseudoAffineWitness
instance ( Semimanifold a, Semimanifold b, Semimanifold c
         , LSpace (Needle a), LSpace (Needle b), LSpace (Needle c)
         , Scalar (Needle a) ~ Scalar (Needle b), Scalar (Needle b) ~ Scalar (Needle c)
         , Scalar (Needle' a) ~ Scalar (Needle a), Scalar (Needle' b) ~ Scalar (Needle b)
         , Scalar (Needle' c) ~ Scalar (Needle c) )
     => LocallyCoercible (a,(b,c)) ((a,b),c) where
  locallyTrivialDiffeomorphism = regroup
  coerceNeedle _ = regroup
  coerceNeedle' _ = regroup
  oppositeLocalCoercion = CanonicalDiffeomorphism
  interiorLocalCoercion _ = case ( semimanifoldWitness :: SemimanifoldWitness a
                                 , semimanifoldWitness :: SemimanifoldWitness b
                                 , semimanifoldWitness :: SemimanifoldWitness c ) of
       (SemimanifoldWitness, SemimanifoldWitness, SemimanifoldWitness)
              -> CanonicalDiffeomorphism
instance ∀ a b c .
         ( Semimanifold a, Semimanifold b, Semimanifold c
         , LSpace (Needle a), LSpace (Needle b), LSpace (Needle c)
         , Scalar (Needle a) ~ Scalar (Needle b), Scalar (Needle b) ~ Scalar (Needle c)
         , Scalar (Needle' a) ~ Scalar (Needle a), Scalar (Needle' b) ~ Scalar (Needle b)
         , Scalar (Needle' c) ~ Scalar (Needle c)  )
     => LocallyCoercible ((a,b),c) (a,(b,c)) where
  locallyTrivialDiffeomorphism = regroup'
  coerceNeedle _ = regroup'
  coerceNeedle' _ = regroup'
  oppositeLocalCoercion = CanonicalDiffeomorphism
  interiorLocalCoercion _ = case ( semimanifoldWitness :: SemimanifoldWitness a
                                 , semimanifoldWitness :: SemimanifoldWitness b
                                 , semimanifoldWitness :: SemimanifoldWitness c ) of
       (SemimanifoldWitness, SemimanifoldWitness, SemimanifoldWitness)
            -> CanonicalDiffeomorphism

instance ∀ a b c . (Semimanifold a, Semimanifold b, Semimanifold c)
                          => Semimanifold (a,b,c) where
  type Needle (a,b,c) = (Needle a, Needle b, Needle c)
  type Interior (a,b,c) = (Interior a, Interior b, Interior c)
  (a,b,c).+~^(v,w,x) = (a.+~^v, b.+~^w, c.+~^x)
  (a,b,c).-~^(v,w,x) = (a.-~^v, b.-~^w, c.-~^x)
  fromInterior (i,j,k) = (fromInterior i, fromInterior j, fromInterior k)
  toInterior (a,b,c) = liftA3 (,,) (toInterior a) (toInterior b) (toInterior c)
  translateP = Tagged $ \(a,b,c) (v,w,x) -> (ta a v, tb b w, tc c x)
   where Tagged ta = translateP :: Tagged a (Interior a -> Needle a -> Interior a)
         Tagged tb = translateP :: Tagged b (Interior b -> Needle b -> Interior b)
         Tagged tc = translateP :: Tagged c (Interior c -> Needle c -> Interior c)
  semimanifoldWitness = case ( semimanifoldWitness :: SemimanifoldWitness a
                             , semimanifoldWitness :: SemimanifoldWitness b
                             , semimanifoldWitness :: SemimanifoldWitness c ) of
             (SemimanifoldWitness, SemimanifoldWitness, SemimanifoldWitness)
                   -> SemimanifoldWitness
instance (PseudoAffine a, PseudoAffine b, PseudoAffine c) => PseudoAffine (a,b,c) where
  (a,b,c).-~.(d,e,f) = liftA3 (,,) (a.-~.d) (b.-~.e) (c.-~.f)
  pseudoAffineWitness = case ( pseudoAffineWitness :: PseudoAffineWitness a
                             , pseudoAffineWitness :: PseudoAffineWitness b
                             , pseudoAffineWitness :: PseudoAffineWitness c ) of
             (PseudoAffineWitness, PseudoAffineWitness, PseudoAffineWitness)
                   -> PseudoAffineWitness


instance LinearManifold (a n) => Semimanifold (LinAff.Point a n) where
  type Needle (LinAff.Point a n) = a n
  fromInterior = id
  toInterior = pure
  LinAff.P v .+~^ w = LinAff.P $ v ^+^ w
  translateP = Tagged $ \(LinAff.P v) w -> LinAff.P $ v ^+^ w
instance LinearManifold (a n) => PseudoAffine (LinAff.Point a n) where
  LinAff.P v .-~. LinAff.P w = return $ v ^-^ w


instance (LSpace a, LSpace b, s~Scalar a, s~Scalar b)
              => Semimanifold (Tensor s a b) where
  type Needle (Tensor s a b) = Tensor s a b
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+~^)
  (.+~^) = (^+^)
instance (LSpace a, LSpace b, s~Scalar a, s~Scalar b)
              => PseudoAffine (Tensor s a b) where
  a.-~.b = pure (a^-^b)

instance (LSpace a, LSpace b, Scalar a~s, Scalar b~s)
                          => Semimanifold (LinearMap s a b) where
  type Needle (LinearMap s a b) = LinearMap s a b
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+^)
  (.+~^) = (^+^)
instance (LSpace a, LSpace b, Scalar a~s, Scalar b~s)
                          => PseudoAffine (LinearMap s a b) where
  a.-~.b = pure (a^-^b)

instance Semimanifold S⁰ where
  type Needle S⁰ = ZeroDim ℝ
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+~^)
  p .+~^ Origin = p
  p .-~^ Origin = p
instance PseudoAffine S⁰ where
  PositiveHalfSphere .-~. PositiveHalfSphere = pure Origin
  NegativeHalfSphere .-~. NegativeHalfSphere = pure Origin
  _ .-~. _ = Option Nothing

instance Semimanifold S¹ where
  type Needle S¹ = ℝ
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+~^)
  S¹ φ₀ .+~^ δφ
     | φ' < 0     = S¹ $ φ' + tau
     | otherwise  = S¹ $ φ'
   where φ' = toS¹range $ φ₀ + δφ
instance PseudoAffine S¹ where
  S¹ φ₁ .-~. S¹ φ₀
     | δφ > pi     = pure (δφ - 2*pi)
     | δφ < (-pi)  = pure (δφ + 2*pi)
     | otherwise   = pure δφ
   where δφ = φ₁ - φ₀

instance Semimanifold D¹ where
  type Needle D¹ = ℝ
  type Interior D¹ = ℝ
  fromInterior = D¹ . tanh
  toInterior (D¹ x) | abs x < 1  = return $ atanh x
                    | otherwise  = empty
  translateP = Tagged (+)
instance PseudoAffine D¹ where
  D¹ 1 .-~. _ = empty
  D¹ (-1) .-~. _ = empty
  D¹ x .-~. y
    | abs x < 1  = return $ atanh x - y
    | otherwise  = empty

instance Semimanifold S² where
  type Needle S² = ℝ²
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+~^)
  S² ϑ₀ φ₀ .+~^ δv
     | ϑ₀ < pi/2  = sphereFold PositiveHalfSphere $ ϑ₀*^embed(S¹ φ₀) ^+^ δv
     | otherwise  = sphereFold NegativeHalfSphere $ (pi-ϑ₀)*^embed(S¹ φ₀) ^+^ δv
instance PseudoAffine S² where
  S² ϑ₁ φ₁ .-~. S² ϑ₀ φ₀
     | ϑ₀ < pi/2  = pure ( ϑ₁*^embed(S¹ φ₁) ^-^ ϑ₀*^embed(S¹ φ₀) )
     | otherwise  = pure ( (pi-ϑ₁)*^embed(S¹ φ₁) ^-^ (pi-ϑ₀)*^embed(S¹ φ₀) )

sphereFold :: S⁰ -> ℝ² -> S²
sphereFold hfSphere v
   | ϑ₀ > pi     = S² (inv $ tau - ϑ₀) (toS¹range $ φ₀+pi)
   | otherwise  = S² (inv ϑ₀) φ₀
 where S¹ φ₀ = coEmbed v
       ϑ₀ = magnitude v `mod'` tau
       inv ϑ = case hfSphere of PositiveHalfSphere -> ϑ
                                NegativeHalfSphere -> pi - ϑ


instance Semimanifold ℝP² where
  type Needle ℝP² = ℝ²
  fromInterior = id
  toInterior = pure
  translateP = Tagged (.+~^)
  ℝP² r₀ φ₀ .+~^ V2 δr δφ
   | r₀ > 1/2   = case r₀ + δr of
                   r₁ | r₁ > 1     -> ℝP² (2-r₁) (toS¹range $ φ₀+δφ+pi)
                      | otherwise  -> ℝP²    r₁  (toS¹range $ φ₀+δφ)
  ℝP² r₀ φ₀ .+~^ δxy = let v = r₀*^embed(S¹ φ₀) ^+^ δxy
                           S¹ φ₁ = coEmbed v
                           r₁ = magnitude v `mod'` 1
                       in ℝP² r₁ φ₁  
instance PseudoAffine ℝP² where
  ℝP² r₁ φ₁ .-~. ℝP² r₀ φ₀
   | r₀ > 1/2   = pure `id` case φ₁-φ₀ of
                          δφ | δφ > 3*pi/2  -> V2 (  r₁ - r₀) (δφ - 2*pi)
                             | δφ < -3*pi/2 -> V2 (  r₁ - r₀) (δφ + 2*pi)
                             | δφ > pi/2    -> V2 (2-r₁ - r₀) (δφ - pi  )
                             | δφ < -pi/2   -> V2 (2-r₁ - r₀) (δφ + pi  )
                             | otherwise    -> V2 (  r₁ - r₀) (δφ       )
   | otherwise  = pure ( r₁*^embed(S¹ φ₁) ^-^ r₀*^embed(S¹ φ₀) )


-- instance (PseudoAffine m, VectorSpace (Needle m), Scalar (Needle m) ~ ℝ)
--              => Semimanifold (CD¹ m) where
--   type Needle (CD¹ m) = (Needle m, ℝ)
--   CD¹ h₀ m₀ .+~^ (h₁δm, δh)
--       = let h₁ = min 1 . max 1e-300 $ h₀+δh; δm = h₁δm^/h₁
--         in CD¹ h₁ (m₀.+~^δm)
-- instance (PseudoAffine m, VectorSpace (Needle m), Scalar (Needle m) ~ ℝ)
--              => PseudoAffine (CD¹ m) where
--   CD¹ h₁ m₁ .-~. CD¹ h₀ m₀
--      = fmap ( \δm -> (h₁*^δm, h₁-h₀) ) $ m₁.-~.m₀
                               


tau :: ℝ
tau = 2 * pi

toS¹range :: ℝ -> ℝ
toS¹range φ = (φ+pi)`mod'`tau - pi




class ImpliesMetric s where
  type MetricRequirement s x :: Constraint
  type MetricRequirement s x = Semimanifold x
  inferMetric :: (MetricRequirement s x, LSpace (Needle x))
                     => s x -> Metric x
  inferMetric' :: (MetricRequirement s x, LSpace (Needle x))
                     => s x -> Metric' x

instance ImpliesMetric Norm where
  type MetricRequirement Norm x = (SimpleSpace x, x ~ Needle x)
  inferMetric = id
  inferMetric' = dualNorm



type DualNeedleWitness x = DualSpaceWitness (Needle x)

