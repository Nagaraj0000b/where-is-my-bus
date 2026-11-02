-- Load one GTFS snapshot from /gtfs into the schema.
--
--   psql -v label=delhi_buses_static_gtfs_v1 -f /db/load.sql
--
-- Idempotent: re-running with the same label deletes that snapshot's rows and
-- reloads them. The source files are never modified - /gtfs is mounted ro.
--
-- COPY runs server-side, so this needs no client library and no npm install.

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- ---------------------------------------------------------------------------
-- Snapshot row
-- ---------------------------------------------------------------------------

DELETE FROM feed_snapshot WHERE label = :'label';   -- cascades to every table

INSERT INTO feed_snapshot (label, source_dir)
VALUES (:'label', '/gtfs');

DROP TABLE IF EXISTS snap;
CREATE TEMP TABLE snap AS
  SELECT snapshot_id FROM feed_snapshot WHERE label = :'label';

-- ---------------------------------------------------------------------------
-- Staging - text columns throughout, matching each file's real header order.
-- Nothing is coerced during COPY, so a surprise value fails loudly in the
-- transform rather than silently landing as NULL.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE s_agency (
  agency_id text, agency_name text, agency_url text, agency_timezone text,
  agency_lang text, agency_phone text, agency_fare_url text, agency_email text
) ON COMMIT DROP;
COPY s_agency FROM '/gtfs/agency.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_calendar (
  service_id text, monday text, tuesday text, wednesday text, thursday text,
  friday text, saturday text, sunday text, start_date text, end_date text
) ON COMMIT DROP;
COPY s_calendar FROM '/gtfs/calendar.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_feed_info (
  feed_publisher_name text, feed_publisher_url text, feed_lang text,
  feed_start_date text, feed_end_date text, feed_version text
) ON COMMIT DROP;
COPY s_feed_info FROM '/gtfs/feed_info.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_stops (
  stop_id text, stop_code text, stop_name text, stop_lat text, stop_lon text
) ON COMMIT DROP;
COPY s_stops FROM '/gtfs/stops.txt' WITH (FORMAT csv, HEADER true);

-- Note the column order: this feed puts agency_id first and long_name before
-- short_name, which is not the order the GTFS reference lists.
CREATE TEMP TABLE s_routes (
  agency_id text, route_id text, route_long_name text, route_short_name text,
  route_desc text, route_type text
) ON COMMIT DROP;
COPY s_routes FROM '/gtfs/routes.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_trips (
  route_id text, service_id text, trip_id text, trip_headsign text,
  trip_short_name text, direction_id text, block_id text, shape_id text,
  wheelchair_accessible text, bikes_allowed text
) ON COMMIT DROP;
COPY s_trips FROM '/gtfs/trips.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_shapes (
  shape_id text, shape_pt_lat text, shape_pt_lon text,
  shape_pt_sequence text, shape_dist_traveled text
) ON COMMIT DROP;
COPY s_shapes FROM '/gtfs/shapes.txt' WITH (FORMAT csv, HEADER true);

CREATE TEMP TABLE s_stop_times (
  trip_id text, arrival_time text, departure_time text, stop_id text,
  stop_sequence text, fare_stage text, stop_dist text
) ON COMMIT DROP;
COPY s_stop_times FROM '/gtfs/stop_times.txt' WITH (FORMAT csv, HEADER true);

-- ---------------------------------------------------------------------------
-- Record what the feed says about itself
-- ---------------------------------------------------------------------------

UPDATE feed_snapshot fs SET
  feed_version = fi.feed_version,
  feed_start   = to_date(fi.feed_start_date, 'YYYYMMDD'),
  feed_end     = to_date(fi.feed_end_date,   'YYYYMMDD')
FROM (SELECT * FROM s_feed_info LIMIT 1) fi
WHERE fs.label = :'label';

-- ---------------------------------------------------------------------------
-- agency, calendar, stops
-- ---------------------------------------------------------------------------

INSERT INTO agency (snapshot_id, agency_id, agency_name, agency_url, agency_timezone, agency_lang)
SELECT snap.snapshot_id, s.agency_id, s.agency_name, nullif(s.agency_url, ''),
       nullif(s.agency_timezone, ''), nullif(s.agency_lang, '')
FROM s_agency s, snap;

INSERT INTO calendar (snapshot_id, service_id, monday, tuesday, wednesday,
                      thursday, friday, saturday, sunday, start_date, end_date)
SELECT snap.snapshot_id, s.service_id,
       s.monday = '1', s.tuesday = '1', s.wednesday = '1', s.thursday = '1',
       s.friday = '1', s.saturday = '1', s.sunday = '1',
       to_date(s.start_date, 'YYYYMMDD'), to_date(s.end_date, 'YYYYMMDD')
FROM s_calendar s, snap;

INSERT INTO stops (snapshot_id, stop_id, stop_code, stop_name, stop_lat, stop_lon, geom)
SELECT snap.snapshot_id, s.stop_id, nullif(s.stop_code, ''), s.stop_name,
       s.stop_lat::double precision, s.stop_lon::double precision,
       ST_SetSRID(ST_MakePoint(s.stop_lon::double precision,
                               s.stop_lat::double precision), 4326)
FROM s_stops s, snap;

-- ---------------------------------------------------------------------------
-- shapes: raw points first, then the derived M-linestring
-- ---------------------------------------------------------------------------

INSERT INTO shape_points (snapshot_id, shape_id, shape_pt_sequence,
                          shape_pt_lat, shape_pt_lon, shape_dist_traveled)
SELECT snap.snapshot_id, s.shape_id, s.shape_pt_sequence::int,
       s.shape_pt_lat::double precision, s.shape_pt_lon::double precision,
       nullif(s.shape_dist_traveled, '')::double precision
FROM s_shapes s, snap;

INSERT INTO shapes (snapshot_id, shape_id, n_points, declared_m, geodesic_m, geom)
SELECT
  p.snapshot_id,
  p.shape_id,
  count(*),
  max(p.shape_dist_traveled),
  ST_Length(ST_Force2D(ST_SetSRID(ST_MakeLine(
    ST_MakePointM(p.shape_pt_lon, p.shape_pt_lat,
                  coalesce(p.shape_dist_traveled, 0))
    ORDER BY p.shape_pt_sequence), 4326))::geography),
  ST_SetSRID(ST_MakeLine(
    ST_MakePointM(p.shape_pt_lon, p.shape_pt_lat,
                  coalesce(p.shape_dist_traveled, 0))
    ORDER BY p.shape_pt_sequence), 4326)
FROM shape_points p, snap
WHERE p.snapshot_id = snap.snapshot_id
GROUP BY p.snapshot_id, p.shape_id;

-- ---------------------------------------------------------------------------
-- routes
-- ---------------------------------------------------------------------------

INSERT INTO routes (snapshot_id, route_id, agency_id, route_short_name,
                    route_long_name, route_desc, route_type, direction_tag)
SELECT snap.snapshot_id, s.route_id, s.agency_id,
       nullif(s.route_short_name, ''), nullif(s.route_long_name, ''),
       nullif(s.route_desc, ''), s.route_type::int,
       CASE
         WHEN s.route_short_name LIKE '%UP'   THEN 'UP'
         WHEN s.route_short_name LIKE '%DOWN' THEN 'DOWN'
       END
FROM s_routes s, snap;

-- ---------------------------------------------------------------------------
-- trips, then stop_times, then the denormalised trip bounds
-- ---------------------------------------------------------------------------

INSERT INTO trips (snapshot_id, trip_id, route_id, service_id, shape_id)
SELECT snap.snapshot_id, s.trip_id, s.route_id, s.service_id, s.shape_id
FROM s_trips s, snap;

-- stop_dist is deliberately not read: it is blank on every row of this feed.
INSERT INTO stop_times (snapshot_id, trip_id, stop_sequence, stop_id,
                        arrival_s, departure_s, fare_stage)
SELECT snap.snapshot_id, s.trip_id, s.stop_sequence::int, s.stop_id,
       gtfs_seconds(s.arrival_time), gtfs_seconds(s.departure_time),
       nullif(s.fare_stage, '')::smallint
FROM s_stop_times s, snap;

UPDATE trips t SET
  start_s = b.start_s,
  end_s   = b.end_s,
  n_stops = b.n_stops
FROM (
  SELECT snapshot_id, trip_id,
         min(arrival_s) AS start_s,
         max(arrival_s) AS end_s,
         count(*)       AS n_stops
  FROM stop_times
  WHERE snapshot_id = (SELECT snapshot_id FROM snap)
  GROUP BY snapshot_id, trip_id
) b
WHERE t.snapshot_id = b.snapshot_id AND t.trip_id = b.trip_id;

COMMIT;

ANALYZE;
