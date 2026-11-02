-- Results table for the ETA cross-validation.
--
--   psql -f /db/schema_eta_calibration.sql
--
-- One row per (held-out day, journey length). Seven days rotated through
-- as the held-out day gives seven independent read-outs of the same
-- question, instead of the single-day calibration that docs/eta-design.md
-- currently rests on.
--
-- Both the mean-based and median-based summing methods are recorded side
-- by side on every fold, so "sum means, not medians" can be checked as a
-- finding that holds generally rather than one that happened to hold on
-- Thursday.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS eta_calibration_fold (
  held_out_day       date   NOT NULL,
  n_hops             int    NOT NULL,
  journeys           bigint NOT NULL,
  avg_actual_s       double precision,

  -- how far off, on average, in each direction (positive = bus was LATER
  -- than predicted). This is the optimism bias.
  bias_mean_sum_s    double precision,
  bias_median_sum_s  double precision,

  -- how far off regardless of direction
  mae_mean_sum_s     double precision,
  mae_median_sum_s   double precision,

  -- residual spread for the mean-based predictor - this is what the
  -- confidence band in docs/eta-design.md is built from
  p10_resid_s        double precision,
  p25_resid_s        double precision,
  p50_resid_s        double precision,
  p75_resid_s        double precision,
  p90_resid_s        double precision,

  PRIMARY KEY (held_out_day, n_hops)
);

COMMENT ON TABLE eta_calibration_fold IS
  'Cross-validation results: each row is one held-out day at one journey length. Built by db/crossvalidate_eta.sql, one fold per run.';
