-- |
-- Module      : Data.SimplicialComplex
-- Copyright   : (c) Justus Sagemüller 2015
-- License     : GPL v3
-- 
-- Maintainer  : (@) sagemueller $ geo.uni-koeln.de
-- Stability   : experimental
-- Portability : portable
-- 
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
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE DataKinds                  #-}


module Data.SimplicialComplex (
        -- * Simplices
          Simplex(..)
        -- ** Construction
        , (.<.), makeSimplex, makeSimplex'
        -- ** Deconstruction
        , simplexVertices, simplexVertices'
        -- * Simplicial complexes
        , Triangulation
        -- * Triangulation-builder monad
        , TriangT
        , evalTriangT, runTriangT, doTriangT, getTriang
        -- ** Subsimplex-references
        , SimplexIT, simplexITList, lookSimplex
        , lookSplxFacesIT, lookSupersimplicesIT, tgetSimplexIT
        , lookVertexIT, lookSplxVerticesIT
        , sharedBoundary
        , distinctSimplices, NeighbouringSimplices
        -- ** Building triangulations
        , disjointTriangulation
        , mixinTriangulation
        -- * Misc util
        , HaskMonad, liftInTriangT, unliftInTriangT
        , Nat, Zero, One, Two, Three, Succ
        ) where



import Data.List hiding (filter, all, elem)
import Data.Maybe
import qualified Data.Vector as Arr
import Data.List.FastNub
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
import Data.Ord (comparing)

import Math.LinearMap.Category
import Data.Tagged

import Data.Manifold.Types.Primitive ((^), empty)
import Data.Manifold.PseudoAffine
    
import Data.Embedding
import Data.CoNat

import qualified Prelude as Hask hiding(foldl)
import qualified Control.Applicative as Hask
import qualified Control.Monad       as Hask
import Control.Monad.Trans.List
import Control.Monad.Trans.Class
import qualified Data.Foldable       as Hask
import Data.Foldable (all, elem)

import Data.Functor.Identity (Identity, runIdentity)

import Control.Category.Constrained.Prelude hiding ((^), all, elem)
import Control.Arrow.Constrained
import Control.Monad.Constrained
import Data.Foldable.Constrained


infixr 5 :<|, .<.

-- | An /n/-simplex is a connection of /n/+1 points in a simply connected region of a manifold.
data Simplex :: Nat -> * -> * where
   ZS :: !x -> Simplex Z x
   (:<|) :: KnownNat n => !x -> !(Simplex n x) -> Simplex (S n) x

deriving instance (Show x) => Show (Simplex n x)
instance Hask.Functor (Simplex n) where
  fmap f (ZS x) = ZS (f x)
  fmap f (x:<|xs) = f x :<| fmap f xs

-- | Use this together with ':<|' to easily build simplices, like you might construct lists.
--   E.g. @(0,0) ':<|' (1,0) '.<.' (0,1) :: 'Simplex' 'Two' ℝ²@.
(.<.) :: x -> x -> Simplex One x
x .<. y = x :<| ZS y


makeSimplex :: ∀ x n . KnownNat n => x ^ S n -> Simplex n x
makeSimplex xs = case makeSimplex' $ Hask.toList xs of
     Option (Just s) -> s

makeSimplex' :: ∀ x n . KnownNat n => [x] -> Option (Simplex n x)
makeSimplex' [] = Option Nothing
makeSimplex' [x] = cozeroT $ ZS x
makeSimplex' (x:xs) = fCosuccT ((x:<|) <$> makeSimplex' xs)

simplexVertices :: ∀ x n . Simplex n x -> x ^ S n
simplexVertices (ZS x) = pure x
simplexVertices (x :<| s) = freeCons x (simplexVertices s)

simplexVertices' :: ∀ x n . Simplex n x -> [x]
simplexVertices' (ZS x) = [x]
simplexVertices' (x :<| s) = x : simplexVertices' s


type Array = Arr.Vector

-- | An /n/-dimensional /abstract simplicial complex/ is a collection of /n/-simplices
--   which are &#x201c;glued together&#x201d; in some way. The preferred way to construct
--   such complexes is to run a 'TriangT' builder.
data Triangulation (n :: Nat) (x :: *) where
        TriangSkeleton :: KnownNat n
                 => Triangulation n x  -- The lower-dimensional skeleton.
                 -> Array              -- Array of `S n`-simplices in this triangulation.
                       ( Int ^ S (S n)   -- “down link” – the subsimplices
                       , [Int]           -- “up link” – what higher simplices have
                       )                 --       this one as a subsimplex?
                 -> Triangulation (S n) x
        TriangVertices :: Array (x, [Int]) -> Triangulation Z x
instance Hask.Functor (Triangulation n) where
  fmap f (TriangVertices vs) = TriangVertices $ first f <$> vs
  fmap f (TriangSkeleton sk vs) = TriangSkeleton (f<$>sk) vs
deriving instance (Show x) => Show (Triangulation n x)

nTopSplxs :: Triangulation n' x -> Int
nTopSplxs (TriangVertices vs) = Arr.length vs
nTopSplxs (TriangSkeleton _ vs) = Arr.length vs

nSplxs :: ∀ k n x . (KnownNat k, KnownNat n) => Triangulation n x -> Tagged k Int
nSplxs t = case t of
      TriangVertices vs   | n == k  -> Tagged $ Arr.length vs
      TriangSkeleton _ vs | n == k  -> Tagged $ Arr.length vs
      TriangSkeleton sk _ | n > k   -> nSplxs sk
      _                             -> Tagged 0
 where (Tagged k) = theNatN :: Tagged k Int
       (Tagged n) = theNatN :: Tagged n Int

-- | Combine two triangulations (assumed as disjoint) to a single, non-connected complex.
instance (KnownNat n) => Semigroup (Triangulation n x) where
  TriangVertices vs₁ <> TriangVertices vs₂ = TriangVertices $ vs₁ Arr.++ vs₂
  TriangSkeleton sk₁ sp₁ <> TriangSkeleton sk₂ sp₂
            = TriangSkeleton (sk₁ <> shiftUprefs (Arr.length sp₁) sk₂)
                             (sp₁ Arr.++ fmap (first $ fmap (+ nTopSplxs sk₁)) sp₂)
   where shiftUprefs :: Int -> Triangulation n' x -> Triangulation n' x
         shiftUprefs δn (TriangVertices vs)
                       = TriangVertices $ fmap (second $ fmap (+δn)) vs
         shiftUprefs δn (TriangSkeleton sk' vs)
                       = TriangSkeleton sk' $ fmap (second $ fmap (+δn)) vs
instance (KnownNat n) => Monoid (Triangulation n x) where
  mappend = (<>)
  mempty = coInduceT (TriangVertices mempty) (`TriangSkeleton`mempty)




 
-- | A &#x201c;conservative&#x201d; state monad containing a 'Triangulation'. It
--   can be extended by new simplices, which can then be indexed using 'SimplexIT'.
--   The universally-quantified @t@ argument ensures you can't index simplices that
--   don't actually exist in this triangulation.
newtype TriangT t n x m y = TriangT {
            unsafeRunTriangT :: Triangulation n x -> m (y, Triangulation n x) }
   deriving (Hask.Functor)
instance (Hask.Functor m, Monad m (->))
             => Hask.Applicative (TriangT t n x m) where
  pure x = TriangT $ pure . (x,)
  TriangT fs <*> TriangT xs = TriangT $
      fs >=> \(f, t') -> fmap (first f) $ xs t'
instance (Hask.Functor m, Monad m (->)) => Hask.Monad (TriangT t n x m) where
  return x = TriangT $ pure . (x,)
  TriangT xs >>= f = TriangT $
      \t -> xs t >>= \(y,t') -> let (TriangT zs) = f y in zs t'

instance MonadTrans (TriangT t n x) where
  lift m = TriangT $ \tr -> Hask.liftM (,tr) m

type HaskMonad m = (Hask.Applicative m, Hask.Monad m)

triangReadT :: ∀ t n x m y . HaskMonad m => (Triangulation n x -> m y) -> TriangT t n x m y
triangReadT f = TriangT $ \t -> fmap (,t) $ f t

unsafeEvalTriangT :: ∀ n t x m y . HaskMonad m
                         => TriangT t n x m y -> Triangulation n x -> m y
unsafeEvalTriangT t = fmap fst . unsafeRunTriangT t

execTriangT :: ∀ n x m y . HaskMonad m => (∀ t . TriangT t n x m y)
                  -> Triangulation n x -> m (Triangulation n x)
execTriangT t = fmap snd . unsafeRunTriangT (t :: TriangT () n x m y)

evalTriangT :: ∀ n x m y . (KnownNat n, HaskMonad m) => (∀ t . TriangT t n x m y) -> m y
evalTriangT t = fmap fst (unsafeRunTriangT (t :: TriangT () n x m y) mempty)

runTriangT :: ∀ n x m y . (∀ t . TriangT t n x m y)
                  -> Triangulation n x -> m (y, Triangulation n x)
runTriangT t = unsafeRunTriangT (t :: TriangT () n x m y)

doTriangT :: ∀ n x m y . KnownNat n => (∀ t . TriangT t n x m y) -> m (y, Triangulation n x)
doTriangT t = runTriangT t mempty

getEntireTriang :: ∀ t n x m . HaskMonad m => TriangT t n x m (Triangulation n x)
getEntireTriang = TriangT $ \t -> pure (t, t)

getTriang :: ∀ t n k x m . (HaskMonad m, KnownNat k, KnownNat n)
                   => TriangT t n x m (Option (Triangulation k x))
getTriang = onSkeleton getEntireTriang

liftInTriangT :: ∀ t n x m μ y . (HaskMonad m, MonadTrans μ)
                   => TriangT t n x m y -> TriangT t n x (μ m) y
liftInTriangT (TriangT b) = TriangT $ lift . b

unliftInTriangT :: ∀ t n x m μ y . (HaskMonad m, MonadTrans μ)
                   => (∀ m' a . μ m a -> m a) -> TriangT t n x (μ m) y -> TriangT t n x m y
unliftInTriangT unlift (TriangT b) = TriangT $ \t -> unlift (b t)



forgetVolumes :: ∀ n x t m y . (KnownNat n, HaskMonad m)
                     => TriangT t n x m y -> TriangT t (S n) x m y
forgetVolumes (TriangT f) = TriangT $ \(TriangSkeleton l bk)
                             -> fmap (\(y, l') -> (y, TriangSkeleton l' bk)) $ f l

onSkeleton :: ∀ n k x t m y . (KnownNat k, KnownNat n, HaskMonad m)
                   => TriangT t k x m y -> TriangT t n x m (Option y)
onSkeleton q@(TriangT qf) = case tryToMatchTTT forgetVolumes q of
    Option (Just q') -> pure <$> q'
    _ -> return empty


newtype SimplexIT (t :: *) (n :: Nat) (x :: *) = SimplexIT { tgetSimplexIT' :: Int }
          deriving (Eq, Ord, Show)

-- | A unique (for the given dimension) ID of a triagulation's simplex. It is the index
--   where that simplex can be found in the 'simplexITList'.
tgetSimplexIT :: SimplexIT t n x -> Int
tgetSimplexIT = tgetSimplexIT'

-- | Reference the /k/-faces of a given simplex in a triangulation.
lookSplxFacesIT :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
               => SimplexIT t (S k) x -> TriangT t n x m (SimplexIT t k x ^ S(S k))
lookSplxFacesIT = fmap (\(Option(Just r))->r) . onSkeleton . lookSplxFacesIT'

lookSplxFacesIT' :: ∀ t m n x . (HaskMonad m, KnownNat n)
               => SimplexIT t (S n) x -> TriangT t (S n) x m (SimplexIT t n x ^ S(S n))
lookSplxFacesIT' (SimplexIT i) = triangReadT rc
 where rc (TriangSkeleton _ ssb) = return . fmap SimplexIT . fst $ ssb Arr.! i

lookSplxVerticesIT :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
               => SimplexIT t k x -> TriangT t n x m (SimplexIT t Z x ^ S k)
lookSplxVerticesIT = fmap (\(Option(Just r))->r) . onSkeleton . lookSplxVerticesIT'

lookSplxVerticesIT' :: ∀ t m n x . (HaskMonad m, KnownNat n)
               => SimplexIT t n x -> TriangT t n x m (SimplexIT t Z x ^ S n)
lookSplxVerticesIT' i = fmap 
       (\vs -> case freeVector vs of
          Option (Just vs') -> vs'
          _ -> error $ "Impossible number " ++ show (length vs) ++ " of vertices for "
                  ++ show n ++ "-simplex in `lookSplxVerticesIT'`."
       ) $ lookSplxsVerticesIT [i]
 where (Tagged n) = theNatN :: Tagged n Int
          

lookSplxsVerticesIT :: ∀ t m n x . HaskMonad m
               => [SimplexIT t n x] -> TriangT t n x m [SimplexIT t Z x]
lookSplxsVerticesIT is = triangReadT rc
 where rc (TriangVertices _) = return is
       rc (TriangSkeleton sk up) = unsafeEvalTriangT
              ( lookSplxsVerticesIT
                      $ SimplexIT <$> fastNub [ j | SimplexIT i <- is
                                                  , j <- Hask.toList . fst $ up Arr.! i ]
              ) sk

lookVertexIT :: ∀ t m n x . (HaskMonad m, KnownNat n)
                                => SimplexIT t Z x -> TriangT t n x m x
lookVertexIT = fmap (\(Option(Just r))->r) . onSkeleton . lookVertexIT'

lookVertexIT' :: ∀ t m x . HaskMonad m => SimplexIT t Z x -> TriangT t Z x m x
lookVertexIT' (SimplexIT i) = triangReadT $ \(TriangVertices vs) -> return.fst $ vs Arr.! i

lookSimplex :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
               => SimplexIT t k x -> TriangT t n x m (Simplex k x)
lookSimplex s = do 
       vis <- lookSplxVerticesIT s
       fmap makeSimplex $ mapM lookVertexIT vis

simplexITList :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
               => TriangT t n x m [SimplexIT t k x]
simplexITList = fmap (\(Option(Just r))->r) $ onSkeleton simplexITList'

simplexITList' :: ∀ t m n x . (HaskMonad m, KnownNat n)
               => TriangT t n x m [SimplexIT t n x]
simplexITList' = triangReadT $ return . sil
 where sil :: Triangulation n x -> [SimplexIT t n x]
       sil (TriangVertices vs) = [ SimplexIT i | i <- [0 .. Arr.length vs - 1] ]
       sil (TriangSkeleton _ bk) = [ SimplexIT i | i <- [0 .. Arr.length bk - 1] ]


lookSupersimplicesIT :: ∀ t m n k j x . (HaskMonad m, KnownNat k, KnownNat j, KnownNat n)
                  => SimplexIT t k x -> TriangT t n x m [SimplexIT t j x]
lookSupersimplicesIT = runListT . defLstt . matchLevel . pure
 where lvlIt :: ∀ i . (KnownNat i, KnownNat n) => ListT (TriangT t n x m) (SimplexIT t i x)
                                        -> ListT (TriangT t n x m) (SimplexIT t (S i) x)
       lvlIt (ListT m) = ListT . fmap (fnubConcatBy $ comparing tgetSimplexIT)
                                    $ mapM lookSupersimplicesIT' =<< m
       matchLevel = ftorTryToMatchT lvlIt
       defLstt (Option (Just lt)) = lt
       defLstt _ = ListT $ return []

lookSupersimplicesIT' :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
                  => SimplexIT t k x -> TriangT t n x m [SimplexIT t (S k) x]
lookSupersimplicesIT' = fmap (\(Option(Just r))->r) . onSkeleton . lookSupersimplicesIT''

lookSupersimplicesIT'' :: ∀ t m n x . (HaskMonad m, KnownNat n)
                  => SimplexIT t n x -> TriangT t (S n) x m [SimplexIT t (S n) x]
lookSupersimplicesIT'' (SimplexIT i) =
    fmap ( \tr -> SimplexIT <$> case tr of
                    TriangSkeleton (TriangSkeleton _ tsps) _ -> snd (tsps Arr.! i)
                    TriangSkeleton (TriangVertices tsps) _ -> snd (tsps Arr.! i)
         ) getEntireTriang

sharedBoundary :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
         => SimplexIT t (S k) x -> SimplexIT t (S k) x
           -> TriangT t n x m (Option (SimplexIT t k x))
sharedBoundary i j = fmap snd <$> distinctSimplices i j

type NeighbouringSimplices t n x = ((SimplexIT t Z x, SimplexIT t Z x), SimplexIT t n x)

distinctSimplices :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n)
         => SimplexIT t (S k) x -> SimplexIT t (S k) x
           -> TriangT t n x m (Option (NeighbouringSimplices t k x))
distinctSimplices i j = do
   [iSubs,jSubs] <- mapM lookSplxFacesIT [i,j]
   case fnubIntersect (Hask.toList iSubs) (Hask.toList jSubs) of
     [shBound] -> do
          shVerts <- lookSplxVerticesIT shBound
          [[iIVert], [jIVert]] <- forM [i,j]
              $ fmap (filter (not . (`elem` shVerts)) . Hask.toList) . lookSplxVerticesIT
          return $ pure ((iIVert, jIVert), shBound)
     _         -> return empty


triangulationBulk :: ∀ t m n k x . (HaskMonad m, KnownNat k, KnownNat n) => TriangT t n x m [Simplex k x]
triangulationBulk = simplexITList >>= mapM lookSimplex

withThisSubsimplex :: ∀ t m n k j x . (HaskMonad m, KnownNat j, KnownNat k, KnownNat n)
                   => SimplexIT t j x -> TriangT t n x m [SimplexIT t k x]
withThisSubsimplex s = do
      svs <- lookSplxVerticesIT s
      simplexITList >>= filterM (lookSplxVerticesIT >>> fmap`id`
                                      \s'vs -> all (`elem`s'vs) svs )

lookupSimplexCone :: ∀ t m n k x . ( HaskMonad m, KnownNat k, KnownNat n )
     => SimplexIT t Z x -> SimplexIT t k x -> TriangT t n x m (Option (SimplexIT t (S k) x))
lookupSimplexCone tip base = do
    tipSups  :: [SimplexIT t (S k) x] <- lookSupersimplicesIT tip
    baseSups :: [SimplexIT t (S k) x] <- lookSupersimplicesIT base
    return $ case intersect tipSups baseSups of
       (res:_) -> pure res
       _ -> empty
    


-- | Import an entire triangulation, as disjoint from everything already in the monad.
disjointTriangulation :: ∀ t m n x . (KnownNat n, HaskMonad m)
       => Triangulation n x -> TriangT t n x m [SimplexIT t n x]
disjointTriangulation t = TriangT $
                       \tr -> return ( [ SimplexIT k
                                       | k <- take (nTopSplxs t) [nTopSplxs tr ..] ]
                                     , tr <> t )


-- | Import a triangulation like with 'disjointTriangulation',
--   together with references to some of its subsimplices.
mixinTriangulation :: ∀ t m f k n x . ( KnownNat n, KnownNat k
                                      , HaskMonad m, Functor f (->) (->) )
       => (∀ s . TriangT s n x m (f (SimplexIT s k x)))
              -> TriangT t n x m (f (SimplexIT t k x))
mixinTriangulation t
      = TriangT $ \tr -> do
           (sqs, tr') <- doTriangT t'
           let (Tagged n) = nSplxs tr :: Tagged k Int
           return ( fmap (\k -> SimplexIT $ n + k) sqs, tr <> tr' )
 where t' :: ∀ s . TriangT s n x m (f Int)
       t' = fmap (fmap tgetSimplexIT) t


                                                    





-- | Type-level zero of kind 'Nat'.
type Zero = Z
type One = S Zero
type Two = S One
type Three = S Two
type Succ = S


