-- The routing index: which routes call at which places, and in what order.
--
--   psql -f /db/schema_route_places.sql
--   (needs stop_place first - see schema_stop_places.sql)
--
-- WHY THIS TABLE EXISTS
--
-- Journey planning asks the same question over and over: "which routes
-- serve this place, and what can I reach from it". Answered directly
-- against stop_times that is a join across 3.85 million rows every time.
-- Collapsed to route + place + position it is about a hundred thousand
-- rows, which is small enough to sit in memory and be joined repeatedly
-- inside one request.
--
-- Keyed on PLACE, not stop_id, deliberately. Delhi lists roughly 1.9
-- stop_ids per physical stop (one per direction), and routing on the raw
-- ids loses two thirds of the real connections - 5% of stop pairs appear
-- directly connected instead of the true 16.8%. See
-- docs/journey-design.md section 3 for the measurements.
--
-- stop_sequence is kept because travel times are stored per
-- (route_id, to_stop_sequence) in route_segment_travel_time, so a journey
-- leg still has to be expressed as "from sequence A to sequence B" to be
-- costed.
--
-- Rebuildable from the static feed at any time.

\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS route_place;

CREATE TABLE route_place AS
-- DISTINCT ON keeps one row per (route, position). Many trips run the
-- same route, and route variants can disagree about which stop sits at a
-- given position; taking the first deterministically is enough here
-- because the place is what the traveller cares about, and variants that
-- differ at a position are rare.
SELECT DISTINCT ON (t.route_id, st.stop_sequence)
    t.route_id,
    st.stop_sequence,
    st.stop_id,
    sp.place_id
FROM stop_times st
JOIN trips      t  ON t.trip_id  = st.trip_id AND t.snapshot_id = st.snapshot_id
JOIN stop_place sp ON sp.stop_id = st.stop_id
WHERE st.snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
ORDER BY t.route_id, st.stop_sequence, st.stop_id;

ALTER TABLE route_place ADD PRIMARY KEY (route_id, stop_sequence);

-- "what can I board here, and where does it sit on that route" - the
-- lookup every journey query starts and ends with.
CREATE INDEX idx_route_place_place ON route_place (place_id, route_id, stop_sequence);

ANALYZE route_place;

COMMENT ON TABLE route_place IS
  'Routing index: which routes call at which places, in order. Place-keyed rather than stop-keyed because Delhi lists ~1.9 stop_ids per physical stop and stop-level routing loses two thirds of real connections.';

\echo ''
\echo 'routing index built:'
SELECT count(*) AS rows,
       count(DISTINCT route_id) AS routes,
       count(DISTINCT place_id) AS places_served,
       round(count(*)::numeric / count(DISTINCT route_id), 1) AS avg_stops_per_route
FROM route_place;

\echo ''
\echo 'how well connected is the average place?'
SELECT round(avg(routes)::numeric, 1) AS avg_routes_per_place,
       max(routes) AS best_connected_place,
       count(*) FILTER (WHERE routes = 1) AS places_with_one_route
FROM (SELECT place_id, count(DISTINCT route_id) AS routes
      FROM route_place GROUP BY place_id) x;
