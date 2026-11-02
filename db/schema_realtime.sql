-- Where Is My Bus - realtime archive schema
--
-- Written after loading and inspecting real recorded frames from the Azure
-- recorder, not from the GTFS-realtime spec. Two findings from that
-- inspection shape this schema directly - see the comments below.

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------------
-- realtime_frame
--
-- One row per recorded .pb.gz file, including frames with zero vehicles.
--
-- Finding: across the first ~1.75 days of recording, 44% of all successful
-- (HTTP 200, non-empty-body) fetches decoded to a valid FeedMessage with
-- ZERO vehicle entities - a genuine ~35-byte response from OTD's server, not
-- a truncation or recorder bug. This is chronic (52% on day 1, 23% on day 2),
-- present from the third minute of recording, and the fleet count swings
-- from 0 to ~5,600 and back within a single 10s tick either side of it. That
-- looks like a server-side caching/regeneration artifact on OTD's end, not
-- real-world bus behaviour.
--
-- Keeping every frame as a row - including empty ones - rather than only
-- rows with positions is what makes that pattern queryable later, and it is
-- the raw material for the project's own uptime/trust numbers (AGENTS.md
-- goal: "we measure our own error and publish the number").
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS realtime_frame (
  frame_id       serial PRIMARY KEY,
  source_file    text NOT NULL UNIQUE,   -- e.g. vp-20260809T100240Z.pb.gz
  day            date NOT NULL,
  feed_timestamp timestamptz NOT NULL,   -- FeedMessage.header.timestamp
  vehicle_count  int NOT NULL,           -- 0 for a genuinely empty response
  loaded_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS realtime_frame_day_idx ON realtime_frame (day);
CREATE INDEX IF NOT EXISTS realtime_frame_ts_idx  ON realtime_frame (feed_timestamp);

COMMENT ON COLUMN realtime_frame.vehicle_count IS
  'Entities in this frame, including 0. Do not filter empty frames out of this table - the emptiness itself is the feed-reliability signal.';

-- ---------------------------------------------------------------------------
-- vehicle_position
--
-- One row per vehicle entity in a non-empty frame. Only populated from
-- frames where vehicle_count > 0 - an empty frame has nothing to put here.
--
-- Finding: sampled 243,118 vehicle rows across a full day. position.speed is
-- present on 100% of them and is exactly 0 on 100% of them - never once
-- non-zero. position.bearing is absent on 100% of rows (not zero - the field
-- is never sent). Neither column is stored here: speed as reported by this
-- feed carries no information, and a column that is always 0 or always NULL
-- is not data. Real vehicle speed, if wanted, has to be derived from
-- position deltas between consecutive frames of the same vehicle_id - that
-- is Phase 2 map-matching territory, not this loader's job.
--
-- trip_id here is not guaranteed to exist in the static trips table: 3,548 of
-- 5,573 vehicles in one sampled frame carried schedule_relationship=ADDED,
-- meaning the vehicle is running a trip the static schedule does not know
-- about. No foreign key to trips is declared for that reason - it would
-- reject the majority of real rows.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS vehicle_position (
  frame_id             int  NOT NULL REFERENCES realtime_frame ON DELETE CASCADE,
  vehicle_id           text NOT NULL,
  route_id             text,
  trip_id              text,
  start_time           text,   -- HH:MM:SS as sent, not cross-checked against trips
  schedule_relationship text, -- 'SCHEDULED' | 'ADDED' | others per GTFS-rt enum
  lat                  double precision NOT NULL,
  lon                  double precision NOT NULL,
  geom                 geometry(Point, 4326) NOT NULL,
  position_timestamp   timestamptz NOT NULL,  -- VehiclePosition.timestamp
  PRIMARY KEY (frame_id, vehicle_id)
);

CREATE INDEX IF NOT EXISTS vehicle_position_vehicle_ts_idx
  ON vehicle_position (vehicle_id, position_timestamp);

CREATE INDEX IF NOT EXISTS vehicle_position_route_idx
  ON vehicle_position (route_id);

CREATE INDEX IF NOT EXISTS vehicle_position_geog_idx
  ON vehicle_position USING gist ((geom::geography));

COMMENT ON COLUMN vehicle_position.trip_id IS
  'No FK to trips - a large share of vehicles report schedule_relationship=ADDED, meaning the trip does not exist in the static schedule at all.';
