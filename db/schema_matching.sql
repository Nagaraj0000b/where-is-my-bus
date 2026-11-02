-- Where the "how far along its route is this bus, right now" work lives.
--
--   psql -f /db/schema_matching.sql
--
-- This is a separate table from vehicle_position on purpose. vehicle_position
-- is exactly what the feed sent us - the loader's one job. This table is what
-- WE worked out from that - a different job, so it gets its own table instead
-- of extra columns bolted onto vehicle_position.
--
-- Two numbers are calculated per bus sighting:
--   raw_dist_along_route_m       - straight "closest point on the line" answer,
--                                   no memory of anything earlier. Can be wrong
--                                   for a single bad GPS reading.
--   accepted_dist_along_route_m  - the number we actually trust: if a reading
--                                   would mean the bus travelled faster than
--                                   any real bus can, or jumped backward more
--                                   than normal GPS wobble, we ignore it and
--                                   keep showing the last trusted position
--                                   instead. See tools/match-vehicle-progress.js
--                                   for exactly how that decision is made.

CREATE TABLE IF NOT EXISTS vehicle_progress (
  frame_id                     integer NOT NULL,
  vehicle_id                   text    NOT NULL,
  raw_dist_along_route_m       double precision,
  accepted_dist_along_route_m  double precision,
  accepted                     boolean,
  reject_reason                text,
  PRIMARY KEY (frame_id, vehicle_id),
  FOREIGN KEY (frame_id, vehicle_id)
    REFERENCES vehicle_position (frame_id, vehicle_id) ON DELETE CASCADE
);

COMMENT ON COLUMN vehicle_progress.raw_dist_along_route_m IS
  'Closest-point-on-the-line answer for this one reading, no memory of earlier readings. Filled in bulk by db/compute_vehicle_raw_progress.sql.';
COMMENT ON COLUMN vehicle_progress.accepted_dist_along_route_m IS
  'The distance we actually trust for this bus at this moment. Equals raw_dist_along_route_m when accepted; equals the previous trusted value when rejected. Filled by tools/match-vehicle-progress.js.';
COMMENT ON COLUMN vehicle_progress.reject_reason IS
  'NULL when accepted. "too fast" or "jumped backward" when rejected - see tools/match-vehicle-progress.js for the exact thresholds.';

-- Most lookups will be "give me this one bus's history in time order" -
-- match that access pattern.
CREATE INDEX IF NOT EXISTS vehicle_progress_vehicle_idx
  ON vehicle_progress (vehicle_id, frame_id);
