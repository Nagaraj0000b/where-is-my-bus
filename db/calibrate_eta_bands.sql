-- Two measurements the ETA design needs before it can be written honestly.
--
--   psql -f /db/calibrate_eta_bands.sql
--
-- QUESTION 1 - how wide should the confidence band be?
--   The app promises "a range plus the source of the estimate, not a bare
--   number" (AGENTS.md). That range has to come from somewhere. The
--   honest source is the model's own past mistakes: if 80% of real
--   journeys landed within some window of the prediction, that window IS
--   the 80% band. Measured per journey length, since we already know
--   error grows with distance. No bell-curve assumption - the residual
--   distribution is lopsided and assuming symmetry would rebuild the
--   exact optimism bias we just removed.
--
-- QUESTION 2 - does a bus that is ALREADY running late stay late?
--   The whole "live positions fix what history cannot" idea rests on this
--   and it has never been tested here. If a bus's recent lateness
--   predicts its future lateness, live correction works and belongs in
--   the design. If it does not, live data only tells us where the bus is
--   right now, and the design should not pretend otherwise.
--
-- Uses MEAN-based hop predictions throughout, because diagnose_eta_bias.sql
-- established that sums must be built from means, not medians.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

\set held_out_day 2026-08-13

-- ---------------------------------------------------------------------------
-- Training hop statistics (6 days), mean-based, hourly + pooled.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _hops_train;

CREATE TEMP TABLE _hops_train AS
SELECT route_id, to_stop_sequence, hour_of_day, travel_seconds
FROM (
    SELECT route_id,
           stop_sequence AS to_stop_sequence,
           extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
           extract(hour FROM passage_time)::int AS hour_of_day
    FROM (
        SELECT route_id, vehicle_id, day, stop_sequence, passage_time,
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
) b;

DROP TABLE IF EXISTS _hop_pred;

CREATE TEMP TABLE _hop_pred AS
SELECT
    seg.route_id, seg.to_stop_sequence, h.hour_of_day,
    coalesce(
        CASE WHEN hourly.n >= 3 THEN hourly.mean_s END,
        pooled.mean_s
    ) AS pred_seconds
FROM (SELECT DISTINCT route_id, to_stop_sequence FROM _hops_train) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day,
           count(*) AS n, avg(travel_seconds) AS mean_s
    FROM _hops_train GROUP BY route_id, to_stop_sequence, hour_of_day
) hourly ON hourly.route_id = seg.route_id
        AND hourly.to_stop_sequence = seg.to_stop_sequence
        AND hourly.hour_of_day = h.hour_of_day
LEFT JOIN (
    SELECT route_id, to_stop_sequence, avg(travel_seconds) AS mean_s
    FROM _hops_train GROUP BY route_id, to_stop_sequence
) pooled ON pooled.route_id = seg.route_id
        AND pooled.to_stop_sequence = seg.to_stop_sequence;

CREATE UNIQUE INDEX ON _hop_pred (route_id, to_stop_sequence, hour_of_day);
ANALYZE _hop_pred;

-- ---------------------------------------------------------------------------
-- Held-out day, grouped into clean consecutive-stop runs.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _runs;

CREATE TEMP TABLE _runs AS
SELECT vehicle_id, route_id, stop_sequence, passage_time,
       row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
         - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _runs (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _runs;

-- ===========================================================================
-- QUESTION 1: empirical prediction bands per journey length.
-- ===========================================================================

DROP TABLE IF EXISTS _spans;

CREATE TEMP TABLE _spans AS
SELECT a.vehicle_id, a.route_id, a.run_key,
       a.stop_sequence AS start_seq, b.stop_sequence AS end_seq,
       (b.stop_sequence - a.stop_sequence) AS n_hops,
       extract(hour FROM a.passage_time)::int AS start_hour,
       extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
FROM _runs a
JOIN _runs b
  ON b.vehicle_id = a.vehicle_id AND b.route_id = a.route_id
 AND b.run_key = a.run_key
 AND b.stop_sequence - a.stop_sequence IN (1, 3, 5, 10, 20);

CREATE INDEX ON _spans (route_id, start_seq, end_seq, start_hour);
ANALYZE _spans;

DROP TABLE IF EXISTS _resid;

CREATE TEMP TABLE _resid AS
SELECT n_hops, actual_seconds, predicted_seconds,
       (actual_seconds - predicted_seconds) AS residual_s
FROM (
    SELECT s.n_hops, s.actual_seconds, sum(p.pred_seconds) AS predicted_seconds
    FROM _spans s
    JOIN _hop_pred p
      ON p.route_id = s.route_id AND p.hour_of_day = s.start_hour
     AND p.to_stop_sequence > s.start_seq AND p.to_stop_sequence <= s.end_seq
    GROUP BY s.vehicle_id, s.route_id, s.run_key, s.start_seq, s.end_seq,
             s.n_hops, s.actual_seconds
    HAVING count(p.pred_seconds) = s.n_hops
) x;

\echo ''
\echo '=== Q1: EMPIRICAL PREDICTION BANDS (mean-based predictor) ==='
\echo 'residual = actual minus predicted, in seconds. Positive = bus was LATER.'
\echo 'An honest 80% band runs from the p10 column to the p90 column.'
SELECT
    n_hops,
    count(*) AS journeys,
    round(percentile_cont(0.10) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS p10_s,
    round(percentile_cont(0.25) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS p25_s,
    round(percentile_cont(0.50) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS p50_s,
    round(percentile_cont(0.75) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS p75_s,
    round(percentile_cont(0.90) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS p90_s,
    round((percentile_cont(0.90) WITHIN GROUP (ORDER BY residual_s)
         - percentile_cont(0.10) WITHIN GROUP (ORDER BY residual_s))::numeric, 0) AS band_width_s
FROM _resid
GROUP BY n_hops ORDER BY n_hops;

\echo ''
\echo '=== Q1b: is the residual lopsided? (if so, a symmetric +/- band would lie) ==='
SELECT
    n_hops,
    round(percentile_cont(0.50) WITHIN GROUP (ORDER BY residual_s)::numeric, 0) AS median_s,
    round(avg(residual_s)::numeric, 0) AS mean_s,
    round((percentile_cont(0.90) WITHIN GROUP (ORDER BY residual_s)
         - percentile_cont(0.50) WITHIN GROUP (ORDER BY residual_s))::numeric, 0) AS upper_half_s,
    round((percentile_cont(0.50) WITHIN GROUP (ORDER BY residual_s)
         - percentile_cont(0.10) WITHIN GROUP (ORDER BY residual_s))::numeric, 0) AS lower_half_s
FROM _resid
GROUP BY n_hops ORDER BY n_hops;

-- ===========================================================================
-- QUESTION 2: does recent lateness predict future lateness?
--
-- At each point in a run, compare how the bus did over the PREVIOUS 5 hops
-- against how it then does over the NEXT 10 hops. Both measured as
-- "actual minus predicted", so both are in the same units: seconds of
-- lateness beyond what history said.
-- ===========================================================================

DROP TABLE IF EXISTS _obs;

CREATE TEMP TABLE _obs AS
SELECT
    vehicle_id, route_id, run_key, stop_sequence AS here_seq,
    extract(hour FROM passage_time)::int AS here_hour,
    extract(epoch FROM passage_time - LAG(passage_time, 5) OVER w)  AS hist_actual_s,
    extract(epoch FROM LEAD(passage_time, 10) OVER w - passage_time) AS fut_actual_s
FROM _runs
WINDOW w AS (PARTITION BY vehicle_id, route_id, run_key ORDER BY stop_sequence);

DROP TABLE IF EXISTS _persist;

CREATE TEMP TABLE _persist AS
SELECT
    o.hist_actual_s - hp.hist_pred_s AS hist_resid_s,
    o.fut_actual_s  - hp.fut_pred_s  AS fut_resid_s,
    hp.fut_pred_s,
    o.fut_actual_s
FROM _obs o
JOIN LATERAL (
    SELECT
        sum(p.pred_seconds) FILTER (WHERE p.to_stop_sequence <= o.here_seq) AS hist_pred_s,
        sum(p.pred_seconds) FILTER (WHERE p.to_stop_sequence >  o.here_seq) AS fut_pred_s,
        count(*) FILTER (WHERE p.to_stop_sequence <= o.here_seq) AS n_hist,
        count(*) FILTER (WHERE p.to_stop_sequence >  o.here_seq) AS n_fut
    FROM _hop_pred p
    WHERE p.route_id = o.route_id
      AND p.hour_of_day = o.here_hour
      AND p.to_stop_sequence >  o.here_seq - 5
      AND p.to_stop_sequence <= o.here_seq + 10
) hp ON hp.n_hist = 5 AND hp.n_fut = 10
WHERE o.hist_actual_s IS NOT NULL AND o.fut_actual_s IS NOT NULL;

\echo ''
\echo '=== Q2: does being late ALREADY predict being late NEXT? ==='
\echo 'correlation of (lateness over previous 5 hops) with (lateness over next 10 hops).'
\echo 'near 0 = no, live correction would not help. near 1 = yes, delay persists strongly.'
SELECT
    count(*) AS observations,
    round(corr(hist_resid_s, fut_resid_s)::numeric, 3) AS correlation,
    round(regr_slope(fut_resid_s, hist_resid_s)::numeric, 3) AS slope_future_per_past
FROM _persist;

\echo ''
\echo '=== Q2b: does applying a live correction actually reduce error? ==='
\echo 'uncorrected = history-only prediction. corrected = plus a share of observed lateness.'
SELECT
    count(*) AS observations,
    round(avg(abs(fut_resid_s))::numeric, 1)                        AS mae_uncorrected_s,
    round(avg(abs(fut_resid_s - 1.0 * hist_resid_s))::numeric, 1)   AS mae_corr_1x_s,
    round(avg(abs(fut_resid_s - 2.0 * hist_resid_s))::numeric, 1)   AS mae_corr_2x_s,
    round(avg(abs(fut_resid_s - 0.5 * hist_resid_s))::numeric, 1)   AS mae_corr_half_s
FROM _persist;

\echo ''
\echo '=== Q2c: bias before and after the best correction ==='
SELECT
    round(avg(fut_resid_s)::numeric, 1)                      AS bias_uncorrected_s,
    round(avg(fut_resid_s - 1.0 * hist_resid_s)::numeric, 1) AS bias_corr_1x_s,
    round(avg(fut_resid_s - 2.0 * hist_resid_s)::numeric, 1) AS bias_corr_2x_s
FROM _persist;

DROP TABLE IF EXISTS _hops_train;
DROP TABLE IF EXISTS _hop_pred;
DROP TABLE IF EXISTS _runs;
DROP TABLE IF EXISTS _spans;
DROP TABLE IF EXISTS _resid;
DROP TABLE IF EXISTS _obs;
DROP TABLE IF EXISTS _persist;
