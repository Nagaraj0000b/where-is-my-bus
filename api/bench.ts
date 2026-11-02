// How fast is the API really?
//
//   npm run api      (one terminal)
//   npm run bench    (another)
//
// The numbers reported during development were warm-cache, one request at
// a time - the flattering case. This measures the honest ones: cold cache,
// sustained load, and percentiles rather than medians, because a p50 hides
// exactly the slow requests a user notices.

const BASE = process.env.API_BASE || 'http://localhost:3000';

// Real Delhi coordinates. Several pairs so the database cannot simply
// answer the same cached query over and over.
const PAIRS = [
  { name: 'short, well served', q: 'fromLat=28.6752&fromLon=77.1325&toLat=28.6761&toLon=77.1160' },
  { name: 'needs a change',     q: 'fromLat=28.59588&fromLon=77.06927&toLat=28.65970&toLon=76.99345' },
  { name: 'cross-city',         q: 'fromLat=28.6315&fromLon=77.2167&toLat=28.5355&toLon=77.3910' },
  { name: 'north-south',        q: 'fromLat=28.7041&fromLon=77.1025&toLat=28.5245&toLon=77.1855' },
];

async function timed(path: string): Promise<number> {
  const t = Date.now();
  const res = await fetch(BASE + path);
  await res.text();          // include reading the body, as a real client must
  return Date.now() - t;
}

function stats(ms: number[]) {
  const s = [...ms].sort((a, b) => a - b);
  const at = (p: number) => s[Math.min(s.length - 1, Math.floor(s.length * p))];
  return {
    n: s.length, min: s[0], p50: at(0.5), p90: at(0.9), p95: at(0.95),
    p99: at(0.99), max: s[s.length - 1],
    mean: Math.round(s.reduce((a, b) => a + b, 0) / s.length),
  };
}

function row(label: string, s: ReturnType<typeof stats>) {
  console.log(
    `  ${label.padEnd(26)} p50 ${String(s.p50).padStart(5)}ms   ` +
    `p95 ${String(s.p95).padStart(5)}ms   p99 ${String(s.p99).padStart(5)}ms   ` +
    `max ${String(s.max).padStart(5)}ms`);
}

async function main() {
  console.log(`benchmarking ${BASE}\n`);

  // -------------------------------------------------------------------
  console.log('COLD - first request after the database was restarted');
  // -------------------------------------------------------------------
  // Whatever ran before this warmed nothing for these queries, so this is
  // the worst case a user can hit: an empty cache.
  for (const p of PAIRS) {
    const ms = await timed(`/journey?${p.q}`);
    console.log(`  /journey  ${p.name.padEnd(20)} ${ms}ms`);
  }
  const coldByHour = await timed(`/journey/by-hour?${PAIRS[0].q}`);
  console.log(`  /journey/by-hour  (cold)        ${coldByHour}ms`);

  // -------------------------------------------------------------------
  console.log('\nWARM - one request at a time, 60 each, rotating pairs');
  // -------------------------------------------------------------------
  const journey: number[] = [];
  for (let i = 0; i < 60; i++) journey.push(await timed(`/journey?${PAIRS[i % PAIRS.length].q}`));
  row('/journey', stats(journey));

  const byHour: number[] = [];
  for (let i = 0; i < 20; i++) byHour.push(await timed(`/journey/by-hour?${PAIRS[i % PAIRS.length].q}`));
  row('/journey/by-hour', stats(byHour));

  const eta: number[] = [];
  for (let i = 0; i < 60; i++) eta.push(await timed('/eta?route=2251&from=2&to=12'));
  row('/eta', stats(eta));

  const near: number[] = [];
  for (let i = 0; i < 60; i++) near.push(await timed('/stops/near?lat=28.6315&lon=77.2167&radius=500'));
  row('/stops/near', stats(near));

  // -------------------------------------------------------------------
  console.log('\nUNDER LOAD - many users at once');
  // -------------------------------------------------------------------
  // The single-request numbers above are what one user sees on an idle
  // server. This is what they see when the server is busy, which is the
  // number that actually matters once anyone else is using it.
  for (const concurrency of [10, 25, 50]) {
    const started = Date.now();
    const all = await Promise.all(
      Array.from({ length: concurrency * 4 }, (_, i) =>
        timed(`/journey?${PAIRS[i % PAIRS.length].q}`)),
    );
    const wall = Date.now() - started;
    const s = stats(all);
    console.log(
      `  ${String(concurrency).padStart(2)} concurrent  ->  ` +
      `p50 ${String(s.p50).padStart(5)}ms  p95 ${String(s.p95).padStart(5)}ms  ` +
      `max ${String(s.max).padStart(5)}ms   ` +
      `(${concurrency * 4} requests in ${wall}ms = ${Math.round(concurrency * 4 / (wall / 1000))}/sec)`);
  }

  // -------------------------------------------------------------------
  console.log('\nWORST CASE - by-hour under load (the heaviest endpoint)');
  // -------------------------------------------------------------------
  const started = Date.now();
  const heavy = await Promise.all(
    Array.from({ length: 20 }, (_, i) => timed(`/journey/by-hour?${PAIRS[i % PAIRS.length].q}`)),
  );
  const s = stats(heavy);
  console.log(`  20 concurrent by-hour  ->  p50 ${s.p50}ms  p95 ${s.p95}ms  max ${s.max}ms ` +
    `(${Date.now() - started}ms wall)`);

  console.log('\nNote: these exclude network latency. A phone on Delhi mobile data');
  console.log('adds roughly 40-150ms round trip on top of every number above.');
}

main().catch((e) => {
  console.error('bench failed:', e.message);
  console.error('is the API running? start it with: npm run api');
  process.exit(1);
});
