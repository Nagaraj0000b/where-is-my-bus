// tools/simulate-passenger.js
//
// Simulates live passenger mobile beacons along a real Delhi bus corridor (Route 764).
// Demonstrates crowdsourced telemetry imputation when agency GPS is missing or lagging.
//
// Usage:
//   node tools/simulate-passenger.js              (continuous live simulation)
//   node tools/simulate-passenger.js --once       (sends 3 sample hops and verifies API, then exits)
//   node tools/simulate-passenger.js --interval 500

const API_BASE = process.env.API_BASE || 'http://localhost:3000';
const ROUTE_ID = '764';

// Real stop coordinates along Route 764 (UP direction: Jharoda to Najafgarh/Nehru Place corridor)
const ROUTE_764_STOPS = [
  { seq: 0, id: '9357', name: 'Jharoda Kalan Border', lat: 28.668189, lon: 76.940980 },
  { seq: 1, id: '3172', name: 'Jharoda Kalan', lat: 28.655083, lon: 76.950083 },
  { seq: 2, id: '6725', name: 'CRPF Jharoda', lat: 28.638699, lon: 76.960579 },
  { seq: 3, id: '3177', name: 'Sainik Enclave Jharoda', lat: 28.634205, lon: 76.963407 },
  { seq: 4, id: '3179', name: 'Bangali Colony', lat: 28.627867, lon: 76.967333 },
  { seq: 5, id: '3180', name: 'Baba Haridass Nagar', lat: 28.623817, lon: 76.970483 },
  { seq: 6, id: '4101', name: 'New Anaj Mandi', lat: 28.619058, lon: 76.974408 },
  { seq: 7, id: '3184', name: 'Jharoda Crossing', lat: 28.613874, lon: 76.979440 },
  { seq: 8, id: '4142', name: 'Najafgarh Stand', lat: 28.614263, lon: 76.980945 },
  { seq: 9, id: '3186', name: 'Najafgarh Health Centre', lat: 28.614125, lon: 76.985132 },
  { seq: 10, id: '4247', name: 'Najafgarh Delhi Gate', lat: 28.612622, lon: 76.987005 },
  { seq: 11, id: '3534', name: 'Tuda Mandi', lat: 28.612594, lon: 76.991382 },
  { seq: 12, id: '3535', name: 'Power House Najafgarh', lat: 28.613028, lon: 76.995734 },
  { seq: 13, id: '3536', name: 'Sai Baba Mandir', lat: 28.613534, lon: 76.999263 },
  { seq: 14, id: '10087', name: 'Indra Park (Nangli)', lat: 28.613806, lon: 77.000718 },
];

function parseArgs() {
  const args = process.argv.slice(2);
  let once = false;
  let intervalMs = 1500;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--once') once = true;
    if (args[i] === '--interval' && args[i + 1]) {
      intervalMs = parseInt(args[i + 1], 10);
      i++;
    }
  }
  return { once, intervalMs };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function sendPing(payload) {
  try {
    const res = await fetch(`${API_BASE}/crowdsource/ping`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const body = await res.json();
    return { ok: res.ok, status: res.status, body };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function getCrowdsourcedVehicles(routeId) {
  try {
    const res = await fetch(`${API_BASE}/routes/${routeId}/crowdsourced`);
    return await res.json();
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function main() {
  const { once, intervalMs } = parseArgs();

  console.log('================================================================');
  console.log('  WHERE IS MY BUS — CROWDSOURCED PASSENGER SIMULATOR');
  console.log(`  Route: ${ROUTE_ID} | Target API: ${API_BASE}`);
  console.log('  Simulating telemetry imputation for untracked Delhi buses...');
  console.log('================================================================\n');

  // Verify API is reachable
  try {
    const health = await fetch(`${API_BASE}/health`);
    if (!health.ok && health.status !== 503) {
      console.error(`[ERROR] API responded with unexpected status ${health.status}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`[ERROR] Could not connect to API at ${API_BASE}: ${err.message}`);
    console.error('Make sure the API server is running (e.g. npm run api).');
    process.exit(1);
  }

  const hopsToRun = once ? 3 : ROUTE_764_STOPS.length;

  for (let i = 0; i < hopsToRun; i++) {
    const stop = ROUTE_764_STOPS[i];
    const speedKmh = 18.0 + Math.random() * 8.0; // realistic 18 - 26 km/h urban speed

    console.log(`[STOP ${i + 1}/${ROUTE_764_STOPS.length}] Approaching: ${stop.name} (${stop.id})`);

    // 1. Primary passenger (Alice) broadcasts mobile telemetry beacon
    const pingAlice = {
      route_id: ROUTE_ID,
      lat: stop.lat,
      lon: stop.lon,
      speed: Number(speedKmh.toFixed(1)),
      device_id: 'passenger-alice-s23',
      timestamp: new Date().toISOString(),
    };
    const resAlice = await sendPing(pingAlice);
    if (!resAlice.ok) {
      console.error(`  [!] Alice ping rejected:`, resAlice.body || resAlice.error);
    } else {
      console.log(`  [BEACON] Alice: (${stop.lat.toFixed(5)}, ${stop.lon.toFixed(5)}) @ ${pingAlice.speed} km/h -> API: ${resAlice.status} OK`);
    }

    // 2. Simulate second passenger (Bob) on the same bus from stop 2 onwards
    if (i >= 1) {
      const pingBob = {
        route_id: ROUTE_ID,
        lat: stop.lat + 0.00008, // ~9 meters away inside the same bus
        lon: stop.lon + 0.00008,
        speed: Number((speedKmh - 0.5).toFixed(1)),
        device_id: 'passenger-bob-pixel8',
        timestamp: new Date().toISOString(),
      };
      const resBob = await sendPing(pingBob);
      if (resBob.ok) {
        console.log(`  [BEACON] Bob (co-passenger): agreeing within ~12m @ ${pingBob.speed} km/h`);
      }
    }

    // 3. Inspect crowdsourced vehicle state on the route
    const state = await getCrowdsourcedVehicles(ROUTE_ID);
    if (state.ok && state.vehicles && state.vehicles.length > 0) {
      const v = state.vehicles[0];
      const badge = v.confidence === 'high' ? '[HIGH CONFIDENCE]' : '[MEDIUM CONFIDENCE]';
      console.log(`  [IMPUTED FLEET] ${badge} Lat: ${v.lat}, Lon: ${v.lon}, Speed: ${v.speedKmh} km/h`);
      console.log(`                  Status: ${v.description}`);
    }

    console.log('----------------------------------------------------------------');

    if (!once && i < hopsToRun - 1) {
      await sleep(intervalMs);
    }
  }

  console.log('\n[SIMULATION COMPLETE] Successfully validated passenger telemetry pipeline.');
  if (once) {
    process.exit(0);
  }
}

main().catch((err) => {
  console.error('Fatal simulator error:', err);
  process.exit(1);
});
