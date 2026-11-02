-- Work out how far along its route line every recorded bus sighting is,
-- in chunks, so it finishes in reasonable time on a laptop.
--
--   psql -f /db/compute_vehicle_raw_progress_chunked.sql
--
-- WHY THIS REPLACES THE EARLIER TWO VERSIONS
--
-- The archive grew from 2 days (17M sightings) to 8 days (157M sightings),
-- and vehicle_position is now about 46 GB. Two earlier attempts were too
-- slow to finish, for two different reasons, and it is worth writing both
-- down so neither is repeated:
--
--   1. compute_vehicle_raw_progress.sql did the whole archive as ONE
--      statement. One statement means one transaction: nothing is saved
--      until every row is done, there is no way to see progress, and a
--      cancel throws away all the work. It ran ~2 hours and committed
--      nothing.
--
--   2. compute_vehicle_raw_progress_by_day.sql filtered by day. That
--      sounded better but was actually 8x WORSE. One day is about 12% of
--      the table, which is too big a slice for Postgres to bother using an
--      index for, so it read all 46 GB to pick out one day's rows - once
--      per day, about 368 GB of reading in total.
--
-- What this version does instead: it walks the table in narrow ranges of
-- frame_id. frame_id is the first column of vehicle_position's primary key,
-- so a narrow range is a cheap index lookup that touches only that slice of
-- the table rather than all of it. Each chunk is committed as it finishes,
-- so progress is visible, and stopping this script only loses the chunk in
-- progress rather than everything.
--
-- It also skips the "which rows are already done?" check that the earlier
-- versions did with NOT EXISTS. That check cost one index lookup per row -
-- about 157 million of them. It is not needed, because everything already
-- computed sits below a known frame_id (see START_AFTER below), so a plain
-- "greater than" is enough.
--
-- Idempotent: it starts from whatever the highest already-computed frame_id
-- is, so re-running after loading more days only does the new work.

\set ON_ERROR_STOP on
\timing on
\pset footer off

-- More memory for sorting/hashing, and more CPU cores, for this session
-- only. These do not need a server restart and do not affect anything else.
SET work_mem = '256MB';
SET max_parallel_workers_per_gather = 4;

-- Which line (shape) does each route use, and how long is that line?
-- Route to line is strictly 1:1 in this feed (verified in
-- docs/static-feed-profile.md), so this is a plain lookup. Kept as a real
-- table, not a temp one, so the parallel workers inside the loop below can
-- read it too.
--
-- route_length_m is read from the shape's own M-value at its last point,
-- not from a fresh ST_Length() calculation. Those two disagree by up to a
-- few hundred metres on some routes (checked on 2026-08-16: -172.7m on
-- route 2716) because they are measuring the line two different ways. It
-- matters here because tools/match-vehicle-progress.js compares a bus's
-- raw distance-along-route (also read from the same M-value system) against
-- this route length to spot a bus finishing one lap and starting the next.
-- Using the same measuring system as the thing it is being compared
-- against removes that disagreement rather than needing a bigger safety
-- margin to paper over it.
DROP TABLE IF EXISTS route_shape_lookup;
CREATE TABLE route_shape_lookup AS
SELECT DISTINCT ON (t.route_id)
  t.route_id, t.shape_id, t.snapshot_id,
  ST_M(ST_EndPoint(sh.geom)) AS route_length_m
FROM trips t
JOIN shapes sh ON sh.snapshot_id = t.snapshot_id AND sh.shape_id = t.shape_id
WHERE t.snapshot_id = (SELECT max(snapshot_id) FROM trips);

CREATE UNIQUE INDEX ON route_shape_lookup (route_id);
ANALYZE route_shape_lookup;

DO $$
DECLARE
  -- Everything at or below this frame_id already has a raw distance.
  start_after bigint;
  last_frame  bigint;
  chunk_start bigint;
  -- How many frames to do at once. Small enough that each chunk is a quick
  -- index lookup and commits often; big enough that we are not paying the
  -- per-statement overhead thousands of times.
  chunk_size  bigint := 2000;
  inserted    bigint;
  total       bigint := 0;
  started_at  timestamptz := clock_timestamp();
BEGIN
  SELECT coalesce(max(frame_id), 0) INTO start_after FROM vehicle_progress;
  SELECT max(frame_id) INTO last_frame FROM realtime_frame;

  RAISE NOTICE 'starting after frame %, up to frame %', start_after, last_frame;

  chunk_start := start_after + 1;

  WHILE chunk_start <= last_frame LOOP
    INSERT INTO vehicle_progress (frame_id, vehicle_id, raw_dist_along_route_m)
    SELECT
      vp.frame_id,
      vp.vehicle_id,
      ST_M(
        ST_LineInterpolatePoint(
          sh.geom,
          -- Pull the fraction back into 0-1: rounding can push it a hair
          -- outside when a bus sits right at the very start or end of a line.
          GREATEST(0, LEAST(1, ST_LineLocatePoint(sh.geom, vp.geom)))
        )
      )
    FROM vehicle_position vp
    JOIN route_shape_lookup rs ON rs.route_id = vp.route_id
    JOIN shapes sh ON sh.snapshot_id = rs.snapshot_id AND sh.shape_id = rs.shape_id
    WHERE vp.frame_id >= chunk_start
      AND vp.frame_id <  chunk_start + chunk_size;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    total := total + inserted;

    -- Save this chunk before moving on, so the work so far survives a stop.
    COMMIT;

    RAISE NOTICE 'frames % to %  |  rows this chunk %  |  total %  |  elapsed %',
      chunk_start, chunk_start + chunk_size - 1, inserted, total,
      clock_timestamp() - started_at;

    chunk_start := chunk_start + chunk_size;
  END LOOP;

  RAISE NOTICE 'done. % rows added in %', total, clock_timestamp() - started_at;
END $$;
