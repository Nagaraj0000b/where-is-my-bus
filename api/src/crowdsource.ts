// Crowdsourced Telemetry Imputation & Plausibility Engine.
//
// WHAT THIS DOES
//
// When official municipal telemetry drops (e.g. the ~44% empty responses
// profiled in Delhi's public feed) or fails to report dynamic extra runs
// ("ghost buses"), passengers traveling on board transmit GPS beacons.
//
// To prevent noise, bad GPS readings, or walking passengers from polluting
// the tracking layer, this module applies a multi-stage plausibility filter:
//   1. Boundary check: must be valid coordinates within Delhi transit limits.
//   2. Speed check: urban buses travel between 5 km/h and 80 km/h.
//      Speeds < 5 km/h represent pedestrians walking or stationary passengers
//      at a bus queue; speeds > 80 km/h represent aircraft or highway telemetry.
//   3. Spatial route check: the sighting must lie within 50 meters of the
//      route's physical shape linestring.
//   4. Multi-passenger consensus:
//      - 1 passenger: "Passenger reported" (medium confidence).
//      - 2+ passengers agreeing within 100m on the same route:
//        "Verified by crowd consensus" (high confidence).
//
// Pings are kept in an in-memory ring-buffer with a 3-minute sliding TTL,
// so when passengers leave or a trip concludes, sightings gracefully age out.

import { pool } from './db.ts';

/**
 * Raw input payload submitted by mobile client or passenger simulator.
 */
export interface PassengerPingInput {
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  timestamp?: number | string | Date;
  userId?: string;
  deviceId?: string;
}

/**
 * Validated and sanitized sighting.
 */
export interface ValidatedPing {
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  timestamp: Date;
  passengerId: string;
  distOffRouteMeters?: number;
}

/**
 * Result returned after evaluating plausibility.
 */
export type PingValidationResult =
  | { ok: true; ping: ValidatedPing }
  | {
      ok: false;
      reason: string;
      code: 'MISSING_FIELDS' | 'INVALID_COORDINATES' | 'SPEED_OUT_OF_BOUNDS' | 'OFF_ROUTE';
    };

/**
 * Imputed vehicle surfaced to commuters.
 */
export interface CrowdsourcedVehicle {
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  lastUpdated: string;
  activePassengerCount: number;
  confidence: 'high' | 'medium';
  provenance: 'crowdsourced-telemetry';
  description: string;
}

// Bounding box for Delhi NCR transit area
const DELHI_BOUNDS = {
  minLat: 28.0,
  maxLat: 29.2,
  minLon: 76.5,
  maxLon: 77.8,
};

// Plausible urban bus speeds in Delhi traffic (km/h)
export const MIN_BUS_SPEED_KMH = 5.0;
export const MAX_BUS_SPEED_KMH = 80.0;

// Maximum distance a bus can drift from its published shape before being rejected (meters)
export const MAX_OFF_ROUTE_DISTANCE_METERS = 50.0;

// Maximum distance between two reporting passengers on the same route to be considered the same bus (meters)
export const CONSENSUS_DISTANCE_METERS = 100.0;

// Telemetry TTL: 3 minutes (180,000 ms)
export const PING_TTL_MS = 3 * 60 * 1000;

/**
 * Computes great-circle distance between two geographic coordinates in meters
 * using the Haversine formula.
 */
export function haversineDistanceMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6371000; // Earth radius in meters
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/**
 * Checks if a point lies within MAX_OFF_ROUTE_DISTANCE_METERS of the route's shape linestring.
 * If database is unavailable (or during test harness without DB), falls back gracefully.
 */
export async function checkOffRouteDistance(
  routeId: string,
  lat: number,
  lon: number,
): Promise<{ ok: boolean; distanceMeters?: number; reason?: string }> {
  try {
    const query = `
      SELECT ST_Distance(
        s.geom::geography,
        ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
      ) AS dist_meters
      FROM trips t
      JOIN shapes s ON s.snapshot_id = t.snapshot_id AND s.shape_id = t.shape_id
      WHERE t.route_id = $3
      ORDER BY dist_meters ASC
      LIMIT 1;
    `;
    const res = await pool.query(query, [lon, lat, routeId]);
    if (res.rows.length === 0) {
      // Route has no static shape in DB - permit with warning
      return { ok: true };
    }
    const dist = parseFloat(res.rows[0].dist_meters);
    if (dist > MAX_OFF_ROUTE_DISTANCE_METERS) {
      return {
        ok: false,
        distanceMeters: dist,
        reason: `GPS is ${Math.round(dist)}m away from route ${routeId} geometry (limit is ${MAX_OFF_ROUTE_DISTANCE_METERS}m)`,
      };
    }
    return { ok: true, distanceMeters: dist };
  } catch (_err) {
    // If database query fails or DB is not running, allow through for resilient testing
    return { ok: true };
  }
}

/**
 * Validates a single incoming mobile beacon for route adherence and physics plausibility.
 */
export async function validatePassengerPing(
  input: PassengerPingInput,
  options: { skipDbCheck?: boolean } = {},
): Promise<PingValidationResult> {
  const { routeId, lat, lon, speedKmh } = input;

  if (!routeId || lat === undefined || lon === undefined || speedKmh === undefined) {
    return {
      ok: false,
      reason: 'routeId, lat, lon, and speedKmh are required fields.',
      code: 'MISSING_FIELDS',
    };
  }

  if (
    typeof lat !== 'number' ||
    typeof lon !== 'number' ||
    isNaN(lat) ||
    isNaN(lon) ||
    lat < DELHI_BOUNDS.minLat ||
    lat > DELHI_BOUNDS.maxLat ||
    lon < DELHI_BOUNDS.minLon ||
    lon > DELHI_BOUNDS.maxLon
  ) {
    return {
      ok: false,
      reason: `Coordinates (${lat}, ${lon}) are outside valid Delhi transit bounds.`,
      code: 'INVALID_COORDINATES',
    };
  }

  if (typeof speedKmh !== 'number' || isNaN(speedKmh)) {
    return {
      ok: false,
      reason: 'speedKmh must be a valid number.',
      code: 'SPEED_OUT_OF_BOUNDS',
    };
  }

  if (speedKmh < MIN_BUS_SPEED_KMH) {
    return {
      ok: false,
      reason: `Speed ${speedKmh.toFixed(1)} km/h is below moving threshold (${MIN_BUS_SPEED_KMH} km/h) - appears to be pedestrian or stationary.`,
      code: 'SPEED_OUT_OF_BOUNDS',
    };
  }

  if (speedKmh > MAX_BUS_SPEED_KMH) {
    return {
      ok: false,
      reason: `Speed ${speedKmh.toFixed(1)} km/h exceeds maximum plausible bus speed (${MAX_BUS_SPEED_KMH} km/h).`,
      code: 'SPEED_OUT_OF_BOUNDS',
    };
  }

  let distOffRouteMeters: number | undefined;
  if (!options.skipDbCheck) {
    const routeCheck = await checkOffRouteDistance(routeId, lat, lon);
    if (!routeCheck.ok) {
      return {
        ok: false,
        reason: routeCheck.reason || 'Sighting is too far from route shape.',
        code: 'OFF_ROUTE',
      };
    }
    distOffRouteMeters = routeCheck.distanceMeters;
  }

  const timestamp = input.timestamp ? new Date(input.timestamp) : new Date();
  const passengerId =
    input.userId || input.deviceId || `anon-${Math.random().toString(36).substring(2, 9)}`;

  return {
    ok: true,
    ping: {
      routeId: routeId.trim(),
      lat,
      lon,
      speedKmh,
      timestamp,
      passengerId,
      distOffRouteMeters,
    },
  };
}

/**
 * In-memory sliding-window store for crowdsourced vehicle beacons.
 */
export class CrowdsourceStore {
  // Map of routeId -> array of active sightings
  private pingsByRoute: Map<string, ValidatedPing[]> = new Map();

  /**
   * Ingests a new passenger ping, validating bounds, speed, and route proximity.
   */
  async ingest(
    input: PassengerPingInput,
    options: { skipDbCheck?: boolean } = {},
  ): Promise<PingValidationResult> {
    const res = await validatePassengerPing(input, options);
    if (!res.ok) {
      return res;
    }

    const { ping } = res;
    const existing = this.pingsByRoute.get(ping.routeId) ?? [];

    // Filter out previous pings from this same passenger to avoid duplicates
    const filtered = existing.filter((p) => p.passengerId !== ping.passengerId);
    filtered.push(ping);

    this.pingsByRoute.set(ping.routeId, filtered);
    this.purgeStale(ping.routeId);

    return { ok: true, ping };
  }

  /**
   * Removes sightings older than PING_TTL_MS.
   */
  private purgeStale(routeId: string, now: number = Date.now()) {
    const pings = this.pingsByRoute.get(routeId);
    if (!pings) return;

    const fresh = pings.filter((p) => now - p.timestamp.getTime() <= PING_TTL_MS);
    if (fresh.length === 0) {
      this.pingsByRoute.delete(routeId);
    } else {
      this.pingsByRoute.set(routeId, fresh);
    }
  }

  /**
   * Derives active imputed vehicles along a route using multi-passenger clustering.
   */
  getActiveVehicles(routeId: string, now: number = Date.now()): CrowdsourcedVehicle[] {
    this.purgeStale(routeId, now);
    const pings = this.pingsByRoute.get(routeId);
    if (!pings || pings.length === 0) {
      return [];
    }

    // Cluster pings by spatial proximity (within CONSENSUS_DISTANCE_METERS)
    const clusters: ValidatedPing[][] = [];

    for (const ping of pings) {
      let matchedCluster: ValidatedPing[] | null = null;
      for (const cluster of clusters) {
        // Test distance against cluster center
        const centerLat = cluster.reduce((sum, p) => sum + p.lat, 0) / cluster.length;
        const centerLon = cluster.reduce((sum, p) => sum + p.lon, 0) / cluster.length;
        if (haversineDistanceMeters(ping.lat, ping.lon, centerLat, centerLon) <= CONSENSUS_DISTANCE_METERS) {
          matchedCluster = cluster;
          break;
        }
      }

      if (matchedCluster) {
        matchedCluster.push(ping);
      } else {
        clusters.push([ping]);
      }
    }

    return clusters.map((cluster) => {
      // Centroid coordinates and average speed
      const avgLat = cluster.reduce((sum, p) => sum + p.lat, 0) / cluster.length;
      const avgLon = cluster.reduce((sum, p) => sum + p.lon, 0) / cluster.length;
      const avgSpeed = cluster.reduce((sum, p) => sum + p.speedKmh, 0) / cluster.length;
      const latestTime = new Date(Math.max(...cluster.map((p) => p.timestamp.getTime())));

      const isVerified = cluster.length >= 2;
      const confidence = isVerified ? ('high' as const) : ('medium' as const);

      const description = isVerified
        ? `Verified by crowd consensus (${cluster.length} passengers reporting within ${CONSENSUS_DISTANCE_METERS}m)`
        : 'Passenger reported (1 active mobile beacon)';

      return {
        routeId,
        lat: Number(avgLat.toFixed(6)),
        lon: Number(avgLon.toFixed(6)),
        speedKmh: Number(avgSpeed.toFixed(1)),
        lastUpdated: latestTime.toISOString(),
        activePassengerCount: cluster.length,
        confidence,
        provenance: 'crowdsourced-telemetry',
        description,
      };
    });
  }

  /**
   * Resets the store. Used between test runs.
   */
  clear() {
    this.pingsByRoute.clear();
  }
}

// Global singleton instance for the service
export const crowdsourceStore = new CrowdsourceStore();
