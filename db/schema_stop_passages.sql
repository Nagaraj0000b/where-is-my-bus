-- Where the "when did each bus actually pass each stop" results live.
--
--   psql -f /db/schema_stop_passages.sql
--
-- Each row is one bus passing one stop, with the timestamp worked out by
-- linear interpolation between the two GPS readings that bracket the
-- stop's position along the route. This table accumulates across days
-- and survives the daily TRUNCATE of vehicle_position / vehicle_progress.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS observed_stop_passage (
  id                  serial PRIMARY KEY,
  day                 date NOT NULL,
  route_id            text NOT NULL,
  vehicle_id          text NOT NULL,
  trip_id             text NOT NULL,
  stop_id             text NOT NULL,
  stop_sequence       int NOT NULL,
  dist_along_route_m  double precision NOT NULL,
  passage_time        timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_osp_day
  ON observed_stop_passage (day);

CREATE INDEX IF NOT EXISTS idx_osp_route_stop
  ON observed_stop_passage (route_id, stop_id);

CREATE INDEX IF NOT EXISTS idx_osp_vehicle_day
  ON observed_stop_passage (vehicle_id, day);
