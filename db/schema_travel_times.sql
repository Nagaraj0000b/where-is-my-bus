-- Historical travel-time statistics per route segment - Phase 3's
-- deliverable and the table the ETA is served from.
--
--   psql -f /db/schema_travel_times.sql
--
-- observed_stop_passage says "bus X passed stop Y at time Z". This answers
-- the useful question: "how long does it usually take to get from stop A
-- to stop B on this route, at this hour, on this kind of day - and how
-- much does that vary?"
--
-- REBUILT 2026-08-19 to add day_type. The original version had no idea
-- whether it was predicting a Tuesday or a Sunday, and 7-fold
-- cross-validation showed that was the single biggest source of error -
-- it under-predicted weekdays by +279s over 20 stops while
-- over-predicting weekends by -527s, two large errors that cancelled into
-- a deceptively healthy-looking average. Splitting by day type cut that
-- bias by 83% and 99% respectively. See docs/eta-design.md section 2.2.
--
-- THREE LEVELS OF DETAIL live in this one table, so a lookup can fall
-- back gracefully when a specific combination has too little data:
--
--   day_type='weekday'|'weekend', hour_of_day=0..23  most specific
--   day_type='weekday'|'weekend', hour_of_day=-1     any hour, right kind of day
--   day_type='any',               hour_of_day=-1     last resort
--
-- Sentinels rather than NULLs (-1 for "any hour", 'any' for "any day")
-- because every part of the primary key has to be NOT NULL in Postgres,
-- so a NULL could not identify a row here. Nothing else can legitimately
-- be -1 or 'any', so they are unambiguous.

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS route_segment_travel_time;

CREATE TABLE route_segment_travel_time (
  route_id          text NOT NULL,
  to_stop_sequence  int  NOT NULL,   -- travel time INTO this stop, from the one before
  from_stop_id      text NOT NULL,
  to_stop_id        text NOT NULL,
  day_type          text NOT NULL,   -- 'weekday' | 'weekend' | 'any'
  hour_of_day       int  NOT NULL,   -- 0-23, or -1 meaning "any hour"
  sample_count      int  NOT NULL,
  mean_seconds      double precision NOT NULL,   -- USE THIS for ETAs (see below)
  median_seconds    double precision NOT NULL,   -- better for a SINGLE hop only
  p25_seconds       double precision NOT NULL,
  p75_seconds       double precision NOT NULL,
  stddev_seconds    double precision,
  PRIMARY KEY (route_id, to_stop_sequence, day_type, hour_of_day),
  CONSTRAINT day_type_known CHECK (day_type IN ('weekday', 'weekend', 'any')),
  CONSTRAINT hour_in_range  CHECK (hour_of_day BETWEEN -1 AND 23)
);

CREATE INDEX IF NOT EXISTS idx_rstt_lookup
  ON route_segment_travel_time (route_id, to_stop_sequence, day_type, hour_of_day);

COMMENT ON COLUMN route_segment_travel_time.mean_seconds IS
  'The one to use when ADDING hops together for an ETA. Expected values add up correctly; medians do not. Summing medians under-predicts because hop times are right-skewed (91% of segments). See docs/eta-design.md section 2.1.';
COMMENT ON COLUMN route_segment_travel_time.median_seconds IS
  'Better than the mean for predicting ONE hop in isolation (50.5s vs 52.9s average error), but wrong to sum. Kept for single-hop questions and for comparison.';
COMMENT ON COLUMN route_segment_travel_time.day_type IS
  'weekday | weekend | any. Weekday and weekend traffic differ enough that mixing them was the largest measured source of ETA error.';
COMMENT ON COLUMN route_segment_travel_time.hour_of_day IS
  '0-23 for a specific hour, or -1 meaning pooled across all hours.';
COMMENT ON COLUMN route_segment_travel_time.sample_count IS
  'How many real bus trips this is based on. The ETA resolver requires at least 3 before trusting a specific cell, and falls back to a coarser one otherwise.';
