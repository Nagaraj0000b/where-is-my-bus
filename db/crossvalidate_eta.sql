-- One fold of the ETA cross-validation: hold out ONE day, train on the
-- rest, score, and record the result.
--
--   psql -v held_out_day=2026-08-10 -f /db/crossvalidate_eta.sql
--
-- Run once per day by scripts/crossvalidate-eta.sh. Results accumulate in
-- eta_calibration_fold (schema_eta_calibration.sql).
--
-- Everything here is the same method docs/eta-design.md already describes
-- - sum per-hop predictions, hourly figure when it has at least 3 samples
-- behind it, pooled figure otherwise. The only thing that changes between
-- folds is which day is hidden.
--
-- Both mean-based and median-based sums are computed on the SAME journeys
-- so the comparison between them is like for like.
--
-- Idempotent: deletes this day's existing rows before inserting.

\set ON_ERROR_STOP on
\timing off
\pset footer off

SET work_mem = '256MB';

\echo ''
\echo '--- fold: holding out' :held_out_day '---'

-- ---------------------------------------------------------------------------
-- Training hops: every clean consecutive-stop hop EXCEPT the held-out day.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _cv_hops;

CREATE TEMP TABLE _cv_hops AS
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
        WHERE day <> :'held_out_day'
        WINDOW w AS (PARTITION BY vehicle_id, day ORDER BY passage_time)
    ) a
    WHERE prev_seq IS NOT NULL AND route_id = prev_route
      AND stop_sequence = prev_seq + 1
      AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800
) b;

-- ---------------------------------------------------------------------------
-- Per-hop predictions, both mean and median, for every hour.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _cv_pred;

CREATE TEMP TABLE _cv_pred AS
SELECT
    seg.route_id, seg.to_stop_sequence, h.hour_of_day,
    coalesce(CASE WHEN hourly.n >= 3 THEN hourly.mean_s   END, pooled.mean_s)   AS pred_mean,
    coalesce(CASE WHEN hourly.n >= 3 THEN hourly.median_s END, pooled.median_s) AS pred_median
FROM (SELECT DISTINCT route_id, to_stop_sequence FROM _cv_hops) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day, count(*) AS n,
           avg(travel_seconds) AS mean_s,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_s
    FROM _cv_hops GROUP BY route_id, to_stop_sequence, hour_of_day
) hourly ON hourly.route_id = seg.route_id
        AND hourly.to_stop_sequence = seg.to_stop_sequence
        AND hourly.hour_of_day = h.hour_of_day
LEFT JOIN (
    SELECT route_id, to_stop_sequence,
           avg(travel_seconds) AS mean_s,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_s
    FROM _cv_hops GROUP BY route_id, to_stop_sequence
) pooled ON pooled.route_id = seg.route_id
        AND pooled.to_stop_sequence = seg.to_stop_sequence;

CREATE UNIQUE INDEX ON _cv_pred (route_id, to_stop_sequence, hour_of_day);
ANALYZE _cv_pred;

-- ---------------------------------------------------------------------------
-- The held-out day's real journeys (see evaluate_multistop_eta.sql for why
-- the run_key trick is used to guarantee genuinely consecutive stops).
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _cv_runs;

CREATE TEMP TABLE _cv_runs AS
SELECT vehicle_id, route_id, stop_sequence, passage_time,
       row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
         - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _cv_runs (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _cv_runs;

DROP TABLE IF EXISTS _cv_spans;

CREATE TEMP TABLE _cv_spans AS
SELECT a.vehicle_id, a.route_id, a.run_key,
       a.stop_sequence AS start_seq, b.stop_sequence AS end_seq,
       (b.stop_sequence - a.stop_sequence) AS n_hops,
       extract(hour FROM a.passage_time)::int AS start_hour,
       extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
FROM _cv_runs a
JOIN _cv_runs b
  ON b.vehicle_id = a.vehicle_id AND b.route_id = a.route_id
 AND b.run_key = a.run_key
 AND b.stop_sequence - a.stop_sequence IN (1, 5, 10, 20);

CREATE INDEX ON _cv_spans (route_id, start_seq, end_seq, start_hour);
ANALYZE _cv_spans;

-- ---------------------------------------------------------------------------
-- Score, and record.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _cv_scored;

CREATE TEMP TABLE _cv_scored AS
SELECT s.n_hops, s.actual_seconds,
       sum(p.pred_mean)   AS pred_mean_sum,
       sum(p.pred_median) AS pred_median_sum
FROM _cv_spans s
JOIN _cv_pred p
  ON p.route_id = s.route_id AND p.hour_of_day = s.start_hour
 AND p.to_stop_sequence > s.start_seq AND p.to_stop_sequence <= s.end_seq
GROUP BY s.vehicle_id, s.route_id, s.run_key, s.start_seq, s.end_seq,
         s.n_hops, s.actual_seconds
HAVING count(p.pred_mean) = s.n_hops AND count(p.pred_median) = s.n_hops;

DELETE FROM eta_calibration_fold WHERE held_out_day = :'held_out_day';

INSERT INTO eta_calibration_fold
    (held_out_day, n_hops, journeys, avg_actual_s,
     bias_mean_sum_s, bias_median_sum_s, mae_mean_sum_s, mae_median_sum_s,
     p10_resid_s, p25_resid_s, p50_resid_s, p75_resid_s, p90_resid_s)
SELECT
    :'held_out_day'::date,
    n_hops,
    count(*),
    avg(actual_seconds),
    avg(actual_seconds - pred_mean_sum),
    avg(actual_seconds - pred_median_sum),
    avg(abs(actual_seconds - pred_mean_sum)),
    avg(abs(actual_seconds - pred_median_sum)),
    percentile_cont(0.10) WITHIN GROUP (ORDER BY actual_seconds - pred_mean_sum),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY actual_seconds - pred_mean_sum),
    percentile_cont(0.50) WITHIN GROUP (ORDER BY actual_seconds - pred_mean_sum),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY actual_seconds - pred_mean_sum),
    percentile_cont(0.90) WITHIN GROUP (ORDER BY actual_seconds - pred_mean_sum)
FROM _cv_scored
GROUP BY n_hops;

\echo 'fold recorded:'
SELECT n_hops, journeys,
       round(mae_mean_sum_s::numeric, 1)   AS mae_mean,
       round(mae_median_sum_s::numeric, 1) AS mae_median,
       round(bias_mean_sum_s::numeric, 1)  AS bias_mean
FROM eta_calibration_fold
WHERE held_out_day = :'held_out_day'
ORDER BY n_hops;

DROP TABLE IF EXISTS _cv_hops;
DROP TABLE IF EXISTS _cv_pred;
DROP TABLE IF EXISTS _cv_runs;
DROP TABLE IF EXISTS _cv_spans;
DROP TABLE IF EXISTS _cv_scored;
