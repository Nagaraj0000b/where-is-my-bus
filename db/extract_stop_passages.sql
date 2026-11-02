-- Extract stop passage times from the current day's matched vehicle data.
--
--   psql -f /db/extract_stop_passages.sql
--
-- Run AFTER match-vehicle-progress.js has decided which readings to trust.
-- Results go into observed_stop_passage (accumulated across days).
--
-- How it works: for each bus, we have accepted GPS readings every ~10
-- seconds, each with a "how far along the route" distance. For each pair
-- of consecutive readings where the bus moved forward, any stops whose
-- distance falls between the two readings must have been passed during
-- that interval. We interpolate the exact passage time by assuming
-- constant speed within the 10-second gap.

\set ON_ERROR_STOP on
\timing on
\pset footer off

SET work_mem = '256MB';

-- Step 1: build a canonical stop list per route.
-- One row per (route, stop_sequence) with its distance along the route.
-- Uses DISTINCT ON because multiple trips on the same route share the
-- same stops and distances.

DROP TABLE IF EXISTS _route_stops;

CREATE TEMP TABLE _route_stops AS
SELECT DISTINCT ON (t.route_id, st.stop_sequence)
    t.route_id,
    st.stop_id,
    st.stop_sequence,
    st.dist_along_shape_m
FROM stop_times st
JOIN trips t ON t.trip_id = st.trip_id AND t.snapshot_id = st.snapshot_id
WHERE st.snapshot_id = (SELECT max(snapshot_id) FROM feed_snapshot)
  AND st.dist_along_shape_m IS NOT NULL
ORDER BY t.route_id, st.stop_sequence;

CREATE INDEX ON _route_stops (route_id, dist_along_shape_m);
ANALYZE _route_stops;

\echo ''
\echo 'route-stop pairs:'
SELECT count(*) FROM _route_stops;

-- Step 2: remove any existing passages for this day (makes re-runs safe).
DELETE FROM observed_stop_passage
WHERE day = (SELECT DISTINCT day FROM realtime_frame LIMIT 1);

-- Step 3: extract passages.
--
-- The subquery builds "segments" from consecutive accepted readings using
-- LAG. The outer query joins each segment against the stop list to find
-- stops that fall within the segment's distance range, and interpolates
-- the passage time.
--
-- The interpolation: if at time T1 the bus was at distance D1, and at
-- time T2 it was at D2, then a stop at distance S (where D1 < S <= D2)
-- was passed at time T1 + (S - D1)/(D2 - D1) * (T2 - T1).

\echo ''
\echo 'extracting stop passages...'

INSERT INTO observed_stop_passage
    (day, route_id, vehicle_id, trip_id, stop_id, stop_sequence,
     dist_along_route_m, passage_time)
SELECT
    seg.ts::date,
    seg.route_id,
    seg.vehicle_id,
    seg.trip_id,
    rs.stop_id,
    rs.stop_sequence,
    rs.dist_along_shape_m,
    -- Linear interpolation of the passage time
    seg.prev_ts + (seg.ts - seg.prev_ts)
        * ((rs.dist_along_shape_m - seg.prev_dist_m)
           / (seg.dist_m - seg.prev_dist_m))
FROM (
    SELECT
        vp.vehicle_id,
        vp.route_id,
        vp.trip_id,
        p.accepted_dist_along_route_m              AS dist_m,
        vp.position_timestamp                       AS ts,
        LAG(p.accepted_dist_along_route_m) OVER w   AS prev_dist_m,
        LAG(vp.position_timestamp) OVER w            AS prev_ts,
        LAG(vp.route_id) OVER w                      AS prev_route_id
    FROM vehicle_position vp
    JOIN vehicle_progress p
      ON p.frame_id = vp.frame_id AND p.vehicle_id = vp.vehicle_id
    WHERE p.accepted = true
    WINDOW w AS (PARTITION BY vp.vehicle_id
                 ORDER BY vp.position_timestamp, vp.frame_id)
) seg
JOIN _route_stops rs ON rs.route_id = seg.route_id
WHERE seg.prev_dist_m IS NOT NULL           -- has a previous reading
  AND seg.route_id = seg.prev_route_id      -- same route (not a route change)
  AND seg.dist_m > seg.prev_dist_m + 1.0    -- bus moved forward (>1m, avoids division by near-zero)
  AND rs.dist_along_shape_m > seg.prev_dist_m   -- stop is ahead of previous position
  AND rs.dist_along_shape_m <= seg.dist_m        -- stop is at or before current position
;

\echo ''
\echo 'passages extracted for this day:'
SELECT day, count(*) AS passages,
       count(DISTINCT vehicle_id) AS vehicles,
       count(DISTINCT route_id) AS routes,
       count(DISTINCT stop_id) AS stops
FROM observed_stop_passage
WHERE day = (SELECT DISTINCT day FROM realtime_frame LIMIT 1)
GROUP BY day;

-- Step 4: sanity check — look at implied speeds between consecutive
-- stop passages for the same vehicle. City buses should be 5-60 km/h
-- on average between stops. Anything outside that range is suspicious.
\echo ''
\echo 'speed sanity check (sample of segment speeds between consecutive stops):'
WITH consecutive AS (
    SELECT
        vehicle_id, route_id, stop_sequence,
        passage_time,
        dist_along_route_m,
        LAG(passage_time) OVER w AS prev_time,
        LAG(dist_along_route_m) OVER w AS prev_dist,
        LAG(stop_sequence) OVER w AS prev_seq
    FROM observed_stop_passage
    WHERE day = (SELECT DISTINCT day FROM realtime_frame LIMIT 1)
    WINDOW w AS (PARTITION BY vehicle_id, route_id ORDER BY stop_sequence, passage_time)
),
speeds AS (
    SELECT
        (dist_along_route_m - prev_dist) AS dist_m,
        extract(epoch FROM passage_time - prev_time) AS secs,
        CASE WHEN extract(epoch FROM passage_time - prev_time) > 0
             THEN (dist_along_route_m - prev_dist) / extract(epoch FROM passage_time - prev_time) * 3.6
             ELSE NULL END AS speed_kmh
    FROM consecutive
    WHERE prev_time IS NOT NULL
      AND stop_sequence = prev_seq + 1
      AND dist_along_route_m > prev_dist
      AND extract(epoch FROM passage_time - prev_time) > 0
)
SELECT
    count(*) AS segments,
    round(avg(speed_kmh)::numeric, 1) AS avg_kmh,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY speed_kmh)::numeric, 1) AS median_kmh,
    round(min(speed_kmh)::numeric, 1) AS min_kmh,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY speed_kmh)::numeric, 1) AS p95_kmh,
    round(max(speed_kmh)::numeric, 1) AS max_kmh
FROM speeds;

DROP TABLE IF EXISTS _route_stops;
