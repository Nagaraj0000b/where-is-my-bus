'use strict';

/**
 * Load recorded realtime frames into Postgres.
 *
 *   node tools/load-realtime.js               every day under DATA_ROOT/raw
 *   node tools/load-realtime.js 2026-08-09     one day only
 *
 * Idempotent: source_file is UNIQUE on realtime_frame, so a frame already in
 * the database is skipped rather than duplicated. Safe to re-run after
 * pulling more days down from the recorder.
 *
 * Every frame becomes a realtime_frame row, including empty ones - see
 * db/schema_realtime.sql for why that matters. Only non-empty frames also
 * get vehicle_position rows.
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { Client } = require('pg');
const { transit_realtime } = require('gtfs-realtime-bindings');

// Archive lives outside the repo on purpose - see CLAUDE.md section 9.
const DATA_ROOT = process.env.DATA_ROOT || path.join(process.cwd(), 'data');
const DATABASE_URL = process.env.DATABASE_URL || 'postgres://wimb:wimb_local_dev@localhost:5432/wimb';
const only = process.argv[2];

// vp-20260809T100240Z.pb.gz -> 2026-08-09
// Pulled from the filename rather than re-derived from the feed timestamp,
// so a frame always lands in the day it was actually recorded.
function dayFromFilename(f) {
  const m = f.match(/vp-(\d{4})(\d{2})(\d{2})T/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

// Turn one decoded vehicle entity into the values for one row of
// vehicle_position, plus the matching "($1, $2, ...)" placeholder string.
// startParamNumber is where this row's placeholders should start counting
// from, since several rows share one INSERT statement (see loadFrame below).
function buildVehicleRow(frameId, vehicle, feedTimestamp, startParamNumber) {
  const trip = vehicle.trip || {};
  const position = vehicle.position || {};

  // scheduleRelationship comes back as a number (an enum index); this looks
  // up the human-readable name, e.g. 0 -> "SCHEDULED".
  const scheduleRelationship = trip.scheduleRelationship != null
    ? transit_realtime.TripDescriptor.ScheduleRelationship[trip.scheduleRelationship]
    : null;

  // Not every vehicle sends its own timestamp. When it doesn't, the frame's
  // own timestamp is the closest thing we have to "when was this seen".
  const positionTimestamp = vehicle.timestamp != null
    ? new Date(Number(vehicle.timestamp) * 1000)
    : feedTimestamp;

  const values = [
    frameId,
    (vehicle.vehicle && vehicle.vehicle.id) || null,
    trip.routeId || null,
    trip.tripId || null,
    trip.startTime || null,
    scheduleRelationship,
    position.latitude,
    position.longitude,
    // PostGIS's ST_MakePoint wants (longitude, latitude), the opposite order
    // from how lat/lon are normally written and spoken - easy to get backwards.
    position.longitude,
    position.latitude,
    positionTimestamp,
  ];

  // Build "$5, $6, $7, ..." for however many placeholders this row needs,
  // starting from startParamNumber, then wrap the geometry pair in the
  // PostGIS function call it belongs in.
  const n = values.length;
  const placeholderNumbers = [];
  for (let offset = 0; offset < n; offset++) {
    placeholderNumbers.push(`$${startParamNumber + offset}`);
  }
  const [frameP, vehicleP, routeP, tripP, startP, schedP, latP, lonP, geomLonP, geomLatP, tsP] = placeholderNumbers;
  const placeholderString =
    `(${frameP}, ${vehicleP}, ${routeP}, ${tripP}, ${startP}, ${schedP}, ${latP}, ${lonP}, ` +
    `ST_SetSRID(ST_MakePoint(${geomLonP}, ${geomLatP}), 4326), ${tsP})`;

  return { values, placeholderString };
}

// Decode one .pb.gz file and load it: always a realtime_frame row, plus one
// vehicle_position row per vehicle if the frame isn't empty.
async function loadFrame(client, dir, file) {
  const buf = zlib.gunzipSync(fs.readFileSync(path.join(dir, file)));
  const msg = transit_realtime.FeedMessage.decode(buf);
  const feedTimestamp = new Date(Number(msg.header.timestamp) * 1000);
  const day = dayFromFilename(file);

  const vehicles = msg.entity.filter((e) => e.vehicle).map((e) => e.vehicle);

  // ON CONFLICT DO NOTHING + RETURNING is how re-runs stay safe: if this
  // file was already loaded, nothing comes back and we skip it below instead
  // of inserting a duplicate frame or re-inserting its vehicles.
  const frameResult = await client.query(
    `INSERT INTO realtime_frame (source_file, day, feed_timestamp, vehicle_count)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (source_file) DO NOTHING
     RETURNING frame_id`,
    [file, day, feedTimestamp, vehicles.length]
  );

  if (frameResult.rowCount === 0) return 'skipped'; // already loaded earlier
  const frameId = frameResult.rows[0].frame_id;
  if (vehicles.length === 0) return 'empty'; // a genuinely empty feed response

  // Build one row per vehicle, then insert them all in a single statement -
  // much faster than one INSERT per vehicle when a frame has thousands.
  const columns = ['frame_id', 'vehicle_id', 'route_id', 'trip_id', 'start_time',
    'schedule_relationship', 'lat', 'lon', 'geom', 'position_timestamp'];
  const allValues = [];
  const allPlaceholders = [];

  for (const vehicle of vehicles) {
    const nextParamNumber = allValues.length + 1;
    const row = buildVehicleRow(frameId, vehicle, feedTimestamp, nextParamNumber);
    allValues.push(...row.values);
    allPlaceholders.push(row.placeholderString);
  }

  await client.query(
    `INSERT INTO vehicle_position (${columns.join(', ')})
     VALUES ${allPlaceholders.join(', ')}
     ON CONFLICT (frame_id, vehicle_id) DO NOTHING`,
    allValues
  );

  return 'loaded';
}

async function main() {
  const client = new Client({ connectionString: DATABASE_URL });
  await client.connect();

  const rawDir = path.join(DATA_ROOT, 'raw');
  const days = fs.readdirSync(rawDir).filter((d) => !only || d === only).sort();

  const stats = { loaded: 0, empty: 0, skipped: 0, vehicleRows: 0, failed: 0 };

  for (const day of days) {
    const dir = path.join(rawDir, day);
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.pb.gz')).sort();
    process.stdout.write(`${day}: ${files.length} frames `);

    let filesDone = 0;
    for (const file of files) {
      try {
        const result = await loadFrame(client, dir, file);
        stats[result === 'loaded' ? 'loaded' : result === 'empty' ? 'empty' : 'skipped']++;
      } catch (e) {
        stats.failed++;
        console.error(`\n  ${file} FAILED: ${e.message}`);
      }
      filesDone++;
      // A dot every 500 files so a long run still shows signs of life.
      if (filesDone % 500 === 0) process.stdout.write('.');
    }
    console.log(' done');
  }

  const counted = await client.query('SELECT count(*) FROM vehicle_position');
  stats.vehicleRows = Number(counted.rows[0].count);

  console.log('\n== summary ==');
  console.log(`  frames newly loaded (with vehicles): ${stats.loaded}`);
  console.log(`  frames newly loaded (empty)        : ${stats.empty}`);
  console.log(`  frames already in DB (skipped)      : ${stats.skipped}`);
  console.log(`  frames that failed to decode        : ${stats.failed}`);
  console.log(`  vehicle_position rows in DB (total) : ${stats.vehicleRows}`);

  await client.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
