-- The evaluation that actually matters for the app: multi-stop ETA error.
--
--   psql -f /db/evaluate_multistop_eta.sql
--
-- WHY THIS EXISTS, given evaluate_travel_time_predictions.sql already ran
--
-- That script measured how well we predict ONE hop (stop A to the very
-- next stop B). Median error 16.5s, which sounds good. But no commuter
-- ever asks "how long is one hop" - they ask "when does the bus get to
-- MY stop", which is 5, 10, sometimes 20 hops away. That answer is a SUM
-- of hop predictions, and sums behave differently from their parts:
--
--   - If each hop's error is independent and random, errors partly cancel
--     and total error grows slowly (roughly with the square root of the
--     number of hops).
--   - If errors are correlated - which is exactly what traffic does, since
--     a jam slows an entire corridor at once, not one hop - errors stack
--     and total error grows in proportion to the number of hops.
--
-- Those two cases give very different answers for a 10-stop ETA, and
-- guessing which one applies would be exactly the kind of assumption this
-- project keeps getting burned by. So: measure it.
--
-- Same held-out-day method as before: train on 6 days, test against real
-- journeys on the 7th day that the model never saw. Self-contained - it
-- rebuilds its own training stats and does not read or write the
-- production route_segment_travel_time table.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

\set held_out_day 2026-08-13

-- ---------------------------------------------------------------------------
-- Step 1: training stats from the 6 non-held-out days (same as before).
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _train_stats;

CREATE TEMP TABLE _train_stats AS
SELECT
    route_id,
    to_stop_sequence,
    coalesce(hour_of_day, -1) AS hour_of_day,
    count(*) AS sample_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_seconds
FROM (
    SELECT
        route_id,
        stop_sequence AS to_stop_sequence,
        extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
        extract(hour FROM passage_time)::int AS hour_of_day
    FROM (
        SELECT route_id, vehicle_id, stop_sequence, passage_time,
               LAG(stop_sequence) OVER w AS prev_seq,
               LAG(passage_time)  OVER w AS prev_passage_time,
               LAG(route_id)      OVER w AS prev_route
        FROM observed_stop_passage
        WHERE day != :'held_out_day'
        WINDOW w AS (PARTITION BY vehicle_id, day ORDER BY passage_time)
    ) a
    WHERE prev_seq IS NOT NULL AND route_id = prev_route
      AND stop_sequence = prev_seq + 1
      AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800
) b
GROUP BY GROUPING SETS (
    (route_id, to_stop_sequence, hour_of_day),
    (route_id, to_stop_sequence)
);

CREATE UNIQUE INDEX ON _train_stats (route_id, to_stop_sequence, hour_of_day);
ANALYZE _train_stats;

-- ---------------------------------------------------------------------------
-- Step 2: resolve one prediction per (segment, hour), using the same
-- hourly-preferred-with-pooled-fallback rule the real system would use.
-- Materialised for all 24 hours so the span sums below are a plain join.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _hop_pred;

CREATE TEMP TABLE _hop_pred AS
SELECT
    seg.route_id,
    seg.to_stop_sequence,
    h.hour_of_day,
    coalesce(
        CASE WHEN hourly.sample_count >= 3 THEN hourly.median_seconds END,
        pooled.median_seconds
    ) AS pred_seconds
FROM (SELECT route_id, to_stop_sequence FROM _train_stats WHERE hour_of_day = -1) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
LEFT JOIN _train_stats hourly
       ON hourly.route_id = seg.route_id
      AND hourly.to_stop_sequence = seg.to_stop_sequence
      AND hourly.hour_of_day = h.hour_of_day
LEFT JOIN _train_stats pooled
       ON pooled.route_id = seg.route_id
      AND pooled.to_stop_sequence = seg.to_stop_sequence
      AND pooled.hour_of_day = -1;

CREATE UNIQUE INDEX ON _hop_pred (route_id, to_stop_sequence, hour_of_day);
ANALYZE _hop_pred;

-- ---------------------------------------------------------------------------
-- Step 3: the held-out day's real journeys, grouped into runs of genuinely
-- consecutive stops.
--
-- run_key trick: within one vehicle's ordered passages, subtracting
-- stop_sequence from the row number gives a value that stays CONSTANT
-- exactly while stops advance one at a time, and changes the moment there
-- is a gap, a lap restart, or any jump. Grouping by it therefore gives
-- maximal stretches of clean consecutive stops - which is what a real
-- multi-stop journey is - without trusting sequence arithmetic alone.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _runs;

CREATE TEMP TABLE _runs AS
SELECT
    vehicle_id, route_id, stop_sequence, passage_time,
    row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
      - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _runs (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _runs;

-- ---------------------------------------------------------------------------
-- Step 4: build journeys of several lengths at once (1, 3, 5, 10 and 20
-- stops ahead), by pairing each stop with a later stop inside the same
-- clean run.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _spans;

CREATE TEMP TABLE _spans AS
SELECT
    a.vehicle_id,
    a.route_id,
    a.run_key,   -- carried through so two laps of the same route on the
                 -- same day stay separate journeys rather than collapsing
                 -- into one group later (which would silently drop both)
    a.stop_sequence                                   AS start_seq,
    b.stop_sequence                                   AS end_seq,
    (b.stop_sequence - a.stop_sequence)               AS n_hops,
    extract(hour FROM a.passage_time)::int            AS start_hour,
    extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
FROM _runs a
JOIN _runs b
  ON  b.vehicle_id = a.vehicle_id
  AND b.route_id   = a.route_id
  AND b.run_key    = a.run_key
  AND b.stop_sequence - a.stop_sequence IN (1, 3, 5, 10, 20);

CREATE INDEX ON _spans (route_id, start_seq, end_seq, start_hour);
ANALYZE _spans;

\echo ''
\echo 'held-out-day journeys built, by length:'
SELECT n_hops, count(*) AS journeys FROM _spans GROUP BY n_hops ORDER BY n_hops;

-- ---------------------------------------------------------------------------
-- Step 5: predict each journey by summing its hop predictions.
--
-- The hour used is the hour the journey STARTS - that is what a real
-- system would actually know at prediction time. It does not get to peek
-- at what hour the bus will arrive.
--
-- Only journeys where EVERY hop has a prediction are scored (the HAVING
-- clause) - a partial sum would silently under-predict and quietly
-- flatter the result.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _scored;

CREATE TEMP TABLE _scored AS
SELECT
    s.n_hops,
    s.actual_seconds,
    sum(p.pred_seconds) AS predicted_seconds
FROM _spans s
JOIN _hop_pred p
  ON  p.route_id         = s.route_id
  AND p.hour_of_day      = s.start_hour
  AND p.to_stop_sequence >  s.start_seq
  AND p.to_stop_sequence <= s.end_seq
GROUP BY s.vehicle_id, s.route_id, s.run_key, s.start_seq, s.end_seq,
         s.n_hops, s.actual_seconds
HAVING count(p.pred_seconds) = s.n_hops;

\echo ''
\echo '=== THE NUMBER THAT MATTERS: multi-stop ETA error by journey length ==='
\echo '(if errors CANCEL, error grows ~sqrt(n_hops); if they COMPOUND, ~n_hops)'
SELECT
    n_hops,
    count(*) AS journeys,
    round(avg(actual_seconds)::numeric, 0)                AS avg_actual_s,
    round(avg(abs(actual_seconds - predicted_seconds))::numeric, 1) AS mae_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(actual_seconds - predicted_seconds))::numeric, 1) AS median_err_s,
    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY abs(actual_seconds - predicted_seconds))::numeric, 1) AS p90_err_s,
    round((100.0 * count(*) FILTER (WHERE abs(actual_seconds - predicted_seconds) <= 60) / count(*))::numeric, 1) AS pct_within_60s,
    round((100.0 * count(*) FILTER (WHERE abs(actual_seconds - predicted_seconds) <= 120) / count(*))::numeric, 1) AS pct_within_2min
FROM _scored
GROUP BY n_hops
ORDER BY n_hops;

\echo ''
\echo '=== BIAS CHECK: are we systematically early or late? ==='
\echo '(mean signed error - near zero means no systematic lean;'
\echo ' positive means the bus took LONGER than predicted)'
SELECT
    n_hops,
    round(avg(actual_seconds - predicted_seconds)::numeric, 1) AS mean_signed_err_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY actual_seconds - predicted_seconds)::numeric, 1) AS median_signed_err_s
FROM _scored
GROUP BY n_hops
ORDER BY n_hops;

\echo ''
\echo '=== ERROR AS A SHARE OF JOURNEY LENGTH (is a long ETA proportionally better or worse?) ==='
SELECT
    n_hops,
    round((100.0 * avg(abs(actual_seconds - predicted_seconds)) / avg(actual_seconds))::numeric, 1) AS mae_pct_of_journey
FROM _scored
GROUP BY n_hops
ORDER BY n_hops;

DROP TABLE IF EXISTS _train_stats;
DROP TABLE IF EXISTS _hop_pred;
DROP TABLE IF EXISTS _runs;
DROP TABLE IF EXISTS _spans;
DROP TABLE IF EXISTS _scored;
