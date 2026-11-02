// Prove the journey planner is right BEFORE putting it behind an API.
//
//   node api/check-journey.ts
//
// Same discipline as check-eta.ts (AGENTS.md convention #4). The checks
// that matter most are the ones that would catch a plausible-looking but
// wrong answer: that totals actually add up, that ranking is by TOTAL time
// rather than ride time, and that a journey needing a change is really
// solved by that change rather than by a coincidence in the data.

import { pool } from './src/db.ts';
import { planJourney, planByHour } from './src/journey.ts';

let passed = 0, failed = 0;
const failures: string[] = [];

function check(name: string, ok: boolean, detail = '') {
  if (ok) { passed++; console.log(`  PASS  ${name}`); }
  else { failed++; failures.push(name); console.log(`  FAIL  ${name}${detail ? ' - ' + detail : ''}`); }
}
const section = (t: string) => console.log('\n' + t);

// Two points ~2 km apart, both well served (Shivaji Park / Ordinance Depot area).
const NEAR = { fromLat: 28.67520, fromLon: 77.13250, toLat: 28.67610, toLon: 77.11600 };
// Two points ~8 km apart, likely needing a change.
const FAR  = { fromLat: 28.67520, fromLon: 77.13250, toLat: 28.65900, toLon: 77.05800 };
// A pair that really does surface a one-change journey.
//
// Found the hard way. The first attempt used FAR, which turned out to have
// a direct route, so the transfer code never ran and the section passed by
// accident. The second attempt picked two PLACES with no direct route -
// which also failed to trigger it, because the planner searches an 800 m
// radius and legitimately reached a nearby place that WAS directly
// connected. Correct behaviour, useless as a test.
//
// So this pair was found by running the real planner over random distant
// pairs until one actually returned an option with a change in it.
const NEEDS_CHANGE = { fromLat: 28.59588, fromLon: 77.06927,
                       toLat: 28.65970, toLon: 76.99345 };

const WEEKDAY_9AM = new Date('2026-08-19T03:30:00Z'); // 09:00 Delhi, Wednesday

async function main() {
  // ------------------------------------------------------------------
  section('1. A short journey between two well-served places');
  // ------------------------------------------------------------------
  const near = await planJourney({ ...NEAR, at: WEEKDAY_9AM });
  check('found at least one way to travel', near.options.length > 0);
  check('knows it is a weekday', near.dayType === 'weekday');
  check('used Delhi hour 9', near.hourOfDay === 9, `got ${near.hourOfDay}`);

  const best = near.options[0];
  console.log(`  best: ${best.totalMinutes} min via route ${best.legs[0].routeId} ` +
    `(walk ${best.walkMinutes} + wait ${best.waitMinutes} + ride ${best.rideMinutes}), ` +
    `${best.changes} change(s), confidence ${best.confidence.level}`);

  check('a short hop needs no change', best.changes === 0, `got ${best.changes}`);
  check('total really is walk + wait + ride',
    Math.abs(best.totalMinutes - (best.walkMinutes + best.waitMinutes + best.rideMinutes)) < 0.15,
    `${best.totalMinutes} vs ${best.walkMinutes}+${best.waitMinutes}+${best.rideMinutes}`);
  check('journey time is plausible for ~2 km (3-45 min)',
    best.totalMinutes > 3 && best.totalMinutes < 45, `${best.totalMinutes} min`);
  check('every leg names a route and both ends',
    best.legs.every(l => l.routeId && l.boardPlace && l.alightPlace));
  check('the bus goes forward along its route',
    best.legs.every(l => l.alightStopSequence > l.boardStopSequence));
  check('stop count matches the sequence span',
    best.legs.every(l => l.stops === l.alightStopSequence - l.boardStopSequence));

  // ------------------------------------------------------------------
  section('2. Ranking is by TOTAL time, not ride time');
  // ------------------------------------------------------------------
  // This is the finding the whole design rests on: a faster ride can be a
  // worse journey when the bus comes less often.
  check('options come back sorted by total time',
    near.options.every((o, i, a) => i === 0 || o.totalMinutes >= a[i - 1].totalMinutes));

  const fasterRideRankedLower = near.options.some((o, i) =>
    i > 0 && o.rideMinutes < near.options[0].rideMinutes);
  if (fasterRideRankedLower) {
    console.log('  (confirmed: a faster-riding option ranks below a better total)');
  }
  check('no option claims a total below its own ride time',
    near.options.every(o => o.totalMinutes >= o.rideMinutes));

  // ------------------------------------------------------------------
  section('3. The honesty contract');
  // ------------------------------------------------------------------
  check('every option carries a range',
    near.options.every(o => o.rangeMinutes.earliest !== undefined
                         && o.rangeMinutes.latest !== undefined));
  check('the range brackets the estimate',
    near.options.every(o => o.rangeMinutes.earliest <= o.totalMinutes
                         && o.rangeMinutes.latest >= o.totalMinutes));
  check('the range never starts before now',
    near.options.every(o => o.rangeMinutes.earliest >= 0));
  check('every option has a confidence level and a plain reason',
    near.options.every(o => ['high','medium','low'].includes(o.confidence.level)
                         && o.confidence.because.length > 20));
  check('an option with no observed frequency is marked low confidence',
    near.options.every(o =>
      !o.legs.some(l => l.busEveryMinutes === null) || o.confidence.level === 'low'));
  check('walking assumptions are stated, not hidden',
    near.searched.walkSpeedMetresPerMin > 0 && near.searched.walkRadiusMetres > 0);

  // ------------------------------------------------------------------
  section('4. A longer journey - does the transfer search work?');
  // ------------------------------------------------------------------
  const far = await planJourney({ ...FAR, at: WEEKDAY_9AM });
  if (far.options.length > 0) {
    const f = far.options[0];
    console.log(`  best: ${f.totalMinutes} min, ${f.changes} change(s), ` +
      `${f.legs.map(l => l.routeId).join(' -> ')}, confidence ${f.confidence.level}`);
    check('a longer journey is found', true);
    check('its total also adds up',
      Math.abs(f.totalMinutes - (f.walkMinutes + f.waitMinutes + f.rideMinutes)) < 0.15);
    check('a longer journey takes longer than the short one',
      f.totalMinutes > best.totalMinutes, `${f.totalMinutes} vs ${best.totalMinutes}`);

    const changed = far.options.find(o => o.changes === 1);
    if (changed) {
      check('a one-change option has exactly two legs', changed.legs.length === 2);
      check('the change happens at the same place both legs touch',
        changed.legs[0].alightPlace === changed.legs[1].boardPlace,
        `${changed.legs[0].alightPlace} vs ${changed.legs[1].boardPlace}`);
      check('the two legs use different routes',
        changed.legs[0].routeId !== changed.legs[1].routeId);
      check('waiting is counted for BOTH buses, not just the first',
        Math.abs(changed.waitMinutes
          - (changed.legs[0].waitMinutes + changed.legs[1].waitMinutes)) < 0.15,
        `${changed.waitMinutes} vs legs ${changed.legs[0].waitMinutes}+${changed.legs[1].waitMinutes}`);
    }
  } else {
    console.log(`  no route found: ${far.unavailable?.reason?.slice(0, 70)}`);
    check('an unreachable pair explains itself rather than returning nothing',
      far.unavailable !== undefined);
  }

  // ------------------------------------------------------------------
  section('4b. A pair that genuinely NEEDS a change');
  // ------------------------------------------------------------------
  // The section above passed while never running the transfer code,
  // because that pair had a direct route. This pair is verified in the
  // data to have none, so it exercises the transfer path for real.
  const chg = await planJourney({ ...NEEDS_CHANGE, at: WEEKDAY_9AM });
  check('a transfer journey is found where no direct route exists',
    chg.options.length > 0, chg.unavailable?.reason?.slice(0, 60));

  // Take the changed option specifically. If a direct route also exists it
  // will rank first and is the better answer - but this section is here to
  // exercise the transfer code, so it must assert on a changed option.
  const c = chg.options.find(o => o.changes === 1);
  check('a one-change option is produced at all', c !== undefined,
    'transfer search returned nothing - the transfer path is not being exercised');

  if (c) {
    console.log(`  ${c.totalMinutes} min, ${c.changes} change(s), ` +
      `${c.legs.map(l => l.routeId).join(' -> ')} via ${c.legs[0].alightPlace}`);
    check('it really does involve a change', c.changes === 1, `got ${c.changes}`);
    check('a one-change option has exactly two legs', c.legs.length === 2);
    check('the change happens where both legs meet',
      c.legs[0].alightPlace === c.legs[1].boardPlace,
      `${c.legs[0].alightPlace} vs ${c.legs[1].boardPlace}`);
    check('the two legs use different routes',
      c.legs[0].routeId !== c.legs[1].routeId);
    check('waiting is counted for BOTH buses',
      Math.abs(c.waitMinutes - (c.legs[0].waitMinutes + c.legs[1].waitMinutes)) < 0.15,
      `${c.waitMinutes} vs ${c.legs[0].waitMinutes}+${c.legs[1].waitMinutes}`);
    check('riding is counted for BOTH legs',
      Math.abs(c.rideMinutes - (c.legs[0].rideMinutes + c.legs[1].rideMinutes)) < 0.15,
      `${c.rideMinutes} vs ${c.legs[0].rideMinutes}+${c.legs[1].rideMinutes}`);
    check('total still adds up with a change in it',
      Math.abs(c.totalMinutes - (c.walkMinutes + c.waitMinutes + c.rideMinutes)) < 0.15);
    check('both legs travel forward along their routes',
      c.legs.every(l => l.alightStopSequence > l.boardStopSequence));
    check('a two-bus journey is plausibly long (10-120 min)',
      c.totalMinutes > 10 && c.totalMinutes < 120, `${c.totalMinutes} min`);
  }

  // ------------------------------------------------------------------
  section('5. Refusing rather than inventing');
  // ------------------------------------------------------------------
  const ocean = await planJourney({
    fromLat: 0, fromLon: 0, toLat: 0.01, toLon: 0.01, at: WEEKDAY_9AM });
  check('a place with no stops returns no options, not a fabricated one',
    ocean.options.length === 0);
  check('and says why', ocean.unavailable !== undefined);

  const sameSpot = await planJourney({
    fromLat: 28.67520, fromLon: 77.13250, toLat: 28.67520, toLon: 77.13250, at: WEEKDAY_9AM });
  check('origin and destination at the same point does not crash',
    Array.isArray(sameSpot.options));

  // ------------------------------------------------------------------
  section('6. Time of day actually changes the answer');
  // ------------------------------------------------------------------
  const rush = await planJourney({ ...NEAR, at: new Date('2026-08-19T13:30:00Z') }); // 19:00
  const quiet = await planJourney({ ...NEAR, at: new Date('2026-08-19T06:30:00Z') }); // 12:00
  if (rush.options.length && quiet.options.length) {
    console.log(`  19:00 Delhi: ${rush.options[0].totalMinutes} min | ` +
      `12:00 Delhi: ${quiet.options[0].totalMinutes} min`);
    check('the same journey is not identical at different hours',
      rush.options[0].totalMinutes !== quiet.options[0].totalMinutes,
      'hour statistics may not be reaching the query');
  }

  const weekend = await planJourney({ ...NEAR, at: new Date('2026-08-15T03:30:00Z') }); // Sat
  check('a Saturday is recognised as a weekend', weekend.dayType === 'weekend',
    `got ${weekend.dayType}`);

  // ------------------------------------------------------------------
  section('7. "When should I travel?" - the same journey, hour by hour');
  // ------------------------------------------------------------------
  const byHour = await planByHour({ ...NEAR, dayType: 'weekday' });
  console.log(`  best ${byHour.best?.hourOfDay}:00 = ${byHour.best?.totalMinutes}min | ` +
    `worst ${byHour.worst?.hourOfDay}:00 = ${byHour.worst?.totalMinutes}min`);

  check('covers every service hour (05:00-23:00)', byHour.hours.length === 19,
    `got ${byHour.hours.length}`);
  check('hours come back in order',
    byHour.hours.every((h, i, a) => i === 0 || h.hourOfDay > a[i - 1].hourOfDay));
  check('identifies a best and worst hour',
    byHour.best !== null && byHour.worst !== null);
  check('the best hour really is the lowest total',
    byHour.hours.filter(h => h.bestTotalMinutes !== null)
      .every(h => (h.bestTotalMinutes as number) >= (byHour.best!.totalMinutes)));
  check('the worst hour really is the highest total',
    byHour.hours.filter(h => h.bestTotalMinutes !== null)
      .every(h => (h.bestTotalMinutes as number) <= (byHour.worst!.totalMinutes)));
  check('each costed hour breaks into wait and ride',
    byHour.hours.filter(h => h.bestTotalMinutes !== null)
      .every(h => h.waitMinutes !== null && h.rideMinutes !== null));
  check('wait and ride never exceed the total',
    byHour.hours.filter(h => h.bestTotalMinutes !== null)
      .every(h => (h.waitMinutes as number) + (h.rideMinutes as number)
                  <= (h.bestTotalMinutes as number) + 0.15));
  check('every costed hour carries a confidence',
    byHour.hours.filter(h => h.bestTotalMinutes !== null)
      .every(h => ['high','medium','low'].includes(h.confidence as string)));
  check('an hour with no service is null, not zero',
    byHour.hours.every(h => h.bestTotalMinutes === null || h.bestTotalMinutes > 0));

  // The point of doing this per hour rather than scaling one answer: the
  // best ROUTE can change with the hour, not just the duration.
  const routesUsed = new Set(byHour.hours.map(h => h.bestRouteSummary).filter(Boolean));
  console.log(`  ${routesUsed.size} different routes are best at different hours`);
  check('the best route is not assumed constant across the day',
    routesUsed.size > 1, 'only one route ever wins - hour data may not be reaching the query');

  const weekendHours = await planByHour({ ...NEAR, dayType: 'weekend' });
  check('a weekend request is planned as a weekend', weekendHours.dayType === 'weekend');
  check('weekend and weekday give different pictures',
    JSON.stringify(weekendHours.hours.map(h => h.bestTotalMinutes)) !==
    JSON.stringify(byHour.hours.map(h => h.bestTotalMinutes)));

  const nowhere = await planByHour({ fromLat: 0, fromLon: 0, toLat: 0.02, toLon: 0.02 });
  check('an unreachable pair reports no best hour rather than inventing one',
    nowhere.best === null && nowhere.unavailable !== undefined);

  // ------------------------------------------------------------------
  section('8. Speed');
  // ------------------------------------------------------------------
  const t0 = Date.now();
  for (let i = 0; i < 5; i++) await planJourney({ ...NEAR, at: WEEKDAY_9AM });
  const shortMs = (Date.now() - t0) / 5;
  const t1 = Date.now();
  for (let i = 0; i < 3; i++) await planJourney({ ...FAR, at: WEEKDAY_9AM });
  const farMs = (Date.now() - t1) / 3;
  const t2 = Date.now();
  for (let i = 0; i < 3; i++) await planByHour({ ...NEAR, dayType: 'weekday' });
  const byHourMs = (Date.now() - t2) / 3;
  console.log(`  short journey ${shortMs.toFixed(0)}ms | long journey ${farMs.toFixed(0)}ms | ` +
    `by-hour ${byHourMs.toFixed(0)}ms`);
  check('short journeys under 400ms', shortMs < 400, `${shortMs.toFixed(0)}ms`);
  check('long journeys (with transfer search) under 1500ms', farMs < 1500, `${farMs.toFixed(0)}ms`);
  // The first version of by-hour ran the planner 19 times and took 3.7s.
  // Costing all hours in one query brought it to ~0.5s.
  check('by-hour under 1500ms (it was 3700ms before the single-query rewrite)',
    byHourMs < 1500, `${byHourMs.toFixed(0)}ms`);

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failures.length) { console.log('\nfailures:'); failures.forEach(f => console.log('  - ' + f)); }
  await pool.end();
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
