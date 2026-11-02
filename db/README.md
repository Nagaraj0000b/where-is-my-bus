# Database

PostgreSQL 17 + PostGIS 3.5 in Docker. Holds the static GTFS **and** the
loaded realtime archive.

Both schemas were written *after* profiling the real feed — see
`docs/project-report.md` and `docs/project-report.md`. Several
columns the GTFS / GTFS-realtime specs call useful are empty or meaningless in
Delhi's data, and both schemas reflect what is actually there, not the spec.

## Run

```
docker compose up -d
docker exec wimb-db psql -U wimb -d wimb -f /db/schema.sql
docker exec wimb-db psql -U wimb -d wimb -v label=delhi_buses_static_gtfs_v1 -f /db/load.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/verify.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_realtime.sql
node tools/load-realtime.js
```

The last two lines are the realtime side — `schema_realtime.sql` creates
`realtime_frame` and `vehicle_position`, and `load-realtime.js` (a Node
script, not SQL, since the source is compressed protobuf rather than CSV)
walks `DATA_ROOT/raw` and loads every frame found there. Safe to re-run after
pulling more days down from the recorder — see `tools/load-realtime.js`'s own
header comment for exact idempotency behaviour.

From **Git Bash on Windows**, prefix each `docker exec` with `MSYS_NO_PATHCONV=1`
or it will rewrite `/db/schema.sql` into a Windows path and fail.

**Map-matching (Phase 2)**, run after the above:

```
docker exec wimb-db psql -U wimb -d wimb -f /db/compute_stop_distances.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_matching.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/compute_vehicle_raw_progress_chunked.sql
node tools/match-vehicle-progress.js
```

`compute_stop_distances.sql` fills in each stop's offset along its route
(the feed leaves this blank). `schema_matching.sql` creates
`vehicle_progress`. `compute_vehicle_raw_progress_chunked.sql` works out how
far along its route each recorded bus sighting is, in frame-id chunks so
progress is visible and a stop doesn't lose finished work. `tools/match-
vehicle-progress.js` then decides which of those raw readings to trust, bus
by bus in time order. All four are idempotent. See
[docs/project-report.md](../docs/project-report.md) for the bugs
found building the last two.

**`scripts/run-full-pipeline.sh`** chains everything above end to end -
pull the archive from the recorder VM, load it, run all four matching
steps, print the final numbers. Safe to re-run if interrupted partway
through (e.g. the laptop went to sleep) - every step only does work not
already done.

**A plain web page for looking at the database**: `docker compose up -d`
also starts Adminer at **http://localhost:8081** — log in with System
`PostgreSQL`, Server `db`, Username `wimb`, Password `wimb_local_dev`,
Database `wimb`. Click a table name to see its columns; click "select" in
the sidebar to browse its rows. No SQL required for basic looking-around.

A psql shell:

```
docker exec -it wimb-db psql -U wimb -d wimb
```

Connection string for tooling: `postgres://wimb:wimb_local_dev@localhost:5432/wimb`
(local dev credentials, not a secret worth protecting).

## Loading

`load.sql` COPYs server-side from `/gtfs`, which is the project's
`delhi_buses_static_gtfs_v1/` mounted **read-only** — a bad script cannot touch
the source feed. No npm install, no client library.

It is idempotent: re-running with the same `label` deletes that snapshot and
reloads it. Full load is about two minutes, dominated by the 3.86M-row
`stop_times` insert.

## Snapshots

Every table is keyed by `snapshot_id`. Feeds are kept side by side rather than
overwritten, because measuring how stale Delhi's static data goes is a project
goal and you cannot diff snapshots you have thrown away. Load a new one with a
different label:

```
docker exec wimb-db psql -U wimb -d wimb -v label=gtfs_2026_09 -f /db/load.sql
```

## Tables

| table | rows | notes |
|---|---|---|
| `feed_snapshot` | 1 | one row per downloaded zip |
| `agency` | 2 | DTC, DIMTS |
| `calendar` | 1 | the entire calendar: one service, all days, to 2040 |
| `stops` | 6,872 | `geom` + GiST index on the geography cast |
| `routes` | 2,648 | `direction_tag` derived from the UP/DOWN name suffix |
| `shape_points` | 770,824 | raw, immutable, exactly as published |
| `shapes` | 2,648 | derived `LineStringM` — M carries `shape_dist_traveled` |
| `trips` | 121,844 | `start_s`/`end_s`/`n_stops` denormalised from stop_times |
| `stop_times` | 3,855,149 | times as integer seconds |
| `realtime_frame` | one per recorded file | includes empty (0-vehicle) frames on purpose — see below |
| `vehicle_position` | one per vehicle per non-empty frame | no `speed`/`bearing` columns, no FK to `trips` — both deliberate, see `docs/project-report.md` |
| `vehicle_progress` | one per vehicle sighting matched to a route | `raw_dist_along_route_m` (plain closest-point answer) vs `accepted_dist_along_route_m` (the one we trust) — see `docs/project-report.md` |
| `route_shape_lookup` | one per route | helper table rebuilt each run of `compute_vehicle_raw_progress_chunked.sql`; includes `route_length_m` (from the shape's M-value at its end point) used by the matcher's lap-restart detection |
| `observed_stop_passage` | ~1.25M per day | Phase 3 output: when each bus passed each stop, by interpolation between consecutive accepted GPS readings. Accumulates across daily processing runs; survives TRUNCATE of the position tables |
| `route_segment_travel_time` | 884,994 (68,758 route segments × pooled + hourly breakdowns) | Phase 3 deliverable: historical travel time (median/p25/p75/mean/stddev) for each consecutive-stop hop, pooled across all hours and broken out per hour of day. `hour_of_day = -1` is the pooled row — see `db/schema_travel_times.sql` for why -1 instead of NULL |

### Two deliberate choices

**Times are integer seconds, not `TIME`.** 10,497 rows have arrival times at or
past `24:00:00` (max `26:00:00`). Postgres `TIME` rejects those outright.
Helper: `gtfs_seconds('26:00:00') → 93600`.

**`shapes.geom` is a `LineStringM`.** The M ordinate carries the feed's own
`shape_dist_traveled`, which was verified to be true metres (within 0.4% of the
spheroid measurement, on every one of the 2,648 shapes). So a position can be
located along a route in the feed's own units rather than a re-derived
approximation. `ST_LineLocatePoint` and `ST_InterpolatePoint` work on it
directly.

### The column that is deliberately empty

`stop_times.dist_along_shape_m` is **NULL on every row, on purpose.** The feed
ships a `stop_dist` column and leaves it blank on all 3.86M rows, so each
stop's offset along its route has to be computed. That computation is Phase 2
map-matching work and the loader does not touch it.

## Query shapes

Next departures from a stop:

```sql
SELECT r.route_short_name, r.route_desc, st.departure_s
FROM stop_times st
JOIN trips  t ON t.snapshot_id = st.snapshot_id AND t.trip_id  = st.trip_id
JOIN routes r ON r.snapshot_id = t.snapshot_id  AND r.route_id = t.route_id
WHERE st.snapshot_id = 1 AND st.stop_id = '1' AND st.departure_s >= 8*3600
ORDER BY st.departure_s LIMIT 10;
```

Stops near a point (metres):

```sql
SELECT stop_id, stop_name
FROM stops
WHERE snapshot_id = 1
  AND ST_DWithin(geom::geography,
                 ST_SetSRID(ST_MakePoint(77.2167, 28.6315), 4326)::geography, 500);
```

Buses currently visible near a point, most recent frame only:

```sql
SELECT vp.vehicle_id, vp.route_id, vp.trip_id, vp.schedule_relationship,
       extract(epoch FROM rf.feed_timestamp - vp.position_timestamp) AS age_s
FROM vehicle_position vp
JOIN realtime_frame rf ON rf.frame_id = vp.frame_id
WHERE rf.frame_id = (SELECT max(frame_id) FROM realtime_frame WHERE vehicle_count > 0)
  AND ST_DWithin(vp.geom::geography,
                 ST_SetSRID(ST_MakePoint(77.2167, 28.6315), 4326)::geography, 1000);
```

Feed reliability, per day (the `realtime_frame` finding from
`docs/project-report.md`, as SQL instead of prose):

```sql
SELECT day, count(*) AS frames,
       sum((vehicle_count = 0)::int) AS empty_frames,
       round(100.0 * sum((vehicle_count = 0)::int) / count(*), 1) AS pct_empty
FROM realtime_frame GROUP BY day ORDER BY day;
```

## Reset

```
docker compose down -v      # -v also drops the pgdata volume
```
