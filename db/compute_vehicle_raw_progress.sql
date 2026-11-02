-- For every recorded bus sighting, work out how far along its route line
-- that sighting is - the same calculation used for stops in
-- compute_stop_distances.sql, but applied to a moving bus's GPS spot
-- instead of a fixed stop.
--
--   psql -f /db/compute_vehicle_raw_progress.sql
--
-- This only fills in the "raw" number - the plain closest-point-on-the-line
-- answer for one single reading, with no memory of where the bus was
-- before. It says nothing yet about whether a reading should be trusted.
-- That decision (does this reading make sense given where the bus was a
-- moment ago?) needs to look at each bus's readings in order, one after
-- another, which is easier to read as a normal step-by-step script than as
-- one big database query - see tools/match-vehicle-progress.js for that
-- part.
--
-- Idempotent: safe to re-run after loading more days into vehicle_position.
-- Already-calculated rows are left as they are; only new ones are added.

\set ON_ERROR_STOP on
\timing on
\pset footer off

-- ---------------------------------------------------------------------------
-- Step 1: which line (shape) does each route use? Verified in the static
-- feed profile: a route never has two lines, so this is a plain one-to-one
-- lookup, built fresh from whichever static snapshot is newest.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS route_shape;

CREATE TEMP TABLE route_shape AS
SELECT DISTINCT route_id, shape_id, snapshot_id
FROM trips
WHERE snapshot_id = (SELECT max(snapshot_id) FROM trips);

\echo 'routes with a known line to match against:'
SELECT count(*) FROM route_shape;

-- ---------------------------------------------------------------------------
-- Step 2: for every bus sighting whose route number matches a known line,
-- find the closest point on that line and read off how far along it is.
-- Sightings whose route number does not match anything (the small "ghost
-- route" gap documented in docs/realtime-feed-profile.md) are skipped -
-- there is no line to measure against.
--
-- Only sightings not already done are processed, so re-running this after
-- new days are loaded does not repeat work that is already finished.
-- ---------------------------------------------------------------------------

INSERT INTO vehicle_progress (frame_id, vehicle_id, raw_dist_along_route_m)
SELECT
  vp.frame_id,
  vp.vehicle_id,
  ST_M(
    ST_LineInterpolatePoint(
      sh.geom,
      -- Same rounding-error safety net as compute_stop_distances.sql: pull
      -- the fraction back into 0-1 in case it lands a hair outside it.
      GREATEST(0, LEAST(1, ST_LineLocatePoint(sh.geom, vp.geom)))
    )
  )
FROM vehicle_position vp
JOIN route_shape rs ON rs.route_id = vp.route_id
JOIN shapes sh ON sh.snapshot_id = rs.snapshot_id AND sh.shape_id = rs.shape_id
WHERE NOT EXISTS (
  SELECT 1 FROM vehicle_progress p
  WHERE p.frame_id = vp.frame_id AND p.vehicle_id = vp.vehicle_id
);

\echo ''
\echo 'bus sightings with a raw distance now calculated:'
SELECT count(*) FROM vehicle_progress WHERE raw_dist_along_route_m IS NOT NULL;

\echo ''
\echo 'bus sightings skipped (route number matches no known line):'
SELECT count(*) FROM vehicle_position vp
WHERE NOT EXISTS (SELECT 1 FROM route_shape rs WHERE rs.route_id = vp.route_id);
