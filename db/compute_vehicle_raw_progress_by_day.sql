-- Same job as compute_vehicle_raw_progress.sql, but run one day at a time.
--
--   psql -v day=2026-08-09 -f /db/compute_vehicle_raw_progress_by_day.sql
--
-- Why this version exists: the archive grew from 2 days to 8 (157M vehicle
-- sightings), and the original one-shot version tried to do the whole thing
-- as a single INSERT with the default 64MB work_mem. That made Postgres
-- spill its sort/hash work to disk over and over instead of doing it in
-- memory, so it ran for nearly 2 hours without committing a single row and
-- had to be cancelled. Splitting by day means:
--   - each day commits on its own, so progress is visible and a crash only
--     loses the day in progress, not everything
--   - a bigger work_mem for just this session, since one day's join fits in
--     memory even where the whole archive would not
--
-- Idempotent, same as the original: the NOT EXISTS check skips sightings
-- that already have a raw distance.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '512MB';

DROP TABLE IF EXISTS route_shape;
CREATE TEMP TABLE route_shape AS
SELECT DISTINCT route_id, shape_id, snapshot_id
FROM trips
WHERE snapshot_id = (SELECT max(snapshot_id) FROM trips);

INSERT INTO vehicle_progress (frame_id, vehicle_id, raw_dist_along_route_m)
SELECT
  vp.frame_id,
  vp.vehicle_id,
  ST_M(
    ST_LineInterpolatePoint(
      sh.geom,
      GREATEST(0, LEAST(1, ST_LineLocatePoint(sh.geom, vp.geom)))
    )
  )
FROM vehicle_position vp
JOIN realtime_frame rf ON rf.frame_id = vp.frame_id AND rf.day = :'day'
JOIN route_shape rs ON rs.route_id = vp.route_id
JOIN shapes sh ON sh.snapshot_id = rs.snapshot_id AND sh.shape_id = rs.shape_id
WHERE NOT EXISTS (
  SELECT 1 FROM vehicle_progress p
  WHERE p.frame_id = vp.frame_id AND p.vehicle_id = vp.vehicle_id
);

\echo 'day done:'
SELECT :'day' AS day, count(*) AS raw_rows_now
FROM vehicle_progress vpr
JOIN vehicle_position vp ON vp.frame_id = vpr.frame_id AND vp.vehicle_id = vpr.vehicle_id
JOIN realtime_frame rf ON rf.frame_id = vp.frame_id
WHERE rf.day = :'day';
