// Database connection for the API.
//
// One shared pool. The local-dev credentials below are not a secret worth
// protecting (see db/README.md) - anything real would come from
// DATABASE_URL in the environment.

import pg from 'pg';

const CONNECTION_STRING =
  process.env.DATABASE_URL || 'postgres://wimb:wimb_local_dev@localhost:5432/wimb';

export const pool = new pg.Pool({
  connectionString: CONNECTION_STRING,
  max: 10,
});

// The travel-time statistics were built with the hour and day-of-week read
// in DELHI local time, not UTC (see db/compute_travel_times.sql). Every
// lookup has to ask the same way round or it would be reading, say, the
// 09:00 statistics for a bus that is actually running at 14:30.
export const DELHI_TIMEZONE = 'Asia/Kolkata';
