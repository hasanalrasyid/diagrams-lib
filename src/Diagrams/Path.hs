{-# LANGUAGE CPP                        #-}
#if __GLASGOW_HASKELL__ >= 707
{-# LANGUAGE DeriveDataTypeable         #-}
#endif
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Path
-- Copyright   :  (c) 2011 diagrams-lib team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- This module defines /paths/, which are collections of concretely
-- located 'Trail's.  Many drawing systems (cairo, svg, ...) have a
-- similar notion of \"path\".  Note that paths with multiple trails
-- are necessary for being able to draw /e.g./ filled objects with
-- holes in them.
--
-----------------------------------------------------------------------------

module Diagrams.Path
       (

         -- * Paths

         Path(..), pathTrails

         -- * Constructing paths
         -- $construct

       , pathFromTrail
       , pathFromTrailAt
       , pathFromLocTrail

         -- * Eliminating paths

       , pathVertices
       , pathOffsets
       , pathCentroid
       , pathLocSegments, fixPath

         -- * Modifying paths

       , scalePath
       , reversePath

         -- * Miscellaneous

       , explodePath
       , partitionPath

       ) where

import           Control.Arrow        ((***))
import           Control.Lens         (Rewrapped, Wrapped (..), iso, mapped, op, over, view, (%~),
                                       _Unwrapped', _Wrapped)
import qualified Data.Foldable        as F
import           Data.List            (partition)
import           Data.Semigroup
import           Data.Typeable

import           Diagrams.Align
import           Diagrams.Core
import           Diagrams.Located
import           Diagrams.Points
import           Diagrams.Segment
import           Diagrams.Trail
import           Diagrams.TrailLike
import           Diagrams.Transform

import           Linear.Affine
import           Linear.Metric
import           Linear.Vector

------------------------------------------------------------
--  Paths  -------------------------------------------------
------------------------------------------------------------

-- | A /path/ is a (possibly empty) list of 'Located' 'Trail's.
--   Hence, unlike trails, paths are not translationally invariant,
--   and they form a monoid under /superposition/ (placing one path on
--   top of another) rather than concatenation.
newtype Path v n = Path [Located (Trail v n)]
  deriving (Semigroup, Monoid
#if __GLASGOW_HASKELL__ >= 707
  , Typeable
#endif
  )

#if __GLASGOW_HASKELL__ < 707
-- This should really be Typeable2 Path but since Path has kind
--   (* -> *) -> * -> *
-- not
--   * -> * -> *
-- we can only do Typeable1 (Path v). This is why the instance cannot be 
-- derived.
instance forall v. Typeable1 v => Typeable1 (Path v) where
  typeOf1 _ = mkTyConApp (mkTyCon3 "diagrams-lib" "Diagrams.Path" "Path") [] `mkAppTy`
              typeOf1 (undefined :: v n)
#endif

instance Wrapped (Path v n) where
  type Unwrapped (Path v n) = [Located (Trail v n)]
  _Wrapped' = iso (\(Path x) -> x) Path

instance Rewrapped (Path v n) (Path v' n')

-- | Extract the located trails making up a 'Path'.
pathTrails :: Path v n -> [Located (Trail v n)]
pathTrails = op Path

deriving instance Show (v n) => Show (Path v n)
deriving instance Eq   (v n) => Eq   (Path v n)
deriving instance Ord  (v n) => Ord  (Path v n)

type instance V (Path v n) = v
type instance N (Path v n) = n

instance (Additive v, Num n) => HasOrigin (Path v n) where
  moveOriginTo = over _Wrapped' . map . moveOriginTo

-- | Paths are trail-like; a trail can be used to construct a
--   singleton path.
instance (Metric v, OrderedField n) => TrailLike (Path v n) where
  trailLike = Path . (:[])

-- See Note [Transforming paths]
instance (HasLinearMap v, Metric v, OrderedField n)
    => Transformable (Path v n) where
  transform = over _Wrapped . map . transform

instance (Metric v, OrderedField n) => Enveloped (Path v n) where
  getEnvelope = F.foldMap trailEnvelope . op Path --view pathTrails
          -- this type signature is necessary to work around an apparent bug in ghc 6.12.1
    where trailEnvelope :: Located (Trail v n) -> Envelope v n
          trailEnvelope (viewLoc -> (p, t)) = moveOriginTo ((-1) *. p) (getEnvelope t)

instance (Metric v, OrderedField n) => Juxtaposable (Path v n) where
  juxtapose = juxtaposeDefault

instance (Metric v, OrderedField n) => Alignable (Path v n) where
  defaultBoundary = envelopeBoundary

instance (HasLinearMap v, Metric v, OrderedField n)
    => Renderable (Path v n) NullBackend where
  render _ _ = mempty

------------------------------------------------------------
--  Constructing paths  ------------------------------------
------------------------------------------------------------

-- $construct
-- Since paths are 'TrailLike', any function producing a 'TrailLike'
-- can be used to construct a (singleton) path.  The functions in this
-- section are provided for convenience.

-- | Convert a trail to a path beginning at the origin.
pathFromTrail :: (Metric v, OrderedField n) => Trail v n -> Path v n
pathFromTrail = trailLike . (`at` origin)

-- | Convert a trail to a path with a particular starting point.
pathFromTrailAt :: (Metric v, OrderedField n) => Trail v n -> Point v n -> Path v n
pathFromTrailAt t p = trailLike (t `at` p)

-- | Convert a located trail to a singleton path.  This is equivalent
--   to 'trailLike', but provided with a more specific name and type
--   for convenience.
pathFromLocTrail :: (Metric v, OrderedField n) => Located (Trail v n) -> Path v n
pathFromLocTrail = trailLike

------------------------------------------------------------
--  Eliminating paths  -------------------------------------
------------------------------------------------------------

-- | Extract the vertices of a path, resulting in a separate list of
--   vertices for each component trail (see 'trailVertices').
pathVertices :: (Metric v, OrderedField n) => Path v n -> [[Point v n]]
pathVertices = map trailVertices . op Path

-- | Compute the total offset of each trail comprising a path (see 'trailOffset').
pathOffsets :: (Metric v, OrderedField n) => Path v n -> [v n]
pathOffsets = map (trailOffset . unLoc) . op Path

-- | Compute the /centroid/ of a path (/i.e./ the average location of
--   its vertices).
pathCentroid :: (Metric v, OrderedField n) => Path v n -> Point v n
pathCentroid = centroid . concat . pathVertices

-- | Convert a path into a list of lists of located segments.
pathLocSegments :: (Metric v, OrderedField n) => Path v n -> [[Located (Segment Closed v n)]]
pathLocSegments = map trailLocSegments . op Path

-- | Convert a path into a list of lists of 'FixedSegment's.
fixPath :: (Metric v, OrderedField n) => Path v n -> [[FixedSegment v n]]
fixPath = map fixTrail . op Path

-- | \"Explode\" a path by exploding every component trail (see
--   'explodeTrail').
explodePath :: (V t ~ v, N t ~ n, Additive v, TrailLike t) => Path v n -> [[t]]
explodePath = map explodeTrail . op Path

-- | Partition a path into two paths based on a predicate on trails:
--   the first containing all the trails for which the predicate returns
--   @True@, and the second containing the remaining trails.
partitionPath :: (Located (Trail v n) -> Bool) -> Path v n -> (Path v n, Path v n)
partitionPath p = (view _Unwrapped' *** view _Unwrapped') . partition p . op Path

------------------------------------------------------------
--  Modifying paths  ---------------------------------------
------------------------------------------------------------

-- | Scale a path using its centroid (see 'pathCentroid') as the base
--   point for the scale.
scalePath :: (HasLinearMap v, Metric v, OrderedField n) => n -> Path v n -> Path v n
scalePath d p = (scale d `under` translation (origin .-. pathCentroid p)) p

-- | Reverse all the component trails of a path.
reversePath :: (Metric v, OrderedField n) => Path v n -> Path v n
reversePath = _Wrapped . mapped %~ reverseLocTrail

