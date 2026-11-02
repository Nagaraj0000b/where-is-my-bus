#!/bin/bash
# Cross-validate the ETA method across all 7 recorded days.
#
# docs/eta-design.md is currently calibrated on ONE held-out day
# (Thursday 2026-08-13), and that day happened to run about 8% slower
# than the others. So its numbers could be a property of that day rather
# than of the method. This rotates the held-out day through all seven and
# records each result, which answers three questions the design leaves
# open:
#
#   1. Does "sum means, not medians" hold on every day, or only Thursday?
#   2. Are the confidence bands stable day to day, or was Thursday wide?
#   3. What is the honest average performance, across days?
#
# Each fold is independent and idempotent - re-running replaces that day's
# row rather than duplicating it - so this is safe to interrupt and resume.

set -e
cd "$(dirname "$0")/.."

DAYS=(2026-08-10 2026-08-11 2026-08-12 2026-08-13 2026-08-14 2026-08-15 2026-08-16)
LOG="scripts/crossvalidate-eta.log"

exec > >(tee -a "$LOG") 2>&1

echo ""
echo "========================================================================"
echo "=== $(date) : ETA CROSS-VALIDATION, 7 FOLDS ==="
echo "========================================================================"

echo "--- creating results table if needed ---"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb \
  -f /db/schema_eta_calibration.sql

for DAY in "${DAYS[@]}"; do
    echo ""
    echo "=== $(date) : fold - holding out $DAY ==="
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb \
      -v held_out_day="$DAY" -f /db/crossvalidate_eta.sql
done

echo ""
echo "========================================================================"
echo "=== $(date) : ALL FOLDS DONE - SUMMARY ==="
echo "========================================================================"

echo ""
echo "--- Q1: does 'sum means, not medians' hold on EVERY day? ---"
echo "(mae_mean should be LOWER than mae_median at 5+ hops, on every row)"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT held_out_day, to_char(held_out_day,'Dy') AS dow, n_hops,
       round(mae_mean_sum_s::numeric,1)   AS mae_mean,
       round(mae_median_sum_s::numeric,1) AS mae_median,
       CASE WHEN mae_mean_sum_s < mae_median_sum_s THEN 'mean wins'
            ELSE 'median wins' END AS verdict
FROM eta_calibration_fold
WHERE n_hops IN (1, 10)
ORDER BY n_hops, held_out_day;"

echo ""
echo "--- Q2: how stable are the confidence bands across days? ---"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT n_hops,
       count(*) AS folds,
       round(avg(p10_resid_s)::numeric,0) AS avg_p10,
       round(min(p10_resid_s)::numeric,0) AS min_p10,
       round(max(p10_resid_s)::numeric,0) AS max_p10,
       round(avg(p90_resid_s)::numeric,0) AS avg_p90,
       round(min(p90_resid_s)::numeric,0) AS min_p90,
       round(max(p90_resid_s)::numeric,0) AS max_p90
FROM eta_calibration_fold
GROUP BY n_hops ORDER BY n_hops;"

echo ""
echo "--- Q3: honest average performance across all 7 days ---"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT n_hops,
       sum(journeys) AS total_journeys,
       round(avg(avg_actual_s)::numeric,0)     AS avg_journey_s,
       round(avg(mae_mean_sum_s)::numeric,1)   AS avg_mae_s,
       round(avg(bias_mean_sum_s)::numeric,1)  AS avg_bias_s,
       round(min(bias_mean_sum_s)::numeric,1)  AS best_day_bias_s,
       round(max(bias_mean_sum_s)::numeric,1)  AS worst_day_bias_s
FROM eta_calibration_fold
GROUP BY n_hops ORDER BY n_hops;"

echo ""
echo "--- was the original held-out day (Thu Aug 13) unrepresentative? ---"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT n_hops,
       round(avg(mae_mean_sum_s) FILTER (WHERE held_out_day =  '2026-08-13')::numeric,1) AS thursday_mae,
       round(avg(mae_mean_sum_s) FILTER (WHERE held_out_day <> '2026-08-13')::numeric,1) AS other_days_mae,
       round(avg(bias_mean_sum_s) FILTER (WHERE held_out_day =  '2026-08-13')::numeric,1) AS thursday_bias,
       round(avg(bias_mean_sum_s) FILTER (WHERE held_out_day <> '2026-08-13')::numeric,1) AS other_days_bias
FROM eta_calibration_fold
GROUP BY n_hops ORDER BY n_hops;"

echo ""
echo "=== $(date) : CROSS-VALIDATION FINISHED ==="
