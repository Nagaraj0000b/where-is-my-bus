'use strict';

/**
 * Walk the archive and report fleet count over time.
 *
 *   node tools/scan-archive.js            all days
 *   node tools/scan-archive.js 2026-08-09 one day
 *
 * Answers the questions the timetable cannot: how many buses were actually
 * visible, and when did the feed lie about it.
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { transit_realtime } = require('gtfs-realtime-bindings');

// Archive lives outside the repo on purpose - see CLAUDE.md section 9.
const DATA_ROOT = process.env.DATA_ROOT || path.join(process.cwd(), 'data');
const only = process.argv[2];

const rawDir = path.join(DATA_ROOT, 'raw');
const days = fs.readdirSync(rawDir).filter((d) => !only || d === only).sort();

let total = 0, empty = 0, failed = 0;
const counts = [];

for (const day of days) {
  const dir = path.join(rawDir, day);
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.pb.gz')).sort();
  console.log('\n== ' + day + ' — ' + files.length + ' frames ==');

  let prev = null;
  for (const f of files) {
    total++;
    let n, feedTs;
    try {
      const buf = zlib.gunzipSync(fs.readFileSync(path.join(dir, f)));
      const m = transit_realtime.FeedMessage.decode(buf);
      n = m.entity.length;
      feedTs = Number(m.header.timestamp);
    } catch (e) {
      failed++;
      console.log('  ' + f + '  DECODE FAILED: ' + e.message);
      continue;
    }
    counts.push(n);
    if (n === 0) {
      empty++;
      console.log('  ' + f.slice(3, 18) + '  ** ZERO VEHICLES ** (feed served an empty but valid response)');
    } else if (prev !== null && prev > 0) {
      const delta = n - prev;
      // A tenth of the fleet appearing or vanishing between two frames 10s
      // apart is not buses moving. It is the feed.
      if (Math.abs(delta) > prev * 0.10) {
        console.log('  ' + f.slice(3, 18) + '  ' + String(n).padStart(5) +
          '  jump ' + (delta > 0 ? '+' : '') + delta +
          ' (' + ((delta / prev) * 100).toFixed(0) + '%)');
      }
    }
    prev = n;
  }
}

if (counts.length) {
  const s = [...counts].sort((a, b) => a - b);
  const q = (x) => s[Math.floor(s.length * x)];
  console.log('\n== fleet visible in the feed ==');
  console.log('  frames decoded ', counts.length, ' zero-vehicle:', empty, ' undecodable:', failed);
  console.log('  min', s[0], ' p05', q(0.05), ' p50', q(0.5), ' p95', q(0.95), ' max', s[s.length - 1]);
  const nz = s.filter((x) => x > 0);
  if (nz.length) {
    const spread = nz[nz.length - 1] - nz[0];
    console.log('  ignoring empties, the count swings by ' + spread +
      ' buses (' + ((spread / nz[nz.length - 1]) * 100).toFixed(0) + '% of peak)');
  }
}
