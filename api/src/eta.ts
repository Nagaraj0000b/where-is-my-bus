// Working out when a bus will reach a stop, and how much to trust that.
//
// This is the whole point of the project, so it is worth being clear about
// what it does and does not do. Every rule below came out of measurement
// on real recorded data, not from what seemed sensible - and in three
// separate cases what seemed sensible turned out to be wrong. The full
// story, with numbers, is in docs/eta-design.md.
//
// The three rules that matter:
//
//   1. ADD UP AVERAGES, NOT MIDDLE VALUES. For guessing one hop the middle
//      value (median) is better. For adding hops together it is wrong,
//      because averages add up correctly and middles do not. Hop times are
//      lopsided - a bus can be enormously late but never much early - so
//      every middle value sits a little below its own average, and twenty
//      small under-guesses become one big one.
//
//   2. WEEKDAYS AND WEEKENDS ARE DIFFERENT ROADS. Mixing them was the
//      single biggest source of error: the model was too optimistic on
//      weekdays and too pessimistic on weekends, and those two large
//      errors cancelled into a small one that looked fine on average.
//
//   3. DO NOT EXTRAPOLATE DELAY. "This bus is three minutes late, so add
//      three minutes" makes the answer 16-55% WORSE. A bus running late
//      now barely predicts a bus running late later (correlation 0.088).
//      Live position tells us WHICH hops are left, not how long they take.

import { pool, DELHI_TIMEZONE } from './db.ts';

// How many real bus trips have to sit behind a statistic before we prefer
// it to a coarser one. Below this, a "specific" number is mostly noise.
const MIN_SAMPLES_TO_TRUST = 3;

export type DayType = 'weekday' | 'weekend';

/** Which level of detail a hop's estimate actually came from. */
export type HopSource =
  | 'this-hour-this-daytype'  // best: right hour, right kind of day
  | 'any-hour-this-daytype'   // right kind of day, averaged over the day
  | 'any-day-any-hour'        // last resort
  | 'missing';                // this segment has never been observed

export interface EtaResult {
  /** Best single guess, in seconds from now. */
  predictedSeconds: number;
  /** Predicted arrival as an actual moment in time. */
  predictedArrival: Date;
  /**
   * The honest range. Roughly 8 journeys in 10 land inside this.
   * Deliberately not symmetric - see docs/eta-design.md section 4.
   */
  range: { earliestSeconds: number; latestSeconds: number;
           earliest: Date; latest: Date };
  /** How many stop-to-stop hops this estimate had to add up. */
  hops: number;
  /** Weekday and weekend behave differently enough to be worth reporting. */
  dayType: DayType;
  /** Delhi-local hour the estimate was made for. */
  hourOfDay: number;
  /**
   * How the estimate was built, hop by hop. A journey leaning on
   * 'any-day-any-hour' is a weaker answer than one built from
   * 'this-hour-this-daytype', even though both produce a number.
   */
  quality: Record<HopSource, number>;
  /** Set when we could NOT produce an estimate, with the reason. */
  unavailable?: { reason: string; missingHops: number };
}

/**
 * Delhi-local hour and day type for a moment in time.
 *
 * Has to match how db/compute_travel_times.sql bucketed the history.
 * Delhi is UTC+5:30, and the database session runs in UTC, so reading the
 * hour straight off a timestamp would be five and a half hours out - and
 * because the offset includes a half hour, it would also smear rush hour
 * across two buckets.
 */
export function delhiTimeParts(at: Date): { hourOfDay: number; dayType: DayType } {
  // Intl is the boring, correct way to do this: it handles the offset
  // itself rather than us hard-coding +5:30, so it cannot drift if the
  // rules ever change.
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: DELHI_TIMEZONE,
    hour: '2-digit',
    weekday: 'short',
    hour12: false,
  }).formatToParts(at);

  const hourText = parts.find((p) => p.type === 'hour')?.value ?? '0';
  const weekday = parts.find((p) => p.type === 'weekday')?.value ?? 'Mon';

  // Intl gives hour 24 for midnight in some locales; fold it back to 0.
  const hourOfDay = Number(hourText) % 24;
  const dayType: DayType = weekday === 'Sat' || weekday === 'Sun' ? 'weekend' : 'weekday';

  return { hourOfDay, dayType };
}

/**
 * The measured spread of this method's own past mistakes, used to build
 * the range shown to the user.
 *
 * These are NOT a bell curve or a guess. They are the 10th and 90th
 * percentile of how wrong the predictor actually was on days it had never
 * seen, per docs/eta-design.md section 4. Weekends are tighter than
 * weekdays because weekend traffic is genuinely more predictable.
 *
 * Values are seconds relative to the prediction: negative means the bus
 * arrived earlier than predicted.
 */
const BAND_ANCHORS: Record<DayType, { hops: number; low: number; high: number }[]> = {
  weekday: [
    { hops: 1,  low: -70,  high: 59 },
    { hops: 5,  low: -245, high: 243 },
    { hops: 10, low: -402, high: 431 },
    { hops: 20, low: -662, high: 760 },
  ],
  weekend: [
    { hops: 1,  low: -43,  high: 40 },
    { hops: 5,  low: -151, high: 146 },
    { hops: 10, low: -257, high: 255 },
    { hops: 20, low: -438, high: 438 },
  ],
};

/**
 * Range for a journey of any length, by reading between the measured
 * anchor points above.
 *
 * Beyond 20 hops we carry on at the same rate as the 10-to-20 stretch.
 * That is extrapolation and is marked as such here rather than pretending
 * it was measured - journeys that long are rare and the honest thing is a
 * wide range, not a confident one.
 */
export function rangeForHops(hops: number, dayType: DayType): { low: number; high: number } {
  const anchors = BAND_ANCHORS[dayType];

  if (hops <= anchors[0].hops) return { low: anchors[0].low, high: anchors[0].high };

  for (let i = 0; i < anchors.length - 1; i++) {
    const a = anchors[i];
    const b = anchors[i + 1];
    if (hops <= b.hops) {
      const howFar = (hops - a.hops) / (b.hops - a.hops);
      return {
        low:  a.low  + (b.low  - a.low)  * howFar,
        high: a.high + (b.high - a.high) * howFar,
      };
    }
  }

  // Past the last measured point: continue the final slope.
  const last = anchors[anchors.length - 1];
  const secondLast = anchors[anchors.length - 2];
  const perHopLow  = (last.low  - secondLast.low)  / (last.hops - secondLast.hops);
  const perHopHigh = (last.high - secondLast.high) / (last.hops - secondLast.hops);
  const extra = hops - last.hops;

  return { low: last.low + perHopLow * extra, high: last.high + perHopHigh * extra };
}

interface HopRow {
  to_stop_sequence: number;
  day_type: string;
  hour_of_day: number;
  sample_count: number;
  mean_seconds: number;
}

/**
 * Pick the best available estimate for one hop, preferring the most
 * specific statistic that has enough real trips behind it.
 *
 * Falling back rather than failing is deliberate: a coarser number that is
 * honestly labelled beats no answer at all, which is the whole "degrade
 * instead of disappearing" idea this project is built on.
 */
function resolveHop(
  candidates: HopRow[],
  dayType: DayType,
  hourOfDay: number,
): { seconds: number; source: HopSource } {
  const specific = candidates.find(
    (r) => r.day_type === dayType && r.hour_of_day === hourOfDay,
  );
  if (specific && specific.sample_count >= MIN_SAMPLES_TO_TRUST) {
    return { seconds: specific.mean_seconds, source: 'this-hour-this-daytype' };
  }

  const sameDayType = candidates.find(
    (r) => r.day_type === dayType && r.hour_of_day === -1,
  );
  if (sameDayType && sameDayType.sample_count >= MIN_SAMPLES_TO_TRUST) {
    return { seconds: sameDayType.mean_seconds, source: 'any-hour-this-daytype' };
  }

  const anything = candidates.find(
    (r) => r.day_type === 'any' && r.hour_of_day === -1,
  );
  if (anything) {
    return { seconds: anything.mean_seconds, source: 'any-day-any-hour' };
  }

  return { seconds: 0, source: 'missing' };
}

/**
 * When will this bus reach that stop?
 *
 * `fromStopSequence` is where the bus is now; `toStopSequence` is the stop
 * being asked about. Both are positions along the route, counting from its
 * start.
 */
export async function estimateArrival(opts: {
  routeId: string;
  fromStopSequence: number;
  toStopSequence: number;
  at?: Date;
}): Promise<EtaResult> {
  const at = opts.at ?? new Date();
  const { hourOfDay, dayType } = delhiTimeParts(at);
  const hops = opts.toStopSequence - opts.fromStopSequence;

  const emptyQuality: Record<HopSource, number> = {
    'this-hour-this-daytype': 0,
    'any-hour-this-daytype': 0,
    'any-day-any-hour': 0,
    missing: 0,
  };

  if (hops <= 0) {
    return {
      predictedSeconds: 0,
      predictedArrival: at,
      range: { earliestSeconds: 0, latestSeconds: 0, earliest: at, latest: at },
      hops: 0,
      dayType,
      hourOfDay,
      quality: emptyQuality,
      unavailable: {
        reason: 'The target stop is not ahead of the bus on this route.',
        missingHops: 0,
      },
    };
  }

  // Fetch every candidate statistic for the whole stretch in one go - the
  // three levels of detail for each hop - and choose between them below.
  // One query rather than one per hop, because a long journey would
  // otherwise mean dozens of round trips.
  const { rows } = await pool.query<HopRow>(
    `
    SELECT to_stop_sequence, day_type, hour_of_day, sample_count, mean_seconds
    FROM route_segment_travel_time
    WHERE route_id = $1
      AND to_stop_sequence > $2
      AND to_stop_sequence <= $3
      AND (   (day_type = $4 AND hour_of_day = $5)
           OR (day_type = $4 AND hour_of_day = -1)
           OR (day_type = 'any' AND hour_of_day = -1) )
    `,
    [opts.routeId, opts.fromStopSequence, opts.toStopSequence, dayType, hourOfDay],
  );

  const bySequence = new Map<number, HopRow[]>();
  for (const row of rows) {
    const list = bySequence.get(row.to_stop_sequence) ?? [];
    list.push(row);
    bySequence.set(row.to_stop_sequence, list);
  }

  const quality = { ...emptyQuality };
  let total = 0;

  for (let seq = opts.fromStopSequence + 1; seq <= opts.toStopSequence; seq++) {
    const { seconds, source } = resolveHop(bySequence.get(seq) ?? [], dayType, hourOfDay);
    quality[source]++;
    total += seconds;
  }

  const predictedArrival = new Date(at.getTime() + total * 1000);
  const band = rangeForHops(hops, dayType);
  const earliestSeconds = total + band.low;
  const latestSeconds = total + band.high;

  const result: EtaResult = {
    predictedSeconds: total,
    predictedArrival,
    range: {
      earliestSeconds,
      latestSeconds,
      earliest: new Date(at.getTime() + earliestSeconds * 1000),
      latest: new Date(at.getTime() + latestSeconds * 1000),
    },
    hops,
    dayType,
    hourOfDay,
    quality,
  };

  // If any hop has never been observed, the total is a sum with holes in
  // it and would silently read as "sooner than reality". Say so rather
  // than quietly hand back a number that is wrong in a known direction.
  if (quality.missing > 0) {
    result.unavailable = {
      reason:
        `${quality.missing} of ${hops} stop-to-stop legs have never been observed, ` +
        `so this estimate would be too low. Showing it as unavailable rather than wrong.`,
      missingHops: quality.missing,
    };
  }

  return result;
}
