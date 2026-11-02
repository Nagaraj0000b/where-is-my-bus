'use strict';

/**
 * Phase 1 reconnaissance. Streams every GTFS file once and reports what is
 * actually in it. Nothing here is production code - it exists to answer
 * schema questions before the schema is written.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const ROOT = process.argv[2] || 'process.env.PROFILE_GTFS_ROOT || path.join(process.cwd(), 'delhi_buses_static_gtfs_v1')';

function splitCsv(line) {
  // These files have no quoted fields with commas in the columns we touch,
  // but stop_name can contain quotes, so handle the simple quoted case.
  if (line.indexOf('"') === -1) return line.split(',');
  const out = [];
  let cur = '';
  let q = false;
  for (const ch of line) {
    if (ch === '"') q = !q;
    else if (ch === ',' && !q) { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

async function scan(file, onHeader, onRow) {
  const rl = readline.createInterface({
    input: fs.createReadStream(path.join(ROOT, file)),
    crlfDelay: Infinity,
  });
  let header = null;
  let n = 0;
  for await (const line of rl) {
    if (!line.trim()) continue;
    if (!header) {
      header = splitCsv(line).map((h) => h.trim().replace(/^\uFEFF/, ''));
      onHeader(header);
      continue;
    }
    n++;
    onRow(splitCsv(line), n);
  }
  return n;
}

function pct(a, b) {
  return b === 0 ? '0%' : ((a / b) * 100).toFixed(1) + '%';
}

(async () => {
  const report = [];
  const say = (s) => { report.push(s); console.log(s); };

  // ---- stops ---------------------------------------------------------------
  const stopIds = new Set();
  const stopNames = new Map();
  let badCoord = 0;
  let outsideDelhi = 0;
  {
    let col;
    const n = await scan('stops.txt', (h) => { col = h; }, (r) => {
      const id = r[col.indexOf('stop_id')];
      const name = r[col.indexOf('stop_name')];
      const lat = Number(r[col.indexOf('stop_lat')]);
      const lon = Number(r[col.indexOf('stop_lon')]);
      stopIds.add(id);
      stopNames.set(name, (stopNames.get(name) || 0) + 1);
      if (!Number.isFinite(lat) || !Number.isFinite(lon) || (lat === 0 && lon === 0)) badCoord++;
      // Delhi NCR rough bounding box
      else if (lat < 28.2 || lat > 29.0 || lon < 76.7 || lon > 77.6) outsideDelhi++;
    });
    const dupNames = [...stopNames.values()].filter((c) => c > 1).length;
    say('## stops.txt');
    say(`  rows                 ${n}`);
    say(`  unique stop_id       ${stopIds.size}`);
    say(`  distinct stop_name   ${stopNames.size}  (${dupNames} names used by >1 stop)`);
    say(`  bad/zero coords      ${badCoord}`);
    say(`  outside Delhi bbox   ${outsideDelhi}`);
    say('');
  }

  // ---- routes --------------------------------------------------------------
  const routeIds = new Set();
  let longEqShort = 0;
  let emptyDesc = 0;
  const routeTypes = new Map();
  const agencies = new Map();
  {
    let col;
    const n = await scan('routes.txt', (h) => { col = h; say('## routes.txt\n  header               ' + h.join(',')); }, (r) => {
      const id = r[col.indexOf('route_id')];
      routeIds.add(id);
      const ln = r[col.indexOf('route_long_name')];
      const sn = r[col.indexOf('route_short_name')];
      if (ln === sn) longEqShort++;
      if (!r[col.indexOf('route_desc')]) emptyDesc++;
      const t = r[col.indexOf('route_type')];
      routeTypes.set(t, (routeTypes.get(t) || 0) + 1);
      const a = r[col.indexOf('agency_id')];
      agencies.set(a, (agencies.get(a) || 0) + 1);
    });
    say(`  rows                 ${n}`);
    say(`  unique route_id      ${routeIds.size}`);
    say(`  long_name==short     ${longEqShort} (${pct(longEqShort, n)})`);
    say(`  empty route_desc     ${emptyDesc}`);
    say(`  route_type           ${[...routeTypes].map(([k, v]) => k + ':' + v).join(' ')}`);
    say(`  agency_id            ${[...agencies].map(([k, v]) => k + ':' + v).join(' ')}`);
    say('');
  }

  // ---- trips ---------------------------------------------------------------
  const tripIds = new Set();
  const tripShape = new Map();
  const tripRoute = new Map();
  const shapeIdsUsed = new Set();
  const serviceIds = new Map();
  let noShape = 0, noDir = 0, noBlock = 0, noHeadsign = 0, orphanRoute = 0;
  {
    let col;
    const n = await scan('trips.txt', (h) => { col = h; }, (r) => {
      const tid = r[col.indexOf('trip_id')];
      const rid = r[col.indexOf('route_id')];
      const sid = r[col.indexOf('shape_id')];
      tripIds.add(tid);
      tripRoute.set(tid, rid);
      tripShape.set(tid, sid);
      if (!routeIds.has(rid)) orphanRoute++;
      if (!sid) noShape++; else shapeIdsUsed.add(sid);
      if (!r[col.indexOf('direction_id')]) noDir++;
      if (!r[col.indexOf('block_id')]) noBlock++;
      if (!r[col.indexOf('trip_headsign')]) noHeadsign++;
      const sv = r[col.indexOf('service_id')];
      serviceIds.set(sv, (serviceIds.get(sv) || 0) + 1);
    });
    say('## trips.txt');
    say(`  rows                 ${n}`);
    say(`  unique trip_id       ${tripIds.size}`);
    say(`  distinct shape_id    ${shapeIdsUsed.size}`);
    say(`  missing shape_id     ${noShape} (${pct(noShape, n)})`);
    say(`  empty direction_id   ${noDir} (${pct(noDir, n)})`);
    say(`  empty block_id       ${noBlock} (${pct(noBlock, n)})`);
    say(`  empty trip_headsign  ${noHeadsign} (${pct(noHeadsign, n)})`);
    say(`  trips w/ unknown rt  ${orphanRoute}`);
    say(`  service_id spread    ${[...serviceIds].map(([k, v]) => k + ':' + v).join(' ')}`);
    say('');
  }

  // ---- shapes --------------------------------------------------------------
  const shapeDefined = new Set();
  let shapePts = 0, shapeDistBlank = 0, shapeDistZero = 0;
  const shapeMaxDist = new Map();
  {
    let col;
    shapePts = await scan('shapes.txt', (h) => { col = h; }, (r) => {
      const sid = r[col.indexOf('shape_id')];
      shapeDefined.add(sid);
      const d = r[col.indexOf('shape_dist_traveled')];
      if (d === undefined || d === '') shapeDistBlank++;
      else {
        const v = Number(d);
        if (v === 0) shapeDistZero++;
        const cur = shapeMaxDist.get(sid) || 0;
        if (v > cur) shapeMaxDist.set(sid, v);
      }
    });
    const lens = [...shapeMaxDist.values()].sort((a, b) => a - b);
    const q = (p) => lens.length ? lens[Math.floor(lens.length * p)] : 0;
    say('## shapes.txt');
    say(`  points               ${shapePts}`);
    say(`  distinct shape_id    ${shapeDefined.size}`);
    say(`  blank dist_traveled  ${shapeDistBlank} (${pct(shapeDistBlank, shapePts)})`);
    say(`  avg pts per shape    ${(shapePts / shapeDefined.size).toFixed(0)}`);
    say(`  shape length metres  p05=${q(0.05).toFixed(0)} p50=${q(0.5).toFixed(0)} p95=${q(0.95).toFixed(0)} max=${(lens[lens.length - 1] || 0).toFixed(0)}`);
    let missing = 0;
    for (const s of shapeIdsUsed) if (!shapeDefined.has(s)) missing++;
    say(`  shapes used by trips but absent from shapes.txt: ${missing}`);
    let unused = 0;
    for (const s of shapeDefined) if (!shapeIdsUsed.has(s)) unused++;
    say(`  shapes defined but never used by a trip:         ${unused}`);
    say('');
  }

  // ---- stop_times ----------------------------------------------------------
  {
    let col;
    let rows = 0;
    let stopDistBlank = 0, arrEqDep = 0, seqStartsZero = 0, past24 = 0;
    let orphanTrip = 0, orphanStop = 0, nonMonotonic = 0, timeNonMonotonic = 0;
    const tripStopCount = new Map();
    const tripFirstSeq = new Map();
    const lastSeqByTrip = new Map();
    const lastTimeByTrip = new Map();
    const stopsSeen = new Set();
    const fareStages = new Map();

    const toSec = (t) => {
      const p = t.split(':');
      if (p.length !== 3) return NaN;
      return (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2]);
    };

    rows = await scan('stop_times.txt', (h) => { col = h; say('## stop_times.txt\n  header               ' + h.join(',')); }, (r) => {
      const tid = r[col.indexOf('trip_id')];
      const stopId = r[col.indexOf('stop_id')];
      const seq = Number(r[col.indexOf('stop_sequence')]);
      const arr = r[col.indexOf('arrival_time')];
      const dep = r[col.indexOf('departure_time')];
      const sd = r[col.indexOf('stop_dist')];
      const fs_ = r[col.indexOf('fare_stage')];

      if (sd === undefined || sd === '') stopDistBlank++;
      if (arr === dep) arrEqDep++;
      const a = toSec(arr);
      if (a >= 86400) past24++;
      if (!tripIds.has(tid)) orphanTrip++;
      if (!stopIds.has(stopId)) orphanStop++;
      stopsSeen.add(stopId);
      fareStages.set(fs_, (fareStages.get(fs_) || 0) + 1);

      tripStopCount.set(tid, (tripStopCount.get(tid) || 0) + 1);
      if (!tripFirstSeq.has(tid)) tripFirstSeq.set(tid, seq);
      if (seq === 0) seqStartsZero++;

      const ls = lastSeqByTrip.get(tid);
      if (ls !== undefined && seq <= ls) nonMonotonic++;
      lastSeqByTrip.set(tid, seq);

      const lt = lastTimeByTrip.get(tid);
      if (lt !== undefined && a < lt) timeNonMonotonic++;
      lastTimeByTrip.set(tid, a);
    });

    const counts = [...tripStopCount.values()].sort((a, b) => a - b);
    const qq = (p) => counts[Math.floor(counts.length * p)];
    let tripsNoTimes = 0;
    for (const t of tripIds) if (!tripStopCount.has(t)) tripsNoTimes++;
    let stopsNeverServed = 0;
    for (const s of stopIds) if (!stopsSeen.has(s)) stopsNeverServed++;

    say(`  rows                 ${rows}`);
    say(`  trips represented    ${tripStopCount.size}`);
    say(`  blank stop_dist      ${stopDistBlank} (${pct(stopDistBlank, rows)})`);
    say(`  arrival==departure   ${arrEqDep} (${pct(arrEqDep, rows)})`);
    say(`  times >= 24:00:00    ${past24} (${pct(past24, rows)})`);
    say(`  stop_sequence == 0   ${seqStartsZero}`);
    say(`  seq not increasing   ${nonMonotonic}`);
    say(`  time going backwards ${timeNonMonotonic}`);
    say(`  rows w/ unknown trip ${orphanTrip}`);
    say(`  rows w/ unknown stop ${orphanStop}`);
    say(`  fare_stage values    ${[...fareStages].slice(0, 6).map(([k, v]) => (k === '' ? '(blank)' : k) + ':' + v).join(' ')}`);
    say(`  stops per trip       min=${counts[0]} p50=${qq(0.5)} p95=${qq(0.95)} max=${counts[counts.length - 1]}`);
    say(`  trips with no times  ${tripsNoTimes}`);
    say(`  stops never served   ${stopsNeverServed}`);
    say('');
  }

  fs.writeFileSync(path.join(__dirname, 'gtfs-profile.txt'), report.join('\n'));
  console.log('written to gtfs-profile.txt');
})();
