// End-to-end tests for the running API, over real HTTP.
//
//   npm run api        (in one terminal)
//   npm run test-api   (in another)
//
// Different job from check-eta.ts. That one calls the ETA logic directly
// and asks "is the maths right". This one asks "does the service behave
// when a real client - or a careless one, or a hostile one - talks to it".
// So most of what is below is deliberately awkward input.

const BASE = process.env.API_BASE || 'http://localhost:3000';

let passed = 0;
let failed = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail = '') {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    failures.push(name + (detail ? ` (${detail})` : ''));
    console.log(`  FAIL  ${name}${detail ? ' - ' + detail : ''}`);
  }
}

function section(title: string) {
  console.log('\n' + title);
}

async function get(path: string) {
  const started = Date.now();
  const res = await fetch(BASE + path);
  const ms = Date.now() - started;
  let body: any = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, body, ms };
}

async function post(path: string, payload: any) {
  const started = Date.now();
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const ms = Date.now() - started;
  let body: any = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, body, ms };
}

async function main() {
  console.log(`testing ${BASE}`);

  // -------------------------------------------------------------------
  section('1. Service is up');
  // -------------------------------------------------------------------
  const health = await get('/health');
  check('GET /health returns 200', health.status === 200, `got ${health.status}`);
  check('health says ok', health.body?.ok === true);
  check('health reports route segments loaded',
    typeof health.body?.routeSegments === 'number' && health.body.routeSegments > 1000,
    `got ${health.body?.routeSegments}`);

  // -------------------------------------------------------------------
  section('2. A realistic user journey: near me -> route -> ETA');
  // -------------------------------------------------------------------
  // This is the actual sequence a phone app would perform.
  const near = await get('/stops/near?lat=28.6315&lon=77.2167&radius=500');
  check('found stops near Connaught Place', near.status === 200 && near.body.count > 0,
    `got ${near.body?.count}`);
  check('nearest stop is genuinely nearest',
    Number(near.body?.stops?.[0]?.metres_away) <= Number(near.body?.stops?.[1]?.metres_away),
    'results not sorted by distance');
  check('every stop is inside the radius asked for',
    near.body?.stops?.every((s: any) => Number(s.metres_away) <= 500));
  // Regression: Delhi lists a separate stop_id per direction of the same
  // physical stop. Near Connaught Place this used to show "Shivaji Stadium
  // Terminal" and "Regal / Palika Kendra" twice each. /stops/near now
  // routes through stop_place so one physical place is one result.
  check('each place appears at most once (no direction-pair duplicates)',
    new Set(near.body.stops.map((s: any) => s.place_id)).size === near.body.stops.length,
    `${near.body.stops.length} stops but fewer distinct places`);
  check('every result carries a place_id',
    near.body.stops.every((s: any) => s.place_id !== undefined));

  // Pick a route that actually has travel-time data, then walk its stops.
  const routeProbe = await get('/routes/2251/stops');
  check('GET /routes/2251/stops returns 200', routeProbe.status === 200,
    `got ${routeProbe.status}`);
  check('route has stops', routeProbe.body?.stopCount > 0, `got ${routeProbe.body?.stopCount}`);
  check('stops come back in sequence order',
    routeProbe.body?.stops?.every((s: any, i: number, arr: any[]) =>
      i === 0 || s.stop_sequence > arr[i - 1].stop_sequence));
  check('stops carry their distance along the route',
    routeProbe.body?.stops?.[0]?.metres_along_route !== undefined);

  const eta = await get('/eta?route=2251&from=2&to=12');
  check('GET /eta returns 200', eta.status === 200, `got ${eta.status}`);
  check('eta is available', eta.body?.available === true);
  check('estimate has both seconds and human text',
    typeof eta.body?.estimate?.seconds === 'number' && typeof eta.body?.estimate?.text === 'string');

  // -------------------------------------------------------------------
  section('3. The honesty contract - the whole point of the project');
  // -------------------------------------------------------------------
  check('a range is ALWAYS present alongside the estimate',
    eta.body?.range?.earliestSeconds !== undefined &&
    eta.body?.range?.latestSeconds !== undefined);
  check('the range actually brackets the estimate',
    eta.body.range.earliestSeconds <= eta.body.estimate.seconds &&
    eta.body.range.latestSeconds >= eta.body.estimate.seconds,
    `${eta.body.range.earliestSeconds} <= ${eta.body.estimate.seconds} <= ${eta.body.range.latestSeconds}`);
  check('confidence has a level AND a plain-language reason',
    ['high', 'medium', 'low'].includes(eta.body?.confidence?.level) &&
    typeof eta.body?.confidence?.because === 'string' &&
    eta.body.confidence.because.length > 20);
  check('provenance is exposed, not hidden',
    eta.body?.basis?.legsByDetail !== undefined);
  check('leg counts add up to the number of stops travelled',
    Object.values(eta.body.basis.legsByDetail as Record<string, number>)
      .reduce((a, b) => a + b, 0) === eta.body.stopsAway,
    JSON.stringify(eta.body.basis.legsByDetail));
  check('caveats are present', Array.isArray(eta.body?.caveats) && eta.body.caveats.length > 0);
  check('caveats admit there is no live position',
    eta.body.caveats.some((c: string) => c.toLowerCase().includes('live')));

  // -------------------------------------------------------------------
  section('4. Refuses rather than guesses');
  // -------------------------------------------------------------------
  const backwards = await get('/eta?route=2251&from=12&to=5');
  check('a stop behind the bus returns 422, not a number',
    backwards.status === 422, `got ${backwards.status}`);
  check('and explains why', typeof backwards.body?.reason === 'string');
  check('and does NOT include an estimate field',
    backwards.body?.estimate === undefined);

  const sameStop = await get('/eta?route=2251&from=5&to=5');
  check('asking about the stop the bus is at returns 422',
    sameStop.status === 422, `got ${sameStop.status}`);

  const unknownRoute = await get('/eta?route=definitely-not-a-route&from=1&to=5');
  check('an unknown route returns 422 rather than 0 seconds',
    unknownRoute.status === 422, `got ${unknownRoute.status}`);

  const unknownRouteStops = await get('/routes/definitely-not-a-route/stops');
  check('unknown route on /routes returns 404',
    unknownRouteStops.status === 404, `got ${unknownRouteStops.status}`);

  // -------------------------------------------------------------------
  section('5. Careless input');
  // -------------------------------------------------------------------
  const noParams = await get('/eta');
  check('missing every parameter returns 400', noParams.status === 400, `got ${noParams.status}`);
  check('and the error explains the shape expected',
    typeof noParams.body?.error === 'string' && noParams.body.error.includes('route'));

  const partial = await get('/eta?route=2251&from=2');
  check('missing "to" returns 400', partial.status === 400, `got ${partial.status}`);

  const notNumbers = await get('/eta?route=2251&from=abc&to=xyz');
  check('non-numeric stop positions return 400', notNumbers.status === 400,
    `got ${notNumbers.status}`);

  const fractional = await get('/eta?route=2251&from=2.7&to=12.3');
  check('fractional stop positions return 400', fractional.status === 400,
    `got ${fractional.status}`);

  const badDate = await get('/eta?route=2251&from=2&to=12&at=not-a-date');
  check('an unparseable "at" returns 400', badDate.status === 400, `got ${badDate.status}`);

  const negative = await get('/eta?route=2251&from=-5&to=3');
  check('negative stop positions do not crash the server',
    negative.status === 200 || negative.status === 422 || negative.status === 400,
    `got ${negative.status}`);

  const huge = await get('/eta?route=2251&from=1&to=999999');
  check('an absurd stop number is refused, not answered',
    huge.status === 422, `got ${huge.status}`);

  const noLatLon = await get('/stops/near');
  check('/stops/near without coordinates returns 400', noLatLon.status === 400,
    `got ${noLatLon.status}`);

  const badLatLon = await get('/stops/near?lat=hello&lon=world');
  check('/stops/near with nonsense coordinates returns 400', badLatLon.status === 400,
    `got ${badLatLon.status}`);

  const oceanic = await get('/stops/near?lat=0&lon=0&radius=500');
  check('coordinates in the ocean return an empty list, not an error',
    oceanic.status === 200 && oceanic.body.count === 0, `got ${oceanic.status}`);

  const notFound = await get('/no-such-endpoint');
  check('an unknown path returns 404', notFound.status === 404, `got ${notFound.status}`);

  // -------------------------------------------------------------------
  section('6. Hostile input');
  // -------------------------------------------------------------------
  // The route id goes into a parameterised query, so this should be
  // treated as a route name that simply does not exist - never executed.
  const injection = await get(
    "/routes/" + encodeURIComponent("2251'; DROP TABLE stops; --") + "/stops");
  check('SQL injection in a path parameter is treated as data',
    injection.status === 404, `got ${injection.status}`);

  const stillThere = await get('/stops/near?lat=28.6315&lon=77.2167&radius=300');
  check('...and the stops table still exists afterwards',
    stillThere.status === 200 && stillThere.body.count > 0);

  const injectionQuery = await get(
    '/eta?route=' + encodeURIComponent("' OR 1=1 --") + '&from=1&to=3');
  check('SQL injection in a query parameter is treated as data',
    injectionQuery.status === 422, `got ${injectionQuery.status}`);

  const hugeRadius = await get('/stops/near?lat=28.6315&lon=77.2167&radius=99999999');
  check('an enormous radius does not hang or crash',
    hugeRadius.status === 200 && hugeRadius.body.count <= 30,
    `got ${hugeRadius.status}, count ${hugeRadius.body?.count} - should stay capped`);

  // -------------------------------------------------------------------
  section('7. Behaviour that should hold across requests');
  // -------------------------------------------------------------------
  const weekday = await get('/eta?route=2251&from=2&to=12&at=2026-08-19T13:30:00Z'); // Wed 19:00
  const weekend = await get('/eta?route=2251&from=2&to=12&at=2026-08-15T13:30:00Z'); // Sat 19:00
  check('a weekday request is labelled weekday',
    weekday.body?.basis?.dayType === 'weekday', `got ${weekday.body?.basis?.dayType}`);
  check('a weekend request is labelled weekend',
    weekend.body?.basis?.dayType === 'weekend', `got ${weekend.body?.basis?.dayType}`);
  check('weekend responses warn that weekend data is thin',
    weekend.body?.caveats?.some((c: string) => c.toLowerCase().includes('weekend')),
    JSON.stringify(weekend.body?.caveats));
  check('the two give different estimates (day type is really used)',
    weekday.body?.estimate?.seconds !== weekend.body?.estimate?.seconds,
    'weekday and weekend produced identical answers');

  const longer = await get('/eta?route=2251&from=2&to=20');
  const shorter = await get('/eta?route=2251&from=2&to=6');
  if (longer.body?.available && shorter.body?.available) {
    check('a longer journey takes longer',
      longer.body.estimate.seconds > shorter.body.estimate.seconds);
    check('a longer journey has a wider range',
      (longer.body.range.latestSeconds - longer.body.range.earliestSeconds) >
      (shorter.body.range.latestSeconds - shorter.body.range.earliestSeconds));
  }

  // Regression: on a thin route the statistical band can reach back before
  // "now", which once produced "the bus may arrive 44 seconds ago". Real
  // as a statistic, nonsense to show someone standing at a stop - and the
  // text and the number disagreed, which is worse than either alone.
  const thinRoute = await get('/eta?route=2717&from=1&to=11');
  if (thinRoute.body?.available) {
    check('the early end of the range is never in the past',
      thinRoute.body.range.earliestSeconds >= 0,
      `got ${thinRoute.body.range.earliestSeconds}s`);
    check('the range text agrees with the range numbers',
      thinRoute.body.range.earliestSeconds === 0
        ? thinRoute.body.range.text.includes('any moment')
        : !thinRoute.body.range.text.includes('any moment'),
      `text "${thinRoute.body.range.text}" vs ${thinRoute.body.range.earliestSeconds}s`);
    check('and it says so explicitly when the bus could already be arriving',
      thinRoute.body.range.couldBeArrivingNow === true);
    check('earliestAt is never before the time asked about',
      new Date(thinRoute.body.range.earliestAt).getTime() >= Date.now() - 5000);
  }

  const repeat1 = await get('/eta?route=2251&from=2&to=12&at=2026-08-19T13:30:00Z');
  const repeat2 = await get('/eta?route=2251&from=2&to=12&at=2026-08-19T13:30:00Z');
  check('the same question twice gives the same answer',
    repeat1.body?.estimate?.seconds === repeat2.body?.estimate?.seconds);

  // -------------------------------------------------------------------
  section('8. /journey - the endpoint the app is really for');
  // -------------------------------------------------------------------
  // Two well-served points ~2 km apart, and a pair verified to need a
  // change (see api/check-journey.ts for how that pair was found).
  const NEARBY = 'fromLat=28.6752&fromLon=77.1325&toLat=28.6761&toLon=77.1160';
  const XFER   = 'fromLat=28.59588&fromLon=77.06927&toLat=28.65970&toLon=76.99345';

  const j = await get(`/journey?${NEARBY}&at=2026-08-19T03:30:00Z`);
  check('GET /journey returns 200', j.status === 200, `got ${j.status}`);
  check('it found ways to travel', j.body?.available === true && j.body.options.length > 0);
  check('options are sorted by total time',
    j.body.options.every((o: any, i: number, a: any[]) =>
      i === 0 || o.totalMinutes >= a[i - 1].totalMinutes));
  check('each option breaks down into walk, wait and ride',
    j.body.options.every((o: any) =>
      o.breakdown?.walkMinutes !== undefined &&
      o.breakdown?.waitMinutes !== undefined &&
      o.breakdown?.rideMinutes !== undefined));
  check('the breakdown actually sums to the total',
    j.body.options.every((o: any) =>
      Math.abs(o.totalMinutes -
        (o.breakdown.walkMinutes + o.breakdown.waitMinutes + o.breakdown.rideMinutes)) < 0.15));
  check('every option carries a range, never a bare number',
    j.body.options.every((o: any) =>
      o.rangeMinutes?.earliest !== undefined && o.rangeMinutes?.latest !== undefined));
  check('the range brackets the estimate and never starts in the past',
    j.body.options.every((o: any) =>
      o.rangeMinutes.earliest >= 0 &&
      o.rangeMinutes.earliest <= o.totalMinutes &&
      o.rangeMinutes.latest >= o.totalMinutes));
  check('each option says how much to trust it, in plain language',
    j.body.options.every((o: any) =>
      ['high','medium','low'].includes(o.confidence?.level) &&
      typeof o.confidence?.because === 'string' && o.confidence.because.length > 20));
  check('each option has a human-readable summary',
    j.body.options.every((o: any) => typeof o.summary === 'string' && o.summary.length > 10));
  check('walking and waiting assumptions are stated, not hidden',
    j.body.assumptions?.walkSpeedMetresPerMin > 0 &&
    typeof j.body.assumptions?.waitRule === 'string');
  check('caveats admit the data source and its limits',
    Array.isArray(j.body.caveats) && j.body.caveats.length >= 3);
  check('caveats admit these are not scheduled times',
    j.body.caveats.some((c: string) => c.toLowerCase().includes('not a published')
                                    || c.toLowerCase().includes('not scheduled')));

  const jx = await get(`/journey?${XFER}&at=2026-08-19T03:30:00Z`);
  const changed = jx.body?.options?.find((o: any) => o.changes === 1);
  check('a journey needing a change is served over HTTP', changed !== undefined,
    'transfer path not reachable through the API');
  if (changed) {
    check('a one-change option returns two legs', changed.legs.length === 2);
    check('the change place is the same in both legs',
      changed.legs[0].alightPlace === changed.legs[1].boardPlace);
    check('each leg reports how often that bus runs',
      changed.legs.every((l: any) => 'busEveryMinutes' in l));
    check('the summary mentions both routes',
      changed.summary.includes(changed.legs[0].routeName) &&
      changed.summary.includes(changed.legs[1].routeName));
  }

  // A weekend request must warn that weekend data is thin.
  const jw = await get(`/journey?${NEARBY}&at=2026-08-15T03:30:00Z`);
  check('weekend requests are labelled weekend',
    jw.body?.context?.dayType === 'weekend', `got ${jw.body?.context?.dayType}`);
  check('and warn that weekend data rests on two days',
    jw.body?.caveats?.some((c: string) => c.toLowerCase().includes('weekend')));

  // --- careless and hostile input on the new endpoint ---
  const jNone = await get('/journey');
  check('/journey with no parameters returns 400', jNone.status === 400, `got ${jNone.status}`);
  check('and the error shows the expected shape',
    typeof jNone.body?.error === 'string' && jNone.body.error.includes('fromLat'));

  const jPartial = await get('/journey?fromLat=28.6&fromLon=77.1');
  check('/journey missing the destination returns 400', jPartial.status === 400,
    `got ${jPartial.status}`);

  const jBadNum = await get('/journey?fromLat=abc&fromLon=xyz&toLat=1&toLon=2');
  check('/journey with non-numeric coordinates returns 400', jBadNum.status === 400,
    `got ${jBadNum.status}`);

  const jOutOfRange = await get('/journey?fromLat=999&fromLon=77&toLat=28&toLon=77');
  check('/journey with an impossible latitude returns 400', jOutOfRange.status === 400,
    `got ${jOutOfRange.status}`);

  const jBadDate = await get(`/journey?${NEARBY}&at=not-a-date`);
  check('/journey with an unparseable time returns 400', jBadDate.status === 400,
    `got ${jBadDate.status}`);

  const jOcean = await get('/journey?fromLat=0&fromLon=0&toLat=0.02&toLon=0.02');
  check('/journey where there are no stops returns 422, not an invented route',
    jOcean.status === 422, `got ${jOcean.status}`);
  check('and explains that no route was found',
    typeof jOcean.body?.reason === 'string');

  const jInject = await get('/journey?fromLat=' +
    encodeURIComponent("28.6 OR 1=1; DROP TABLE stops;--") + '&fromLon=77&toLat=28&toLon=77');
  check('SQL injection in a coordinate is rejected as bad input',
    jInject.status === 400, `got ${jInject.status}`);
  const stopsAlive = await get('/stops/near?lat=28.6315&lon=77.2167&radius=300');
  check('...and the stops table is still there', stopsAlive.body?.count > 0);

  // -------------------------------------------------------------------
  section('8b. /journey/by-hour - "when should I travel?"');
  // -------------------------------------------------------------------
  const bh = await get(`/journey/by-hour?${NEARBY}`);
  check('GET /journey/by-hour returns 200', bh.status === 200, `got ${bh.status}`);
  check('covers the 19 service hours', bh.body?.hours?.length === 19,
    `got ${bh.body?.hours?.length}`);
  check('names a best and worst hour to travel',
    bh.body?.best?.hourOfDay !== undefined && bh.body?.worst?.hourOfDay !== undefined);
  check('the best hour is genuinely the quickest',
    bh.body.hours.filter((h: any) => h.bestTotalMinutes !== null)
      .every((h: any) => h.bestTotalMinutes >= bh.body.best.totalMinutes));
  check('gives plain-language advice', typeof bh.body?.advice === 'string'
    && bh.body.advice.length > 20);
  check('every costed hour carries a confidence',
    bh.body.hours.filter((h: any) => h.bestTotalMinutes !== null)
      .every((h: any) => ['high','medium','low'].includes(h.confidence)));
  check('hours with no service are null, not zero or missing',
    bh.body.hours.every((h: any) => h.bestTotalMinutes === null || h.bestTotalMinutes > 0));
  check('caveats admit these are observed, not scheduled',
    bh.body?.caveats?.some((c: string) => c.toLowerCase().includes('observed')));

  const bhWeekend = await get(`/journey/by-hour?${NEARBY}&dayType=weekend`);
  check('a weekend day type is honoured', bhWeekend.body?.dayType === 'weekend');
  check('weekend warns its data is thin',
    bhWeekend.body?.caveats?.some((c: string) => c.toLowerCase().includes('weekend')));

  const bhBadDay = await get(`/journey/by-hour?${NEARBY}&dayType=someday`);
  check('an invalid dayType returns 400', bhBadDay.status === 400, `got ${bhBadDay.status}`);

  const bhNone = await get('/journey/by-hour');
  check('/journey/by-hour with no parameters returns 400', bhNone.status === 400,
    `got ${bhNone.status}`);

  const bhOcean = await get('/journey/by-hour?fromLat=0&fromLon=0&toLat=0.02&toLon=0.02');
  check('/journey/by-hour where nothing runs returns 422', bhOcean.status === 422,
    `got ${bhOcean.status}`);

  console.log(`  /journey/by-hour: ${bh.ms}ms (was 3700ms before the single-query rewrite)`);
  check('by-hour responds under 1500ms', bh.ms < 1500, `${bh.ms}ms`);

  // -------------------------------------------------------------------
  section('8c. /routes/search - browsing by route number');
  // -------------------------------------------------------------------
  const routeSearch = await get('/routes/search?q=764');
  check('GET /routes/search returns 200', routeSearch.status === 200,
    `got ${routeSearch.status}`);
  check('finds both directions of route 764',
    routeSearch.body?.routes?.some((r: any) => r.route_short_name === '764UP') &&
    routeSearch.body?.routes?.some((r: any) => r.route_short_name === '764DOWN'),
    JSON.stringify(routeSearch.body?.routes?.map((r: any) => r.route_short_name)));
  check('every result carries a route_desc to tell directions apart',
    routeSearch.body?.routes?.every((r: any) => typeof r.route_desc === 'string'));
  check('an exact-number match (764UP/764DOWN) is sorted before 764B... variants',
    ['764UP', '764DOWN'].includes(routeSearch.body.routes[0].route_short_name) &&
    ['764UP', '764DOWN'].includes(routeSearch.body.routes[1].route_short_name),
    JSON.stringify(routeSearch.body.routes.slice(0, 2).map((r: any) => r.route_short_name)));

  const routeSearchNone = await get('/routes/search?q=zz9nomatch');
  check('a route number nobody runs returns an empty list, not an error',
    routeSearchNone.status === 200 && routeSearchNone.body?.count === 0,
    `got ${routeSearchNone.status}, count ${routeSearchNone.body?.count}`);

  const routeSearchEmpty = await get('/routes/search?q=');
  check('an empty q returns 400', routeSearchEmpty.status === 400,
    `got ${routeSearchEmpty.status}`);

  // -------------------------------------------------------------------
  section('9. Speed');
  // -------------------------------------------------------------------
  const jt: number[] = [];
  for (let i = 0; i < 10; i++) jt.push((await get(`/journey?${NEARBY}`)).ms);
  jt.sort((a, b) => a - b);
  const jMedian = jt[Math.floor(jt.length / 2)];
  console.log(`  /journey over 10 calls: median ${jMedian}ms, worst ${jt[jt.length - 1]}ms`);
  check('median /journey response under 500ms', jMedian < 500, `${jMedian}ms`);

  const jxt = (await get(`/journey?${XFER}`)).ms;
  console.log(`  /journey with transfer search: ${jxt}ms`);
  check('a transfer journey responds under 2s', jxt < 2000, `${jxt}ms`);
  const timings: number[] = [];
  for (let i = 0; i < 20; i++) {
    const r = await get('/eta?route=2251&from=2&to=12');
    timings.push(r.ms);
  }
  timings.sort((a, b) => a - b);
  const median = timings[Math.floor(timings.length / 2)];
  const worst = timings[timings.length - 1];
  console.log(`  /eta over 20 calls: median ${median}ms, worst ${worst}ms`);
  check('median ETA response under 100ms', median < 100, `${median}ms`);
  check('worst ETA response under 500ms', worst < 500, `${worst}ms`);

  const concurrent = Date.now();
  await Promise.all(Array.from({ length: 30 }, () => get('/eta?route=2251&from=2&to=15')));
  const concurrentMs = Date.now() - concurrent;
  console.log(`  30 concurrent /eta calls: ${concurrentMs}ms total`);
  check('30 concurrent requests complete under 3s', concurrentMs < 3000, `${concurrentMs}ms`);

  // -------------------------------------------------------------------
  section('10. Crowdsourced Telemetry Ingestion & Consensus');
  // -------------------------------------------------------------------
  const missingPing = await post('/crowdsource/ping', { route_id: '764' });
  check('missing coordinates returns 400', missingPing.status === 400, `got ${missingPing.status}`);

  const walkingPing = await post('/crowdsource/ping', {
    route_id: '764',
    lat: 28.6323,
    lon: 77.2165,
    speed: 3.0,
  });
  check('pedestrian walking speed (<5 km/h) returns 400', walkingPing.status === 400, `got ${walkingPing.status}`);

  const validAlice = await post('/crowdsource/ping', {
    route_id: '764',
    lat: 28.6323,
    lon: 77.2165,
    speed: 22.5,
    device_id: 'dev-alice',
  });
  check('valid onboard telemetry returns 200', validAlice.status === 200, `got ${validAlice.status}`);
  check('returns confirmed ping data', validAlice.body?.ok === true && validAlice.body?.ping?.routeId === '764');

  const liveState = await get('/routes/764/crowdsourced');
  check('GET /routes/:id/crowdsourced returns 200', liveState.status === 200, `got ${liveState.status}`);
  check('returns active crowdsourced vehicle array', Array.isArray(liveState.body?.vehicles) && liveState.body?.vehicles.length > 0);
  check('provenance is explicitly crowdsourced-telemetry', liveState.body?.provenance === 'crowdsourced-telemetry');

  // -------------------------------------------------------------------
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failures.length) {
    console.log('\nfailures:');
    for (const f of failures) console.log('  - ' + f);
  }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('test run itself failed:', e.message);
  console.error('is the API running? start it with: npm run api');
  process.exit(1);
});
