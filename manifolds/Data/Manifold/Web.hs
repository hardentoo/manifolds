-- |
-- Module      : Data.Manifold.Web
-- Copyright   : (c) Justus Sagemüller 2016
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
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE ParallelListComp           #-}
{-# LANGUAGE UnicodeSyntax              #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}


module Data.Manifold.Web (
              -- * The web data type
              PointsWeb
              -- ** Construction
            , fromWebNodes, fromShadeTree_auto, fromShadeTree, fromShaded
              -- ** Lookup
            , indexWeb, webEdges
              -- ** Local environments
            , localFocusWeb
              -- * Differential equations
            , filterDEqnSolution_static, iterateFilterDEqn_static
              -- * Misc
            , ConvexSet(..), ellipsoid
            ) where


import Data.List hiding (filter, all, elem, sum, foldr1)
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Vector as Arr
import qualified Data.Vector.Unboxed as UArr
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
import Control.DeepSeq

import Data.VectorSpace
import Data.LinearMap.HerMetric
import Data.Tagged

import Data.Manifold.Types
import Data.Manifold.Types.Primitive (empty)
import Data.Manifold.PseudoAffine
import Data.Manifold.TreeCover
import Data.SetLike.Intersection
    
import qualified Prelude as Hask hiding(foldl, sum, sequence)
import qualified Control.Applicative as Hask
import qualified Control.Monad       as Hask hiding(forM_, sequence)
import Control.Monad.Trans.State
import qualified Data.Foldable       as Hask
import Data.Foldable (all, toList)
import qualified Data.Traversable as Hask
import Data.Traversable (forM)

import Control.Category.Constrained.Prelude hiding
     ((^), all, elem, sum, forM, Foldable(..), foldr1, Traversable, traverse)
import Control.Arrow.Constrained
import Control.Monad.Constrained hiding (forM)
import Data.Foldable.Constrained
import Data.Traversable.Constrained (Traversable, traverse)

import GHC.Generics (Generic)


type WebNodeId = Int
type NeighbourRefs = UArr.Vector WebNodeId

data PointsWeb :: * -> * -> * where
   PointsWeb :: {
       webNodeRsc :: ShadeTree x
     , webNodeAssocData :: Arr.Vector (y, NeighbourRefs)
     } -> PointsWeb x y
  deriving (Generic, Hask.Functor, Hask.Foldable, Hask.Traversable)

instance (NFData x, NFData (Needle' x), NFData y) => NFData (PointsWeb x y)

instance Foldable (PointsWeb x) (->) (->) where
  ffoldl = uncurry . Hask.foldl' . curry
  foldMap = Hask.foldMap
instance Traversable (PointsWeb x) (PointsWeb x) (->) (->) where
  traverse f (PointsWeb rsc asd)
           = fmap (PointsWeb rsc . (`Arr.zip`ngss) . Arr.fromList)
              . traverse f $ Arr.toList ys
   where (ys,ngss) = Arr.unzip asd



fromWebNodes :: ∀ x y . WithField ℝ Manifold x
                    => (Shade x->Metric x) -> [(x,y)] -> PointsWeb x y
fromWebNodes mf = fromShaded mf . fromLeafPoints . map (uncurry WithAny . swap)

fromShadeTree_auto :: ∀ x . WithField ℝ Manifold x => ShadeTree x -> PointsWeb x ()
fromShadeTree_auto = fromShaded (recipMetric . _shadeExpanse) . constShaded ()

fromShadeTree :: ∀ x . WithField ℝ Manifold x
     => (Shade x -> Metric x) -> ShadeTree x -> PointsWeb x ()
fromShadeTree mf = fromShaded mf . constShaded ()

fromShaded :: ∀ x y . WithField ℝ Manifold x
     => (Shade x -> Metric x) -- ^ Local scalar-product generator. You can always
                              --   use @'recipMetric' . '_shadeExpanse'@ (but this
                              --   may give distortions compared to an actual
                              --   Riemannian metric).
     -> (x`Shaded`y)          -- ^ Source tree.
     -> PointsWeb x y
fromShaded metricf shd = PointsWeb shd' assocData 
 where shd' = stripShadedUntopological shd
       assocData = Hask.foldMap locMesh $ twigsWithEnvirons shd
       
       locMesh :: ((Int, ShadeTree (x`WithAny`y)), [(Int, ShadeTree (x`WithAny`y))])
                   -> Arr.Vector (y, NeighbourRefs)
       locMesh ((i₀, locT), neighRegions) = Arr.map findNeighbours locLeaves
        where locLeaves = Arr.map (first (+i₀)) . Arr.indexed . Arr.fromList
                                          $ onlyLeaves locT
              vicinityLeaves = Hask.foldMap
                                (\(i₀n, ngbR) -> Arr.map (first (+i₀n))
                                               . Arr.indexed
                                               . Arr.fromList
                                               $ onlyLeaves ngbR
                                ) neighRegions
              findNeighbours :: (Int, x`WithAny`y) -> (y, NeighbourRefs)
              findNeighbours (i, WithAny y x)
                         = (y, UArr.fromList $ fst<$>execState seek mempty)
               where seek = do
                        Hask.forM_ (locLeaves Arr.++ vicinityLeaves)
                                  $ \(iNgb, WithAny _ xNgb) ->
                           when (iNgb/=i) `id`do
                              let (Option (Just v)) = xNgb.-~.x
                              oldNgbs <- get
                              when (all (\(_,(_,nw)) -> visibleOverlap nw v) oldNgbs) `id`do
                                 let w = w₀ ^/ (w₀<.>^v)
                                      where w₀ = toDualWith locRieM v
                                 put $ (iNgb, (v,w))
                                       : [ neighbour
                                         | neighbour@(_,(nv,_))<-oldNgbs
                                         , visibleOverlap w nv
                                         ]
              
              visibleOverlap :: Needle' x -> Needle x -> Bool
              visibleOverlap w v = o < 1
               where o = w<.>^v
              
              locRieM :: Metric x
              locRieM = case pointsCovers . map _topological
                                  $ onlyLeaves locT
                                   ++ Hask.foldMap (onlyLeaves . snd) neighRegions of
                          [sh₀] -> metricf sh₀

indexWeb :: WithField ℝ Manifold x => PointsWeb x y -> WebNodeId -> Option (x,y)
indexWeb (PointsWeb rsc assocD) i
  | i>=0, i<Arr.length assocD
  , Right (_,x) <- indexShadeTree rsc i  = pure (x, fst (assocD Arr.! i))
  | otherwise                            = empty

webEdges :: ∀ x y . WithField ℝ Manifold x
            => PointsWeb x y -> [((x,y), (x,y))]
webEdges web@(PointsWeb rsc assoc) = (lookId***lookId) <$> toList allEdges
 where allEdges :: Set.Set (WebNodeId,WebNodeId)
       allEdges = Hask.foldMap (\(i,(_,ngbs))
                    -> Set.fromList [(min i i', max i i')
                                    | i'<-UArr.toList ngbs ]
                               ) $ Arr.indexed assoc
       lookId i | Option (Just xy) <- indexWeb web i  = xy


localFocusWeb :: WithField ℝ Manifold x => PointsWeb x y -> PointsWeb x ((x,y), [(x,y)])
localFocusWeb (PointsWeb rsc asd) = PointsWeb rsc asd''
 where asd' = Arr.imap (\i (y,n) -> case indexShadeTree rsc i of
                                         Right (_,x) -> ((x,y),n) ) asd
       asd''= Arr.map (\(xy,n) ->
                       ((xy, [fst (asd' Arr.! j) | j<-UArr.toList n]), n)
                 ) asd'


data ConvexSet x
    = EmptyConvex
    | ConvexSet {
      convexSetHull :: Shade' x
      -- ^ If @p@ is in all intersectors, it must also be in the hull.
    , convexSetIntersectors :: [Shade' x]
    }

ellipsoid :: Shade' x -> ConvexSet x
ellipsoid s = ConvexSet s [s]

intersectors :: ConvexSet x -> Option (NonEmpty (Shade' x))
intersectors (ConvexSet h []) = pure (h:|[])
intersectors (ConvexSet _ (i:sts)) = pure (i:|sts)
intersectors _ = empty

-- | Under intersection.
instance Refinable x => Semigroup (ConvexSet x) where
  a<>b = sconcat (a:|[b])
  sconcat csets
    | Option (Just allIntersectors) <- sconcat <$> Hask.traverse intersectors csets
    , IntersectT ists <- rmTautologyIntersect perfectRefine $ IntersectT allIntersectors
    , Option (Just hull') <- intersectShade's ists
                 = ConvexSet hull' (NE.toList ists)
    | otherwise  = EmptyConvex
   where perfectRefine sh₁ sh₂
           | sh₁`subShade'`sh₂   = pure sh₁
           | sh₂`subShade'`sh₁   = pure sh₂
           | otherwise           = empty

iterateFilterDEqn_static :: (WithField ℝ Manifold x, Refinable y)
       => DifferentialEqn x y -> PointsWeb x (Shade' y) -> [PointsWeb x (Shade' y)]
iterateFilterDEqn_static f = map (fmap convexSetHull)
                           . itWhileJust (filterDEqnSolutions_static f)
                           . fmap (`ConvexSet`[])

filterDEqnSolution_static :: (WithField ℝ Manifold x, Refinable y)
       => DifferentialEqn x y -> PointsWeb x (Shade' y) -> Option (PointsWeb x (Shade' y))
filterDEqnSolution_static f = localFocusWeb >>> Hask.traverse `id`
                   \((x,shy), ngbs) -> if null ngbs
                     then pure shy
                     else refineShade' shy
                            =<< filterDEqnSolution_loc f ((x,shy), NE.fromList ngbs)

filterDEqnSolutions_static :: (WithField ℝ Manifold x, Refinable y)
       => DifferentialEqn x y -> PointsWeb x (ConvexSet y) -> Option (PointsWeb x (ConvexSet y))
filterDEqnSolutions_static f = localFocusWeb >>> Hask.traverse `id`
            \((x, shy@(ConvexSet hull _)), ngbs) -> if null ngbs
              then pure shy
              else ((shy<>) . ellipsoid)
                      <$> filterDEqnSolution_loc f
                               ((x,hull), second convexSetHull<$>NE.fromList ngbs)
                     >>= \case EmptyConvex -> empty
                               c           -> pure c





itWhileJust :: (a -> Option a) -> a -> [a]
itWhileJust f x | Option (Just y) <- f x  = x : itWhileJust f y
itWhileJust _ x = [x]


