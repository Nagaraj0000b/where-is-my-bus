-- Follow-up to calibrate_eta_bands.sql, in fairness to the idea it
-- appeared to kill.
--
--   psql -f /db/calibrate_live_correction.sql
--
-- That script tested whether a bus already running late keeps running
-- late, and found the link is very weak (correlation 0.079). It then
-- tested corrections of 0.5x, 1x and 2x the observed lateness, and all
-- three made the prediction WORSE.
--
-- But those were all far more aggressive than the data supports. The
-- measured regression slope was 0.115, meaning the statistically best
-- correction is about a ninth of the observed lateness - gentler than
-- anything tested. Dismissing live correction without testing near its
-- own optimum would be unfair to it, and exactly the kind of shortcut
-- this project has been bitten by before.
--
-- This also tests a longer history window (10 hops instead of 5), on the
-- theory that 5 hops may simply be too short to tell a genuinely delayed
-- bus apart from ordinary noise.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

\set held_out_day 2026-08-13

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
    coalesce(CASE WHEN hourly.n >= 3 THEN hourly.mean_s END, pooled.mean_s) AS pred_seconds
FROM (SELECT DISTINCT route_id, to_stop_sequence FROM _hops_train) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day, count(*) AS n, avg(travel_seconds) AS mean_s
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

DROP TABLE IF EXISTS _runs;

CREATE TEMP TABLE _runs AS
SELECT vehicle_id, route_id, stop_sequence, passage_time,
       row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
         - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _runs (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _runs;

-- ---------------------------------------------------------------------------
-- Same setup as before, but keeping BOTH a 5-hop and a 10-hop history
-- window so the two can be compared directly.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _obs;

CREATE TEMP TABLE _obs AS
SELECT
    vehicle_id, route_id, run_key, stop_sequence AS here_seq,
    extract(hour FROM passage_time)::int AS here_hour,
    extract(epoch FROM passage_time - LAG(passage_time, 5)  OVER w) AS hist5_actual_s,
    extract(epoch FROM passage_time - LAG(passage_time, 10) OVER w) AS hist10_actual_s,
    extract(epoch FROM LEAD(passage_time, 10) OVER w - passage_time) AS fut_actual_s
FROM _runs
WINDOW w AS (PARTITION BY vehicle_id, route_id, run_key ORDER BY stop_sequence);

DROP TABLE IF EXISTS _p;

CREATE TEMP TABLE _p AS
SELECT
    o.hist5_actual_s  - hp.hist5_pred_s  AS hist5_resid_s,
    o.hist10_actual_s - hp.hist10_pred_s AS hist10_resid_s,
    o.fut_actual_s    - hp.fut_pred_s    AS fut_resid_s
FROM _obs o
JOIN LATERAL (
    SELECT
        sum(p.pred_seconds) FILTER (WHERE p.to_stop_sequence >  o.here_seq - 5
                                      AND p.to_stop_sequence <= o.here_seq) AS hist5_pred_s,
        sum(p.pred_seconds) FILTER (WHERE p.to_stop_sequence <= o.here_seq) AS hist10_pred_s,
        sum(p.pred_seconds) FILTER (WHERE p.to_stop_sequence >  o.here_seq) AS fut_pred_s,
        count(*) FILTER (WHERE p.to_stop_sequence >  o.here_seq - 5
                           AND p.to_stop_sequence <= o.here_seq) AS n_hist5,
        count(*) FILTER (WHERE p.to_stop_sequence <= o.here_seq) AS n_hist10,
        count(*) FILTER (WHERE p.to_stop_sequence >  o.here_seq) AS n_fut
    FROM _hop_pred p
    WHERE p.route_id = o.route_id
      AND p.hour_of_day = o.here_hour
      AND p.to_stop_sequence >  o.here_seq - 10
      AND p.to_stop_sequence <= o.here_seq + 10
) hp ON hp.n_hist5 = 5 AND hp.n_hist10 = 10 AND hp.n_fut = 10
WHERE o.hist5_actual_s IS NOT NULL
  AND o.hist10_actual_s IS NOT NULL
  AND o.fut_actual_s IS NOT NULL;

\echo ''
\echo '=== how strong is the signal, for each history window? ==='
SELECT
    count(*) AS observations,
    round(corr(hist5_resid_s,  fut_resid_s)::numeric, 3) AS corr_5hop_history,
    round(corr(hist10_resid_s, fut_resid_s)::numeric, 3) AS corr_10hop_history,
    round(regr_slope(fut_resid_s, hist5_resid_s)::numeric, 3)  AS best_coef_5hop,
    round(regr_slope(fut_resid_s, hist10_resid_s)::numeric, 3) AS best_coef_10hop
FROM _p;

\echo ''
\echo '=== GENTLE corrections, near the statistically optimal coefficient ==='
\echo '(5-hop history. uncorrected is the baseline to beat.)'
SELECT
    round(avg(abs(fut_resid_s))::numeric, 2)                       AS mae_uncorrected,
    round(avg(abs(fut_resid_s - 0.05 * hist5_resid_s))::numeric, 2) AS mae_coef_0_05,
    round(avg(abs(fut_resid_s - 0.10 * hist5_resid_s))::numeric, 2) AS mae_coef_0_10,
    round(avg(abs(fut_resid_s - 0.115 * hist5_resid_s))::numeric, 2) AS mae_coef_0_115,
    round(avg(abs(fut_resid_s - 0.20 * hist5_resid_s))::numeric, 2) AS mae_coef_0_20,
    round(avg(abs(fut_resid_s - 0.30 * hist5_resid_s))::numeric, 2) AS mae_coef_0_30
FROM _p;

\echo ''
\echo '=== same sweep using the LONGER 10-hop history window ==='
SELECT
    round(avg(abs(fut_resid_s))::numeric, 2)                        AS mae_uncorrected,
    round(avg(abs(fut_resid_s - 0.05 * hist10_resid_s))::numeric, 2) AS mae_coef_0_05,
    round(avg(abs(fut_resid_s - 0.10 * hist10_resid_s))::numeric, 2) AS mae_coef_0_10,
    round(avg(abs(fut_resid_s - 0.20 * hist10_resid_s))::numeric, 2) AS mae_coef_0_20,
    round(avg(abs(fut_resid_s - 0.30 * hist10_resid_s))::numeric, 2) AS mae_coef_0_30
FROM _p;

\echo ''
\echo '=== what the correction does to BIAS (the thing it genuinely fixes) ==='
SELECT
    round(avg(fut_resid_s)::numeric, 1)                         AS bias_uncorrected,
    round(avg(fut_resid_s - 0.115 * hist5_resid_s)::numeric, 1) AS bias_coef_0_115,
    round(avg(fut_resid_s - 0.30 * hist5_resid_s)::numeric, 1)  AS bias_coef_0_30,
    round(avg(fut_resid_s - 1.00 * hist5_resid_s)::numeric, 1)  AS bias_coef_1_0
FROM _p;

DROP TABLE IF EXISTS _hops_train;
DROP TABLE IF EXISTS _hop_pred;
DROP TABLE IF EXISTS _runs;
DROP TABLE IF EXISTS _obs;
DROP TABLE IF EXISTS _p;
