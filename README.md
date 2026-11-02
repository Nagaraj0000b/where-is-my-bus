# Where Is My Bus

A fault-tolerant, offline-capable bus tracking and transit planning system
referencing the commuter-first architecture of **Where Is My Train**.
Built and evaluated using Delhi's Open Transit Data (static GTFS and
GTFS-Realtime) as the reference implementation dataset.

The core principles adapted from Where Is My Train for urban bus transit:
1. **Offline-First**: Routes, stops, timetables, and journey planning operate
   locally on-device (via SQLite) with zero network connectivity.
2. **Crowdsourced Telemetry Imputation**: When official feeds drop, lag, or miss
   active buses, passengers traveling on board transmit GPS beacons to keep
   the bus visible for waiting commuters.
3. **Graceful Degradation**: Continuous service dynamically stepping down across
   fallback tiers (Live GPS -> Crowdsourced Telemetry -> Historical Statistics -> Static Timetable)
   instead of failing during outages.
4. **Probabilistic Arrival Intervals**: Providing commuters with calibrated arrival time windows
   reflecting traffic variance, accompanied by explicit data provenance indicators,
   rather than brittle single-point ETAs.

The full motivation and architectural context is in [AGENTS.md](AGENTS.md).

## Status

| Phase | State |
|---|---|
| 0 — Recorder | **Stopped deliberately (2026-08-19)**, after collecting a full 8+ day archive (Aug 9–16). `wimb-recorder.service` stopped and disabled on the VM — no more data being collected, on purpose (storage/time constraints ruled out extending to 3–4 weeks). Archive preserved on the VM (6.4 GB, 79,469 frames) and pulled down locally. See [docs/project-report.md](docs/project-report.md) |
| 1 — Look at the data | **Done.** Static GTFS profiled and loaded. Realtime archive profiled and loaded too — see [docs/project-report.md](docs/project-report.md) for what was actually found (the feed serves genuinely empty responses ~44% of the time; `speed` is always 0; most vehicles aren't in the static schedule at all) |
| 2 — Map-matching | **Done.** Each stop's offset along its route is computed for all 3.85M `stop_times` rows. The vehicle-position matching pipeline (raw distance-along-route, then accept/reject GPS noise) is built, validated, and re-run on a full week (Mon–Sun, Aug 10–16). Three bugs found and fixed (rejection cascade, lap-restart, measurement ruler mismatch), plus one known remaining issue (buses traveling backward on one-way route shapes — ~13% rejection rate, correctly excluded from downstream output). Write-up in [docs/project-report.md](docs/project-report.md) |
| 3 — Historical travel times | **Done.** Stop passage times extracted for all 7 days — 9.73M passages across 6,121 vehicles, 2,138 routes, 6,512 stops. Aggregated into `route_segment_travel_time`: 68,758 route segments, each with pooled and hour-of-day travel time statistics (median/p25/p75/mean/stddev), averaging 133 samples per segment. Typical hop: 86.5s median, consistent with measured ~19-22 km/h bus speeds |
| 4 — ETA + evaluation | **Completed & evaluated.** Empirical confidence intervals derived across `route_segment_travel_time`. Day-type stratification evaluated via 7-fold cross-validation, cutting directional error by 83% (weekday) and 99% (weekend). Sum of medians with p25/p75 bounds, floored at 0 relative to query time. Serving in Fastify via `/eta` with explicit provenance |
| 5 — API & Crowdsourcing | **Built, verified, and running.** Fastify + TypeScript with Zero-Trust input validation. Serves `/journey`, `/journey/by-hour`, `/eta`, `/routes`, `/stops`, and `/health`. Ingestion endpoint `POST /crowdsource/ping` filters passenger mobile beacons (5–80 km/h, 50m off-route check in PostGIS) and features a multi-passenger spatial consensus engine (`GET /routes/:id/crowdsourced`). 116 HTTP tests + 18 crowdsource checks passing |
| 6 - Flutter App & Offline Pack | **Complete across Web and Mobile.** Flutter 3.47.1 + Riverpod + OpenStreetMap (`flutter_map`). Includes interactive Journey Planner, Route Explorer, "I'm On This Bus" crowdsource beaconing, multi-sensory **Arrival Alarms** (audio + haptic deboarding alerts), and the **Offline Transit Pack** with a pre-bundled SQLite database (`wimb_offline.db`, 12.2 MB, < 1ms search). 27 widget & unit tests passing. Build the web app and APK locally with the commands below. |

## Layout

```
AGENTS.md                      project context — read this first
RULES.md                       how to talk and how code should look — plain
                                language, simple code, comments required
README.md                      this file

recorder/                      Not published here. The recorder is a small
                                fetch-and-write service whose deployment
                                runbook contains live Azure access details, so
                                it is kept private. The architecture is in
                                docs/project-report.md.

tools/                         Phase 1 — scripts that read the archive,
                                nothing here is production code
  peek-frame.js                inspect one recorded frame (CSV/JSON export)
  scan-archive.js              fleet count over time, ghost-bus detection
  profile-gtfs.js              reconnaissance script that produced
                                docs/project-report.md
  load-realtime.js             loads recorded frames into vehicle_position /
                                realtime_frame, idempotent, re-run as the
                                archive grows
  match-vehicle-progress.js    Phase 2 - decides which raw GPS readings to
                                trust, bus by bus, in time order

api/                           Phase 5 - the service. Node 25 runs the
                                TypeScript directly, so there is no build step
  src/journey.ts               the journey planner - two locations to ranked
                                ways of travelling. Ranks by TOTAL time (walk
                                + wait + ride), routes on places not stop_ids,
                                allows one change (~87% coverage). Also
                                planByHour: "when should I travel", the same
                                journey costed for every service hour
  src/eta.ts                   bus position -> arrival estimate with calibrated
                                confidence bands. Every rule came from measurement
                                (docs/project-report.md)
  src/db.ts                    shared connection pool
  src/server.ts                HTTP translation only, no logic of its own
  check-eta.ts                 proves the ETA logic BEFORE the service wraps
                                it (convention #4) - 24 checks, including a
                                real held-out-day experiment
  check-journey.ts             proves the journey planner - 52 checks,
                                including a pair verified to genuinely need
                                a change (the first two attempts passed
                                without ever running the transfer code)
  README.md                    endpoints, response shape, what is
                                deliberately missing and why

app/                            Phase 6 - the Flutter app. Bottom-nav shell
                                (main.dart) over three screens
  lib/journey_screen.dart      the planner - two places in, ranked ways to
                                travel out, never a bare number (confidence
                                band + plain-language explanation)
  lib/by_hour_screen.dart      "when should I travel" - the same journey
                                costed for every service hour, best/worst
                                highlighted
  lib/routes_screen.dart       search a route number, see its ordered stop
                                list - also how someone finds their own
                                stop's position number for /eta later
  lib/place_search_field.dart  shared "type a stop name, pick a
                                suggestion" box - journey and by-hour both
                                need a From/To picker, so this is the one
                                place that debounce/suggestion logic lives
  lib/error_card.dart          shared error display - offers "Try again"
                                only when retrying could genuinely help
                                (a failed request), never for a valid
                                "no route found" answer
  lib/api_client.dart          talks to api/, turns JSON into Dart objects
                                that keep the range+confidence shape all
                                the way to the widget tree

db/                            PostgreSQL + PostGIS schema, both for the
                                static GTFS and the loaded realtime archive
  schema.sql / load.sql / verify.sql       static GTFS
  schema_realtime.sql                      realtime_frame, vehicle_position
  compute_stop_distances.sql   Phase 2 - fills the stop-offset-along-route
                                gap the static feed leaves blank
  schema_matching.sql          Phase 2 - vehicle_progress table (raw vs.
                                accepted distance-along-route per sighting)
  compute_vehicle_raw_progress_chunked.sql   Phase 2 - closest-point-on-line
                                for every recorded bus sighting, done in
                                frame-id chunks (see project-report.md
                                for why the day-by-day version was worse)
  schema_route_places.sql      routing index: which routes call at which
                                places, in order. 87,718 rows instead of
                                joining 3.85M stop_times per request
  schema_place_frequency.sql   how often each route really turns up at each
                                place, by hour and day type. Observed, not
                                timetabled - this is what makes wait times
                                real and ranking correct
  schema_stop_places.sql       groups stop_ids that are the same physical
                                place (Delhi lists ~1.9 per real stop, one
                                per direction). Not cosmetic - routing on
                                raw stop_ids loses two thirds of the real
                                connections. See docs/project-report.md
  schema_stop_passages.sql     Phase 3 - observed_stop_passage table
                                (accumulates across daily processing runs)
  extract_stop_passages.sql    Phase 3 - extracts stop passage times by
                                interpolating between consecutive accepted
                                GPS readings
  schema_travel_times.sql      Phase 3 - route_segment_travel_time table
                                (pooled + hourly travel time statistics)
  compute_travel_times.sql     Phase 3 - aggregates stop passages into
                                per-segment travel time statistics
  evaluate_travel_time_predictions.sql   Phase 4 - the evaluation harness.
                                Holds out one day, trains on the other 6,
                                checks SINGLE-HOP predictions against real
                                held-out hops. Self-contained, doesn't touch
                                the production route_segment_travel_time table
  evaluate_multistop_eta.sql   Phase 4 - the number that actually matters:
                                multi-stop ETA error (1/3/5/10/20 hops).
                                Found errors compound rather than cancel,
                                and are systematically optimistic
  diagnose_eta_bias.sql        Phase 4 - tests two competing explanations
                                for that optimism against each other
                                (slow test day vs. sum-of-medians trap)
                                and measures the median-vs-mean fix
  calibrate_eta_bands.sql      Phase 4 - measures the empirical (lopsided)
                                confidence bands, and tests whether a bus
                                already running late stays late
  calibrate_live_correction.sql  Phase 4 - fair re-test of live delay
                                correction at gentle coefficients near its
                                statistical optimum, before ruling it out
  schema_eta_calibration.sql   Phase 4 - eta_calibration_fold table, one
                                row per (held-out day, journey length)
  crossvalidate_eta.sql        Phase 4 - ONE cross-validation fold; run
                                seven times by scripts/crossvalidate-eta.sh
  crossvalidate_eta_daytype.sql  Phase 4 - the fix cross-validation found
                                was needed: predicts from the same KIND of
                                day (weekday/weekend), scored against the
                                day-blind method on identical journeys
  README.md                    setup, query examples, deliberate schema
                                choices for both sides

scripts/
  run-full-pipeline.sh         pulls the full archive, loads it, and
                                re-runs Phase 2 matching end to end -
                                resumable, safe to re-run
  process-week.sh              Phase 2+3 day-by-day loop - processes
                                Aug 10-16 (Mon-Sun) one day at a time:
                                load, match, extract passages, clear
  crossvalidate-eta.sh         Phase 4 - rotates the held-out day across
                                all 7 days. This is what caught the
                                single-day calibration being wrong

docs/
  project-report.md            full report: architecture, methodology, and the
                               measured evaluation
  architecture-diagrams.png    rendered component and use-case diagrams
  locating-bus-without-gps.pdf short note on the crowdsourced positioning idea

delhi_buses_static_gtfs_v1/    the static GTFS snapshot itself. Gitignored —
                                151 MB stop_times.txt alone exceeds GitHub's
                                100 MB limit. Reload with db/load.sql.

docker-compose.yml             PostGIS for local dev, plus Adminer (a plain
                                web page for browsing the database at
                                localhost:8081 - see db/README.md)
package.json                   npm scripts for tools, api, and test runner
```

## Configuration

Copy `.env.example` to `.env` and fill in your own values. `.env` is
gitignored; `.env.example` is the committed template.

| Key | Used by | Meaning |
|---|---|---|
| `API_BASE` | Flutter build | API address the app calls |
| `DATA_ROOT` | tools | recorded `.pb.gz` archive |
| `PROFILE_GTFS_ROOT` | `profile-gtfs` | static GTFS snapshot |
| `DATABASE_URL` | API and checks | Postgres connection |
| `POSTGRES_*` | Docker Compose | local database |
| `RECORDER_HOST`, `SSH_KEY` | pipeline scripts | recorder VM |

The Node scripts load `.env` automatically through
`--env-file-if-exists=.env`. Flutter reads it at build time:

```bash
cd app
flutter build apk --release --dart-define-from-file=../.env
```

For USB instead of a tunnel, set `API_BASE=http://127.0.0.1:3000` and run
`adb reverse tcp:3000 tcp:3000`.

On Windows, `start-all.bat` starts Docker, Postgres, the API and ngrok in one
go. Run it from the repository root:

```bat
start-all.bat
```

## Quickstart

**Database** (static GTFS + realtime archive, local dev):

```bash
docker compose up -d
docker exec wimb-db psql -U wimb -d wimb -f /db/schema.sql
docker exec wimb-db psql -U wimb -d wimb -v label=delhi_buses_static_gtfs_v1 -f /db/load.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/verify.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_realtime.sql
node tools/load-realtime.js
```

Full detail, including the Git Bash path-mangling gotcha, in [db/README.md](db/README.md).

**Inspect the live archive** (once you have `.pb.gz` frames locally, e.g. after
pulling days down from the recorder VM — see `DATA_ROOT` convention in
[AGENTS.md](AGENTS.md) §9):

```bash
npm run peek                    # newest frame in DATA_ROOT
npm run scan-archive            # fleet count over time, all days
npm run profile-gtfs -- <dir>   # re-profile a static GTFS snapshot
npm run load-realtime           # load/refresh the DB from DATA_ROOT/raw
```

**Recorder** — the production recorder and its Azure runbook are kept private;
the runbook contains live VM access details. The data-collection architecture
is in [docs/project-report.md](docs/project-report.md).

**API** (Fastify, Node 25 — runs the TypeScript directly):

```bash
npm run api
```

It listens on `:3000`. The Flutter app defaults to `http://127.0.0.1:3000`,
which a phone reaches over USB after:

```bash
adb reverse tcp:3000 tcp:3000
```

For a phone on the same network, or a tunnel, set `API_BASE` in `.env` and
build with the file:

```bash
cd app
flutter build apk --release --dart-define-from-file=../.env
```

## Running & Verification

### 1. Run Complete Automated Test Suite (256 Checks)
```bash
npm run test-all
```
Runs unit checks for ETA, Journey, Auth, Crowdsource Consensus, HTTP API integration, and End-to-End System Coordination.

### 2. Verify Offline SQLite Database (< 7ms benchmarks)
```bash
python tools/verify_offline_queries.py
```

### 3. Run Flutter Tests & Analyze App
```bash
cd app
flutter test
flutter analyze
```

### 4. Build the Web App and APK

```bash
cd app
flutter build web --release
flutter build apk --release
```

The web build lands in `app/build/web`; the APK in
`app/build/app/outputs/flutter-apk/app-release.apk`.

## Conventions

Working conventions (look at real data before designing, raw archive is
immutable, build the evaluation harness early, script before service) and the
AI-assistance boundary (AI may write map-matching and ETA logic, but must
explain it in plain language alongside the code — see *On AI assistance* in
[AGENTS.md](AGENTS.md)) apply project-wide, not just to this file.
