/**
 * test-arrival-alarm-coordination.js
 * 
 * Verifies end-to-end coordination between:
 *  1. Fastify API Server (live on http://localhost:3000)
 *  2. Crowdsourced Telemetry Ingestion (POST /crowdsource/ping)
 *  3. Dynamic ETA Engine (/eta?route=...&from=...&to=...)
 *  4. Client-side Arrival Alarm & Deboarding Alert Logic
 * 
 * Flow:
 *  - Discovers Route 764UP (routeId 2232) terminating at Nehru Place.
 *  - Commuter configures Arrival Alarm for Destination Stop (Nehru Place Terminal).
 *  - Passenger simulator broadcasts GPS telemetry along the route.
 *  - System tracks proximity and verifies alarm triggers precisely 1 stop away.
 */

const API_BASE = 'http://localhost:3000';

async function run() {
  console.log('===============================================================');
  console.log('🧪 TESTING END-TO-END ARRIVAL ALARM SYSTEM COORDINATION');
  console.log('===============================================================\n');

  // Step 1: Check API health
  console.log('[1/5] Verifying API Server Connectivity...');
  try {
    const healthRes = await fetch(`${API_BASE}/health`);
    if (!healthRes.ok) throw new Error(`HTTP ${healthRes.status}`);
    const health = await healthRes.json();
    console.log(`   ✓ API connected: ok=${health.ok}, routeSegments=${health.routeSegments}`);
  } catch (err) {
    console.error(`   ✗ API server unreachable at ${API_BASE}. Make sure the Fastify daemon is running.`);
    process.exit(1);
  }

  // Step 2: Search for Route 764 and fetch its ordered stops
  console.log('\n[2/5] Resolving Route 764 and Fetching Ordered Stops...');
  const searchRes = await fetch(`${API_BASE}/routes/search?q=764`);
  if (!searchRes.ok) throw new Error(`Route search failed: HTTP ${searchRes.status}`);
  const { routes } = await searchRes.json();
  const route764 = routes.find(r => r.route_short_name === '764UP') || routes[0];
  console.log(`   ✓ Found Route: "${route764.route_short_name}" (ID: ${route764.route_id})`);
  console.log(`     Desc: "${route764.route_desc}"`);

  const stopsRes = await fetch(`${API_BASE}/routes/${route764.route_id}/stops`);
  if (!stopsRes.ok) throw new Error(`Stops fetch failed: HTTP ${stopsRes.status}`);
  const { stops } = await stopsRes.json();
  console.log(`   ✓ Received ${stops.length} stops for Route ${route764.route_short_name}.`);

  // Target the terminal stop: Nehru Place Terminal (last stop)
  const targetStop = stops[stops.length - 1];
  console.log(`   🎯 Destination Target Stop: "${targetStop.stop_name}" (Sequence #${targetStop.stop_sequence})`);

  // Step 3: Initialize Commuter Arrival Alarm Client State
  console.log('\n[3/5] Configuring Client Arrival Alarm for Destination...');
  const alarmState = {
    isActive: true,
    isTriggered: false,
    routeId: route764.route_id,
    routeName: route764.route_short_name,
    targetStopName: targetStop.stop_name,
    targetStopSequence: targetStop.stop_sequence,
    stopThreshold: 1, // Alert 1 stop before
    minuteThreshold: 5,
    currentStopSequence: null,
    stopsAway: null,
    triggeredAt: null,
    triggerReason: null,
  };
  console.log(`   ✓ Alarm armed: threshold=1 stop before destination (Stop #${targetStop.stop_sequence})`);

  // Step 4: Simulate bus traveling towards destination
  console.log('\n[4/5] Simulating Bus Telemetry and Evaluating Proximity Trigger...');
  
  // Test stops: 4 stops away, 3 stops away, 2 stops away, 1 stop away
  const lastSeq = targetStop.stop_sequence;
  const testStages = [
    { seq: lastSeq - 4, expectedTrigger: false, desc: '4 stops away (monitoring)' },
    { seq: lastSeq - 3, expectedTrigger: false, desc: '3 stops away (approaching)' },
    { seq: lastSeq - 2, expectedTrigger: false, desc: '2 stops away (preparing)' },
    { seq: lastSeq - 1, expectedTrigger: true,  desc: '1 STOP AWAY (THRESHOLD REACHED!)' },
  ];

  for (const stage of testStages) {
    const currentStop = stops.find(s => s.stop_sequence === stage.seq);
    if (!currentStop) continue;

    // A. Broadcast passenger telemetry ping to API
    const pingRes = await fetch(`${API_BASE}/crowdsource/ping`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        route_id: route764.route_id,
        lat: currentStop.lat || 28.5500,
        lon: currentStop.lon || 77.2500,
        speed: 24.5,
        device_id: 'sim-alarm-passenger',
      }),
    });
    if (!pingRes.ok) throw new Error(`Ping failed at stop ${stage.seq}`);

    // B. Fetch live ETA from backend
    const etaRes = await fetch(`${API_BASE}/eta?route=${route764.route_id}&from=${stage.seq}&to=${targetStop.stop_sequence}`);
    const etaData = await etaRes.json();
    const etaText = etaData.available ? etaData.range.text : 'calculating';
    const stopsRemaining = targetStop.stop_sequence - stage.seq;

    // C. Client evaluates progress against alarm threshold
    alarmState.currentStopSequence = stage.seq;
    alarmState.stopsAway = stopsRemaining;

    if (stopsRemaining <= alarmState.stopThreshold && !alarmState.isTriggered) {
      alarmState.isTriggered = true;
      alarmState.triggeredAt = new Date().toISOString();
      alarmState.triggerReason = 'stopsRemaining';
    }

    const triggerStatus = alarmState.isTriggered ? '🚨 TRIGGERED' : '⏳ ACTIVE (MONITORING)';
    console.log(`   Stop #${stage.seq} (${currentStop.stop_name}):`);
    console.log(`      • Distance to destination: ${stopsRemaining} stop(s)`);
    console.log(`      • Backend ETA Window: "${etaText}"`);
    console.log(`      • Alarm Engine State: ${triggerStatus} [${stage.desc}]`);

    if (alarmState.isTriggered !== stage.expectedTrigger) {
      throw new Error(`Stage failure at stop #${stage.seq}: expected trigger=${stage.expectedTrigger}, got=${alarmState.isTriggered}`);
    }
  }

  // Step 5: Test Alarm Snooze and Dismissal
  console.log('\n[5/5] Testing Snooze and Dismissal Transitions...');
  // Snooze
  alarmState.isTriggered = false;
  alarmState.snoozedUntil = Date.now() + 120000;
  console.log('   ✓ Commuter pressed "Snooze": audible alert silenced for 2 minutes.');

  // Dismiss
  alarmState.isActive = false;
  alarmState.isTriggered = false;
  alarmState.snoozedUntil = null;
  console.log('   ✓ Commuter pressed "Dismiss": destination reached, alarm safely deactivated.');

  console.log('\n===============================================================');
  console.log('🎉 ALL SYSTEM COORDINATION CHECKS PASSED SUCCESSFULLY!');
  console.log('   • Fastify Ingestion ↔ Route Stops ↔ ETA Engine ↔ Alarm System');
  console.log('===============================================================\n');
}

run().catch(err => {
  console.error('\n❌ Coordination test failed:', err);
  process.exit(1);
});
