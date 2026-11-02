-- Why does the multi-stop ETA come out systematically optimistic?
--
--   psql -f /db/diagnose_eta_bias.sql
--
-- evaluate_multistop_eta.sql found that summing per-hop MEDIAN travel
-- times under-predicts real journeys, and that the gap grows with
-- distance (+30s over 1 hop, +505s over 20 hops). Before assuming why,
-- this checks the two candidate explanations against each other:
--
--   THEORY A - "the held-out day was just slow."
--     If Thursday Aug 13 had worse traffic than the six training days,
--     any model trained on those days would under-predict it, and the
--     method itself would be fine.
--
--   THEORY B - "sum of medians is not the median of the sum."
--     Hop times are right-skewed: a bus is occasionally very late, never
--     very early. That pulls each hop's mean above its median. Summing
--     medians therefore stacks many small under-estimates into one big
--     one, and the effect grows with the number of hops - which matches
--     the shape of what we measured.
--
-- These predict different things, so they can be told apart:
--   - Under A, the whole day is slow, so a mean-based sum would be too
--     low as well, and the per-hop bias would show up on day 13 versus
--     the training days directly.
--   - Under B, swapping median for mean should shrink the bias sharply,
--     because the mean already contains the tail the median throws away.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

\set held_out_day 2026-08-13

-- ---------------------------------------------------------------------------
-- Every clean consecutive-stop hop, all 7 days, tagged train vs test.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _all_hops;

CREATE TEMP TABLE _all_hops AS
SELECT
    route_id, to_stop_sequence, hour_of_day, travel_seconds,
    (day = :'held_out_day') AS is_test_day
FROM (
    SELECT
        route_id, day,
        stop_sequence AS to_stop_sequence,
        extract(epoch FROM passage_time - prev_passage_time) AS travel_seconds,
        extract(hour FROM passage_time)::int AS hour_of_day
    FROM (
        SELECT route_id, vehicle_id, day, stop_sequence, passage_time,
               LAG(stop_sequence) OVER w AS prev_seq,
               LAG(passage_time)  OVER w AS prev_passage_time,
               LAG(route_id)      OVER w AS prev_route
        FROM observed_stop_passage
        WINDOW w AS (PARTITION BY vehicle_id, day ORDER BY passage_time)
    ) a
    WHERE prev_seq IS NOT NULL AND route_id = prev_route
      AND stop_sequence = prev_seq + 1
      AND extract(epoch FROM passage_time - prev_passage_time) BETWEEN 1 AND 1800
) b;

CREATE INDEX ON _all_hops (route_id, to_stop_sequence, hour_of_day);
ANALYZE _all_hops;

-- ---------------------------------------------------------------------------
-- TEST OF THEORY A: was the held-out day actually slower than the rest?
-- ---------------------------------------------------------------------------

\echo ''
\echo '=== THEORY A CHECK: was the held-out day slower than the training days? ==='
SELECT
    CASE WHEN is_test_day THEN 'held-out day (Thu Aug 13)' ELSE 'training days (other 6)' END AS which_days,
    count(*) AS hops,
    round(avg(travel_seconds)::numeric, 1) AS mean_hop_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds)::numeric, 1) AS median_hop_s
FROM _all_hops
GROUP BY is_test_day
ORDER BY is_test_day;

-- ---------------------------------------------------------------------------
-- TEST OF THEORY B: how right-skewed is a typical hop? If the mean sits
-- well above the median, summing medians must under-predict.
-- ---------------------------------------------------------------------------

\echo ''
\echo '=== THEORY B CHECK: are hop times right-skewed (mean above median)? ==='
\echo '(per route segment, on the TRAINING days only - the data the model sees)'
SELECT
    count(*) AS segments,
    round(avg(mean_s - median_s)::numeric, 2)   AS avg_mean_minus_median_s,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY mean_s - median_s)::numeric, 2) AS median_mean_minus_median_s,
    count(*) FILTER (WHERE mean_s > median_s)   AS segments_right_skewed,
    count(*) FILTER (WHERE mean_s < median_s)   AS segments_left_skewed,
    round((100.0 * count(*) FILTER (WHERE mean_s > median_s) / count(*))::numeric, 1) AS pct_right_skewed
FROM (
    SELECT
        route_id, to_stop_sequence,
        avg(travel_seconds) AS mean_s,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_s
    FROM _all_hops
    WHERE NOT is_test_day
    GROUP BY route_id, to_stop_sequence
) per_segment;

-- ---------------------------------------------------------------------------
-- THE DECIDING TEST: rebuild the multi-stop evaluation, but score
-- median-sum and mean-sum side by side on the exact same journeys.
--
-- If mean-sum removes most of the bias, Theory B is the explanation and
-- the fix is simply "don't sum medians."
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _pred_both;

CREATE TEMP TABLE _pred_both AS
SELECT
    seg.route_id, seg.to_stop_sequence, h.hour_of_day,
    coalesce(
        CASE WHEN hourly.n >= 3 THEN hourly.median_s END, pooled.median_s
    ) AS pred_median,
    coalesce(
        CASE WHEN hourly.n >= 3 THEN hourly.mean_s   END, pooled.mean_s
    ) AS pred_mean
FROM (SELECT DISTINCT route_id, to_stop_sequence FROM _all_hops WHERE NOT is_test_day) seg
CROSS JOIN generate_series(0, 23) AS h(hour_of_day)
LEFT JOIN (
    SELECT route_id, to_stop_sequence, hour_of_day, count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_s,
           avg(travel_seconds) AS mean_s
    FROM _all_hops WHERE NOT is_test_day
    GROUP BY route_id, to_stop_sequence, hour_of_day
) hourly ON hourly.route_id = seg.route_id
        AND hourly.to_stop_sequence = seg.to_stop_sequence
        AND hourly.hour_of_day = h.hour_of_day
LEFT JOIN (
    SELECT route_id, to_stop_sequence, count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY travel_seconds) AS median_s,
           avg(travel_seconds) AS mean_s
    FROM _all_hops WHERE NOT is_test_day
    GROUP BY route_id, to_stop_sequence
) pooled ON pooled.route_id = seg.route_id
        AND pooled.to_stop_sequence = seg.to_stop_sequence;

CREATE UNIQUE INDEX ON _pred_both (route_id, to_stop_sequence, hour_of_day);
ANALYZE _pred_both;

DROP TABLE IF EXISTS _runs2;

CREATE TEMP TABLE _runs2 AS
SELECT vehicle_id, route_id, stop_sequence, passage_time,
       row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
         - stop_sequence AS run_key
FROM observed_stop_passage
WHERE day = :'held_out_day';

CREATE INDEX ON _runs2 (vehicle_id, route_id, run_key, stop_sequence);
ANALYZE _runs2;

DROP TABLE IF EXISTS _spans2;

CREATE TEMP TABLE _spans2 AS
SELECT a.vehicle_id, a.route_id, a.run_key,
       a.stop_sequence AS start_seq, b.stop_sequence AS end_seq,
       (b.stop_sequence - a.stop_sequence) AS n_hops,
       extract(hour FROM a.passage_time)::int AS start_hour,
       extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
FROM _runs2 a
JOIN _runs2 b
  ON b.vehicle_id = a.vehicle_id AND b.route_id = a.route_id
 AND b.run_key = a.run_key
 AND b.stop_sequence - a.stop_sequence IN (1, 5, 10, 20);

CREATE INDEX ON _spans2 (route_id, start_seq, end_seq, start_hour);
ANALYZE _spans2;

\echo ''
\echo '=== DECIDING TEST: median-sum vs mean-sum, same journeys, same day ==='
SELECT
    n_hops,
    count(*) AS journeys,
    round(avg(actual_seconds - pred_median_sum)::numeric, 1) AS median_sum_bias_s,
    round(avg(actual_seconds - pred_mean_sum)::numeric, 1)   AS mean_sum_bias_s,
    round(avg(abs(actual_seconds - pred_median_sum))::numeric, 1) AS median_sum_mae_s,
    round(avg(abs(actual_seconds - pred_mean_sum))::numeric, 1)   AS mean_sum_mae_s
FROM (
    SELECT s.n_hops, s.actual_seconds,
           sum(p.pred_median) AS pred_median_sum,
           sum(p.pred_mean)   AS pred_mean_sum
    FROM _spans2 s
    JOIN _pred_both p
      ON p.route_id = s.route_id AND p.hour_of_day = s.start_hour
     AND p.to_stop_sequence > s.start_seq AND p.to_stop_sequence <= s.end_seq
    GROUP BY s.vehicle_id, s.route_id, s.run_key, s.start_seq, s.end_seq,
             s.n_hops, s.actual_seconds
    HAVING count(p.pred_median) = s.n_hops AND count(p.pred_mean) = s.n_hops
) scored
GROUP BY n_hops
ORDER BY n_hops;

DROP TABLE IF EXISTS _all_hops;
DROP TABLE IF EXISTS _pred_both;
DROP TABLE IF EXISTS _runs2;
DROP TABLE IF EXISTS _spans2;
