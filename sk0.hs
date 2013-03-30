{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE ConstraintKinds          #-}
-- {-# LANGUAGE StandaloneDeriving       #-}
{-# LANGUAGE ScopedTypeVariables      #-}

import Data.List
import qualified Data.Map as Map
import Data.Maybe
import Data.Function

import qualified Data.Vector as V
import Data.Vector(fromList, toList, (!), singleton)
import qualified Data.Vector.Algorithms.Insertion as VAIns

import Data.VectorSpace
import Data.Basis

import Control.Arrow
import Control.Monad
import Control.Monad.Trans.Maybe




type EuclidSpace v = (HasBasis v, EqFloating(Scalar v), Eq v)
type EqFloating f = (Eq f, Ord f, Floating f)


-- | A chart is a homeomorphism from a connected, open subset /Q/ ⊂ /M/ of
-- an /n/-manifold /M/ to either the open unit disk /Dⁿ/ ⊂ /V/ ≃ ℝ/ⁿ/, or
-- the half-disk /Hⁿ/ = {/x/ ∊ /Dⁿ/: x₀≥0}. In e.g. the former case, 'chartInMap'
-- is thus defined ∀ /v/ ∊ /V/ : |/v/| < 1, while 'chartOutMap p' will yield @Just x@
-- with /x/ ∊ /Dⁿ/ provided /p/ is in /Q/, and @Nothing@ otherwise.
-- Obviously, @fromJust . 'chartOutMap' . 'chartInMap'@ should be equivalent to @id@
-- on /Dⁿ/, and @'chartInMap' . fromJust . 'chartOutMap'@ to @id@ on /Q/.
data Chart :: * -> * where
  Chart :: (Manifold m, v ~ TangentSpace m) =>
        { chartInMap :: v -> m
        , chartOutMap :: m -> Maybe v
        , chartKind :: ChartKind      } -> Chart m
data ChartKind = LandlockedChart  -- ^ A /M/ ⇆ /Dⁿ/ chart, for ordinary manifolds
               | RimChart         -- ^ A /M/ ⇆ /Hⁿ/ chart, for manifolds with a rim

isInUpperHemi :: EuclidSpace v => v -> Bool
isInUpperHemi v = (snd . head) (decompose v) >= 0

rimGuard :: EuclidSpace v => ChartKind -> v -> Maybe v
rimGuard LandlockedChart v = Just v
rimGuard RimChart v
 | isInUpperHemi v = Just v
 | otherwise       = Nothing

chartEnv :: Manifold m => Chart m
               -> (TangentSpace m->TangentSpace m)
               -> m -> Maybe m
chartEnv (Chart inMap outMap chKind) f 
   = fmap inMap . (>>=rimGuard chKind) . fmap f . outMap

chartEnv' :: (Manifold m, Monad f) => Chart m
               -> (TangentSpace m->f(TangentSpace m))
               -> m -> MaybeT f m
chartEnv' (Chart inMap outMap chKind) f x
  = MaybeT $ case outMap x of
              Just w -> liftM (fmap inMap . rimGuard chKind) $ f w
              Nothing -> return Nothing
   

 

type Atlas m = [Chart m]

class (EuclidSpace(TangentSpace m)) => Manifold m where
  type TangentSpace m :: *
  
  triangulation :: m -> Triangulation m
--   triangulation = autoTriangulation
  
  localAtlas :: m -> Atlas m




data S2 = S2 { ϑParamS2 :: Double -- [0, π[
             , φParamS2 :: Double -- [0, 2π[
             }


instance Manifold S2 where
  type TangentSpace S2 = (Double, Double)
  localAtlas (S2 ϑ φ)
   | ϑ<pi-2     = [ Chart (\(x,y)
                             -> S2(2 * sqrt(x^2+y^2)) (atan2 y x) )
                          (\(S2 ϑ' φ')
                             -> let r=ϑ'/2
                                in guard (r<1) >> Just (r * cos φ', r * sin φ') )
                          LandlockedChart ]
   | ϑ>2        = [ Chart (\(x,y)
                             -> S2(pi - 2*sqrt(x^2+y^2)) (atan2 y x) )
                          (\(S2 ϑ' φ')
                             -> let r=(pi-ϑ')/2
                                in guard (r<1) >> Just (r * cos φ', r * sin φ') )
                          LandlockedChart ]
   | otherwise  = localAtlas(S2 0 φ) ++ localAtlas(S2 (2*pi) φ)




type FastNub a = (Eq a, Ord a) -- S̶h̶o̶u̶l̶d̶ ̶r̶e̶a̶l̶l̶y̶ ̶b̶e̶ ̶(̶E̶q̶ ̶a̶,̶̶ ̶H̶a̶s̶h̶a̶b̶l̶e̶ ̶a̶)̶
fastNub :: FastNub a => [a] -> [a]
fastNub = map head . group . sort

-- | Simply a merge sort that discards equivalent elements.
fastNubBy :: (a->a->Ordering) -> [a] -> [a]
fastNubBy _ [] = []
fastNubBy _ [e] = [e]
fastNubBy cmp es = merge(fastNubBy cmp lhs)(fastNubBy cmp rhs)
 where (lhs,rhs) = splitAt (length es `quot` 2) es
       merge [] rs = rs
       merge ls [] = ls
       merge (l:ls) (r:rs) = case cmp l r of
                              LT -> l : merge ls (r:rs)
                              GT -> r : merge (l:ls) rs
                              EQ -> merge (l:ls) rs

-- | Like 'fastNubBy', but doesn't just discard duplicates but \"merges\" them.
-- @'fastNubBy' cmp = cmp `'fastNubByWith'` 'const'@.
fastNubByWith :: (a->a->Ordering) -> (a->a->a) -> [a] -> [a]
fastNubByWith _ _ [] = []
fastNubByWith _ _ [e] = [e]
fastNubByWith cmp cmb es = merge(fastNubByWith cmp cmb lhs)(fastNubByWith cmp cmb rhs)
 where (lhs,rhs) = splitAt (length es `quot` 2) es
       merge [] rs = rs
       merge ls [] = ls
       merge (l:ls) (r:rs) = case cmp l r of
                              LT -> l : merge ls (r:rs)
                              GT -> r : merge (l:ls) rs
                              EQ -> merge (cmb l r : ls) rs




data Simplex p
   = Simplex0 { getSimplex0 :: p }
   | SimplexN { simplexNLDBounds :: Array(Simplex p)
              , simplexNInnards :: SimplexInnards p  } 
   | PermutedSimplex { simplexPermutation :: SimplexPermutation 
                     , thePermutedSimplex :: Simplex p          }
                     

data SimplexInnards p
 = SimplexBarycenter p
 | SimplexInnards
    { simplexBarySubdivs :: Array(SubSimplex p)
    , simplexBarySubdividers :: Array(SubSimplex p) }
    
-- | The name \"subsimplex\" is used somewhat ambiguously in this module:
-- 'SubSimplex' is the type for /parts of a simplex' subdivision/; on the
-- other hand many of the functions refer to @subsimplex@ in the more
-- conventional sense, i.e. one of the sides, vertices, or the entirety
-- of a simplex.
data SubSimplex p = SubSimplex
    { subSimplexInnards :: SimplexInnards p
    , subSimplexBoundaries :: Array(SimplexSideShare) }
    
data SimplexSideShare = SimplexSideShare
    { sideShareTarget :: SubSimplexSideShare
    , sharePermutation :: SimplexPermutation }
    
data SubSimplexSideShare = ShareSubdivider Int
                         | ShareSubdivision Int
                         | ShareInFace Int SubSimplexSideShare
                         deriving (Eq, Ord)

data SimplexPermutation
  = SimplexIdPermutation
  | SimplexPermutation { subSimplexRemapping :: Array(Int, SimplexPermutation) }
  deriving(Eq, Show)
 
newtype SubSplxIndex = SubSplxIndex{ getSubSplxIndex::[Int] }
   deriving (Eq, Ord)

simplexBarycenter :: Simplex p -> p
simplexBarycenter (Simplex0 p) = p
simplexBarycenter (SimplexN _ (SimplexBarycenter p)) = p
 
findSharedSide :: Simplex p -> SimplexSideShare -> Simplex p
findSharedSide s@(Simplex0 _) _ = s
findSharedSide s@(SimplexN _ (SimplexInnards _ subdividers))
               (SimplexSideShare (ShareSubdivider n) π)
         = π `permuteSimplex` SimplexN ( fmap (findSharedSide s) sdBnds ) sdInn 
   where (SubSimplex sdInn sdBnds) = subdividers ! n
findSharedSide s@(SimplexN _ (SimplexInnards subdivisions _))
               (SimplexSideShare (ShareSubdivision n) π)
         = π `permuteSimplex` SimplexN ( fmap (findSharedSide s) sdBnds ) sdInn 
   where (SubSimplex sdInn sdBnds) = subdivisions ! n
findSharedSide (SimplexN faces _)
               (SimplexSideShare (ShareInFace n sshare) perm)
         = findSharedSide (faces!n) (SimplexSideShare sshare perm)

permuteSimplex :: SimplexPermutation -> Simplex p -> Simplex p
SimplexIdPermutation `permuteSimplex` s = s
π `permuteSimplex` PermutedSimplex σ s = (π ↺↺ σ) `permuteSimplex` s



instance Permutation SimplexPermutation where
  invPerm (SimplexIdPermutation) = SimplexIdPermutation
  invPerm (SimplexPermutation rm)
           = SimplexPermutation . fromList
             . map(\(n, (_,π)) -> (n, invPerm π) )
             . sortBy (compare `on` fst.snd) . zip[0..] $ toList rm
  π ↺↺ SimplexIdPermutation = π
  SimplexIdPermutation ↺↺ π = π
  SimplexPermutation rm ↺↺ SimplexPermutation rm'
     = SimplexPermutation $ V.map (\(n, π) -> second (π↺↺) $ rm' ! n ) rm



instance (Show p) => Show (Simplex p) where
  show (Simplex0 p) = "Simplex0(" ++ show p ++ ")"
  show (SimplexN sss _) = "SimplexN " ++ show sss ++ " undefined"

simplexVertices :: Eq p => Simplex p -> [p]
simplexVertices (Simplex0 p) = [p]
simplexVertices (SimplexN vs _) = nub $ simplexVertices =<< toList vs


fSimplexVertices :: Simplex p -> [p]
fSimplexVertices (Simplex0 p) = [p]
fSimplexVertices s = map (getSimplex0 . (`locateSubSimplex`s) . fst)
                      . distinctDim0SubsplxGroups $ simplexDimension s


simplexDimension :: Simplex p -> Int
simplexDimension (Simplex0 _) = 0
simplexDimension (SimplexN faces _) = simplexDimension (V.head faces) + 1
simplexDimension (PermutedSimplex _ s) = simplexDimension s

simplexBarySubdivNSimplices :: Simplex p -> Int
simplexBarySubdivNSimplices (Simplex0 _) = 1
simplexBarySubdivNSimplices (SimplexN _ (SimplexInnards sds _)) = V.length sds
simplexBarySubdivNSimplices (PermutedSimplex _ s) = simplexBarySubdivNSimplices s

{-
simplexInnards :: Simplex p -> [[SimplexInnards p]]
simplexInnards (Simplex0 _) = []
simplexInnards (SimplexN lds inrs) = [inrs] : map concat(transpose $ map simplexInnards lds)

emptySimplexCone :: p -> Simplex p -> Simplex p
emptySimplexCone p q@(Simplex0 _) = SimplexN [Simplex0 p, q] undefined
emptySimplexCone p s@(SimplexN qs _) = SimplexN (s : map (emptySimplexCone p) qs) undefined
manualfillSimplexCone :: p -> [[SimplexInnards p]] -> Simplex p -> Simplex p
manualfillSimplexCone [inrs]         p q@(Simplex0 _)       = SimplexN [Simplex0 p,q] inrs
manualfillSimplexCone ([inrs]:sinrs) p s@(SimplexN qs binr)
      = SimplexN (s : zipWith manualfillSimplexCone qs contins) inrs
  where contins = transpose $ map (divide $ length qs) sinrs
-}

--               deriving(Eq)

-- | Note that the 'Functor' instances of 'Simplex' and 'Triangulation'
-- are only vaguely related to the actual category-theoretic /simplicial functor/.
instance Functor Simplex where
  fmap f(Simplex0 p) = Simplex0(f p)
  fmap f(SimplexN lds innards) = SimplexN (fmap(fmap f) lds) (fmap f innards)
  fmap f(PermutedSimplex π s) = PermutedSimplex π $ fmap f s

instance Functor SimplexInnards where
  fmap f(SimplexBarycenter p) = SimplexBarycenter $ f p
  fmap f(SimplexInnards divs dvders)
       = SimplexInnards (fmap (fmap f) divs) (fmap (fmap f) dvders)
instance Functor SubSimplex where
  fmap f(SubSimplex irs fr) = SubSimplex (fmap f irs) fr


newtype Triangulation p
  = Triangulation
    { simplicialComplex      :: Array (Simplex p)
--     , barycentricSubdivision :: Triangulation p 
    }       --  -> Triangulation p
  deriving (Show)


triangulationVertices :: Eq p => Triangulation p -> [p]
triangulationVertices (Triangulation sComplex) = nub $ simplexVertices =<< toList sComplex

simplexBarycentricSubdivision :: Simplex p -> Triangulation p
simplexBarycentricSubdivision s@(SimplexN _ (SimplexInnards subdiv dividers))
         = Triangulation $ fmap finalise subdiv
    where finalise(SubSimplex inrs bounds)
             = SimplexN (fmap (findSharedSide s) bounds) inrs
 {-  where finalise(SubSimplex inrs bounds)
             = SimplexN (map (lookupBound faceSubdivs) bounds) inrs
         lookupBound lds (ShareSubdivider q) = SimplexN bbounds divInr
          where divInr = dividers !! q
                bbounds | (SimplexBarycenter _)<-divInr  = []
                        | otherwise                      = finalise divInr
         lookupBound lds (ShareInFace f b) = simplicialComplex(faceSubdivs!!f) !! q
          where reconstrFace = SimplexN (
         
         faceSubdivs = map simplexBarycentricSubdivision lds
         
             Triangulation sideSubdiv <- map simplexBarycentricSubdivision lds
             subside <- sideSubdiv
             return $ emptySimplexCone baryc subside
             case subside of
              p@(Simplex0 _)           -> return $ SimplexN [baryc, p]
              s@(SimplexN lds innards) -> return . SimplexN $ s :           -}
simplexBarycentricSubdivision (PermutedSimplex _ s) = simplexBarycentricSubdivision s
simplexBarycentricSubdivision s0 = Triangulation $ singleton s0
    
-- deriving instance Eq (Triangulation p)

instance Functor Triangulation where
  fmap f(Triangulation c) = Triangulation(fmap(fmap f)c)


data IndexedVert p = IndexedVert {indexedVertex::p, vertexIndex::Int}
instance Eq (IndexedVert p) where {(==) = (==)`on`vertexIndex}
instance Ord (IndexedVert p) where {compare = compare`on`vertexIndex}

-- The sketch below is not good. A better one might be the following,
-- procedural-style:
-- while (∃ wrong-rim):
--    pick a rim subsimplex to build a cone c on top of, such that
--    the number of other rim-simplices which can also build a cone to
--    the tip of c is maximised.
-- 
-- autoTriangulation :: forall m . Manifold m => m -> Triangulation m
-- autoTriangulation m = undefined -- Triangulation
--  where 
--        basisChart :: Chart m
--        basisChart = head $ localAtlas m
--        
--        chartCovers :: Chart m -> m -> Bool
--        chartCovers (Chart _ outMap _) p = isJust $ outMap p
--        
--        expandablyRim :: Chart m -> [m] -> [m]
--        expandablyRim (Chart inMap outMap chKind) = 
--        
--        basisSimplexVerts :: [m]
--        basisSimplexVerts = liftM fromJust . runMaybeT $ chartEnv' basisChart spreadStBall m
--        
--        spreadStBall :: EuclidSpace v => v -> [v]
--        spreadStBall v = map recompose $
--                    zeroP : map dimSingP decomp'
--         where zeroP = map (\(b, _) -> (b,0)) decomp
--               dimSingP(n,_) = map z decomp'
--                where z(n',(b,q))
--                       | n'/=n          = (b,0)
--                       | q'<-signum q
--                       , q'/=0          = (b, q'*0.9)
--                       | otherwise      = (b, 0.9)
--               decomp = decompose v
--               decomp' = zip [0..] decomp
              

ballAround :: EuclidSpace v
    =>  Scalar v        -- ^ Size of the ball to be created
     -> v               -- ^ Center of the ball (this also defines what space we're in, and thereby the dimension of the ball)
     -> Triangulation v -- ^ A barycentrically-subdividable simplicial complex triangulating the ball in question
r `ballAround`p = fmap ((^+^p) . l₁tol₂) $ Triangulation orthoplex
 where orthoplex
        | [] <- vDecomp  = singleton $ Simplex0 p
        | otherwise      = orthSides
         
       vDecomp = decompose p
       vBasis = map fst vDecomp
       n = length $ vDecomp
       
       orthSides = V.map (affineSimplex . (p:)) $ fromList orthVertices
       
       orthVertices = (map.map) ( recompose . zip vBasis )
                            $ map directSide orthDirections
       directSide [] = []
       directSide (c:cs) = (c:map(const 0)cs) : map(0:)(directSide cs)
       orthDirections = map (take n) . take (2^n)     -- e.g. [ [-r,-r], [-r, r], [ r,-r], [ r, r] ]
                      . fix.fix $ \q ~(l:ls) -> (-r:l) : (r:l) : q ls
       
       l₁tol₂ = coordMap inflate
        where inflate vl = map scale vl
               where l₁ = sum $ map abs vl
                     l₂ = sqrt . sum $ map (^2) vl
                     scale | l₂>0       = (* (l₁ / l₂))
                           | otherwise = id



affineSimplex :: forall v . EuclidSpace v => [v] -> Simplex v
-- affineSimplex _ = undefined
-- affineSimplex [v] = Simplex0 v
affineSimplex vertices = undefined
 where 
--        uniqueSubs :: [Simplex v]
       subLookup :: Map SubSplxIndex (Simplex v)
--        (uniqueSubs, 
       subLookup = prepareSubs vertices
       
       prepareSubs vs = {- ( map fst unqSubGroups
                        ,-} foldr mpIns Map.empty unqSubGroups -- )
         where 
               unqSubGroups :: [ (Simplex v, [(SubSplxIndex, SimplexPermutation)]) ]
               unqSubGroups
                  = map ( first $ \(SubSplxIndex path) 
                      -> constructSubAt path vs (SubSplxIndex . (path++) )
                     ) subgroups
                     
               constructSubAt :: [Int] -> [v] -> ([Int]->SubSplxIndex) -> Simplex v
               constructSubAt (dir:path) vs' pb
                  = constructSubAt path (deleteAt dir vs') pb
               constructSubAt [] vs' pb 
                  = constructor vs' ((subLookup Map.!) . pb)
                  
               mpIns (ref, slaves) prev 
                  = foldr (\(idx,π) -> Map.insert idx (permuteSimplex π ref)
                     ) prev slaves
                              
               subgroups :: [(SubSplxIndex, [(SubSplxIndex,SimplexPermutation)])]
               subgroups = distinctSubsplxGroups dimension 
               
               dimension :: Int
               dimension = length vs
       
       
       constructor :: [v] -> ([Int]->Simplex v) -> Simplex v
       constructor [v] _ = Simplex0 v
       constructor vs subF = cstrResult
         where
               cstrResult :: Simplex v
               cstrResult = SimplexN (fromList [ subF[n] | n<-[0 .. dimension-1] ])
                                     innards
               
               subdivs :: Array (SubSimplex v)
               subdivs = do
                    ([sdId], base) <- fromList $ filter(null . tail . fst) uniqueSSPs
                    let fiLookup = (id &&& findSharedSide cstrResult . ShareSubdivider)
                                          . fst . (subDvdsSel Map.!) . ShareInFace sdId
                        bsdLookup sd = ShareInFace sdId sd
                    buildSDCones base fiLookup bsdLookup
                                         
               subDvdsSel :: Map
                               SubSimplexSideShare -- The face-subdivision that the desired simplex is a cone over.
                               (Int, SubSimplex v) -- Index of that cone in the resultant subdivisers-array, and actual subsimplex implementation.
               subDvdsSel = Map.fromList undefined
               
--                backrenderSDS :: SimplexSideShare -> Simplex v
               nSubdivsPerSide = simplexBarySubdivNSimplices . fromJust 
                                       $ V.find(null . tail . fst) uniqueSSPs
               
               facesSel, ldSubSel :: Map [Int] ([Int], Simplex v)
               (facesSel, ldSubSel) =
                           Map.partition(null . tail . fst)
                           . Map.fromList
                           . rendMerge uniqueSSPs
                           . sortBy(compare `on` fst.snd)
                           . Map.toList
                           . Map.filter(not . null . getSubSplxIndex . fst)
                           $ distinctSubsplxSelect dimension
                where rendMerge rs@((rSp, rendered) : rnas)
                                qs@((qSp, (SubSplxIndex tSp, π)) : tnas)
                        | tSp==rSp   = (qSp, (tSp, permuteSimplex π rendered))
                                       : rendMerge rs tnas
                        | otherwise  = rendMerge rnas qs
                      rendMerge _ _ = []
               
               uniqueSSPs :: [([Int], Simplex v)]
               uniqueSSPs = map((id &&& subF) . getSubSplxIndex . fst)
                              $ distinctProperSubsplxGroups dimension
               
               buildSDCones :: Simplex v
                            -- ^ The cones' base simplex /b/, i.e. the simplex the subdivisions of which form the cones' bases.
                            -> (SubSimplexSideShare->(Int, Simplex v))
                            -- ^ Index of the subdivider that is the cone over this shared-side (relative to /b/), as well as this simplex in constructed form.
                            -> (SubSimplexSideShare->SimplexSideShare)
                            -- ^ Sideshare-index of a subdivision of /b/, as a side of the simplex containing the built cones.
                                 -> Array (SubSimplex v)
                                 -- ^ Cones of the barycenter over /b/'s subdivisions.
               buildSDCones b@(Simplex0 p) _ sfShare 
                      = singleton $ SubSimplex cnInrs cnvBounds
                where (SimplexN _ cnInrs) = constructor cnBounds vsFun
                      cnBounds = [barycenter, p]
                      vsFun = Simplex0 . (cnBounds!!) . head
                      cnvBounds = fromList [ barycenterShare, sfShare $ ShareSubdivision 0 ]
               buildSDCones b@(SimplexN sSides (SimplexInnards sDivs sDivd))
                            swLookup sfShare
                               = V.map build $ V.indexed sDivs
                where build (sdIdx, SubSimplex cbInrs cbBounds) = SubSimplex cnInrs cnvBounds
                       where (SimplexN _ cnInrs) = constructor coneVs vsFun
                             coneVs = barycenter : fSimplexVertices cnBase
                             cnBounds = cnBase `V.cons` V.map snd cnMantle
                             cnMantle = V.map (\(SimplexSideShare bfs π) 
                                                  -> let(i, z) = swLookup bfs
                                                     in ((i,π), up1pS π`permuteSimplex`z) )
                                              cbBounds
                             up1pS SimplexIdPermutation = SimplexIdPermutation
                             up1pS π@(SimplexPermutation pa)
                               = SimplexPermutation 
                                   $ (0,π) `V.cons` V.map (\(i,σ)->(i+1, up1pS σ)) pa
                             cnvBounds = sfShare(ShareSubdivision sdIdx) 
                                          `V.cons`
                                          V.map (uncurry(SimplexSideShare . ShareSubdivider)
                                                     . fst)       cnMantle
                             cnBase = SimplexN (fmap (findSharedSide b) cbBounds) cbInrs
                             vsFun (dsideId:drestId) = locateSubSimplex(SubSplxIndex drestId)
                                                            $ cnBounds ! dsideId
--                       sSubdivs = simplicialComplex $ simplexBarycentricSubdivision b
--                       cnvBounds = fromList [ barycenterShare, sfShare prePath ]
               
               barycenterShare :: SimplexSideShare
               barycenterShare = SimplexSideShare (ShareSubdivider $ undefined)
                                                  SimplexIdPermutation
               
               barycenter :: v
               barycenter = midBetween vs
               
               dimension :: Int
               dimension = length vs
               
               innards :: SimplexInnards v
               innards = undefined
              
{-       
 where sides  = map affineSimplex $ gapPositions vs
       result = SimplexN sides $ innardsBetween sides
       
       innardsBetween [s0@(Simplex0 p0), s1@(Simplex0 p1)]
           = SimplexInnards [ SubSimplex (innardsBetween [s0, barycenter])
                                         [ ShareInFace 0 $ ShareSubdivision 0
                                         , ShareSubdivider 0 ]
                            , SubSimplex (innardsBetween [barycenter, s1])
                                         [ ShareSubdivider 0
                                         , ShareInFace 1 $ ShareSubdivision 0 ] ]
                            [ SubSimplex (SimplexBarycenter barycenter) ]
        where barycenter = midBetween [p0,p1]
       innardsBetween sidess = SimplexInnards subdivs dividers
        where 
              subdivs = 
              
              rCones = Map.fromList [ 
              
              buildCone (fId, (sId, SubSimplex fsInrs fsBounds))
                         = SubSimplex coneInnards coneBounds
               where coneInnards = innardsBetween rSides
                     rSides = srcFace`findSharedSide`sId
                                : map ( ... )
                     srcFace = sidess !! fId
                                                  
              nSides = length sidess
              
              [sideSubs,sideSubDivs] =
                  [ concat . zip [0..]
                        $ map (zip [0..] . sspAccess . simplexNInnards) sidess
                  | sspAccess <- [ simplexBarySubdivs, simplexBarySubdividers ] ]
              barycenter
                    = midBetween $ map simplexBarycenter sidess
              subinnards = do
                  SimplexN sSides (SimplexInnards sBaryc sBarysubs) <- sidess
                  SimplexInnards sBsubBary _ <- sBarysubs
                  return
                  sSides : map()
                  
       distinctSubfaces s@[SimplexN [s0,s1] _] = [s:[s0,s1]]
       distinctSubfaces sidess = thisLevel : (thisLevel >>= distinctSubfaces)
        where thisLevel = [ f | SimplexN(f:_)<-sidess ]
       subdivided = Triangulation . map snd . snd $ subdivide result
       
       subdivide (Simplex0 v)    = (v, [([v],Simplex0 v)])
       subdivide (SimplexN vs _) = orq $ map subdivide vs
        where
              orq ps = ( b, map((\vs -> (vs, affineSimplex vs)) . (b:) )
                             . orientate . concat $ map (map fst . snd) ps )
               where b = midBetween $ map fst ps
 -}              
       midBetween :: [v] -> v
       midBetween vs = sumV vs ^/ (fromIntegral $ length vs)
       
--        orientate = zipWith($) $ cycle [reverse, id]

thisWholeSimplex = SubSplxIndex[]

type SubSplxPathfinder = SubSplxIndex -> SubSplxIndex

splxPathAriths :: (Int->Int->Int) -> SubSplxPathfinder->SubSplxPathfinder->SubSplxPathfinder
splxPathAriths ifx f1 f2 p
   = SubSplxIndex $ zipWith ifx (getSubSplxIndex $ f1 p) (getSubSplxIndex $ f2 p)

instance Num SubSplxPathfinder where
  fromInteger n (SubSplxIndex p) = SubSplxIndex(fromInteger n : p)
  (+) = splxPathAriths(+)
  (-) = splxPathAriths(+)
  (*) = splxPathAriths(+)
  abs = id
  signum = const $ const thisWholeSimplex
instance Enum SubSplxPathfinder where
  toEnum = fromIntegral
  fromEnum p = head . getSubSplxIndex $ p thisWholeSimplex

pathToSubSmplx :: SubSplxPathfinder->SubSplxIndex
pathToSubSmplx = ($ thisWholeSimplex) 
instance Show SubSplxIndex where
  show(SubSplxIndex p)
   | chainShow@(_:_) <- intercalate"."(map show p) = "pathToSubSmplx("++chainShow++")"
   | otherwise = "thisWholeSimplex"

locateSubSimplex :: SubSplxIndex -> Simplex p -> Simplex p
locateSubSimplex (SubSplxIndex (dir:path)) (SimplexN faces _)
     = locateSubSimplex (SubSplxIndex path) $ faces ! dir
locateSubSimplex idx (PermutedSimplex SimplexIdPermutation s)
     = locateSubSimplex idx s
locateSubSimplex idx (PermutedSimplex π (PermutedSimplex σ s))
     = locateSubSimplex idx $ PermutedSimplex (π↺↺σ) s
locateSubSimplex (SubSplxIndex (dir:path))
                 (PermutedSimplex (SimplexPermutation rm) (SimplexN faces _))
   = let (tgt, π) = rm ! dir
     in  locateSubSimplex (SubSplxIndex path) $ permuteSimplex π (faces ! tgt)
locateSubSimplex _ s = s

type SimplexPermutation' = Array Int

instance Permutation SimplexPermutation' where
  (↺↺) = V.backpermute
  invPerm = fst . undoableSort



asSimplexPermutation :: SimplexPermutation' -> SimplexPermutation
asSimplexPermutation vPerm
  | V.and $ V.imap(==) vPerm  = SimplexIdPermutation
  | otherwise                 = SimplexPermutation $
                      mapElAndRest( \k qerm
                         -> (k, asSimplexPermutation $ V.map (m k) qerm)
                       ) vPerm
     where m k q
            | q<k   = q - k + n - 1
            | q>k   = q - k     - 1
           
           n = V.length vPerm
           
           mapElAndRest :: (a -> Array a -> b) -> Array a -> Array b
           mapElAndRest f arr = V.zipWith f arr gapqs
            where gapqs = V.map fromList . fromList . gapPositions $ toList arr
   


-- | Remove \"gaps\" in an array of unique numbers, i.e. the set of elements
-- is mapped strict-monotonically to @[0 .. length arr - 1]@.
sediment :: Array Int -> Array Int
sediment = V.map fst . saSortBy(compare`on`fst.snd)
             . V.indexed . saSortBy(compare`on`snd) . V.indexed



distinctSubsplxGroups :: Int -> [(SubSplxIndex, [(SubSplxIndex,SimplexPermutation)])]
distinctSubsplxGroups = (sel!!)
 where sel = [ groupEquivs $ findAll [0 .. n-1] | n<-[0..] ]
       
       findAll :: [Int] -> [ (SubSplxIndex, [Int]) ]
       findAll [] = []
       findAll sid = (thisWholeSimplex, sid)
                       : (deeper =<< zip[0..] (gapPositions sid))
        where deeper(wy, newSpl) = map (first wy) $ findAll newSpl
              
       groupEquivs :: [ (SubSplxIndex, [Int]) ]
                      -> [(SubSplxIndex, [(SubSplxIndex,SimplexPermutation)])]
       groupEquivs = sortBy (compare`on`fst)
                      . map (\(cfg,eqvs@((dpath,dperm):_))
                           -> ( dpath
                              , map (\(path,perm)
                                   -> ( path, asSimplexPermutation $ dperm↺↻perm )
                                 ) eqvs
                              ) )
                      . fastNubByWith ( compare `on` fst )
                                      ( \(c1,l1)(_,l2) -> (c1,l1++l2) )
                      . map(\(path, cfg) -> let(unSort,sorted)=undoableSort $ fromList cfg
                                            in (toList sorted, [(path, unSort)])           )

distinctProperSubsplxGroups :: Int -> [(SubSplxIndex, [(SubSplxIndex,SimplexPermutation)])]
distinctProperSubsplxGroups = (sel!!)
 where sel = [ tail $ distinctSubsplxGroups n | n<-[0.. ] ]

distinctDim0SubsplxGroups :: Int -> [(SubSplxIndex, [(SubSplxIndex,SimplexPermutation)])]
distinctDim0SubsplxGroups = (sel!!)
 where sel = [ filter((==n) . length . getSubSplxIndex . fst) 
                      $ distinctSubsplxGroups n 
             | n<-[0.. ] ]

distinctSubsplxSelect :: Int -> Map SubSplxIndex (SubSplxIndex, SimplexPermutation)
distinctSubsplxSelect = (sel!!)
 where sel = [ constructMap $ distinctSubsplxGroups n | n<-[0.. ] ]
       constructMap = foldr ins Map.empty
        where ins (ref, slaves) prev = foldr (\(idx,π) -> Map.insert idx (ref,π)) prev slaves

undoableSort :: Ord a => Array a -> (SimplexPermutation', Array a)
undoableSort = V.unzip . saSortBy(compare`on`snd) . V.indexed


data ManifoldFromTriangltn a tSpc = ManifoldFromTriangltn
         { manifoldTriangulation :: Triangulation a
         , triangltnFocus :: [Int]                  }


              
{-
edgeSimplex2subdiv =              
 Triangulation {simplicialComplex = [ SimplexN [ SimplexN [ Simplex0(Space2D 3.0 0.0), Simplex0(Space2D 1.5 1.5)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.5 1.5), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 3.0 0.0)] undefined ] undefined
                                    , SimplexN [ SimplexN [ Simplex0(Space2D 1.5 1.5), Simplex0(Space2D 0.0 3.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 0.0 3.0), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 1.5 1.5)] undefined ] undefined
                                    , SimplexN [ SimplexN [ Simplex0(Space2D 0.0 3.0), Simplex0(Space2D 0.0 1.5)] undefined
                                               , SimplexN [ Simplex0(Space2D 0.0 1.5), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 0.0 3.0)] undefined ] undefined
                                    , SimplexN [ SimplexN [ Simplex0(Space2D 0.0 1.5), Simplex0(Space2D 0.0 0.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 0.0 0.0), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 0.0 1.5)] undefined ] undefined
                                    , SimplexN [ SimplexN [ Simplex0(Space2D 0.0 0.0), Simplex0(Space2D 1.5 0.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.5 0.0), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 0.0 0.0)] undefined ] undefined
                                    , SimplexN [ SimplexN [ Simplex0(Space2D 1.5 0.0), Simplex0(Space2D 3.0 0.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 3.0 0.0), Simplex0(Space2D 1.0 1.0)] undefined
                                               , SimplexN [ Simplex0(Space2D 1.0 1.0), Simplex0(Space2D 1.5 0.0)] undefined ] undefined ]}
edgeSimplex3 =
 SimplexN [ SimplexN [ SimplexN [ Simplex0(Space3D 0.0 3.0 0.0), Simplex0(Space3D 3.0 0.0 0.0)] undefined
                     , SimplexN [ Simplex0(Space3D 3.0 0.0 0.0), Simplex0(Space3D 0.0 0.0 3.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 3.0), Simplex0(Space3D 0.0 3.0 0.0)] undefined ] undefined
          , SimplexN [ SimplexN [ Simplex0(Space3D 0.0 3.0 0.0), Simplex0(Space3D 0.0 0.0 3.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 3.0), Simplex0(Space3D 0.0 0.0 0.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 0.0), Simplex0(Space3D 0.0 3.0 0.0)] undefined ] undefined
          , SimplexN [ SimplexN [ Simplex0(Space3D 3.0 0.0 0.0), Simplex0(Space3D 0.0 0.0 0.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 0.0), Simplex0(Space3D 0.0 0.0 3.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 3.0), Simplex0(Space3D 3.0 0.0 0.0)] undefined ] undefined
          , SimplexN [ SimplexN [ Simplex0(Space3D 3.0 0.0 0.0), Simplex0(Space3D 0.0 3.0 0.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 3.0 0.0), Simplex0(Space3D 0.0 0.0 0.0)] undefined
                     , SimplexN [ Simplex0(Space3D 0.0 0.0 0.0), Simplex0(Space3D 3.0 0.0 0.0)] undefined ] undefined ] undefined
-}
 


infixl 7 ↺↺, ↺↻
class Permutation π where
  (↺↺) :: π -> π -> π
  (↺↻) :: π -> π -> π
  p↺↻q = p ↺↺ invPerm q
  invPerm :: π -> π




deleteAt :: Int -> [a] -> [a]
deleteAt n = uncurry(++) . second tail . splitAt n

-- | @'omit1s' [0,1,2,3] = [[1,2,3], [0,2,3], [0,1,3], [0,1,2]]@
omit1s :: [a] -> [[a]]
omit1s [] = []
omit1s [_] = [[]]
omit1s (v:vs) = vs : map(v:) (omit1s vs)

-- | @'gapPositions' [0,1,2,3] = [[1,2,3], [2,3,0], [3,0,1], [0,1,2]]@
gapPositions :: [a] -> [[a]]
gapPositions = gp id
 where gp rq (v:vs) = (vs++rq[]) : gp (rq.(v:)) vs
       gp _ _ = []


type Map = Map.Map


type Array = V.Vector

saSort :: Ord a => Array a -> Array a
saSort = V.modify VAIns.sort

-- The sorting algorithm of choice is simple insertion sort, because simplices
-- that can feasibly be handled will always have low dimension, so the better
-- complexity of more sophisticated sorting algorithms is no use on the short
-- vertex arrays.
{-# inline saSortBy #-}
saSortBy :: VAIns.Comparison a -> Array a -> Array a
saSortBy cmp = V.modify $ VAIns.sortBy cmp


-- | Unlike the related 'zipWith', 'associateWith' \"spreads out\" the shorter
-- list by duplicating elements, before merging, to minimise the number of
-- elements from the longer list which aren't used.
associateWith :: (a->b->c) -> [a] -> [b] -> [c]
associateWith f a b
  | lb>la      = spreadn(lb`quot`la) f a b
  | otherwise  = spreadn(la`quot`lb) (flip f) b a
 where la = length a; lb = length b
       spreadn n f' = go
        where go (e:es) t
               | (et, tr) <- splitAt n t  
                    = foldr((:) . f' e) (go es tr) et
              go _ _ = []
              
-- | @associate = associateWith (,)@.
associate :: [a] -> [b] -> [(a,b)]
associate = associateWith (,)

associaterSectorsWith :: (a->[b]->c) -> [a] -> [b] -> [c]
associaterSectorsWith f a b = spreadn(lb`quot`la) a b
 where la = length a; lb = length b
       spreadn n (e:es) t
        | (et, tr) <- splitAt n t  = f e et : spreadn n es tr
       spreadn _ _ _ = []

associaterSectors :: [a] -> [b] -> [(a,[b])]
associaterSectors = associaterSectorsWith (,)
       
associatelSectorsWith :: ([a]->b->c) -> [a] -> [b] -> [c]
associatelSectorsWith f = flip (associaterSectorsWith $ flip f)

associatelSectors :: [a] -> [b] -> [([a],b)]
associatelSectors = associatelSectorsWith (,)

partitions :: Int -> [a] -> [[a]]
partitions n = go
 where go [] = []
       go l | (chunk,rest) <- splitAt n l  = chunk : go rest

divide :: Int -> [a] -> [[a]]
divide n ls = partitions(length ls`div`n) ls
 
 
mapOnNth :: (a->a) -> Int -> [a] -> [a]
mapOnNth f 0 (l:ls) = f l : ls
mapOnNth f n (l:ls) = l : mapOnNth f (n-1) ls
mapOnNth _ _   []   = []

mapExceptOnNth :: (a->a) -> Int -> [a] -> [a]
mapExceptOnNth f 0 (l:ls) = l : map f ls
mapExceptOnNth f n (l:ls) = f l : mapOnNth f (n-1) ls
mapExceptOnNth _ _   []   = []

{-# INLINE coordMap #-}
coordMap :: HasBasis v => ([Scalar v] -> [Scalar v]) -> v -> v
coordMap f = recompose . uncurry zip . second f . unzip . decompose

data Space2D = Space2D Double Double
       deriving(Eq, Show)
data Space2DIndex = X' | Y

instance AdditiveGroup Space2D where
  zeroV = Space2D 0 0
  Space2D x y ^+^ Space2D x' y' = Space2D (x+x') (y+y')
  negateV (Space2D x y) = Space2D (-x) (-y)
instance VectorSpace Space2D where
  type Scalar Space2D = Double
  λ *^ Space2D x y = Space2D (λ*x) (λ*y)
instance HasBasis Space2D where
  type Basis Space2D = Space2DIndex
  basisValue X' = Space2D 1 0
  basisValue Y  = Space2D 0 1
  decompose (Space2D x y) = [(X', x), (Y, y)]
  decompose' (Space2D x _) X' = x
  decompose' (Space2D _ y) Y  = y


data Space3D = Space3D Double Double Double
       deriving(Eq, Show)
data Space3DIndex = X'' | Y' | Z

instance AdditiveGroup Space3D where
  zeroV = Space3D 0 0 0
  Space3D x y z ^+^ Space3D x' y' z' = Space3D (x+x') (y+y') (z+z')
  negateV (Space3D x y z) = Space3D (-x) (-y) (-z)
instance VectorSpace Space3D where
  type Scalar Space3D = Double
  λ *^ Space3D x y z = Space3D (λ*x) (λ*y) (λ*z)
instance HasBasis Space3D where
  type Basis Space3D = Space3DIndex
  basisValue X'' = Space3D 1 0 0
  basisValue Y'  = Space3D 0 1 0
  basisValue Z   = Space3D 0 0 1
  decompose (Space3D x y z) = [(X'', x), (Y', y), (Z, z)]
  decompose' (Space3D x _ _) X'' = x
  decompose' (Space3D _ y _) Y'  = y
  decompose' (Space3D _ _ z) Z   = z
