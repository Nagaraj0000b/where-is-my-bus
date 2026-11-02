-- Where Is My Bus - static GTFS schema
--
-- Written after profiling the actual Delhi feed, not from the GTFS spec.
-- The comments record what the real data does, because several columns the
-- spec calls useful are empty here.

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------------
-- Snapshots
--
-- The feed is re-downloaded periodically and kept side by side rather than
-- overwritten. Measuring how stale Delhi's static data goes is a project goal,
-- and you cannot diff snapshots you have thrown away.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS feed_snapshot (
  snapshot_id   serial PRIMARY KEY,
  label         text NOT NULL UNIQUE,
  feed_version  text,
  feed_start    date,
  feed_end      date,
  source_dir    text,
  imported_at   timestamptz NOT NULL DEFAULT now(),
  note          text
);

COMMENT ON TABLE feed_snapshot IS
  'One row per downloaded GTFS zip. Every other table is scoped to a snapshot.';

-- ---------------------------------------------------------------------------
-- Helper: GTFS times run past 24:00:00
--
-- 10,497 rows in this feed have arrival_time >= 24:00:00 (after-midnight
-- services). Postgres TIME rejects those, so times are stored as integer
-- seconds since noon-minus-12 of the service day, per the GTFS spec.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION gtfs_seconds(t text) RETURNS integer
  LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT split_part(t, ':', 1)::int * 3600
       + split_part(t, ':', 2)::int * 60
       + split_part(t, ':', 3)::int
$$;

-- ---------------------------------------------------------------------------
-- agency
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS agency (
  snapshot_id     int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  agency_id       text NOT NULL,
  agency_name     text NOT NULL,
  agency_url      text,
  agency_timezone text,
  agency_lang     text,
  PRIMARY KEY (snapshot_id, agency_id)
);

-- ---------------------------------------------------------------------------
-- calendar
--
-- This feed has exactly one service_id, active all seven days from 2025-01-01
-- to 2040-01-01. There is effectively no calendar: every trip nominally runs
-- every day. Kept as a real table anyway so a future snapshot that grows a
-- genuine calendar loads without a migration.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS calendar (
  snapshot_id int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  service_id  text NOT NULL,
  monday      boolean NOT NULL,
  tuesday     boolean NOT NULL,
  wednesday   boolean NOT NULL,
  thursday    boolean NOT NULL,
  friday      boolean NOT NULL,
  saturday    boolean NOT NULL,
  sunday      boolean NOT NULL,
  start_date  date NOT NULL,
  end_date    date NOT NULL,
  PRIMARY KEY (snapshot_id, service_id)
);

-- ---------------------------------------------------------------------------
-- stops
--
-- 6,872 stops. stop_name is NOT unique - 2,002 names are shared by more than
-- one stop - so search must disambiguate by location, never by name alone.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stops (
  snapshot_id int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  stop_id     text NOT NULL,
  stop_code   text,
  stop_name   text NOT NULL,
  stop_lat    double precision NOT NULL,
  stop_lon    double precision NOT NULL,
  geom        geometry(Point, 4326) NOT NULL,
  PRIMARY KEY (snapshot_id, stop_id)
);

-- Radius search: ST_DWithin(geom::geography, :here::geography, metres)
CREATE INDEX IF NOT EXISTS stops_geog_idx ON stops USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS stops_name_idx ON stops USING gin (to_tsvector('simple', stop_name));

-- ---------------------------------------------------------------------------
-- shape_points - raw, immutable
--
-- Kept exactly as published. shape_dist_traveled is fully populated here
-- (0 blanks across 770,824 points), which is the only linear reference the
-- feed provides anywhere.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS shape_points (
  snapshot_id         int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  shape_id            text NOT NULL,
  shape_pt_sequence   int  NOT NULL,
  shape_pt_lat        double precision NOT NULL,
  shape_pt_lon        double precision NOT NULL,
  shape_dist_traveled double precision,
  PRIMARY KEY (snapshot_id, shape_id, shape_pt_sequence)
);

-- ---------------------------------------------------------------------------
-- shapes - derived geometry
--
-- LineString **M**: the M ordinate carries shape_dist_traveled, so a point can
-- be located along the route in the feed's own distance units rather than a
-- re-derived approximation. ST_LineLocatePoint / ST_InterpolatePoint operate
-- on this directly.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS shapes (
  snapshot_id int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  shape_id    text NOT NULL,
  n_points    int  NOT NULL,
  declared_m  double precision,   -- max shape_dist_traveled, as published
  geodesic_m  double precision,   -- ST_Length on the geography, as measured
  geom        geometry(LineStringM, 4326) NOT NULL,
  PRIMARY KEY (snapshot_id, shape_id)
);

COMMENT ON COLUMN shapes.declared_m IS
  'Route length the feed claims. Compare against geodesic_m - a large gap means the published distances are not metres.';

CREATE INDEX IF NOT EXISTS shapes_geom_idx ON shapes USING gist (geom);

-- ---------------------------------------------------------------------------
-- routes
--
-- route_long_name == route_short_name on all 2,648 rows; the human-readable
-- "A to B" text lives in route_desc. Direction is not in direction_id (empty
-- for every trip) but encoded in the name suffix: 1,292 UP, 1,270 DOWN,
-- 86 neither. direction_tag captures that so queries do not re-parse strings.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS routes (
  snapshot_id      int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  route_id         text NOT NULL,
  agency_id        text,
  route_short_name text,
  route_long_name  text,
  route_desc       text,
  route_type       int,
  direction_tag    text CHECK (direction_tag IN ('UP', 'DOWN')),
  PRIMARY KEY (snapshot_id, route_id),
  FOREIGN KEY (snapshot_id, agency_id) REFERENCES agency (snapshot_id, agency_id)
);

CREATE INDEX IF NOT EXISTS routes_short_name_idx ON routes (snapshot_id, route_short_name);

-- ---------------------------------------------------------------------------
-- trips
--
-- trip_id is route_id || '_HH_MM' on all 121,844 rows - trips are pure
-- timetable expansions of a route. direction_id, block_id, trip_headsign and
-- trip_short_name are empty for every single trip and are therefore not
-- columns here. No block_id means static data cannot chain a vehicle's
-- consecutive trips; that has to come from the realtime archive.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS trips (
  snapshot_id  int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  trip_id      text NOT NULL,
  route_id     text NOT NULL,
  service_id   text NOT NULL,
  shape_id     text NOT NULL,
  start_s      int,   -- arrival at stop_sequence 0, denormalised from stop_times
  end_s        int,
  n_stops      int,
  PRIMARY KEY (snapshot_id, trip_id),
  FOREIGN KEY (snapshot_id, route_id)   REFERENCES routes   (snapshot_id, route_id),
  FOREIGN KEY (snapshot_id, service_id) REFERENCES calendar (snapshot_id, service_id),
  FOREIGN KEY (snapshot_id, shape_id)   REFERENCES shapes   (snapshot_id, shape_id)
);

CREATE INDEX IF NOT EXISTS trips_route_start_idx ON trips (snapshot_id, route_id, start_s);

-- ---------------------------------------------------------------------------
-- stop_times - the big one, 3,855,149 rows
--
-- Two things the profile found:
--   * arrival_time == departure_time on 100% of rows. No dwell time is
--     modelled. Both columns are kept because that identity is a finding about
--     this feed, not a permanent property of it.
--   * stop_dist is blank on 100% of rows. The feed defines the column and
--     never fills it. dist_along_shape_m below is where the computed value
--     goes - it is deliberately left NULL by the loader.
--
-- stop_sequence starts at 0, not 1.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stop_times (
  snapshot_id        int  NOT NULL REFERENCES feed_snapshot ON DELETE CASCADE,
  trip_id            text NOT NULL,
  stop_sequence      int  NOT NULL,
  stop_id            text NOT NULL,
  arrival_s          int  NOT NULL,
  departure_s        int  NOT NULL,
  fare_stage         smallint,
  dist_along_shape_m double precision,
  PRIMARY KEY (snapshot_id, trip_id, stop_sequence),
  FOREIGN KEY (snapshot_id, trip_id) REFERENCES trips (snapshot_id, trip_id),
  FOREIGN KEY (snapshot_id, stop_id) REFERENCES stops (snapshot_id, stop_id)
);

COMMENT ON COLUMN stop_times.dist_along_shape_m IS
  'Distance of this stop along the trip shape. The feed ships this column (stop_dist) empty on every row; Phase 2 map-matching fills it.';

-- The primary screen: what is coming to this stop, next.
CREATE INDEX IF NOT EXISTS stop_times_stop_arrival_idx
  ON stop_times (snapshot_id, stop_id, arrival_s);

CREATE INDEX IF NOT EXISTS stop_times_trip_idx
  ON stop_times (snapshot_id, trip_id);
