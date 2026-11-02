-- User accounts for the app.
--
--   psql -f /db/schema_auth.sql
--
-- WHY THIS EXISTS
--
-- Everything before this file is about buses, and none of it needs to know
-- who is asking. The journey planner, the ETA and the route browser all
-- work perfectly well for an anonymous stranger, and that is deliberate -
-- a person standing at a stop in the rain should not have to sign up to
-- find out when the bus comes.
--
-- Accounts exist for the things that genuinely cannot work without knowing
-- who you are, and which AGENTS.md already asks for:
--
--   * saved places (home, work) that follow you to a new phone
--   * "I'm on this bus" - the manual replacement for the sensor-based
--     boarding detection that was cut (AGENTS.md section 4)
--   * ghost bus reporting - a scheduled trip with no live vehicle, told to
--     us by a real person standing where the bus should be
--
-- The last two are contributions FROM a user, so they have to be
-- attributable, or a single bad actor could poison the data and nobody
-- could tell which reports to drop.
--
-- WHY THE TABLE IS NOT CALLED "user"
--
-- `user` is a reserved word in PostgreSQL - `SELECT * FROM user` returns
-- the current database role, not your table. It can be worked around with
-- quoting ("user") everywhere forever, which is a trap for whoever writes
-- the next query. `app_user` avoids the whole problem.

BEGIN;

CREATE TABLE IF NOT EXISTS app_user (
  -- A random UUID rather than 1, 2, 3. With counting ids, anyone holding
  -- id 42 knows there are at least 41 other accounts and can walk the list
  -- by guessing; a UUID cannot be guessed. It also means an id created on
  -- a laptop and an id created on a server can never collide.
  user_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Stored lowercased and trimmed by the API before it ever gets here, so
  -- "Nagga@Example.com " and "nagga@example.com" are the same account
  -- rather than two. citext would do this in the database instead, but it
  -- needs an extension, and one lowercase() call in the API is simpler.
  email          text NOT NULL UNIQUE,

  -- The bcrypt hash, never the password itself. bcrypt output is a single
  -- 60-character string that already carries its own salt and cost factor
  -- inside it, so there is no separate salt column to keep alongside.
  password_hash  text NOT NULL,

  display_name   text NOT NULL,

  created_at     timestamptz NOT NULL DEFAULT now(),

  -- Updated on each successful login. Not security-critical, but it is
  -- what lets the app say "welcome back" honestly, and it is the first
  -- thing worth looking at if an account is ever reported as misused.
  last_login_at  timestamptz,

  -- Guards against a row being written straight into the database with a
  -- blank or obviously junk email, bypassing the API's own checks. Cheap
  -- insurance: the database is the last place that can still say no.
  CONSTRAINT app_user_email_looks_real CHECK (position('@' IN email) > 1),
  CONSTRAINT app_user_display_name_not_blank CHECK (length(trim(display_name)) > 0)
);

-- Login looks an account up by email every single time, and that lookup
-- sits directly in front of the password check, so it should not be a
-- table scan. The UNIQUE constraint above already creates an index, but it
-- is a case-SENSITIVE one; the API lowercases before querying, so this
-- expression index is what the login query actually gets to use.
CREATE INDEX IF NOT EXISTS app_user_email_lower_idx ON app_user (lower(email));

COMMIT;
