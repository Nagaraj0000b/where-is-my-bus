// Prove the ETA logic is right BEFORE putting it behind an API.
//
//   node api/check-eta.ts
//
// AGENTS.md working convention #4: "Script first, service second. Don't
// wrap logic in an API until it is correct in a script." This is that
// script. Every check either passes or explains what it expected.
//
// The important one is the last: it re-runs the real held-out-day
// experiment through THIS code, so the numbers the API will actually serve
// are checked against the numbers docs/eta-design.md promises - rather
// than assuming the code matches the design just because it was written
// from it.

import { pool } from './src/db.ts';
import { estimateArrival, delhiTimeParts, rangeForHops } from './src/eta.ts';

let passed = 0;
let failed = 0;

function check(name: string, condition: boolean, detail = '') {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name}${detail ? ' - ' + detail : ''}`);
  }
}

function section(title: string) {
  console.log('\n' + title);
}

async function main() {
  // -------------------------------------------------------------------
  section('1. Delhi time, not UTC');
  // -------------------------------------------------------------------
  // 2026-08-19 09:00 UTC is 14:30 in Delhi. If this returned 9 we would be
  // reading the wrong hour's statistics for every single request.
  const morningUtc = new Date('2026-08-19T09:00:00Z');
  const parts = delhiTimeParts(morningUtc);
  check('09:00 UTC is hour 14 in Delhi', parts.hourOfDay === 14,
    `got ${parts.hourOfDay}`);
  check('a Wednesday is a weekday', parts.dayType === 'weekday',
    `got ${parts.dayType}`);

  // Saturday 02:00 Delhi is still Friday in UTC - the case that would be
  // mis-filed as weekday traffic if we read the date in UTC.
  const satEarly = new Date('2026-08-14T20:30:00Z'); // = Sat 02:00 Delhi
  const satParts = delhiTimeParts(satEarly);
  check('Sat 02:00 Delhi counts as weekend', satParts.dayType === 'weekend',
    `got ${satParts.dayType}`);
  check('Sat 02:00 Delhi is hour 2', satParts.hourOfDay === 2,
    `got ${satParts.hourOfDay}`);

  // -------------------------------------------------------------------
  section('2. The range widens with distance, and never inverts');
  // -------------------------------------------------------------------
  const r1 = rangeForHops(1, 'weekday');
  const r10 = rangeForHops(10, 'weekday');
  const r20 = rangeForHops(20, 'weekday');
  check('range grows with journey length',
    (r20.high - r20.low) > (r10.high - r10.low) &&
    (r10.high - r10.low) > (r1.high - r1.low));
  check('lower bound is below upper bound at every length',
    r1.low < r1.high && r10.low < r10.high && r20.low < r20.high);
  check('weekend range is tighter than weekday',
    (rangeForHops(10, 'weekend').high - rangeForHops(10, 'weekend').low) <
    (r10.high - r10.low));
  // Between two measured anchors the answer should land between them.
  const r7 = rangeForHops(7, 'weekday');
  check('7 hops sits between the measured 5 and 10 anchors',
    r7.high > rangeForHops(5, 'weekday').high && r7.high < r10.high);

  // -------------------------------------------------------------------
  section('3. A real ETA on a real route');
  // -------------------------------------------------------------------
  // Pick by DATA DENSITY, not by number of stops. Picking the route with
  // the most stops (the obvious first instinct) chose a 176-stop route
  // whose observations were spread so thin across hours that almost every
  // hop fell back to the coarsest statistic - which made the rush-hour
  // check below meaningless, because both times of day resolved to the
  // same day-averaged number.
  const busiest = await pool.query<{ route_id: string; avg_obs: number }>(`
    SELECT route_id, avg(sample_count) AS avg_obs
    FROM route_segment_travel_time
    WHERE day_type = 'any'
    GROUP BY route_id
    HAVING max(to_stop_sequence) >= 15 AND count(*) >= 15
    ORDER BY avg(sample_count) DESC
    LIMIT 1
  `);
  const routeId = busiest.rows[0].route_id;

  const eta = await estimateArrival({
    routeId,
    fromStopSequence: 2,
    toStopSequence: 12,
    at: new Date('2026-08-19T12:30:00Z'), // 18:00 Delhi, evening rush
  });

  console.log(`  (route ${routeId}, stop 2 -> 12, 18:00 Delhi)`);
  console.log(`  predicted ${Math.round(eta.predictedSeconds)}s ` +
    `(${(eta.predictedSeconds / 60).toFixed(1)} min), ` +
    `range ${Math.round(eta.range.earliestSeconds)}..${Math.round(eta.range.latestSeconds)}s`);
  console.log(`  quality: ${JSON.stringify(eta.quality)}`);

  check('produced an estimate', eta.predictedSeconds > 0);
  check('counted 10 hops', eta.hops === 10, `got ${eta.hops}`);
  check('knows it is a weekday', eta.dayType === 'weekday');
  check('used Delhi hour 18', eta.hourOfDay === 18, `got ${eta.hourOfDay}`);
  check('estimate is physically plausible (2-60 min for 10 stops)',
    eta.predictedSeconds > 120 && eta.predictedSeconds < 3600,
    `got ${Math.round(eta.predictedSeconds)}s`);
  check('range brackets the estimate',
    eta.range.earliestSeconds < eta.predictedSeconds &&
    eta.range.latestSeconds > eta.predictedSeconds);
  check('arrival time matches the seconds figure',
    Math.abs((eta.predictedArrival.getTime() - new Date('2026-08-19T12:30:00Z').getTime()) / 1000
             - eta.predictedSeconds) < 1);

  // -------------------------------------------------------------------
  section('4. Rush hour really is slower than midday');
  // -------------------------------------------------------------------
  // Both times must be inside real service hours. Comparing against
  // midnight proves nothing: only 4% of midnight cells have enough data,
  // so midnight falls back to the day-averaged figure and would look
  // identical to anything else by construction.
  const rush = await estimateArrival({
    routeId, fromStopSequence: 2, toStopSequence: 12,
    at: new Date('2026-08-19T13:30:00Z'), // 19:00 Delhi - the measured peak
  });
  const offPeak = await estimateArrival({
    routeId, fromStopSequence: 2, toStopSequence: 12,
    at: new Date('2026-08-19T05:30:00Z'), // 11:00 Delhi - midday, well covered
  });
  console.log(`  19:00 Delhi: ${Math.round(rush.predictedSeconds)}s ` +
    `(${rush.quality['this-hour-this-daytype']}/10 hops at best detail) | ` +
    `11:00 Delhi: ${Math.round(offPeak.predictedSeconds)}s ` +
    `(${offPeak.quality['this-hour-this-daytype']}/10 at best detail)`);
  check('the estimate actually varies by time of day',
    rush.predictedSeconds !== offPeak.predictedSeconds,
    'both times gave the same answer - the hour statistics are not being used');
  check('the evening peak predicts a slower journey than midday',
    rush.predictedSeconds > offPeak.predictedSeconds,
    `peak ${Math.round(rush.predictedSeconds)}s vs midday ${Math.round(offPeak.predictedSeconds)}s`);
  check('most hops on a data-dense route use the best statistic',
    rush.quality['this-hour-this-daytype'] >= 8,
    `only ${rush.quality['this-hour-this-daytype']}/10`);

  // -------------------------------------------------------------------
  section('5. Refuses to answer rather than answering wrongly');
  // -------------------------------------------------------------------
  const backwards = await estimateArrival({
    routeId, fromStopSequence: 12, toStopSequence: 5,
  });
  check('a stop behind the bus is reported unavailable, not estimated',
    backwards.unavailable !== undefined && backwards.predictedSeconds === 0);

  const unknownRoute = await estimateArrival({
    routeId: 'no-such-route-9999', fromStopSequence: 1, toStopSequence: 5,
  });
  check('an unknown route is reported unavailable',
    unknownRoute.unavailable !== undefined,
    'should refuse when no segment has ever been observed');
  check('and says how many legs were missing',
    unknownRoute.unavailable?.missingHops === 4,
    `got ${unknownRoute.unavailable?.missingHops}`);

  // -------------------------------------------------------------------
  section('6. THE REAL TEST: does this code reproduce the design\'s numbers?');
  // -------------------------------------------------------------------
  // Re-run the held-out-day experiment through this exact code path, on a
  // sample of real journeys from a day the statistics were NOT built from.
  // docs/eta-design.md section 3 promises roughly 295s average error for a
  // 10-hop weekday journey. If this code disagrees, either the code or the
  // document is wrong and both need looking at.
  //
  // Note this is a slightly harder test than the design's own figure: the
  // production table was built from ALL seven days including this one, so
  // in principle it should do a little BETTER, not worse. It is used here
  // as a sanity bound, not a replication.
  const sample = await pool.query<{
    route_id: string; start_seq: number; end_seq: number;
    start_time: Date; actual_seconds: number;
  }>(`
    WITH runs AS (
      SELECT vehicle_id, route_id, stop_sequence, passage_time,
             row_number() OVER (PARTITION BY vehicle_id ORDER BY passage_time, stop_sequence)
               - stop_sequence AS run_key
      FROM observed_stop_passage
      WHERE day = '2026-08-13'
    )
    SELECT a.route_id, a.stop_sequence AS start_seq, b.stop_sequence AS end_seq,
           a.passage_time AS start_time,
           extract(epoch FROM b.passage_time - a.passage_time) AS actual_seconds
    FROM runs a
    JOIN runs b ON b.vehicle_id = a.vehicle_id AND b.route_id = a.route_id
               AND b.run_key = a.run_key AND b.stop_sequence = a.stop_sequence + 10
    ORDER BY random()
    LIMIT 400
  `);

  let errorTotal = 0;
  let signedTotal = 0;
  let scored = 0;

  for (const row of sample.rows) {
    const result = await estimateArrival({
      routeId: row.route_id,
      fromStopSequence: row.start_seq,
      toStopSequence: row.end_seq,
      at: row.start_time,
    });
    if (result.unavailable) continue;
    errorTotal += Math.abs(row.actual_seconds - result.predictedSeconds);
    signedTotal += row.actual_seconds - result.predictedSeconds;
    scored++;
  }

  const mae = errorTotal / scored;
  const bias = signedTotal / scored;
  console.log(`  scored ${scored} real 10-hop journeys from Thu 13 Aug`);
  console.log(`  average error ${mae.toFixed(1)}s, bias ${bias.toFixed(1)}s`);
  console.log(`  (docs/eta-design.md predicts ~295s error, ~+27s bias for weekday 10-hop)`);

  check('scored a decent sample', scored > 200, `only ${scored}`);
  check('average error is in the expected range (<450s)', mae < 450,
    `got ${mae.toFixed(1)}s - the code may not match the design`);
  check('bias is small and not wildly optimistic (<150s)', Math.abs(bias) < 150,
    `got ${bias.toFixed(1)}s`);

  // -------------------------------------------------------------------
  console.log(`\n${passed} passed, ${failed} failed`);
  await pool.end();
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
