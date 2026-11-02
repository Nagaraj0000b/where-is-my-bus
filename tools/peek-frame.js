'use strict';

/**
 * Look inside one recorded frame.
 *
 *   node tools/peek-frame.js                    newest frame in the archive
 *   node tools/peek-frame.js <file.pb.gz>       a specific frame
 *   node tools/peek-frame.js <file> --csv out.csv   every vehicle, as a spreadsheet
 *   node tools/peek-frame.js <file> --json         one vehicle, in full
 *
 * The archive is gzipped protobuf, which no ordinary program can open. This is
 * the readable view of it.
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { transit_realtime } = require('gtfs-realtime-bindings');

// Archive lives outside the repo on purpose - see CLAUDE.md section 9.
const DATA_ROOT = process.env.DATA_ROOT || path.join(process.cwd(), 'data');

function newestFrame() {
  const rawDir = path.join(DATA_ROOT, 'raw');
  if (!fs.existsSync(rawDir)) return null;
  const days = fs.readdirSync(rawDir).sort();
  for (let i = days.length - 1; i >= 0; i--) {
    const dir = path.join(rawDir, days[i]);
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.pb.gz')).sort();
    if (files.length) return path.join(dir, files[files.length - 1]);
  }
  return null;
}

const args = process.argv.slice(2);
const flags = args.filter((a) => a.startsWith('--'));
const positional = args.filter((a) => !a.startsWith('--'));
const file = positional[0] || newestFrame();

if (!file) {
  console.error('No frames found under ' + DATA_ROOT + '\\raw. Is the recorder running?');
  process.exit(1);
}

const raw = fs.readFileSync(file);
const buf = file.endsWith('.gz') ? zlib.gunzipSync(raw) : raw;
const msg = transit_realtime.FeedMessage.decode(buf);

// protobufjs puts defaults on the prototype, so an own-property check is the
// only way to tell "sent as zero" from "never sent".
const has = (o, k) => o != null && Object.prototype.hasOwnProperty.call(o, k);

const feedTs = Number(msg.header.timestamp);
console.log('file       ', path.basename(file));
console.log('feed time  ', new Date(feedTs * 1000).toISOString(),
            '(' + new Date(feedTs * 1000).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) + ' IST)');
console.log('vehicles   ', msg.entity.length);

const rows = [];
const ages = [];
const sched = {};
let moving = 0;

for (const e of msg.entity) {
  const v = e.vehicle;
  if (!v) continue;
  const t = v.trip || {};
  const p = v.position || {};
  const age = has(v, 'timestamp') ? feedTs - Number(v.timestamp) : null;
  if (age !== null) ages.push(age);

  const sr = has(t, 'scheduleRelationship')
    ? transit_realtime.TripDescriptor.ScheduleRelationship[t.scheduleRelationship]
    : '';
  sched[sr || '(absent)'] = (sched[sr || '(absent)'] || 0) + 1;
  if (has(p, 'speed') && p.speed > 0) moving++;

  rows.push({
    vehicle: (v.vehicle && v.vehicle.id) || e.id || '',
    route_id: t.routeId || '',
    trip_id: t.tripId || '',
    start_time: t.startTime || '',
    sched_rel: sr,
    lat: has(p, 'latitude') ? p.latitude.toFixed(6) : '',
    lon: has(p, 'longitude') ? p.longitude.toFixed(6) : '',
    speed: has(p, 'speed') ? p.speed : '',
    age_s: age === null ? '' : age,
  });
}

if (ages.length) {
  ages.sort((a, b) => a - b);
  const q = (x) => ages[Math.floor(ages.length * x)];
  console.log('position age (seconds behind the feed clock):');
  console.log('   min', ages[0], ' p50', q(0.5), ' p75', q(0.75), ' p95', q(0.95), ' max', ages[ages.length - 1]);
  console.log('   fresher than 30s:', ages.filter((a) => a <= 30).length + '/' + ages.length,
              '  older than 60s:', ages.filter((a) => a > 60).length + '/' + ages.length);
}
console.log('schedule relationship:', Object.entries(sched).map(([k, c]) => k + '=' + c).join('  '));
console.log('reporting non-zero speed:', moving + '/' + rows.length);

const csvFlag = flags.indexOf('--csv');
if (csvFlag !== -1) {
  const out = args[args.indexOf('--csv') + 1] || 'frame.csv';
  const cols = Object.keys(rows[0]);
  fs.writeFileSync(out, cols.join(',') + '\n' + rows.map((r) => cols.map((c) => r[c]).join(',')).join('\n') + '\n');
  console.log('\nwrote ' + out + ' — ' + rows.length + ' vehicles, opens in Excel');
} else if (flags.includes('--json')) {
  console.log('\none vehicle, every field the feed actually sent:');
  console.log(JSON.stringify(msg.entity[0], null, 2));
} else {
  console.log('\nfirst 15 vehicles:\n');
  const cols = ['vehicle', 'route_id', 'trip_id', 'start_time', 'sched_rel', 'lat', 'lon', 'age_s'];
  const w = cols.map((c) => Math.max(c.length, ...rows.slice(0, 15).map((r) => String(r[c]).length)));
  console.log(cols.map((c, i) => c.padEnd(w[i])).join('  '));
  console.log(w.map((x) => '-'.repeat(x)).join('  '));
  for (const r of rows.slice(0, 15)) console.log(cols.map((c, i) => String(r[c]).padEnd(w[i])).join('  '));
  console.log('\n--csv out.csv  for all ' + rows.length + ' vehicles    --json  for one in full');
}
