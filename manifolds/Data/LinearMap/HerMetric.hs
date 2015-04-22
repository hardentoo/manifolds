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




module Data.LinearMap.HerMetric (
  -- * Metric operator types
    HerMetric, HerMetric'
  -- * Evaluating metrics
  , metricSq, metricSq', metric, metric', metrics, metrics'
  -- * Defining metrics by projectors
  , projector, projector'
  -- * Utility for metrics
  , transformMetric, transformMetric'
  , dualiseMetric, dualiseMetric'
  , recipMetric, recipMetric'
  , eigenSpan, eigenSpan'
  , eigenCoSpan, eigenCoSpan'
  , metriScale', metriScale
  , adjoint
  -- * The dual-space class
  , HasMetric
  , HasMetric'(..)
  , (^<.>)
--   , riesz, riesz'
  -- * Fundamental requirements
  , MetricScalar
  , FiniteDimensional(..)
  ) where
    

    

import Data.VectorSpace
import Data.LinearMap
import Data.Basis
import Data.MemoTrie
import Data.Semigroup
import Data.Tagged
import Data.Void
import qualified Data.List as List

import qualified Prelude as Hask
import qualified Control.Applicative as Hask
import qualified Control.Monad as Hask

import Control.Category.Constrained.Prelude hiding ((^))
import Control.Arrow.Constrained
    
import Data.Manifold.Types.Primitive
import Data.CoNat

import qualified Data.Vector as Arr
import qualified Numeric.LinearAlgebra.HMatrix as HMat

import Data.VectorSpace.FiniteDimensional
import Data.LinearMap.Category
import Data.Embedding



infixr 7 <.>^, ^<.>


-- | 'HerMetric' is a portmanteau of /Hermitian/ and /metric/ (in the sense as
--   used in e.g. general relativity &#x2013; though those particular ones aren't positive
--   definite and thus not really metrics).
-- 
--   Mathematically, there are two directly equivalent ways to describe such a metric:
--   as a bilinear mapping of two vectors to a scalar, or as a linear mapping from
--   a vector space to its dual space. We choose the latter, though you can always
--   as well think of metrics as &#x201c;quadratic dual vectors&#x201d;.
--   
--   Yet other possible interpretations of this type include /density matrix/ (as in
--   quantum mechanics), /standard range of statistical fluctuations/, and /volume element/.
newtype HerMetric v = HerMetric {
   -- morally:  @getHerMetric :: v :-* DualSpace v@.
          metricMatrix :: Maybe (HMat.Matrix (Scalar v)) -- @Nothing@ for zero metric.
                      }

matrixMetric :: HasMetric v => HMat.Matrix (Scalar v) -> HerMetric v
matrixMetric = HerMetric . Just

instance (HasMetric v) => AdditiveGroup (HerMetric v) where
  zeroV = HerMetric Nothing
  negateV (HerMetric m) = HerMetric $ negate <$> m
  HerMetric Nothing ^+^ HerMetric n = HerMetric n
  HerMetric m ^+^ HerMetric Nothing = HerMetric m
  HerMetric (Just m) ^+^ HerMetric (Just n) = HerMetric . Just $ m + n
instance HasMetric v => VectorSpace (HerMetric v) where
  type Scalar (HerMetric v) = Scalar v
  s *^ (HerMetric m) = HerMetric $ HMat.scale s <$> m 

-- | A metric on the dual space; equivalent to a linear mapping from the dual space
--   to the original vector space.
-- 
--   Prime-versions of the functions in this module target those dual-space metrics, so
--   we can avoid some explicit handling of double-dual spaces.
newtype HerMetric' v = HerMetric' {
          metricMatrix' :: Maybe (HMat.Matrix (Scalar v))
                      }

matrixMetric' :: HasMetric v => HMat.Matrix (Scalar v) -> HerMetric' v
matrixMetric' = HerMetric' . Just

instance (HasMetric v) => AdditiveGroup (HerMetric' v) where
  zeroV = HerMetric' Nothing
  negateV (HerMetric' m) = HerMetric' $ negate <$> m
  HerMetric' Nothing ^+^ HerMetric' n = HerMetric' n
  HerMetric' m ^+^ HerMetric' Nothing = HerMetric' m
  HerMetric' (Just m) ^+^ HerMetric' (Just n) = matrixMetric' $ m + n
instance HasMetric v => VectorSpace (HerMetric' v) where
  type Scalar (HerMetric' v) = Scalar v
  s *^ (HerMetric' m) = HerMetric' $ HMat.scale s <$> m 
    

-- | A metric on @v@ that simply yields the squared overlap of a vector with the
--   given dual-space reference.
--   
--   It will perhaps be the most common way of defining 'HerMetric' values to start
--   with such dual-space vectors and superimpose the projectors using the 'VectorSpace'
--   instance; e.g. @'projector' (1,0) '^+^' 'projector' (0,2)@ yields a hermitian operator
--   describing the ellipsoid span of the vectors /e/&#x2080; and 2&#x22c5;/e/&#x2081;.
--   Metrics generated this way are positive definite if no negative coefficients have
--   been introduced with the '*^' scaling operator or with '^-^'.
projector :: HasMetric v => DualSpace v -> HerMetric v
projector u = matrixMetric $ HMat.outer uDecomp uDecomp
 where uDecomp = asPackedVector u

projector' :: HasMetric v => v -> HerMetric' v
projector' v = matrixMetric' $ HMat.outer vDecomp vDecomp
 where vDecomp = asPackedVector v


singularMetric :: forall v . HasMetric v => HerMetric v
singularMetric = matrixMetric $ HMat.scale (1/0) (HMat.ident dim)
 where (Tagged dim) = dimension :: Tagged v Int
singularMetric' :: forall v . HasMetric v => HerMetric' v
singularMetric' = matrixMetric' $ HMat.scale (1/0) (HMat.ident dim)
 where (Tagged dim) = dimension :: Tagged v Int



-- | Evaluate a vector through a metric. For the canonical metric on a Hilbert space,
--   this will be simply 'magnitudeSq'.
metricSq :: HasMetric v => HerMetric v -> v -> Scalar v
metricSq (HerMetric Nothing) _ = 0
metricSq (HerMetric (Just m)) v = vDecomp `HMat.dot` HMat.app m vDecomp
 where vDecomp = asPackedVector v


metricSq' :: HasMetric v => HerMetric' v -> DualSpace v -> Scalar v
metricSq' (HerMetric' Nothing) _ = 0
metricSq' (HerMetric' (Just m)) u = uDecomp `HMat.dot` HMat.app m uDecomp
 where uDecomp = asPackedVector u

-- | Evaluate a vector's &#x201c;magnitude&#x201d; through a metric. This assumes an actual
--   mathematical metric, i.e. positive definite &#x2013; otherwise the internally used
--   square root may get negative arguments (though it can still produce results if the
--   scalars are complex; however, complex spaces aren't supported yet).
metric :: (HasMetric v, Floating (Scalar v)) => HerMetric v -> v -> Scalar v
metric m = sqrt . metricSq m

metric' :: (HasMetric v, Floating (Scalar v)) => HerMetric' v -> DualSpace v -> Scalar v
metric' m = sqrt . metricSq' m


toDualWith :: HasMetric v => HerMetric v -> v -> DualSpace v
toDualWith (HerMetric Nothing) = const zeroV
toDualWith (HerMetric (Just m)) = fromPackedVector . HMat.app m . asPackedVector

-- | &#x201c;Anti-normalise&#x201d; a vector: /multiply/ with its own norm, according to metric.
metriScale :: (HasMetric v, Floating (Scalar v)) => HerMetric v -> v -> v
metriScale m v = metric m v *^ v

metriScale' :: (HasMetric v, Floating (Scalar v))
                 => HerMetric' v -> DualSpace v -> DualSpace v
metriScale' m v = metric' m v *^ v


-- | Square-sum over the metrics for each dual-space vector.
-- 
-- @
-- metrics m vs &#x2261; sqrt . sum $ metricSq m '<$>' vs
-- @
metrics :: (HasMetric v, Floating (Scalar v)) => HerMetric v -> [v] -> Scalar v
metrics m vs = sqrt . sum $ metricSq m <$> vs

metrics' :: (HasMetric v, Floating (Scalar v)) => HerMetric' v -> [DualSpace v] -> Scalar v
metrics' m vs = sqrt . sum $ metricSq' m <$> vs


transformMetric :: (HasMetric v, HasMetric w, Scalar v ~ Scalar w)
           => (w :-* v) -> HerMetric v -> HerMetric w
transformMetric _ (HerMetric Nothing) = HerMetric Nothing
transformMetric t (HerMetric (Just m)) = matrixMetric $ HMat.tr tmat HMat.<> m HMat.<> tmat
 where tmat = asPackedMatrix t

transformMetric' :: ( HasMetric v, HasMetric w, Scalar v ~ Scalar w )
           => (v :-* w) -> HerMetric' v -> HerMetric' w
transformMetric' _ (HerMetric' Nothing) = HerMetric' Nothing
transformMetric' t (HerMetric' (Just m))
                      = matrixMetric' $ HMat.tr tmat HMat.<> m HMat.<> tmat
 where tmat = asPackedMatrix t

-- | This doesn't really do anything at all, since @'HerMetric' v@ is essentially a
--   synonym for @'HerMetric' ('DualSpace' v)@.
dualiseMetric :: HasMetric v => HerMetric (DualSpace v) -> HerMetric' v
dualiseMetric (HerMetric m) = HerMetric' m

dualiseMetric' :: HasMetric v => HerMetric' v -> HerMetric (DualSpace v)
dualiseMetric' (HerMetric' m) = HerMetric m


-- | The inverse mapping of a metric tensor. Since a metric maps from
--   a space to its dual, the inverse maps from the dual into the
--   (double-dual) space &#x2013; i.e., it is a metric on the dual space.
recipMetric' :: HasMetric v => HerMetric v -> HerMetric' v
recipMetric' (HerMetric Nothing) = singularMetric'
recipMetric' (HerMetric (Just m))
          | isInfinite' detm  = singularMetric'
          | otherwise         = matrixMetric' minv
 where (minv, (detm, _)) = HMat.invlndet m

recipMetric :: HasMetric v => HerMetric' v -> HerMetric v
recipMetric (HerMetric' Nothing) = singularMetric
recipMetric (HerMetric' (Just m))
          | isInfinite' detm  = singularMetric
          | otherwise         = matrixMetric minv
 where (minv, (detm, _)) = HMat.invlndet m


isInfinite' :: (Eq a, Num a) => a -> Bool
isInfinite' x = x==x*2



-- | The eigenbasis of a /positive definite/ metric, with each eigenvector scaled
--   to the square root of the eigenvalue.
--   
--   This constitutes, in a sense,
--   a decomposition of a metric into a set of 'projector'' vectors. If those
--   are 'sumV'ed again, the original metric is obtained. (This holds even for
--   non-Hilbert/Banach spaces, even though the concept of eigenbasis and
--   &#x201c;scaled length&#x201d; doesn't really makes sense then in the usual way!)
eigenSpan :: (HasMetric v, Scalar v ~ ℝ) => HerMetric' v -> [v]
eigenSpan (HerMetric' Nothing) = []
eigenSpan (HerMetric' (Just m)) = map fromPackedVector eigSpan
 where (μs,vsm) = HMat.eigSH m -- TODO: replace with `eigSH'`, which is unchecked
                               -- (`HerMetric` is always Hermitian!)
       eigSpan = zipWith (HMat.scale . sqrt) (HMat.toList μs) (HMat.toColumns vsm)

eigenSpan' :: (HasMetric v, Scalar v ~ ℝ) => HerMetric v -> [DualSpace v]
eigenSpan' (HerMetric Nothing) = []
eigenSpan' (HerMetric (Just m)) = map fromPackedVector eigSpan
 where (μs,vsm) = HMat.eigSH m -- TODO: replace with `eigSH'`, which is unchecked
                               -- (`HerMetric` is always Hermitian!)
       eigSpan = zipWith (HMat.scale . sqrt) (HMat.toList μs) (HMat.toColumns vsm)

eigenCoSpan :: (HasMetric v, Scalar v ~ ℝ) => HerMetric' v -> [DualSpace v]
eigenCoSpan (HerMetric' Nothing) = []
eigenCoSpan (HerMetric' (Just m)) = map fromPackedVector eigSpan
 where (μs,vsm) = HMat.eigSH m -- TODO: replace with `eigSH'`, which is unchecked
                               -- (`HerMetric` is always Hermitian!)
       eigSpan = zipWith (HMat.scale . recip . sqrt) (HMat.toList μs) (HMat.toColumns vsm)
eigenCoSpan' :: (HasMetric v, Scalar v ~ ℝ) => HerMetric v -> [v]
eigenCoSpan' (HerMetric Nothing) = []
eigenCoSpan' (HerMetric (Just m)) = map fromPackedVector eigSpan
 where (μs,vsm) = HMat.eigSH m -- TODO: replace with `eigSH'`, which is unchecked
                               -- (`HerMetric` is always Hermitian!)
       eigSpan = zipWith (HMat.scale . recip . sqrt) (HMat.toList μs) (HMat.toColumns vsm)


-- | Constraint that a space's scalars need to fulfill so it can be used for 'HerMetric'.
type MetricScalar s = ( SmoothScalar s
                      , Ord s  -- We really rather wouldn't require this...
                      )


type HasMetric v = (HasMetric' v, HasMetric' (DualSpace v), DualSpace (DualSpace v) ~ v)


-- | While the main purpose of this class is to express 'HerMetric', it's actually
--   all about dual spaces.
class ( FiniteDimensional v, FiniteDimensional (DualSpace v)
      , VectorSpace (DualSpace v), HasBasis (DualSpace v)
      , MetricScalar (Scalar v), Scalar v ~ Scalar (DualSpace v)
      , Basis v ~ Basis (DualSpace v) )
    => HasMetric' v where
        
  -- | @'DualSpace' v@ is isomorphic to the space of linear functionals on @v@, i.e.
  --   @v ':-*' 'Scalar' v@.
  --   Typically (for all Hilbert- / 'InnerSpace's) this is in turn isomorphic to @v@
  --   itself, which will be rather more efficient (hence the distinction between a
  --   vector space and its dual is often neglected or reduced to &#x201c;column vs row
  --   vectors&#x201d;).
  --   Mathematically though, it makes sense to keep the concepts apart, even if ultimately
  --   @'DualSpace' v ~ v@ (which needs not /always/ be the case, though!).
  type DualSpace v :: *
  type DualSpace v = v
      
  -- | Apply a dual space vector (aka linear functional) to a vector.
  (<.>^) :: DualSpace v -> v -> Scalar v
            
  -- | Interpret a functional as a dual-space vector. Like 'linear', this /assumes/
  --   (completely unchecked) that the supplied function is linear.
  functional :: (v -> Scalar v) -> DualSpace v
  
  -- | While isomorphism between a space and its dual isn't generally canonical,
  --   the /double-dual/ space should be canonically isomorphic in pretty much
  --   all relevant cases. Indeed, it is recommended that they are the very same type;
  --   this condition is enforced by the 'HerMetric' constraint (which is recommended
  --   over using 'HerMetric'' itself in signatures).
  doubleDual :: HasMetric' (DualSpace v) => v -> DualSpace (DualSpace v)
  doubleDual' :: HasMetric' (DualSpace v) => DualSpace (DualSpace v) -> v
  
  

-- | Simple flipped version of '<.>^'.
(^<.>) :: HasMetric v => v -> DualSpace v -> Scalar v
ket ^<.> bra = bra <.>^ ket


-- -- | Associate a Hilbert space vector canonically with its dual-space counterpart,
-- --   as by the Riesz representation theorem.
-- --   
-- --   Note that usually, Hilbert spaces should just implement @DualSpace v ~ v@,
-- --   according to that same correspondence, so 'riesz' is essentially just a more explicit
-- --   (and less efficient) way of writing @'id' :: v -> DualSpace v'.
-- riesz :: (HasMetric v, InnerSpace v) => v -> DualSpace v
-- riesz v = functional (v<.>)
-- 
-- riesz' :: (HasMetric v, InnerSpace v) => DualSpace v -> v
-- riesz' f = doubleDual' . functional (f<.>^)


instance (MetricScalar k) => HasMetric' (ZeroDim k) where
  Origin<.>^Origin = zeroV
  functional _ = Origin
  doubleDual = id; doubleDual'= id
instance HasMetric' Double where
  (<.>^) = (<.>)
  functional f = f 1
  doubleDual = id; doubleDual'= id
instance ( HasMetric v, HasMetric w, Scalar v ~ Scalar w
         ) => HasMetric' (v,w) where
  type DualSpace (v,w) = (DualSpace v, DualSpace w)
  (v,w)<.>^(v',w') = v<.>^v' + w<.>^w'
  functional f = (functional $ f . (,zeroV), functional $ f . (zeroV,))
  doubleDual = id; doubleDual'= id





-- | Transpose a linear operator. Contrary to popular belief, this does not
--   just inverse the direction of mapping between the spaces, but also switch to
--   their duals.
adjoint :: (HasMetric v, HasMetric w, Scalar w ~ Scalar v)
     => (v :-* w) -> DualSpace w :-* DualSpace v
adjoint m = linear $ \w -> functional $ \v
                     -> w <.>^lapply m v



metrConst :: forall v. (HasMetric v, v ~ DualSpace v, Num (Scalar v))
                 => Scalar v -> HerMetric v
metrConst μ = matrixMetric $ HMat.scale μ (HMat.ident dim)
 where (Tagged dim) = dimension :: Tagged v Int

instance (HasMetric v, v ~ DualSpace v, Num (Scalar v)) => Num (HerMetric v) where
  fromInteger = metrConst . fromInteger
  (+) = (^+^)
  negate = negateV
           
  -- | This does /not/ work correctly if the metrics don't share an eigenbasis!
  HerMetric m * HerMetric n = HerMetric $ liftA2 (HMat.<>) m n
                              
  -- | Undefined, though it could actually be done.
  abs = error "abs undefined for HerMetric"
  signum = error "signum undefined for HerMetric"


metrNumFun :: (HasMetric v, v ~ Scalar v, v ~ DualSpace v, Num v)
      => (v -> v) -> HerMetric v -> HerMetric v
metrNumFun f (HerMetric Nothing) = matrixMetric . HMat.scalar $ f 0
metrNumFun f (HerMetric (Just m)) = matrixMetric . HMat.scalar . f $ m HMat.! 0 HMat.! 0

instance (HasMetric v, v ~ Scalar v, v ~ DualSpace v, Fractional v) 
            => Fractional (HerMetric v) where
  fromRational = metrConst . fromRational
  recip = metrNumFun recip

instance (HasMetric v, v ~ Scalar v, v ~ DualSpace v, Floating v)
            => Floating (HerMetric v) where
  pi = metrConst pi
  sqrt = metrNumFun sqrt
  exp = metrNumFun exp
  log = metrNumFun log
  sin = metrNumFun sin
  cos = metrNumFun cos
  tan = metrNumFun tan
  asin = metrNumFun asin
  acos = metrNumFun acos
  atan = metrNumFun atan
  sinh = metrNumFun sinh
  cosh = metrNumFun cosh
  asinh = metrNumFun asinh
  atanh = metrNumFun atanh
  acosh = metrNumFun acosh




normaliseWith :: HasMetric v => HerMetric v -> v -> Option v
normaliseWith m v = case metric m v of
                      0 -> Hask.empty
                      μ -> pure (v ^/ μ)

orthonormalPairsWith :: forall v . HasMetric v => HerMetric v -> [v] -> [(v, DualSpace v)]
orthonormalPairsWith met = mkON
 where mkON :: [v] -> [(v, DualSpace v)]    -- | Generalised Gram-Schmidt process
       mkON [] = []
       mkON (v:vs) = let onvs = mkON vs
                         v' = List.foldl' (\va (vb,pb) -> va ^-^ vb ^* (pb <.>^ va)) v onvs
                         p' = toDualWith met v'
                     in case sqrt (p' <.>^ v') of
                         0 -> onvs
                         μ -> (v'^/μ, p'^/μ) : onvs
                     


spanHilbertSubspace :: forall s n v . (KnownNat n, HasMetric v, Scalar v ~ s)
      => HerMetric v   -- ^ Metric to induce the inner product on the Hilbert space
          -> [v]       -- ^ @n@ linearly independent vectors, spanning the desired space
          -> Option (Embedding (Linear s) (FreeVect n v) v)
                       -- ^ An embedding from the main space to its @n@-dimensional subspace
                       --   (if the given vectors actually span such a space).
spanHilbertSubspace met = emb . orthonormalPairsWith met
 where emb onb'
         | n'==n      = return $ Embedding emb prj
         | otherwise  = Hask.empty
        where emb = DenseLinear . HMat.fromColumns $ (asPackedVector . fst) <$> onb
              prj = DenseLinear . HMat.fromRows    $ (asPackedVector . snd) <$> onb
              n' = length onb'
              onb = take n onb'
              (Tagged n) = theNatN :: Tagged n Int



