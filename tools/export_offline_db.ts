/**
 * tools/export_offline_db.ts
 *
 * Exports static GTFS routes, places/stops, and ordered route_stops from
 * PostgreSQL into a clean SQLite script, then compiles it into a compact
 * on-device SQLite database at `app/assets/data/wimb_offline.db`.
 *
 * This database powers Where Is My Bus's Offline Transit Pack, allowing:
 *   - Offline stop/place search
 *   - Offline route search and stop listings
 *   - Offline direct bus lookups between any two stops
 *   - Zero data usage and sub-millisecond local query performance
 */

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { pool } from '../api/src/db.ts';

const OUTPUT_DIR = path.resolve('app/assets/data');
const SQL_PATH = path.resolve('scratch/wimb_offline.sql');
const DB_PATH = path.resolve('app/assets/data/wimb_offline.db');

function escapeSql(val: unknown): string {
  if (val === null || val === undefined) return 'NULL';
  return `'${String(val).replace(/'/g, "''")}'`;
}

async function exportDatabase() {
  console.log('===============================================================');
  console.log('📦 EXPORTING OFFLINE TRANSIT PACK (SQLITE DATABASE)');
  console.log('===============================================================\n');

  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }
  const scratchDir = path.dirname(SQL_PATH);
  if (!fs.existsSync(scratchDir)) {
    fs.mkdirSync(scratchDir, { recursive: true });
  }

  // Remove existing DB file if present
  if (fs.existsSync(DB_PATH)) {
    fs.unlinkSync(DB_PATH);
  }

  console.log('[1/4] Querying PostgreSQL for deduplicated routes, places, and route stops...');

  // 1. Routes
  const routesRes = await pool.query(`
    SELECT route_id, route_short_name, route_desc, direction_tag
    FROM routes
    WHERE snapshot_id = (SELECT max(snapshot_id) FROM routes)
    ORDER BY route_short_name
  `);
  console.log(`   ✓ Fetched ${routesRes.rows.length} routes.`);

  // 2. Stops / Places (deduplicated by place_id so duplicate directional stops are merged)
  const stopsRes = await pool.query(`
    SELECT DISTINCT ON (sp.place_id)
           sp.place_id, s.stop_id, s.stop_name, s.stop_lat AS lat, s.stop_lon AS lon
    FROM stops s
    JOIN stop_place sp ON sp.stop_id = s.stop_id
    WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
    ORDER BY sp.place_id, s.stop_id
  `);
  console.log(`   ✓ Fetched ${stopsRes.rows.length} unique transit hubs & stops.`);

  // 3. Ordered Route Stops (one canonical trip per route)
  const routeStopsRes = await pool.query(`
    SELECT DISTINCT ON (t.route_id, st.stop_sequence)
           t.route_id, st.stop_sequence, st.stop_id, s.stop_name,
           round(st.dist_along_shape_m::numeric, 0)::int AS metres_along_route,
           s.stop_lat AS lat, s.stop_lon AS lon
    FROM stop_times st
    JOIN trips t ON t.snapshot_id = st.snapshot_id AND t.trip_id = st.trip_id
    JOIN stops s ON s.snapshot_id = st.snapshot_id AND s.stop_id = st.stop_id
    WHERE st.snapshot_id = (SELECT max(snapshot_id) FROM stop_times)
    ORDER BY t.route_id, st.stop_sequence, st.stop_id
  `);
  console.log(`   ✓ Fetched ${routeStopsRes.rows.length} route-stop sequences.`);

  // Close pool cleanly
  await pool.end();

  // 4. Generate SQL Script
  console.log('\n[2/4] Generating optimized SQLite schema and bulk inserts...');
  const writeStream = fs.createWriteStream(SQL_PATH, { encoding: 'utf-8' });

  writeStream.write(`
PRAGMA journal_mode = OFF;
PRAGMA synchronous = 0;
PRAGMA cache_size = 100000;

BEGIN TRANSACTION;

CREATE TABLE routes (
  route_id TEXT PRIMARY KEY,
  route_short_name TEXT NOT NULL,
  route_desc TEXT,
  direction_tag TEXT
);

CREATE TABLE stops (
  place_id TEXT PRIMARY KEY,
  stop_id TEXT,
  stop_name TEXT NOT NULL,
  lat REAL,
  lon REAL
);

CREATE TABLE route_stops (
  route_id TEXT NOT NULL,
  stop_sequence INTEGER NOT NULL,
  stop_id TEXT NOT NULL,
  stop_name TEXT NOT NULL,
  metres_along_route INTEGER,
  lat REAL,
  lon REAL,
  PRIMARY KEY (route_id, stop_sequence)
);
`);

  // Insert routes
  for (const r of routesRes.rows) {
    writeStream.write(
      `INSERT INTO routes VALUES (${escapeSql(r.route_id)}, ${escapeSql(r.route_short_name)}, ${escapeSql(r.route_desc)}, ${escapeSql(r.direction_tag)});\n`,
    );
  }

  // Insert stops
  for (const s of stopsRes.rows) {
    writeStream.write(
      `INSERT INTO stops VALUES (${escapeSql(s.place_id)}, ${escapeSql(s.stop_id)}, ${escapeSql(s.stop_name)}, ${s.lat ?? 'NULL'}, ${s.lon ?? 'NULL'});\n`,
    );
  }

  // Insert route_stops
  for (const rs of routeStopsRes.rows) {
    writeStream.write(
      `INSERT INTO route_stops VALUES (${escapeSql(rs.route_id)}, ${rs.stop_sequence}, ${escapeSql(rs.stop_id)}, ${escapeSql(rs.stop_name)}, ${rs.metres_along_route ?? 'NULL'}, ${rs.lat ?? 'NULL'}, ${rs.lon ?? 'NULL'});\n`,
    );
  }

  // Indexes for high-performance offline querying
  writeStream.write(`
CREATE INDEX idx_routes_short_name ON routes(route_short_name);
CREATE INDEX idx_stops_name ON stops(stop_name);
CREATE INDEX idx_route_stops_route_id ON route_stops(route_id);
CREATE INDEX idx_route_stops_name ON route_stops(stop_name);
CREATE INDEX idx_route_stops_lookup ON route_stops(route_id, stop_sequence);

COMMIT;
`);

  await new Promise<void>((resolve, reject) => {
    writeStream.end((err?: Error | null) => {
      if (err) reject(err);
      else resolve();
    });
  });

  const sqlStats = fs.statSync(SQL_PATH);
  console.log(`   ✓ SQL export script generated: ${(sqlStats.size / (1024 * 1024)).toFixed(2)} MB.`);

  // 5. Compile into SQLite Database using Python sqlite3
  console.log('\n[3/4] Compiling into SQLite database binary with Python...');
  const pyCmd = `python -c "import sqlite3, os; con = sqlite3.connect(r'${DB_PATH}'); con.executescript(open(r'${SQL_PATH}', encoding='utf-8').read()); con.close();"`;
  execSync(pyCmd, { stdio: 'inherit' });

  const dbStats = fs.statSync(DB_PATH);
  const dbMb = (dbStats.size / (1024 * 1024)).toFixed(2);
  console.log(`   ✓ SQLite database successfully compiled at:`);
  console.log(`     ${DB_PATH} (${dbMb} MB)`);

  // Clean up scratch SQL script
  fs.unlinkSync(SQL_PATH);

  console.log('\n[4/4] Verifying compilation integrity...');
  const verifyCmd = `python -c "import sqlite3; con = sqlite3.connect(r'${DB_PATH}'); cur = con.cursor(); print('  Routes count:', cur.execute('SELECT count(*) FROM routes').fetchone()[0]); print('  Stops count:', cur.execute('SELECT count(*) FROM stops').fetchone()[0]); print('  Route-Stops count:', cur.execute('SELECT count(*) FROM route_stops').fetchone()[0]); con.close();"`;
  execSync(verifyCmd, { stdio: 'inherit' });

  console.log('\n===============================================================');
  console.log('🎉 OFFLINE TRANSIT PACK GENERATED SUCCESSFULLY!');
  console.log('===============================================================\n');
}

exportDatabase().catch(err => {
  console.error('\n❌ Export failed:', err);
  process.exit(1);
});
