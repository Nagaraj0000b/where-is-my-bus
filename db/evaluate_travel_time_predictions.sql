-- Phase 4's first deliverable: does the travel-time model actually work?
--
--   psql -f /db/evaluate_travel_time_predictions.sql
--
-- AGENTS.md working convention #3: "Build the evaluation harness early.
-- Without a number, 'I improved the ETA' is a feeling rather than a
-- result." This is that harness.
--
-- The method: hold out one full day (2026-08-13, a Thursday - a normal
-- weekday, not the biggest or smallest sample day). Build travel-time
-- statistics from the OTHER six days only - this script does its own
-- from-scratch aggregation into a temp table, entirely separate from the
-- real route_segment_travel_time table, so nothing here touches or
-- depends on that production table having been built with all 7 days.
--
-- Then, for every real consecutive-stop hop actually observed on the
-- held-out day, look up what the six-day-trained model would have
-- predicted for that route segment - preferring the hour-of-day-specific
-- figure when there's enough data behind it (sample_count >= 3), falling
-- back to the pooled figure otherwise. Compare predicted vs actual.
--
-- This mirrors exactly how the real system is meant to behave (graceful
-- degradation from a specific estimate to a coarser one), so the
-- evaluation is honest about what would really happen, not an idealised
-- best case.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

-- :'held_out_day' (with the colon-quote syntax below) is psql's own
-- string-interpolation form - it wraps the raw value in SQL quotes and
-- escapes it correctly. The variable itself holds the bare date text,
-- no quotes of its own.
\set held_out_day 2026-08-13

-- ---------------------------------------------------------------------------
-- Step 1: build segments for the TRAINING days only (everything except the
-- held-out day). Same logic as compute_travel_times.sql, just with the one
-- extra day filter.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _train_segments;

CREATE TEMP TABLE _train_segments AS
SELECT
    route_id,
    stop_sequence       AS to_stop_sequence,
    extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
    extract(hour FROM passage_time)::int                 AS hour_of_day
FROM (
    SELECT
        route_id, vehicle_id, day, stop_sequence, passage_time,
        LAG(stop_sequence) OVER w AS prev_stop_sequence,
        LAG(passage_time)  OVER w AS prev_passage_time,
        LAG(route_id)      OVER w AS prev_route_id
    FROM observed_stop_passage
    WHERE day != :'held_out_day'
    WINDOW w AS (PARTITION BY vehicle_id, day ORDER BY passage_time)
) x
WHERE prev_stop_sequence IS NOT NULL
  AND route_id = prev_route_id
  AND stop_sequence = prev_stop_sequence + 1
  AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800;

\echo ''
\echo 'training segments (6 days, held-out day excluded):'
SELECT count(*) FROM _train_segments;

-- ---------------------------------------------------------------------------
-- Step 2: aggregate the training segments, pooled and hourly, same as the
-- real pipeline does.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _train_stats;

CREATE TEMP TABLE _train_stats AS
SELECT
    route_id,
    to_stop_sequence,
    coalesce(hour_of_day, -1) AS hour_of_day,
    count(*) AS sample_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_seconds
FROM _train_segments
GROUP BY GROUPING SETS (
    (route_id, to_stop_sequence, hour_of_day),
    (route_id, to_stop_sequence)
);

CREATE UNIQUE INDEX ON _train_stats (route_id, to_stop_sequence, hour_of_day);
ANALYZE _train_stats;

\echo ''
\echo 'trained route-segment stats (pooled + hourly combined):'
SELECT count(*) FROM _train_stats;

-- ---------------------------------------------------------------------------
-- Step 3: build the TEST segments - real hops actually observed on the
-- held-out day. Same logic, just scoped to that one day.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _test_segments;

CREATE TEMP TABLE _test_segments AS
SELECT
    route_id,
    stop_sequence       AS to_stop_sequence,
    extract(epoch FROM passage_time - prev_passage_time) AS actual_seconds,
    extract(hour FROM passage_time)::int                 AS hour_of_day
FROM (
    SELECT
        route_id, vehicle_id, stop_sequence, passage_time,
        LAG(stop_sequence) OVER w AS prev_stop_sequence,
        LAG(passage_time)  OVER w AS prev_passage_time,
        LAG(route_id)      OVER w AS prev_route_id
    FROM observed_stop_passage
    WHERE day = :'held_out_day'
    WINDOW w AS (PARTITION BY vehicle_id ORDER BY passage_time)
) x
WHERE prev_stop_sequence IS NOT NULL
  AND route_id = prev_route_id
  AND stop_sequence = prev_stop_sequence + 1
  AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800;

\echo ''
\echo 'test segments (held-out day, real observed hops):'
SELECT count(*) FROM _test_segments;

-- ---------------------------------------------------------------------------
-- Step 4: for each test hop, predict using the trained stats - hour-of-day
-- match first (if it has at least 3 samples behind it), pooled fallback
-- otherwise. Then compare.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _predictions;

CREATE TEMP TABLE _predictions AS
SELECT
    t.route_id, t.to_stop_sequence, t.hour_of_day, t.actual_seconds,
    hourly.median_seconds  AS hourly_prediction,
    hourly.sample_count    AS hourly_sample_count,
    pooled.median_seconds  AS pooled_prediction,
    pooled.sample_count    AS pooled_sample_count,
    coalesce(
        CASE WHEN hourly.sample_count >= 3 THEN hourly.median_seconds END,
        pooled.median_seconds
    ) AS used_prediction,
    CASE WHEN hourly.sample_count >= 3 THEN 'hourly' ELSE 'pooled' END AS prediction_source
FROM _test_segments t
LEFT JOIN _train_stats hourly
  ON hourly.route_id = t.route_id AND hourly.to_stop_sequence = t.to_stop_sequence
 AND hourly.hour_of_day = t.hour_of_day
LEFT JOIN _train_stats pooled
  ON pooled.route_id = t.route_id AND pooled.to_stop_sequence = t.to_stop_sequence
 AND pooled.hour_of_day = -1;

\echo ''
\echo 'test hops with NO prediction available at all (route segment never seen in training):'
SELECT count(*) FROM _predictions WHERE used_prediction IS NULL;

\echo ''
\echo 'test hops WITH a prediction (this is what gets scored):'
SELECT count(*) FROM _predictions WHERE used_prediction IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Step 5: the actual numbers that matter.
-- ---------------------------------------------------------------------------

\echo ''
\echo '=== OVERALL ACCURACY (all predictions, hourly-preferred-with-fallback) ==='
SELECT
    count(*) AS n,
    round(avg(abs(actual_seconds - used_prediction))::numeric, 1)  AS mae_seconds,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(actual_seconds - used_prediction))::numeric, 1) AS median_abs_error_s,
    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY abs(actual_seconds - used_prediction))::numeric, 1) AS p90_abs_error_s,
    round((100.0 * count(*) FILTER (WHERE abs(actual_seconds - used_prediction) <= 30) / count(*))::numeric, 1) AS pct_within_30s
FROM _predictions
WHERE used_prediction IS NOT NULL;

\echo ''
\echo '=== ACCURACY BROKEN DOWN BY PREDICTION SOURCE (does hourly actually help?) ==='
SELECT
    prediction_source,
    count(*) AS n,
    round(avg(abs(actual_seconds - used_prediction))::numeric, 1) AS mae_seconds,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(actual_seconds - used_prediction))::numeric, 1) AS median_abs_error_s
FROM _predictions
WHERE used_prediction IS NOT NULL
GROUP BY prediction_source
ORDER BY prediction_source;

\echo ''
\echo '=== BASELINE COMPARISON: what if we had just used the pooled figure always? ==='
SELECT
    count(*) AS n,
    round(avg(abs(actual_seconds - pooled_prediction))::numeric, 1) AS mae_seconds_pooled_only
FROM _predictions
WHERE pooled_prediction IS NOT NULL;

DROP TABLE IF EXISTS _train_segments;
DROP TABLE IF EXISTS _train_stats;
DROP TABLE IF EXISTS _test_segments;
DROP TABLE IF EXISTS _predictions;
