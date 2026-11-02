'use strict';

/**
 * Look at every bus's history of raw positions, in time order, and decide
 * which readings to trust.
 *
 * This is the second half of turning a raw GPS spot into "here is where
 * the bus really is". db/compute_vehicle_raw_progress.sql already worked
 * out the plain "closest point on the route line" answer for every single
 * reading - that part has no memory of anything. This script goes through
 * those readings one bus at a time, in the order they actually happened,
 * and checks each new reading against the last one we trusted for that
 * same bus. See decideAcceptedDistance() below for the actual rule.
 *
 * This needs to remember state (the last trusted reading for each bus) as
 * it goes, which is awkward to express as one big database query, so it is
 * written as a normal step-by-step script instead.
 *
 * Usage:
 *   node tools/match-vehicle-progress.js
 *
 * Each batch is saved to the database as soon as it's decided, not just at
 * the very end. That means if this script is stopped partway through (or
 * the computer restarts, or anything else interrupts it), nothing already
 * saved is lost - running it again picks up only the readings that don't
 * have a decision yet, instead of starting over from nothing.
 *
 * One small side effect of that: if a run is stopped in the middle of one
 * particular bus's history and resumed later, that one bus's next reading
 * after the restart is treated as the start of a fresh sequence (like a
 * route change - see decideAcceptedDistance() below), instead of being
 * compared against its true last position. This only affects, at most, one
 * reading per bus that happened to be mid-sequence at the exact moment of
 * a restart - not worth extra complexity to avoid.
 *
 * Fixed 2026-08-16 (part 1): when a reading was rejected, the "last
 * trusted" record for that bus used to still move its clock forward to the
 * rejected reading's time, even though its distance stayed frozen at the
 * old value. That made the next comparison measure a growing distance gap
 * against a shrinking time gap, which almost guaranteed the next reading
 * would be rejected too. Now the last-trusted record is only touched on
 * acceptance, so a rejected reading never changes what the next one is
 * compared against.
 *
 * Fixed 2026-08-16 (part 2): fixing part 1 exposed a second, bigger problem
 * that it had been accidentally papering over. A bus's tracking only used
 * to reset on a route change, never on a trip change - but a bus finishing
 * one trip and starting its next one (very normal; a bus does many trips a
 * day on the same route) can jump straight from near the end of one trip's
 * line to near the start of the next one. That is a real, large, sudden
 * change, and with no trip-change reset it looked exactly like a bad GPS
 * fix - so it got rejected, forever, because nothing about the comparison
 * ever changes. Measured effect after fixing only part 1: worst single bus
 * stuck for 2,837 readings - about 25 hours, worse than before either fix.
 * Now tracking also resets on a trip change, the same way it already did
 * for a route change.
 */

const { Client } = require('pg');

const CONNECTION_STRING =
  process.env.DATABASE_URL || 'postgres://wimb:wimb_local_dev@localhost:5432/wimb';

// A Delhi city bus is never going to average faster than this. A reading
// that implies a higher speed than this is almost certainly a bad GPS fix,
// not a real, very fast bus.
const MAX_PLAUSIBLE_SPEED_MS = 25; // 90 km/h

// Ordinary GPS wobble on a phone or bus unit is usually within a few tens
// of metres. A jump backward bigger than this is treated as a bad reading,
// not the bus genuinely reversing.
const BACKWARD_TOLERANCE_M = 50;

// How close to the very end/start of a route counts as "at the end" /
// "at the start", for spotting a bus that finished its route and started
// the next lap. Delhi's shortest route is a few km, so this is small
// enough to not misfire on a real mid-route position.
const END_OF_ROUTE_MARGIN_M = 300;

// How many readings to process before writing results back to the
// database in one go. Writing 17 million rows one at a time would take far
// too long, so they are grouped into batches like this instead.
const BATCH_SIZE = 5000;

/**
 * Decide whether one new bus-position reading should be trusted, given the
 * last reading we trusted for the same bus.
 *
 * `last` is { distanceM, timeS, routeId, tripId } for the last trusted
 * reading, or null if this is the first reading we have ever seen for this
 * bus. `reading` is the new one, in the same shape, plus `routeLengthM` -
 * the total length of the route line this bus is on, in metres. Both
 * distanceM values are "how far along the route", in metres; timeS is the
 * reading's own GPS timestamp, in seconds.
 */
function decideAcceptedDistance(last, reading) {
  // No history yet for this bus, or it just switched to a different route
  // or trip. There is nothing sensible to compare against, so the new
  // reading is simply trusted as the start of a fresh sequence.
  if (!last || last.routeId !== reading.routeId || last.tripId !== reading.tripId) {
    return { accepted: true, distanceM: reading.distanceM, reason: null };
  }

  // The bus was near the very end of its route, and is now near the very
  // start. Real GPS traced this exact pattern on route 2716: distance sat
  // at 106,681m (route length ~107km) then the next reading was 63m. That
  // is not a bad GPS fix - it is the bus finishing its route and starting
  // the next lap. OTD's feed keeps the same trip_id for both laps (it is
  // labelled by scheduled departure slot, not a unique journey), so route
  // and trip alone cannot catch this - the position pattern itself has to.
  const wasNearEnd = last.distanceM >= reading.routeLengthM - END_OF_ROUTE_MARGIN_M;
  const nowNearStart = reading.distanceM <= END_OF_ROUTE_MARGIN_M;
  if (wasNearEnd && nowNearStart) {
    return { accepted: true, distanceM: reading.distanceM, reason: null };
  }

  const secondsPassed = reading.timeS - last.timeS;

  // The same GPS fix reported again - no new information, nothing to
  // check. Keep it as accepted, at the same spot as before.
  if (secondsPassed <= 0) {
    return { accepted: true, distanceM: last.distanceM, reason: null };
  }

  const metresMoved = reading.distanceM - last.distanceM;
  const impliedSpeedMS = metresMoved / secondsPassed;

  if (impliedSpeedMS > MAX_PLAUSIBLE_SPEED_MS) {
    return { accepted: false, distanceM: last.distanceM, reason: 'too fast' };
  }

  if (metresMoved < -BACKWARD_TOLERANCE_M) {
    return { accepted: false, distanceM: last.distanceM, reason: 'jumped backward' };
  }

  return { accepted: true, distanceM: reading.distanceM, reason: null };
}

// Writes one batch of decisions back to the database in a single update,
// using unnest() to turn the JavaScript lists back into database rows.
// This is just "update all these rows at once" written the standard
// Postgres way, instead of one slow round trip per row.
async function writeBatch(client, batch) {
  if (batch.length === 0) return;

  const frameIds = batch.map((r) => r.frameId);
  const vehicleIds = batch.map((r) => r.vehicleId);
  const distances = batch.map((r) => r.distanceM);
  const accepteds = batch.map((r) => r.accepted);
  const reasons = batch.map((r) => r.reason);

  await client.query(
    `
    UPDATE vehicle_progress AS target SET
      accepted_dist_along_route_m = data.distance_m,
      accepted = data.accepted,
      reject_reason = data.reason
    FROM (
      SELECT
        unnest($1::int[])     AS frame_id,
        unnest($2::text[])    AS vehicle_id,
        unnest($3::float8[])  AS distance_m,
        unnest($4::boolean[]) AS accepted,
        unnest($5::text[])    AS reason
    ) AS data
    WHERE target.frame_id = data.frame_id AND target.vehicle_id = data.vehicle_id
    `,
    [frameIds, vehicleIds, distances, accepteds, reasons]
  );
}

async function main() {
  const client = new Client({ connectionString: CONNECTION_STRING });
  await client.connect();

  // A cursor lets us walk through millions of rows a few thousand at a
  // time, instead of loading all of them into memory at once.
  //
  // WITH HOLD is important here: it lets the cursor stay open across
  // separate commits below. Without it, committing our progress after each
  // batch would also close the cursor and lose our place. This way, if the
  // script is stopped partway through (or crashes), everything already
  // committed stays saved - only the unfinished part is lost, not all of it.
  await client.query('BEGIN');
  await client.query(`
    DECLARE vehicle_cursor CURSOR WITH HOLD FOR
    SELECT vp.frame_id, vp.vehicle_id, vp.route_id, vp.trip_id,
           extract(epoch FROM vp.position_timestamp) AS time_s,
           p.raw_dist_along_route_m, rs.route_length_m
    FROM vehicle_position vp
    JOIN vehicle_progress p
      ON p.frame_id = vp.frame_id AND p.vehicle_id = vp.vehicle_id
    JOIN route_shape_lookup rs ON rs.route_id = vp.route_id
    WHERE p.accepted IS NULL
    ORDER BY vp.vehicle_id, vp.position_timestamp, vp.frame_id
  `);
  await client.query('COMMIT');

  // What we last trusted for each bus, so the next reading for that same
  // bus can be checked against it. Keyed by vehicle_id.
  const lastByVehicle = new Map();

  let totalProcessed = 0;
  let totalAccepted = 0;

  while (true) {
    const fetched = await client.query(`FETCH ${BATCH_SIZE} FROM vehicle_cursor`);
    if (fetched.rows.length === 0) break;

    const batch = [];

    for (const row of fetched.rows) {
      const reading = {
        distanceM: Number(row.raw_dist_along_route_m),
        timeS: Number(row.time_s),
        routeId: row.route_id,
        tripId: row.trip_id,
        routeLengthM: Number(row.route_length_m),
      };

      const last = lastByVehicle.get(row.vehicle_id) || null;
      const decision = decideAcceptedDistance(last, reading);

      batch.push({
        frameId: row.frame_id,
        vehicleId: row.vehicle_id,
        distanceM: decision.distanceM,
        accepted: decision.accepted,
        reason: decision.reason,
      });

      // Only move the "last trusted" record forward when this reading was
      // actually trusted. If we moved its clock forward on a rejection too,
      // the next reading would be compared against a distance that hasn't
      // moved but a time that has - making it look like the bus travelled
      // impossibly fast, which would reject it too. That was the bug fixed
      // on 2026-08-16 (see the file header comment).
      if (decision.accepted) {
        lastByVehicle.set(row.vehicle_id, {
          distanceM: decision.distanceM,
          timeS: reading.timeS,
          routeId: reading.routeId,
          tripId: reading.tripId,
        });
      }

      totalProcessed++;
      if (decision.accepted) totalAccepted++;
    }

    // This UPDATE commits on its own the moment it finishes (we are not
    // inside a BEGIN/COMMIT block here), so this batch's decisions are
    // safely saved before the loop moves on to the next one.
    await writeBatch(client, batch);
    console.log('processed', totalProcessed, '  accepted', totalAccepted,
      '  rejected', totalProcessed - totalAccepted);
  }

  await client.query('CLOSE vehicle_cursor');
  await client.end();

  console.log('');
  console.log('done.', totalProcessed, 'readings processed,', totalAccepted, 'accepted,',
    totalProcessed - totalAccepted, 'rejected.');
}

// Only run automatically when this file is executed directly (not when it
// is imported elsewhere, e.g. to test decideAcceptedDistance on its own).
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { decideAcceptedDistance };
