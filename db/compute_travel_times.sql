-- Turn raw stop passages into the travel-time statistics the ETA is
-- served from. Run after observed_stop_passage is populated
-- (scripts/process-week.sh).
--
--   psql -f /db/compute_travel_times.sql
--
-- Two steps:
--
-- 1. Build "segments": for each vehicle's passages on a given day, in time
--    order, take each pair of consecutive rows. If stop_sequence went up
--    by exactly 1 on the same route, that pair is one real measurement of
--    "how long did this hop take". Anything else (a skipped stop, a route
--    change, a lap restart wrapping back to stop 1) is excluded rather
--    than guessed at.
--
-- 2. Aggregate those measurements at three levels of detail at once, using
--    GROUPING SETS, so the ETA can fall back when a specific cell is thin:
--       (route, stop, day_type, hour)  most specific
--       (route, stop, day_type)        any hour, right kind of day
--       (route, stop)                  last resort
--
-- Idempotent: truncates and recomputes, so it always matches whatever is
-- currently in observed_stop_passage.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

-- ---------------------------------------------------------------------------
-- Step 1: genuine consecutive-stop hops, tagged with hour and day type.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _segments;

CREATE TEMP TABLE _segments AS
SELECT
    route_id,
    stop_sequence   AS to_stop_sequence,
    stop_id         AS to_stop_id,
    prev_stop_id    AS from_stop_id,
    extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
    -- DELHI LOCAL TIME, not UTC. The database stores timestamps with a
    -- timezone and its session runs in UTC, so reading the hour straight
    -- off would give the UTC hour - and Delhi is UTC+5:30. That has two
    -- consequences worth avoiding:
    --   1. "hour 9" would mean 14:30 in Delhi, making every number here
    --      impossible to sanity-check against real traffic by eye.
    --   2. Because the offset is a half hour, UTC hour buckets straddle
    --      two Delhi hours, mixing rush-hour and non-rush-hour traffic
    --      into the same bucket and blurring exactly the pattern we are
    --      trying to capture.
    extract(hour FROM passage_time AT TIME ZONE 'Asia/Kolkata')::int AS hour_of_day,
    -- Day type is taken from the Delhi calendar date for the same reason:
    -- a bus running at 02:00 on a Saturday in Delhi is still Friday in
    -- UTC, and would otherwise be filed as weekday traffic.
    --
    -- Note: public holidays are NOT handled - 15 August (Independence Day)
    -- sits in the recorded week and is treated as an ordinary Saturday.
    -- See docs/eta-design.md section 7.
    CASE WHEN extract(dow FROM (passage_time AT TIME ZONE 'Asia/Kolkata')::date) IN (0, 6)
         THEN 'weekend' ELSE 'weekday' END AS day_type
FROM (
    SELECT
        route_id, vehicle_id, day, stop_id, stop_sequence, passage_time,
        LAG(stop_id)       OVER w AS prev_stop_id,
        LAG(stop_sequence) OVER w AS prev_stop_sequence,
        LAG(passage_time)  OVER w AS prev_passage_time,
        LAG(route_id)      OVER w AS prev_route_id
    FROM observed_stop_passage
    WINDOW w AS (PARTITION BY vehicle_id, day ORDER BY passage_time)
) x
WHERE prev_stop_sequence IS NOT NULL
  AND route_id = prev_route_id
  AND stop_sequence = prev_stop_sequence + 1
  AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800;
  -- a single hop under 1s or over 30min is a data artifact, not a real hop

\echo ''
\echo 'genuine consecutive-stop hops found:'
SELECT count(*) FROM _segments;

CREATE INDEX ON _segments (route_id, to_stop_sequence);
ANALYZE _segments;

-- ---------------------------------------------------------------------------
-- Step 2: aggregate at all three levels of detail in one pass.
-- ---------------------------------------------------------------------------

TRUNCATE route_segment_travel_time;

\echo ''
\echo 'aggregating (three levels of detail)...'

INSERT INTO route_segment_travel_time
    (route_id, to_stop_sequence, from_stop_id, to_stop_id,
     day_type, hour_of_day, sample_count,
     mean_seconds, median_seconds, p25_seconds, p75_seconds, stddev_seconds)
SELECT
    route_id,
    to_stop_sequence,
    max(from_stop_id),          -- constant per (route, stop_sequence) in practice
    max(to_stop_id),
    coalesce(day_type, 'any'),  -- GROUPING SETS leaves this NULL for the
    coalesce(hour_of_day, -1),  -- coarser levels; the table uses sentinels
    count(*),
    avg(travel_seconds),
    percentile_cont(0.50) WITHIN GROUP (ORDER BY travel_seconds),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY travel_seconds),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY travel_seconds),
    stddev(travel_seconds)
FROM _segments
GROUP BY GROUPING SETS (
    (route_id, to_stop_sequence, day_type, hour_of_day),
    (route_id, to_stop_sequence, day_type),
    (route_id, to_stop_sequence)
);

ANALYZE route_segment_travel_time;

\echo ''
\echo 'rows written, by level of detail:'
SELECT
    CASE WHEN day_type = 'any'   THEN '3. any day, any hour (last resort)'
         WHEN hour_of_day = -1   THEN '2. right day type, any hour'
         ELSE                         '1. right day type, right hour' END AS level,
    count(*) AS rows,
    round(avg(sample_count)::numeric, 1) AS avg_samples,
    count(*) FILTER (WHERE sample_count < 3) AS cells_too_thin_to_trust
FROM route_segment_travel_time
GROUP BY 1 ORDER BY 1;

\echo ''
\echo 'distinct route segments covered:'
SELECT count(*) FROM route_segment_travel_time WHERE day_type = 'any';

\echo ''
\echo 'sanity check - pooled median travel time per hop:'
SELECT
    count(*) AS segments,
    round(min(median_seconds)::numeric, 1) AS min_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY median_seconds)::numeric, 1) AS typical_s,
    round(max(median_seconds)::numeric, 1) AS max_s
FROM route_segment_travel_time
WHERE day_type = 'any';

\echo ''
\echo 'weekday vs weekend, side by side (are they really different?):'
SELECT day_type,
       count(*) AS segments,
       round(avg(mean_seconds)::numeric, 1)   AS avg_mean_s,
       round(avg(median_seconds)::numeric, 1) AS avg_median_s
FROM route_segment_travel_time
WHERE hour_of_day = -1 AND day_type <> 'any'
GROUP BY day_type ORDER BY day_type;

DROP TABLE IF EXISTS _segments;
