-- Does splitting the model by weekday vs weekend fix the bias that
-- cross-validation exposed?
--
--   psql -v held_out_day=2026-08-10 -f /db/crossvalidate_eta_daytype.sql
--
-- WHAT THIS IS TESTING
--
-- The 7-fold cross-validation (scripts/crossvalidate-eta.sh) found the
-- model behaves in opposite directions on weekdays and weekends:
--
--   weekdays  - predicts buses arriving too EARLY  (bias +279s at 20 hops)
--   weekends  - predicts buses arriving too LATE   (bias -527s at 20 hops)
--
-- The cause is contamination: with only 2 weekend days in 7, a model
-- trained on "all other days" is mostly learning weekday traffic, then
-- applying it to a Sunday, when Delhi's roads are plainly not the same.
--
-- So the fix is to stop mixing them. This script predicts each hop from
-- the matching kind of day, and scores it against the existing
-- day-blind method on EXACTLY the same journeys, so the comparison is
-- like for like.
--
-- Fallback chain when data is thin, most specific first:
--   1. this route+stop, this hour, this kind of day   (needs >= 3 samples)
--   2. this route+stop, this kind of day, any hour    (needs >= 3 samples)
--   3. this route+stop, any day, any hour             (last resort)
--
-- HONEST LIMITATION, stated up front: the archive has only two weekend
-- days. Holding one out leaves exactly ONE weekend day to learn from.
-- That is thin, and a weekend result here is much weaker evidence than a
-- weekday one. It is still worth measuring - but it is a reason to be
-- careful, not a reason to trust the number.

\set ON_ERROR_STOP on
\timing off
\pset footer off

SET work_mem = '256MB';

\echo ''
\echo '--- daytype fold: holding out' :held_out_day '---'

-- ---------------------------------------------------------------------------
-- Training hops, now tagged with what kind of day they came from.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _dt_hops;

CREATE TEMP TABLE _dt_hops AS
SELECT route_id, to_stop_sequence, hour_of_day, is_weekend, travel_seconds
FROM (
    SELECT route_id,
           stop_sequence AS to_stop_sequence,
           extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
           extract(hour FROM passage_time AT TIME ZONE 'Asia/Kolkata')::int AS hour_of_day,
           (extract(dow FROM (passage_time AT TIME ZONE 'Asia/Kolkata')::date) IN (0, 6)) AS is_weekend
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
-- Predictions: the new day-type-aware one, and the old day-blind one,
-- side by side in one table so scoring uses identical journeys.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _dt_pred;

CREATE TEMP TABLE _dt_pred AS
SELECT
    seg.route_id, seg.to_stop_sequence, h.hour_of_day, w.is_weekend,
    -- NEW: prefer same-kind-of-day data, degrade gracefully
    coalesce(
        CASE WHEN hd.n >= 3 THEN hd.mean_s END,
        CASE WHEN d.n  >= 3 THEN d.mean_s  END,
        g.mean_s
    ) AS pred_daytype,
    -- OLD: ignores what kind of day it is (the current method)
    coalesce(
        CASE WHEN hg.n >= 3 THEN hg.mean_s END,
        g.mean_s
    ) AS pred_dayblind
FROM (SELECT DISTINCT route_id, to_stop_sequence FROM _dt_hops) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
CROSS JOIN (VALUES (true), (false)) AS w(is_weekend)
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day, is_weekend,
           count(*) AS n, avg(travel_seconds) AS mean_s
    FROM _dt_hops GROUP BY route_id, to_stop_sequence, hour_of_day, is_weekend
) hd ON hd.route_id = seg.route_id AND hd.to_stop_sequence = seg.to_stop_sequence
    AND hd.hour_of_day = h.hour_of_day AND hd.is_weekend = w.is_weekend
LEFT JOIN (
    SELECT route_id, to_stop_sequence, is_weekend,
           count(*) AS n, avg(travel_seconds) AS mean_s
    FROM _dt_hops GROUP BY route_id, to_stop_sequence, is_weekend
) d ON d.route_id = seg.route_id AND d.to_stop_sequence = seg.to_stop_sequence
   AND d.is_weekend = w.is_weekend
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day,
           count(*) AS n, avg(travel_seconds) AS mean_s
    FROM _dt_hops GROUP BY route_id, to_stop_sequence, hour_of_day
) hg ON hg.route_id = seg.route_id AND hg.to_stop_sequence = seg.to_stop_sequence
    AND hg.hour_of_day = h.hour_of_day
LEFT JOIN (
    SELECT route_id, to_stop_sequence, avg(travel_seconds) AS mean_s
    FROM _dt_hops GROUP BY route_id, to_stop_sequence
) g ON g.route_id = seg.route_id AND g.to_stop_sequence = seg.to_stop_sequence;

CREATE UNIQUE INDEX ON _dt_pred (route_id, to_stop_sequence, hour_of_day, is_weekend);
ANALYZE _dt_pred;

-- ---------------------------------------------------------------------------
-- Held-out day's journeys (same run_key method as the other evaluations).
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _dt_runs;

CREATE TEMP TABLE _dt_runs AS
SELECT vehicle_id, route_id, stop_sequence, passage_time,
       row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
         - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _dt_runs (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _dt_runs;

DROP TABLE IF EXISTS _dt_spans;

CREATE TEMP TABLE _dt_spans AS
SELECT a.vehicle_id, a.route_id, a.run_key,
       a.stop_sequence AS start_seq, b.stop_sequence AS end_seq,
       (b.stop_sequence - a.stop_sequence) AS n_hops,
       extract(hour FROM a.passage_time AT TIME ZONE 'Asia/Kolkata')::int AS start_hour,
       (extract(dow FROM (a.passage_time AT TIME ZONE 'Asia/Kolkata')::date) IN (0, 6)) AS is_weekend,
       extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
FROM _dt_runs a
JOIN _dt_runs b
  ON b.vehicle_id = a.vehicle_id AND b.route_id = a.route_id
 AND b.run_key = a.run_key
 AND b.stop_sequence - a.stop_sequence IN (1, 5, 10, 20);

CREATE INDEX ON _dt_spans (route_id, start_seq, end_seq, start_hour, is_weekend);
ANALYZE _dt_spans;

DROP TABLE IF EXISTS _dt_scored;

CREATE TEMP TABLE _dt_scored AS
SELECT s.n_hops, s.actual_seconds,
       sum(p.pred_daytype)  AS pred_daytype_sum,
       sum(p.pred_dayblind) AS pred_dayblind_sum
FROM _dt_spans s
JOIN _dt_pred p
  ON p.route_id = s.route_id AND p.hour_of_day = s.start_hour
 AND p.is_weekend = s.is_weekend
 AND p.to_stop_sequence > s.start_seq AND p.to_stop_sequence <= s.end_seq
GROUP BY s.vehicle_id, s.route_id, s.run_key, s.start_seq, s.end_seq,
         s.n_hops, s.actual_seconds
HAVING count(p.pred_daytype) = s.n_hops AND count(p.pred_dayblind) = s.n_hops;

DELETE FROM eta_daytype_fold WHERE held_out_day = :'held_out_day';

INSERT INTO eta_daytype_fold
    (held_out_day, is_weekend, n_hops, journeys,
     bias_daytype_s, bias_dayblind_s, mae_daytype_s, mae_dayblind_s,
     p10_resid_s, p50_resid_s, p90_resid_s)
SELECT
    :'held_out_day'::date,
    (extract(dow FROM :'held_out_day'::date) IN (0, 6)),
    n_hops,
    count(*),
    avg(actual_seconds - pred_daytype_sum),
    avg(actual_seconds - pred_dayblind_sum),
    avg(abs(actual_seconds - pred_daytype_sum)),
    avg(abs(actual_seconds - pred_dayblind_sum)),
    percentile_cont(0.10) WITHIN GROUP (ORDER BY actual_seconds - pred_daytype_sum),
    percentile_cont(0.50) WITHIN GROUP (ORDER BY actual_seconds - pred_daytype_sum),
    percentile_cont(0.90) WITHIN GROUP (ORDER BY actual_seconds - pred_daytype_sum)
FROM _dt_scored
GROUP BY n_hops;

\echo 'fold recorded (daytype vs dayblind):'
SELECT n_hops, journeys,
       round(mae_daytype_s::numeric,1)  AS mae_new,
       round(mae_dayblind_s::numeric,1) AS mae_old,
       round(bias_daytype_s::numeric,1)  AS bias_new,
       round(bias_dayblind_s::numeric,1) AS bias_old
FROM eta_daytype_fold
WHERE held_out_day = :'held_out_day'
ORDER BY n_hops;

DROP TABLE IF EXISTS _dt_hops;
DROP TABLE IF EXISTS _dt_pred;
DROP TABLE IF EXISTS _dt_runs;
DROP TABLE IF EXISTS _dt_spans;
DROP TABLE IF EXISTS _dt_scored;
