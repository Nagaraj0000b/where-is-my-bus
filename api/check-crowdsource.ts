// Prove crowdsourced telemetry ingestion and consensus logic BEFORE
// putting it behind the Fastify API.
//
//   node api/check-crowdsource.ts
//
// Adheres strictly to AGENTS.md convention #4: "Script first, service second."
// Verifies:
//   - Coordinate sanity checks
//   - Speed threshold filters (reject walking < 5 km/h, reject aircraft > 80 km/h)
//   - Missing field guards
//   - Multi-passenger spatial clustering and consensus confidence scoring
//   - Sliding window TTL expiration

import {
  CrowdsourceStore,
  validatePassengerPing,
  haversineDistanceMeters,
  MIN_BUS_SPEED_KMH,
  MAX_BUS_SPEED_KMH,
} from './src/crowdsource.ts';

let passed = 0;
let failed = 0;
const failures: string[] = [];

function check(name: string, ok: boolean, detail = '') {
  if (ok) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    failures.push(name);
    console.log(`  FAIL  ${name}${detail ? ' - ' + detail : ''}`);
  }
}

function section(title: string) {
  console.log('\n' + title);
}

async function main() {
  section('1. Math & Distance Utilities');
  const dZero = haversineDistanceMeters(28.6323, 77.2165, 28.6323, 77.2165);
  check('zero distance between identical coordinates', dZero === 0);

  // Distance between Shivaji Stadium (28.6323, 77.2165) and Hanuman Mandir (28.6302, 77.2138) ~ 340m
  const dReal = haversineDistanceMeters(28.6323, 77.2165, 28.6302, 77.2138);
  check(
    'realistic distance computed between CP locations (~340m)',
    dReal > 300 && dReal < 400,
    `got ${dReal.toFixed(1)}m`,
  );

  section('2. Input & Bounds Validation');
  const missing = await validatePassengerPing(
    { routeId: '', lat: 28.6323, lon: 77.2165, speedKmh: 20 },
    { skipDbCheck: true },
  );
  check('rejects empty routeId', !missing.ok && missing.code === 'MISSING_FIELDS');

  const outOfBounds = await validatePassengerPing(
    { routeId: '764', lat: 12.9716, lon: 77.5946, speedKmh: 20 }, // Bangalore
    { skipDbCheck: true },
  );
  check(
    'rejects coordinates outside Delhi NCR',
    !outOfBounds.ok && outOfBounds.code === 'INVALID_COORDINATES',
  );

  const walking = await validatePassengerPing(
    { routeId: '764', lat: 28.6323, lon: 77.2165, speedKmh: 3.2 },
    { skipDbCheck: true },
  );
  check(
    `rejects walking speed (< ${MIN_BUS_SPEED_KMH} km/h)`,
    !walking.ok && walking.code === 'SPEED_OUT_OF_BOUNDS',
  );

  const plane = await validatePassengerPing(
    { routeId: '764', lat: 28.6323, lon: 77.2165, speedKmh: 140.0 },
    { skipDbCheck: true },
  );
  check(
    `rejects airplane speed (> ${MAX_BUS_SPEED_KMH} km/h)`,
    !plane.ok && plane.code === 'SPEED_OUT_OF_BOUNDS',
  );

  const valid = await validatePassengerPing(
    { routeId: '764', lat: 28.6323, lon: 77.2165, speedKmh: 28.5, deviceId: 'dev-1' },
    { skipDbCheck: true },
  );
  check('accepts plausible transit speed (28.5 km/h)', valid.ok);

  section('3. Store Ingestion & Multi-Passenger Consensus');
  const store = new CrowdsourceStore();

  // Passenger 1 pings on Route 764
  const p1 = await store.ingest(
    {
      routeId: '764',
      lat: 28.6323,
      lon: 77.2165,
      speedKmh: 22.0,
      deviceId: 'passenger-alice',
    },
    { skipDbCheck: true },
  );
  check('passenger 1 ping successfully ingested', p1.ok);

  let vehicles = store.getActiveVehicles('764');
  check('returns 1 active vehicle for route 764', vehicles.length === 1);
  check(
    'single passenger labeled medium confidence ("Passenger reported")',
    vehicles[0]?.confidence === 'medium',
    vehicles[0]?.confidence,
  );
  check('reports 1 active passenger beacon', vehicles[0]?.activePassengerCount === 1);

  // Passenger 2 pings on Route 764 within 40 meters (same bus)
  const p2 = await store.ingest(
    {
      routeId: '764',
      lat: 28.6325,
      lon: 77.2167,
      speedKmh: 24.0,
      deviceId: 'passenger-bob',
    },
    { skipDbCheck: true },
  );
  check('passenger 2 ping successfully ingested', p2.ok);

  vehicles = store.getActiveVehicles('764');
  check('co-located passengers cluster into 1 vehicle', vehicles.length === 1);
  check(
    'multi-passenger agreement escalates to high confidence ("Verified by crowd")',
    vehicles[0]?.confidence === 'high',
    vehicles[0]?.confidence,
  );
  check('reports 2 active passenger beacons', vehicles[0]?.activePassengerCount === 2);
  check(
    'averaged speed calculated correctly (23.0 km/h)',
    vehicles[0]?.speedKmh === 23.0,
    `got ${vehicles[0]?.speedKmh}`,
  );

  // Passenger 3 pings on Route 764 2 kilometers away (different bus on the corridor)
  await store.ingest(
    {
      routeId: '764',
      lat: 28.6150,
      lon: 77.2100,
      speedKmh: 19.5,
      deviceId: 'passenger-carol',
    },
    { skipDbCheck: true },
  );

  vehicles = store.getActiveVehicles('764');
  check('distant passengers resolve to 2 separate active buses on the route', vehicles.length === 2);

  section('4. Telemetry Staleness & Sliding TTL');
  const now = Date.now();
  // Query 4 minutes into the future (beyond the 3-minute TTL)
  const futureVehicles = store.getActiveVehicles('764', now + 4 * 60 * 1000);
  check('stale pings automatically expire from active tracking', futureVehicles.length === 0);

  // Summary
  console.log('\n----------------------------------------');
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    console.error('Failed checks:', failures);
    process.exit(1);
  } else {
    console.log('All crowdsource telemetry checks passed!\n');
  }
}

main().catch((err) => {
  console.error('Unexpected check failure:', err);
  process.exit(1);
});
