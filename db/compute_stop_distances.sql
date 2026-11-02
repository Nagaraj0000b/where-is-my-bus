-- Work out how far along its route line every stop sits.
--
--   psql -f /db/compute_stop_distances.sql
--
-- The problem this solves: we have a map line drawn for every bus route.
-- We know the total length of each line in real metres. What we didn't
-- know is: for each stop on that route, how far into the line does it sit?
-- Like knowing a road is 10 km long, but not knowing that the third bus
-- stop is at the 2.3 km mark. The official data left this blank for every
-- single stop, on purpose - it's just missing.
--
-- This script fills that gap. It writes the answer into
-- stop_times.dist_along_shape_m.
--
-- How it works, in plain terms: for a stop and the route line it sits on,
-- we find the closest point on the line to that stop, then read off how far
-- along the line that closest point is. PostGIS has two ready-made tools for
-- exactly this:
--   ST_LineLocatePoint(line, point)   -> "what fraction of the way along
--                                        the line is the closest point to
--                                        this stop?" (a number from 0 to 1)
--   ST_LineInterpolatePoint(line, x)  -> "give me the actual point that
--                                        sits x of the way along the line"
-- Since our line already carries real metres at every point along it (the
-- "M" value described above), asking for the point at that fraction and
-- then reading its M value gives us the stop's distance in metres. That's
-- the whole calculation - two off-the-shelf tools chained together.
--
-- Idempotent: safe to re-run. It always recalculates and overwrites, it
-- does not add duplicate rows.

\set ON_ERROR_STOP on
\timing on
\pset footer off

-- ---------------------------------------------------------------------------
-- Step 1: find every distinct (route line, stop) pairing that actually shows
-- up somewhere in the timetable. There are only a few thousand routes and
-- stops, so this is a small list - far smaller than the 3.86 million rows in
-- stop_times. Doing the expensive geometry calculation once per pairing,
-- instead of once per stop_times row, is what keeps this script fast.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS shape_stop_distance;

CREATE TEMP TABLE shape_stop_distance AS
SELECT DISTINCT
  t.snapshot_id,
  t.shape_id,
  st.stop_id
FROM stop_times st
JOIN trips t ON t.snapshot_id = st.snapshot_id AND t.trip_id = st.trip_id;

\echo 'distinct (route line, stop) pairings to calculate:'
SELECT count(*) FROM shape_stop_distance;

-- ---------------------------------------------------------------------------
-- Step 2: for each pairing, do the actual calculation described above.
-- ---------------------------------------------------------------------------

ALTER TABLE shape_stop_distance ADD COLUMN dist_along_shape_m double precision;

-- ST_LineLocatePoint should return a fraction between 0 and 1, but when a
-- stop sits almost exactly at the very start or end of its line, rounding
-- error can push the answer very slightly outside that range (we saw
-- 1.0000000000000002 on one real stop). The next tool refuses anything
-- outside 0-1, so we pull the number back into range first. GREATEST/LEAST
-- here just means "don't let it go below 0, and don't let it go above 1".
UPDATE shape_stop_distance ssd SET
  dist_along_shape_m = ST_M(
    ST_LineInterpolatePoint(
      sh.geom,
      GREATEST(0, LEAST(1, ST_LineLocatePoint(sh.geom, s.geom)))
    )
  )
FROM shapes sh, stops s
WHERE sh.snapshot_id = ssd.snapshot_id AND sh.shape_id = ssd.shape_id
  AND s.snapshot_id  = ssd.snapshot_id AND s.stop_id   = ssd.stop_id;

-- ---------------------------------------------------------------------------
-- Step 3: copy each pairing's answer into every stop_times row that uses it.
-- One pairing (route line + stop) can be reused by many trips, so this one
-- update fills in every matching row at once.
-- ---------------------------------------------------------------------------

UPDATE stop_times st SET
  dist_along_shape_m = ssd.dist_along_shape_m
FROM trips t, shape_stop_distance ssd
WHERE t.snapshot_id   = st.snapshot_id AND t.trip_id   = st.trip_id
  AND ssd.snapshot_id  = t.snapshot_id AND ssd.shape_id = t.shape_id
  AND ssd.stop_id      = st.stop_id;

\echo ''
\echo 'stop_times rows filled in:'
SELECT count(*) FROM stop_times WHERE dist_along_shape_m IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Step 4: a sanity check, not a fix.
--
-- Along one trip, the distance-along-the-line should always go up as the bus
-- visits stop after stop - a bus doesn't travel backward down its own route.
-- If a stop's distance is smaller than the stop before it in the same trip,
-- that means the "closest point on the line" for that stop was not a clean
-- match - most likely the route line loops back near itself (a bus terminal
-- loop, or a road the route uses twice), and the closest-point tool picked
-- the wrong pass of the line. This is exactly the kind of edge case flagged
-- in the discussion before writing this script - the tool can be wrong when
-- a line crosses near itself, and it is worth seeing how often that happens
-- rather than assuming it never does.
-- ---------------------------------------------------------------------------

\echo ''
\echo 'trips where a later stop is calculated as closer to the start than an'
\echo 'earlier stop (distance goes backward - a warning sign, not a crash):'

WITH ordered AS (
  SELECT
    trip_id,
    stop_sequence,
    dist_along_shape_m,
    lag(dist_along_shape_m) OVER (PARTITION BY snapshot_id, trip_id ORDER BY stop_sequence) AS prev_dist
  FROM stop_times
  WHERE snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
)
SELECT count(DISTINCT trip_id) AS trips_with_a_backward_step
FROM ordered
WHERE prev_dist IS NOT NULL AND dist_along_shape_m < prev_dist;

\echo ''
\echo 'out of this many trips total, for comparison:'
SELECT count(*) FROM trips WHERE snapshot_id = (SELECT max(snapshot_id) FROM stop_times);
