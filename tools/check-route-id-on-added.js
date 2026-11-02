'use strict';

/**
 * Quick check: when a bus is "extra" (not on the official timetable,
 * meaning schedule_relationship = ADDED), does it still tell us which
 * route it is on?
 *
 * We answer this by opening one day of recorded frames and counting, for
 * each schedule_relationship value, how many vehicles have a route_id
 * filled in versus blank. This does not check whether that route_id is a
 * real route in the static feed - it only checks whether the realtime feed
 * sends one at all.
 *
 * Usage:
 *   node tools/check-route-id-on-added.js <day-folder-name>
 *   example: node tools/check-route-id-on-added.js 2026-08-09
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { transit_realtime } = require('gtfs-realtime-bindings');

// Archive lives outside the repo on purpose - see CLAUDE.md section 9.
const DATA_ROOT = process.env.DATA_ROOT || path.join(process.cwd(), 'data');
const day = process.argv[2] || '2026-08-09';

// Count vehicles by schedule_relationship, split into "has a route_id" and
// "route_id is blank". This is the only question this script answers.
function countRouteIdPresence(dayFolder) {
  const counts = {};

  const dir = path.join(DATA_ROOT, 'raw', dayFolder);
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.pb.gz'));

  // One frame every 10 seconds is a lot of repeats of the same bus. We only
  // need a good sample, not every single frame, so we look at every 20th
  // file to keep this fast.
  const sampleFiles = files.filter((_, i) => i % 20 === 0);

  for (const file of sampleFiles) {
    const raw = fs.readFileSync(path.join(dir, file));
    const buf = zlib.gunzipSync(raw);
    const message = transit_realtime.FeedMessage.decode(buf);

    for (const entity of message.entity) {
      const vehicle = entity.vehicle;
      if (!vehicle) continue;

      const trip = vehicle.trip || {};
      const relationshipCode = trip.scheduleRelationship;
      const relationshipName = relationshipCode === undefined
        ? '(not sent)'
        : transit_realtime.TripDescriptor.ScheduleRelationship[relationshipCode];

      if (!counts[relationshipName]) {
        counts[relationshipName] = { hasRouteId: 0, blankRouteId: 0 };
      }

      const routeId = trip.routeId;
      if (routeId && routeId.length > 0) {
        counts[relationshipName].hasRouteId++;
      } else {
        counts[relationshipName].blankRouteId++;
      }
    }
  }

  return { counts, framesSampled: sampleFiles.length };
}

const { counts, framesSampled } = countRouteIdPresence(day);

console.log('day:', day, '   frames sampled:', framesSampled);
console.log('');
console.log('schedule_relationship'.padEnd(22), 'has route_id'.padEnd(14), 'route_id blank');
for (const [name, c] of Object.entries(counts)) {
  console.log(String(name).padEnd(22), String(c.hasRouteId).padEnd(14), c.blankRouteId);
}
