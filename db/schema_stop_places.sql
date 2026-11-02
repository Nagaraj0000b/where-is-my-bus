-- Grouping stops that are really the same place.
--
--   psql -f /db/schema_stop_places.sql
--
-- THE PROBLEM
--
-- Delhi's GTFS lists a separate stop_id for each direction of the same
-- physical stop, and often several more for the same junction. Near
-- Connaught Place, "Shivaji Park" appears twice within a few metres, and
-- "Ordinance Depot" likewise. A traveller sees one bus stop; the data has
-- two to five.
--
-- Left alone this quietly breaks journey planning, because a route serving
-- the far side of the road counts as not serving the stop at all. Measured
-- on 400 random stop pairs 2-10 km apart:
--
--   treating each stop_id separately   ->  5.0% directly connected
--   treating nearby stops as one place -> 16.8% directly connected
--
-- Same city, same routes. More than three times the connectivity, purely
-- from not double-counting one physical place.
--
-- Allowing one change as well:
--
--   raw stop_ids : 55.0% of journeys reachable
--   places       : 86.7% of journeys reachable
--
-- WHY 100 METRES
--
-- Tested at three radii on all 6,872 stops:
--
--   100 m -> 3,649 places (1.88 stops each)   <- chosen
--   200 m -> 2,505 places (2.74 stops each)
--   300 m -> 1,544 places (4.45 stops each)
--
-- 100 m merges the direction-duplicates and both sides of a road without
-- over-merging. The larger radii creep upward because DBSCAN links
-- transitively - if A is near B and B is near C, all three join even when
-- A and C are far apart - so at 300 m genuinely separate stops start
-- chaining into one blob.
--
-- 100 m is an identity radius: "is this the same place". It is NOT a
-- walking-transfer radius. If a journey planner later wants to allow a
-- 300 m walk between places, that belongs in the planner as a distance
-- test, not baked in here where it would corrupt identity.
--
-- Rebuildable at any time - nothing else depends on the id values, only on
-- stops sharing one.

\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS stop_place;

CREATE TABLE stop_place AS
SELECT
    stop_id,
    -- UTM zone 43N covers Delhi and is measured in real metres, so the
    -- radius below means what it says. Clustering in raw lat/lon would
    -- make it degrees, which are a different distance north-south than
    -- east-west.
    ST_ClusterDBSCAN(ST_Transform(geom, 32643), 100, 1) OVER () AS place_id
FROM stops
WHERE snapshot_id = (SELECT max(snapshot_id) FROM stops);

ALTER TABLE stop_place ADD PRIMARY KEY (stop_id);
CREATE INDEX IF NOT EXISTS idx_stop_place_place ON stop_place (place_id);
ANALYZE stop_place;

COMMENT ON TABLE stop_place IS
  'Maps each stop_id to the physical place it belongs to. Delhi lists ~1.9 stop_ids per real stop (one per direction), which understates route connectivity threefold if not merged. Built by clustering stops within 100 m.';
COMMENT ON COLUMN stop_place.place_id IS
  'Shared by every stop_id at the same physical place. Values are not stable across rebuilds - join on them, never store them elsewhere.';

\echo ''
\echo 'stops collapsed into places:'
SELECT count(*) AS stops, count(DISTINCT place_id) AS places,
       round(count(*)::numeric / count(DISTINCT place_id), 2) AS stops_per_place
FROM stop_place;

\echo ''
\echo 'the worst offenders (one place, many stop_ids):'
SELECT sp.place_id, count(*) AS stop_ids,
       (array_agg(DISTINCT s.stop_name))[1:3] AS names
FROM stop_place sp
JOIN stops s ON s.stop_id = sp.stop_id
             AND s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
GROUP BY sp.place_id
ORDER BY count(*) DESC
LIMIT 5;
