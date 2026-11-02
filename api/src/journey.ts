// Planning a journey: two locations in, ranked ways to travel out.
//
// This is the screen the whole app is really for. Someone does not want a
// bus - they want to be somewhere else. Which bus is a means, and only
// becomes the interesting question after boarding.
//
// Three things here came out of measurement rather than intuition, and
// all three change the answer materially. See docs/journey-design.md.
//
//   1. RANK BY TOTAL TIME, NOT RIDE TIME. Measured on a real pair: route
//      2433 rides in 5.3 min and comes every 6.4; route 2417 rides in 4.6
//      and comes every 10.7. The FASTER RIDE is the WORSE JOURNEY, because
//      waiting is part of travelling.
//
//   2. ROUTE ON PLACES, NOT STOPS. Delhi lists ~1.9 stop_ids per physical
//      stop, one per direction. Routing on raw ids makes only 5% of stop
//      pairs look directly connected; merging them into places gives the
//      true 16.8%, and lifts one-change coverage from 55% to 86.7%.
//
//   3. ONE TRANSFER IS ENOUGH FOR ~87%. Only 18% of journeys are direct,
//      so a direct-only planner answers under one query in five. Two
//      transfers would add ~13% and a lot of complexity, so those are
//      told honestly that no simple route exists.

import { pool } from './db.ts';
import { delhiTimeParts, rangeForHops, type DayType } from './eta.ts';

// How far someone is assumed willing to walk to a stop, each end.
const WALK_RADIUS_M = 800;

// 5 km/h. A default, not a measurement - stated in the response rather
// than hidden, because it is a real part of the answer.
const WALK_METRES_PER_MIN = 83;

// When a route has never been observed at a place at this hour, we cannot
// say how long the wait is. This stands in, and the option is marked down
// for it rather than quietly presented as equally trustworthy.
const UNKNOWN_GAP_MINUTES = 20;

// How many candidate itineraries to cost precisely. The candidate search
// can return 100k combinations in ~50ms; costing them all would be slow
// and pointless, since the cheap ordering (fewest stops) is a good proxy.
const CANDIDATES_TO_COST = 40;

// A statistic resting on fewer days/samples than this is thin enough to
// mention. Same threshold the ETA model uses.
const MIN_SAMPLES_TO_TRUST = 3;

export interface JourneyLeg {
  routeId: string;
  // The number actually painted on the bus (e.g. "944UP") - NOT the same
  // as routeId, which is just an internal database key from the feed and
  // means nothing to a commuter standing at a stop. See routes.route_short_name.
  routeName: string;
  // The route's real endpoints, e.g. "Kendriya Terminal (Church Road) to
  // Sultan Puri (T)" - this is what's actually printed on the bus's
  // destination board, which is what someone standing at a stop can
  // actually check the physical bus against. See routes.route_desc.
  routeDesc: string;
  boardPlace: string;
  boardStopSequence: number;
  alightPlace: string;
  alightStopSequence: number;
  stops: number;
  rideMinutes: number;
  waitMinutes: number;
  busEveryMinutes: number | null;
  frequencyDaysSeen: number | null;
}

export interface JourneyOption {
  changes: number;
  legs: JourneyLeg[];
  walkMinutes: number;
  waitMinutes: number;
  rideMinutes: number;
  totalMinutes: number;
  rangeMinutes: { earliest: number; latest: number };
  confidence: { level: 'high' | 'medium' | 'low'; because: string };
}

export interface JourneyResult {
  options: JourneyOption[];
  dayType: DayType;
  hourOfDay: number;
  searched: { walkRadiusMetres: number; walkSpeedMetresPerMin: number };
  unavailable?: { reason: string };
}

/** Rounds to one decimal, so responses do not claim false precision. */
const round1 = (n: number) => Math.round(n * 10) / 10;

/**
 * Find places within walking distance of a point.
 *
 * Returns PLACES, not stops - several stop_ids at one junction collapse to
 * one, keeping the nearest walking distance among them.
 */
const NEAR_PLACES_SQL = `
  SELECT DISTINCT ON (sp.place_id)
         sp.place_id,
         s.stop_name,
         ST_Distance(s.geom::geography,
                     ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS walk_m
  FROM stops s
  JOIN stop_place sp ON sp.stop_id = s.stop_id
  WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
    AND ST_DWithin(s.geom::geography,
                   ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography, $3)
  ORDER BY sp.place_id, walk_m
`;

/**
 * Direct journeys: one bus, no change.
 *
 * Costs every option in one query rather than per-candidate, because a
 * well-served pair can have dozens of routes and a round trip each would
 * dominate the response time.
 */
const DIRECT_SQL = `
WITH nf AS (${NEAR_PLACES_SQL}),
     nt AS (SELECT DISTINCT ON (sp.place_id) sp.place_id, s.stop_name,
                   ST_Distance(s.geom::geography,
                               ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography) AS walk_m
            FROM stops s JOIN stop_place sp ON sp.stop_id = s.stop_id
            WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
              AND ST_DWithin(s.geom::geography,
                             ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography, $3)
            ORDER BY sp.place_id, walk_m),
opt AS (
  SELECT DISTINCT ON (b.route_id, nf.place_id, nt.place_id)
         b.route_id, nf.place_id AS board_place, nf.stop_name AS board_name,
         b.stop_sequence AS board_seq, nt.place_id AS alight_place,
         nt.stop_name AS alight_name, a.stop_sequence AS alight_seq,
         nf.walk_m + nt.walk_m AS walk_m,
         (a.stop_sequence - b.stop_sequence) AS stops
  FROM nf
  JOIN route_place b ON b.place_id = nf.place_id
  JOIN route_place a ON a.route_id = b.route_id AND a.stop_sequence > b.stop_sequence
  JOIN nt ON nt.place_id = a.place_id
  ORDER BY b.route_id, nf.place_id, nt.place_id, stops
)
SELECT o.*, r.ride_s, r.thinnest_leg,
       f.avg_gap_minutes, f.days_seen,
       -- route_id is an internal database key, not the number painted on
       -- the bus - route_short_name is the real one (e.g. "944UP").
       -- Falls back to route_id only if a route is somehow missing a
       -- short name, so the app never shows a blank instead of something.
       coalesce(rt.route_short_name, o.route_id) AS route_name,
       rt.route_desc
FROM opt o
LEFT JOIN LATERAL (
  SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thinnest_leg
  FROM route_segment_travel_time
  WHERE route_id = o.route_id AND day_type = $6 AND hour_of_day = $7
    AND to_stop_sequence > o.board_seq AND to_stop_sequence <= o.alight_seq
) r ON true
LEFT JOIN place_route_frequency f
  ON f.place_id = o.board_place AND f.route_id = o.route_id
 AND f.day_type = $6 AND f.hour_of_day = $7
LEFT JOIN LATERAL (
  SELECT route_short_name, route_desc FROM routes
  WHERE route_id = o.route_id AND snapshot_id = (SELECT max(snapshot_id) FROM routes)
  LIMIT 1
) rt ON true
WHERE r.ride_s IS NOT NULL
ORDER BY (o.walk_m / ${WALK_METRES_PER_MIN})
       + coalesce(f.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2
       + r.ride_s / 60
LIMIT 8
`;

/**
 * One-change journeys.
 *
 * Two stages on purpose. Finding candidates is cheap (~50ms even when it
 * returns 100,000 combinations); costing them is not. So candidates are
 * ordered by total stops - a good cheap proxy - and only the best few are
 * costed properly.
 */
const TRANSFER_SQL = `
WITH nf AS (${NEAR_PLACES_SQL}),
     nt AS (SELECT DISTINCT ON (sp.place_id) sp.place_id, s.stop_name,
                   ST_Distance(s.geom::geography,
                               ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography) AS walk_m
            FROM stops s JOIN stop_place sp ON sp.stop_id = s.stop_id
            WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
              AND ST_DWithin(s.geom::geography,
                             ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography, $3)
            ORDER BY sp.place_id, walk_m),
leg1 AS (
  SELECT rp.route_id AS r1, rp.place_id AS board_place, nf.stop_name AS board_name,
         rp.stop_sequence AS s1, m.place_id AS mid, m.stop_sequence AS m1, nf.walk_m AS wa
  FROM nf
  JOIN route_place rp ON rp.place_id = nf.place_id
  JOIN route_place m  ON m.route_id = rp.route_id AND m.stop_sequence > rp.stop_sequence
),
leg2 AS (
  SELECT rp.route_id AS r2, rp.place_id AS alight_place, nt.stop_name AS alight_name,
         rp.stop_sequence AS s2, m.place_id AS mid, m.stop_sequence AS m2, nt.walk_m AS wb
  FROM nt
  JOIN route_place rp ON rp.place_id = nt.place_id
  JOIN route_place m  ON m.route_id = rp.route_id AND m.stop_sequence < rp.stop_sequence
),
cand AS (
  SELECT DISTINCT ON (l1.r1, l2.r2, l1.mid)
         l1.r1, l1.board_place, l1.board_name, l1.s1, l1.m1, l1.mid,
         l2.r2, l2.m2, l2.s2, l2.alight_place, l2.alight_name,
         l1.wa + l2.wb AS walk_m,
         (l1.m1 - l1.s1) + (l2.s2 - l2.m2) AS stops
  FROM leg1 l1
  JOIN leg2 l2 ON l2.mid = l1.mid AND l2.r2 <> l1.r1
  ORDER BY l1.r1, l2.r2, l1.mid, stops
),
top AS (SELECT * FROM cand ORDER BY stops LIMIT ${CANDIDATES_TO_COST})
SELECT t.*, mp.stop_name AS mid_name,
       r1.ride_s AS ride1_s, r1.thin AS thin1,
       r2.ride_s AS ride2_s, r2.thin AS thin2,
       f1.avg_gap_minutes AS gap1, f1.days_seen AS days1,
       f2.avg_gap_minutes AS gap2, f2.days_seen AS days2,
       -- Real bus numbers for each leg - see the matching comment in
       -- DIRECT_SQL above for why this isn't just route_id.
       coalesce(rt1.route_short_name, t.r1) AS route1_name,
       coalesce(rt2.route_short_name, t.r2) AS route2_name,
       rt1.route_desc AS route1_desc,
       rt2.route_desc AS route2_desc
FROM top t
LEFT JOIN LATERAL (
  SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thin
  FROM route_segment_travel_time
  WHERE route_id = t.r1 AND day_type = $6 AND hour_of_day = $7
    AND to_stop_sequence > t.s1 AND to_stop_sequence <= t.m1) r1 ON true
LEFT JOIN LATERAL (
  SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thin
  FROM route_segment_travel_time
  WHERE route_id = t.r2 AND day_type = $6 AND hour_of_day = $7
    AND to_stop_sequence > t.m2 AND to_stop_sequence <= t.s2) r2 ON true
LEFT JOIN place_route_frequency f1
  ON f1.place_id = t.board_place AND f1.route_id = t.r1
 AND f1.day_type = $6 AND f1.hour_of_day = $7
LEFT JOIN place_route_frequency f2
  ON f2.place_id = t.mid AND f2.route_id = t.r2
 AND f2.day_type = $6 AND f2.hour_of_day = $7
LEFT JOIN LATERAL (
  SELECT s.stop_name FROM stops s JOIN stop_place sp ON sp.stop_id = s.stop_id
  WHERE sp.place_id = t.mid AND s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
  LIMIT 1) mp ON true
LEFT JOIN LATERAL (
  SELECT route_short_name, route_desc FROM routes
  WHERE route_id = t.r1 AND snapshot_id = (SELECT max(snapshot_id) FROM routes)
  LIMIT 1) rt1 ON true
LEFT JOIN LATERAL (
  SELECT route_short_name, route_desc FROM routes
  WHERE route_id = t.r2 AND snapshot_id = (SELECT max(snapshot_id) FROM routes)
  LIMIT 1) rt2 ON true
WHERE r1.ride_s IS NOT NULL AND r2.ride_s IS NOT NULL
ORDER BY (t.walk_m / ${WALK_METRES_PER_MIN})
       + coalesce(f1.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2
       + coalesce(f2.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2
       + (r1.ride_s + r2.ride_s) / 60
LIMIT 6
`;

/**
 * How much to trust an option, from the data actually behind it.
 *
 * Two independent weaknesses matter: a frequency resting on one or two
 * days, and a travel-time leg resting on very few observed buses. Either
 * one is worth saying out loud rather than averaging away.
 */
function describeConfidence(
  daysSeen: (number | null)[],
  thinnestLegs: (number | null)[],
  usedFallbackWait: boolean,
): JourneyOption['confidence'] {
  const thinFrequency = daysSeen.some((d) => d === null || d < MIN_SAMPLES_TO_TRUST);
  const thinRide = thinnestLegs.some((t) => t === null || t < MIN_SAMPLES_TO_TRUST);

  if (usedFallbackWait) {
    return {
      level: 'low',
      because: 'This route has never been observed here at this hour, so the wait is a guess, not a measurement.',
    };
  }
  if (thinFrequency && thinRide) {
    return {
      level: 'low',
      because: 'Both how often the bus comes and how long it takes rest on very few observed trips.',
    };
  }
  if (thinFrequency) {
    return {
      level: 'medium',
      because: 'How long the ride takes is well observed, but how often the bus comes rests on only a day or two.',
    };
  }
  if (thinRide) {
    return {
      level: 'medium',
      because: 'How often the bus comes is well observed, but some legs of the ride rest on very few trips.',
    };
  }
  return {
    level: 'high',
    because: 'Both the frequency and the journey time come from several days of observed buses on this route.',
  };
}

/** Plan a journey between two points. */
export async function planJourney(opts: {
  fromLat: number; fromLon: number;
  toLat: number; toLon: number;
  at?: Date;
  // Ask about a specific hour or kind of day instead of "now". Used by
  // planByHour below to answer "when should I travel", which needs the
  // same planning done 19 times over rather than a separate code path.
  forHour?: number;
  forDayType?: DayType;
}): Promise<JourneyResult> {
  const at = opts.at ?? new Date();
  const derived = delhiTimeParts(at);
  const hourOfDay = opts.forHour ?? derived.hourOfDay;
  const dayType = opts.forDayType ?? derived.dayType;

  const params = [
    opts.fromLat, opts.fromLon, WALK_RADIUS_M,
    opts.toLat, opts.toLon,
    dayType, hourOfDay,
  ];

  const base: Omit<JourneyResult, 'options'> = {
    dayType,
    hourOfDay,
    searched: {
      walkRadiusMetres: WALK_RADIUS_M,
      walkSpeedMetresPerMin: WALK_METRES_PER_MIN,
    },
  };

  const direct = await pool.query(DIRECT_SQL, params);

  const options: JourneyOption[] = direct.rows.map((r) => {
    const walk = Number(r.walk_m) / WALK_METRES_PER_MIN;
    const gap = r.avg_gap_minutes === null ? null : Number(r.avg_gap_minutes);
    const wait = (gap ?? UNKNOWN_GAP_MINUTES) / 2;
    const ride = Number(r.ride_s) / 60;
    const stops = Number(r.stops);

    const band = rangeForHops(stops, dayType);
    return {
      changes: 0,
      legs: [{
        routeId: r.route_id,
        routeName: r.route_name,
        routeDesc: r.route_desc ?? '',
        boardPlace: r.board_name,
        boardStopSequence: Number(r.board_seq),
        alightPlace: r.alight_name,
        alightStopSequence: Number(r.alight_seq),
        stops,
        rideMinutes: round1(ride),
        waitMinutes: round1(wait),
        busEveryMinutes: gap,
        frequencyDaysSeen: r.days_seen === null ? null : Number(r.days_seen),
      }],
      walkMinutes: round1(walk),
      waitMinutes: round1(wait),
      rideMinutes: round1(ride),
      totalMinutes: round1(walk + wait + ride),
      rangeMinutes: {
        earliest: round1(Math.max(0, walk + wait + ride + band.low / 60)),
        latest: round1(walk + wait + ride + band.high / 60),
      },
      confidence: describeConfidence(
        [r.days_seen === null ? null : Number(r.days_seen)],
        [r.thinnest_leg === null ? null : Number(r.thinnest_leg)],
        gap === null,
      ),
    };
  });

  // Only pay for the transfer search when direct options are few. A pair
  // with several one-bus options rarely improves by adding a change, and
  // the search is the expensive half of this endpoint.
  if (options.length < 3) {
    const transfer = await pool.query(TRANSFER_SQL, params);

    for (const r of transfer.rows) {
      const walk = Number(r.walk_m) / WALK_METRES_PER_MIN;
      const gap1 = r.gap1 === null ? null : Number(r.gap1);
      const gap2 = r.gap2 === null ? null : Number(r.gap2);
      const wait = (gap1 ?? UNKNOWN_GAP_MINUTES) / 2 + (gap2 ?? UNKNOWN_GAP_MINUTES) / 2;
      const ride = (Number(r.ride1_s) + Number(r.ride2_s)) / 60;
      const stops1 = Number(r.m1) - Number(r.s1);
      const stops2 = Number(r.s2) - Number(r.m2);

      const band = rangeForHops(stops1 + stops2, dayType);
      options.push({
        changes: 1,
        legs: [
          {
            routeId: r.r1,
            routeName: r.route1_name,
            routeDesc: r.route1_desc ?? '',
            boardPlace: r.board_name,
            boardStopSequence: Number(r.s1),
            alightPlace: r.mid_name,
            alightStopSequence: Number(r.m1),
            stops: stops1,
            rideMinutes: round1(Number(r.ride1_s) / 60),
            waitMinutes: round1((gap1 ?? UNKNOWN_GAP_MINUTES) / 2),
            busEveryMinutes: gap1,
            frequencyDaysSeen: r.days1 === null ? null : Number(r.days1),
          },
          {
            routeId: r.r2,
            routeName: r.route2_name,
            routeDesc: r.route2_desc ?? '',
            boardPlace: r.mid_name,
            boardStopSequence: Number(r.m2),
            alightPlace: r.alight_name,
            alightStopSequence: Number(r.s2),
            stops: stops2,
            rideMinutes: round1(Number(r.ride2_s) / 60),
            waitMinutes: round1((gap2 ?? UNKNOWN_GAP_MINUTES) / 2),
            busEveryMinutes: gap2,
            frequencyDaysSeen: r.days2 === null ? null : Number(r.days2),
          },
        ],
        walkMinutes: round1(walk),
        waitMinutes: round1(wait),
        rideMinutes: round1(ride),
        totalMinutes: round1(walk + wait + ride),
        rangeMinutes: {
          earliest: round1(Math.max(0, walk + wait + ride + band.low / 60)),
          latest: round1(walk + wait + ride + band.high / 60),
        },
        confidence: describeConfidence(
          [r.days1 === null ? null : Number(r.days1), r.days2 === null ? null : Number(r.days2)],
          [r.thin1 === null ? null : Number(r.thin1), r.thin2 === null ? null : Number(r.thin2)],
          gap1 === null || gap2 === null,
        ),
      });
    }
  }

  options.sort((a, b) => a.totalMinutes - b.totalMinutes);

  if (options.length === 0) {
    return {
      ...base,
      options: [],
      unavailable: {
        reason:
          'No route found with at most one change. About 13% of journeys in Delhi need two or more ' +
          'changes, which this planner does not attempt rather than suggesting a poor third leg.',
      },
    };
  }

  return { ...base, options: options.slice(0, 6) };
}

// ---------------------------------------------------------------------------
// "When should I travel?" - the same journey, hour by hour.
// ---------------------------------------------------------------------------

export interface HourlyJourney {
  hourOfDay: number;
  bestTotalMinutes: number | null;
  bestRouteSummary: string | null;
  changes: number | null;
  waitMinutes: number | null;
  rideMinutes: number | null;
  confidence: 'high' | 'medium' | 'low' | null;
}

export interface ByHourResult {
  dayType: DayType;
  hours: HourlyJourney[];
  best: { hourOfDay: number; totalMinutes: number } | null;
  worst: { hourOfDay: number; totalMinutes: number } | null;
  unavailable?: { reason: string };
}

// Delhi buses run roughly 05:00-23:00. Outside that the frequency data is
// almost entirely absent (hour 00 has usable numbers on only 4% of cells),
// so planning those hours would return a fallback guess dressed up as an
// answer.
const SERVICE_HOURS_START = 5;
const SERVICE_HOURS_END = 23;

/**
 * Cost every route option against every service hour, in ONE pass.
 *
 * The first version of this ran the whole planner once per hour and took
 * 3.7 seconds. What fixes it: WHICH routes serve these two places does not
 * change with the hour - only how long they take and how often they run.
 * So the options are found once, then CROSS JOINed against the hours and
 * costed together.
 */
const DIRECT_BY_HOUR_SQL = `
WITH nf AS (${NEAR_PLACES_SQL}),
     nt AS (SELECT DISTINCT ON (sp.place_id) sp.place_id, s.stop_name,
                   ST_Distance(s.geom::geography,
                               ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography) AS walk_m
            FROM stops s JOIN stop_place sp ON sp.stop_id = s.stop_id
            WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
              AND ST_DWithin(s.geom::geography,
                             ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography, $3)
            ORDER BY sp.place_id, walk_m),
opt AS (
  SELECT DISTINCT ON (b.route_id, nf.place_id, nt.place_id)
         b.route_id, nf.place_id AS board_place,
         b.stop_sequence AS board_seq, a.stop_sequence AS alight_seq,
         nf.walk_m + nt.walk_m AS walk_m
  FROM nf
  JOIN route_place b ON b.place_id = nf.place_id
  JOIN route_place a ON a.route_id = b.route_id AND a.stop_sequence > b.stop_sequence
  JOIN nt ON nt.place_id = a.place_id
  ORDER BY b.route_id, nf.place_id, nt.place_id, (a.stop_sequence - b.stop_sequence)
),
costed AS (
  SELECT h.hour_of_day, o.route_id,
         o.walk_m / ${WALK_METRES_PER_MIN} AS walk_min,
         coalesce(f.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2 AS wait_min,
         r.ride_s / 60 AS ride_min,
         r.thinnest,
         f.days_seen,
         (f.avg_gap_minutes IS NOT NULL) AS gap_known
  FROM opt o
  CROSS JOIN generate_series($7::int, $8::int) AS h(hour_of_day)
  JOIN LATERAL (
    SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thinnest
    FROM route_segment_travel_time
    WHERE route_id = o.route_id AND day_type = $6 AND hour_of_day = h.hour_of_day
      AND to_stop_sequence > o.board_seq AND to_stop_sequence <= o.alight_seq
  ) r ON r.ride_s IS NOT NULL
  LEFT JOIN place_route_frequency f
    ON f.place_id = o.board_place AND f.route_id = o.route_id
   AND f.day_type = $6 AND f.hour_of_day = h.hour_of_day
)
SELECT DISTINCT ON (hour_of_day)
       hour_of_day, route_id AS route_summary, 0 AS changes,
       walk_min, wait_min, ride_min, thinnest, days_seen, gap_known,
       (walk_min + wait_min + ride_min) AS total_min
FROM costed
ORDER BY hour_of_day, total_min
`;

/**
 * Same idea for one-change journeys: find the candidates once (the search
 * is hour-independent), then cost them against all hours together.
 */
const TRANSFER_BY_HOUR_SQL = `
WITH nf AS (${NEAR_PLACES_SQL}),
     nt AS (SELECT DISTINCT ON (sp.place_id) sp.place_id, s.stop_name,
                   ST_Distance(s.geom::geography,
                               ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography) AS walk_m
            FROM stops s JOIN stop_place sp ON sp.stop_id = s.stop_id
            WHERE s.snapshot_id = (SELECT max(snapshot_id) FROM stops)
              AND ST_DWithin(s.geom::geography,
                             ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography, $3)
            ORDER BY sp.place_id, walk_m),
leg1 AS (
  SELECT rp.route_id AS r1, rp.place_id AS board_place, rp.stop_sequence AS s1,
         m.place_id AS mid, m.stop_sequence AS m1, nf.walk_m AS wa
  FROM nf JOIN route_place rp ON rp.place_id = nf.place_id
          JOIN route_place m  ON m.route_id = rp.route_id AND m.stop_sequence > rp.stop_sequence
),
leg2 AS (
  SELECT rp.route_id AS r2, rp.stop_sequence AS s2,
         m.place_id AS mid, m.stop_sequence AS m2, nt.walk_m AS wb
  FROM nt JOIN route_place rp ON rp.place_id = nt.place_id
          JOIN route_place m  ON m.route_id = rp.route_id AND m.stop_sequence < rp.stop_sequence
),
cand AS (
  SELECT DISTINCT ON (l1.r1, l2.r2, l1.mid)
         l1.r1, l1.board_place, l1.s1, l1.m1, l1.mid, l2.r2, l2.m2, l2.s2,
         l1.wa + l2.wb AS walk_m,
         (l1.m1 - l1.s1) + (l2.s2 - l2.m2) AS stops
  FROM leg1 l1 JOIN leg2 l2 ON l2.mid = l1.mid AND l2.r2 <> l1.r1
  ORDER BY l1.r1, l2.r2, l1.mid, stops
),
top AS (SELECT * FROM cand ORDER BY stops LIMIT ${CANDIDATES_TO_COST}),
costed AS (
  SELECT h.hour_of_day, t.r1, t.r2,
         t.walk_m / ${WALK_METRES_PER_MIN} AS walk_min,
         coalesce(f1.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2
       + coalesce(f2.avg_gap_minutes, ${UNKNOWN_GAP_MINUTES}) / 2 AS wait_min,
         (r1.ride_s + r2.ride_s) / 60 AS ride_min,
         least(r1.thin, r2.thin) AS thinnest,
         least(f1.days_seen, f2.days_seen) AS days_seen,
         (f1.avg_gap_minutes IS NOT NULL AND f2.avg_gap_minutes IS NOT NULL) AS gap_known
  FROM top t
  CROSS JOIN generate_series($7::int, $8::int) AS h(hour_of_day)
  JOIN LATERAL (
    SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thin
    FROM route_segment_travel_time
    WHERE route_id = t.r1 AND day_type = $6 AND hour_of_day = h.hour_of_day
      AND to_stop_sequence > t.s1 AND to_stop_sequence <= t.m1) r1 ON r1.ride_s IS NOT NULL
  JOIN LATERAL (
    SELECT sum(mean_seconds) AS ride_s, min(sample_count) AS thin
    FROM route_segment_travel_time
    WHERE route_id = t.r2 AND day_type = $6 AND hour_of_day = h.hour_of_day
      AND to_stop_sequence > t.m2 AND to_stop_sequence <= t.s2) r2 ON r2.ride_s IS NOT NULL
  LEFT JOIN place_route_frequency f1
    ON f1.place_id = t.board_place AND f1.route_id = t.r1
   AND f1.day_type = $6 AND f1.hour_of_day = h.hour_of_day
  LEFT JOIN place_route_frequency f2
    ON f2.place_id = t.mid AND f2.route_id = t.r2
   AND f2.day_type = $6 AND f2.hour_of_day = h.hour_of_day
)
SELECT DISTINCT ON (hour_of_day)
       hour_of_day, (r1 || ' -> ' || r2) AS route_summary, 1 AS changes,
       walk_min, wait_min, ride_min, thinnest, days_seen, gap_known,
       (walk_min + wait_min + ride_min) AS total_min
FROM costed
ORDER BY hour_of_day, total_min
`;

/**
 * How does this journey change across the day?
 *
 * The best ROUTE can differ by hour, not just the duration - a route that
 * is frequent at 09:00 may be hourly at 21:00 - so each hour is costed on
 * its own rather than scaling one answer.
 *
 * This is the planning question AGENTS.md's feature list never asks but a
 * traveller always does: not only "how do I get there" but "when should I
 * leave". It is only answerable because frequency here is observed rather
 * than taken from a timetable that assumes constant speed.
 */
export async function planByHour(opts: {
  fromLat: number; fromLon: number;
  toLat: number; toLon: number;
  dayType?: DayType;
}): Promise<ByHourResult> {
  const dayType = opts.dayType ?? 'weekday';
  const params = [
    opts.fromLat, opts.fromLon, WALK_RADIUS_M,
    opts.toLat, opts.toLon, dayType,
    SERVICE_HOURS_START, SERVICE_HOURS_END,
  ];

  const direct = await pool.query(DIRECT_BY_HOUR_SQL, params);
  let rows = direct.rows;

  // No one-bus option at any hour? Try with a change. The candidate search
  // is hour-independent too, so the same one-pass trick applies.
  if (rows.length === 0) {
    const transfer = await pool.query(TRANSFER_BY_HOUR_SQL, params);
    rows = transfer.rows;
  }

  const byHour = new Map<number, any>();
  for (const r of rows) byHour.set(Number(r.hour_of_day), r);

  const hours: HourlyJourney[] = [];
  for (let h = SERVICE_HOURS_START; h <= SERVICE_HOURS_END; h++) {
    const r = byHour.get(h);
    if (!r) {
      hours.push({
        hourOfDay: h, bestTotalMinutes: null, bestRouteSummary: null,
        changes: null, waitMinutes: null, rideMinutes: null, confidence: null,
      });
      continue;
    }
    // Same three weaknesses planJourney weighs: no observed frequency at
    // all, a frequency resting on only a day or two, and a ride time from
    // very few buses. The first rewrite of this dropped the days_seen
    // check and silently promoted a 'medium' hour to 'high' - caught by
    // diffing against the slower version it replaced.
    const thin = r.thinnest === null ? 0 : Number(r.thinnest);
    const days = r.days_seen === null ? 0 : Number(r.days_seen);
    const thinRide = thin < MIN_SAMPLES_TO_TRUST;
    const thinFreq = days < MIN_SAMPLES_TO_TRUST;
    hours.push({
      hourOfDay: h,
      bestTotalMinutes: round1(Number(r.total_min)),
      bestRouteSummary: r.route_summary,
      changes: Number(r.changes),
      waitMinutes: round1(Number(r.wait_min)),
      rideMinutes: round1(Number(r.ride_min)),
      confidence: !r.gap_known || (thinRide && thinFreq) ? 'low'
                : (thinRide || thinFreq) ? 'medium'
                : 'high',
    });
  }

  const usable = hours.filter((h) => h.bestTotalMinutes !== null);
  if (usable.length === 0) {
    return {
      dayType, hours, best: null, worst: null,
      unavailable: { reason: 'No route found between these points at any hour of the day.' },
    };
  }

  const sorted = [...usable].sort(
    (a, b) => (a.bestTotalMinutes as number) - (b.bestTotalMinutes as number),
  );
  return {
    dayType,
    hours,
    best:  { hourOfDay: sorted[0].hourOfDay,  totalMinutes: sorted[0].bestTotalMinutes as number },
    worst: { hourOfDay: sorted[sorted.length - 1].hourOfDay,
             totalMinutes: sorted[sorted.length - 1].bestTotalMinutes as number },
  };
}
