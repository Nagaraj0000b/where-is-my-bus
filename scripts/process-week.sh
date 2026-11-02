#!/bin/bash
# Process 7 days (Mon-Sun, Aug 10-16) one day at a time.
#
# For each day:
#   1. Clear realtime tables (keeps static GTFS + stop distances intact)
#   2. Load that day's recorded frames
#   3. Compute raw distance-along-route for every sighting (Phase 2)
#   4. Run the matcher to decide which readings to trust (Phase 2)
#   5. Verify Phase 2 results (rejection rate, worst stuck run)
#   6. Extract stop passage times into the permanent table (Phase 3)
#   7. Report progress
#
# The permanent output is the observed_stop_passage table, which
# accumulates across all 7 days and is NOT cleared between runs.
#
# Safe to re-run: each day's passages are deleted before re-extraction,
# and load-realtime.js skips already-loaded frames.

set -e
cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a
  . .env
  set +a
fi

DAYS=(2026-08-10 2026-08-11 2026-08-12 2026-08-13 2026-08-14 2026-08-15 2026-08-16)
LOG="scripts/process-week.log"

# Tee everything to a log file so the full output survives even if the
# terminal scrollback is lost.
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "========================================================================"
echo "=== $(date) : STARTING 7-DAY PIPELINE ==="
echo "========================================================================"
echo "Days to process: ${DAYS[*]}"
echo ""

# --- one-time setup ---

echo "=== $(date) : creating stop passages table (if not exists) ==="
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -f /db/schema_stop_passages.sql

echo ""

# --- day-by-day loop ---

for DAY in "${DAYS[@]}"; do
    echo ""
    echo "========================================================================"
    echo "=== $(date) : [$DAY] STARTING ==="
    echo "========================================================================"

    # Step 1: clear realtime tables.
    # CASCADE propagates: realtime_frame -> vehicle_position -> vehicle_progress
    echo "--- [$DAY] step 1/7: clearing realtime tables ---"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c \
      "TRUNCATE realtime_frame RESTART IDENTITY CASCADE;"

    # Step 2: load this day's frames.
    echo "--- [$DAY] step 2/7: loading frames ---"
    node tools/load-realtime.js "$DAY"

    # Step 3: compute raw distance-along-route.
    # This also rebuilds route_shape_lookup WITH route_length_m (needed
    # for the matcher's lap-restart detection).
    echo "--- [$DAY] step 3/7: computing raw distance-along-route ---"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" \
      -f /db/compute_vehicle_raw_progress_chunked.sql

    # Step 4: run the matcher.
    echo "--- [$DAY] step 4/7: running matcher ---"
    node tools/match-vehicle-progress.js

    # Step 5: verify Phase 2 results.
    echo "--- [$DAY] step 5/7: verifying Phase 2 ---"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
      SELECT count(*) AS total_readings,
             count(*) FILTER (WHERE accepted) AS accepted,
             count(*) FILTER (WHERE NOT accepted) AS rejected,
             round(100.0 * count(*) FILTER (WHERE NOT accepted) / count(*), 1)
               AS pct_rejected
      FROM vehicle_progress;"

    echo ""
    echo "worst rejected run (should be much less than 2837):"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
      WITH runs AS (
        SELECT vehicle_id, accepted,
          ROW_NUMBER() OVER (PARTITION BY vehicle_id ORDER BY frame_id) -
          ROW_NUMBER() OVER (PARTITION BY vehicle_id, accepted ORDER BY frame_id) AS grp
        FROM vehicle_progress
      )
      SELECT max(cnt) AS worst_rejected_run
      FROM (SELECT count(*) cnt FROM runs WHERE NOT accepted
            GROUP BY vehicle_id, grp) x;"

    # Also check route_shape_lookup has route_length_m (the missing column
    # that caused Bug #2 to never be applied before).
    echo ""
    echo "route_shape_lookup columns (must include route_length_m):"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c \
      "\d route_shape_lookup"

    # Step 6: extract stop passages.
    echo "--- [$DAY] step 6/7: extracting stop passages ---"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" \
      -f /db/extract_stop_passages.sql

    # Step 7: report.
    echo "--- [$DAY] step 7/7: progress so far ---"
    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
      SELECT day, count(*) AS passages,
             count(DISTINCT vehicle_id) AS vehicles,
             count(DISTINCT route_id) AS routes
      FROM observed_stop_passage
      GROUP BY day ORDER BY day;"

    MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
      SELECT pg_size_pretty(pg_database_size('wimb')) AS db_size;"

    echo ""
    echo "=== $(date) : [$DAY] DONE ==="
done

echo ""
echo "========================================================================"
echo "=== $(date) : ALL 7 DAYS COMPLETE ==="
echo "========================================================================"

echo ""
echo "--- final summary ---"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
  SELECT day,
         to_char(day, 'Dy') AS dow,
         count(*) AS passages,
         count(DISTINCT vehicle_id) AS vehicles,
         count(DISTINCT route_id) AS routes,
         count(DISTINCT stop_id) AS stops
  FROM observed_stop_passage
  GROUP BY day ORDER BY day;"

MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
  SELECT count(*) AS total_passages,
         count(DISTINCT day) AS days,
         count(DISTINCT vehicle_id) AS vehicles,
         count(DISTINCT route_id) AS routes,
         count(DISTINCT stop_id) AS stops
  FROM observed_stop_passage;"

MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U "${POSTGRES_USER:-wimb}" -d "${POSTGRES_DB:-wimb}" -c "
  SELECT pg_size_pretty(pg_database_size('wimb')) AS final_db_size;"

echo ""
echo "=== $(date) : PIPELINE FINISHED ==="
