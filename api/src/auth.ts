// Accounts: signing up, logging in, and proving who you are afterwards.
//
// Kept out of server.ts on purpose - that file only translates HTTP, and
// everything decided here (how passwords are stored, how long a login
// lasts, what counts as a good enough password) is a real decision that
// deserves to be readable in one place. See db/schema_auth.sql for why
// accounts exist at all, given that finding a bus does not need one.

import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { pool } from './db.ts';

// HOW LONG BCRYPT TAKES, AND WHY THAT IS THE POINT
//
// bcrypt is deliberately slow. The "cost" is a power of two: cost 12 means
// 2^12 = 4,096 rounds of internal work, which lands around a tenth of a
// second per password on ordinary hardware. A tenth of a second is
// invisible to someone logging in once, but it means an attacker who
// steals the whole table can only test about ten guesses a second per
// core, instead of the billions a second a plain fast hash would allow.
//
// 12 is the usual modern recommendation. Raising it is safe for security
// and only costs login time; lowering it below 10 is not worth doing.
const BCRYPT_COST = 12;

// A login lasts a month before the app has to ask again. This is a bus
// app, not a bank - being logged out on the way to the stop is a genuine
// annoyance, and the token grants nothing more dangerous than reading your
// own saved places.
const TOKEN_LIFETIME = '30d';

/**
 * The key that signs tokens. Anyone holding it can mint a token for any
 * account, so in a real deployment it must come from the environment.
 *
 * The development fallback is a fixed, obviously-fake string rather than a
 * random one generated at startup. A random one would be quietly hostile:
 * every restart of the API would invalidate every token, and the app would
 * log everyone out for no visible reason. A fixed dev key keeps local work
 * predictable, and the warning below makes sure it can never be mistaken
 * for a real one.
 */
function tokenSigningKey(): string {
  const fromEnvironment = process.env.JWT_SECRET;
  if (fromEnvironment && fromEnvironment.length > 0) return fromEnvironment;

  if (!warnedAboutDevelopmentKey) {
    console.warn(
      '[auth] JWT_SECRET is not set - using the built-in development key. ' +
      'Fine on a laptop, never in a real deployment.',
    );
    warnedAboutDevelopmentKey = true;
  }
  return 'wimb-development-only-signing-key-do-not-deploy';
}

// Only warn once, rather than on every single request.
let warnedAboutDevelopmentKey = false;

/** A user as the rest of the app is allowed to see them - never the hash. */
export type PublicUser = {
  userId: string;
  email: string;
  displayName: string;
  createdAt: Date;
};

/** What a successful signup or login hands back. */
export type AuthSuccess = {
  ok: true;
  user: PublicUser;
  token: string;
};

/**
 * What a refused signup or login hands back.
 *
 * `reason` is safe to show a person. It is deliberately vague on the login
 * path - see checkLogin for why saying "no such email" would be a leak.
 */
export type AuthFailure = {
  ok: false;
  reason: string;
};

export type AuthResult = AuthSuccess | AuthFailure;

/**
 * Turn a database row into the shape the outside world sees.
 *
 * Its real job is to be the single place the password hash gets dropped.
 * Every path out of this file goes through here, so a hash cannot escape
 * into a response by someone forgetting to strip it.
 */
function toPublicUser(row: {
  user_id: string;
  email: string;
  display_name: string;
  created_at: Date;
}): PublicUser {
  return {
    userId: row.user_id,
    email: row.email,
    displayName: row.display_name,
    createdAt: row.created_at,
  };
}

/** Mint a signed token saying "this is user X", good for TOKEN_LIFETIME. */
function issueToken(userId: string): string {
  // `sub` (subject) is the standard JWT field for "who this token is
  // about". Using the standard name rather than inventing `userId` means
  // any normal JWT tool can read it.
  return jwt.sign({ sub: userId }, tokenSigningKey(), { expiresIn: TOKEN_LIFETIME });
}

/**
 * Check a password against the rules before it is ever hashed.
 *
 * The only hard rule is length. Forcing a symbol and a digit and a capital
 * is the classic advice and it is now considered actively unhelpful - it
 * pushes people towards "Password1!" and away from long memorable phrases,
 * which are stronger. Length is what actually matters.
 *
 * The 72-byte ceiling is not a style choice: bcrypt itself ignores
 * anything past 72 bytes. Silently truncating would mean two different
 * long passwords could unlock the same account, so it is refused loudly
 * instead.
 */
function passwordProblem(password: string): string | null {
  if (password.length < 8) {
    return 'Password must be at least 8 characters.';
  }
  if (Buffer.byteLength(password, 'utf8') > 72) {
    return 'Password is too long (the limit is 72 bytes).';
  }
  return null;
}

/**
 * A deliberately cheap sanity check, not an attempt to validate email
 * properly. Fully correct email validation by pattern is famously
 * impossible, and the only real proof an address works is sending mail to
 * it. This just catches obvious typos before they reach the database.
 */
function emailLooksReal(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

/** Emails are matched case-insensitively, so they are stored one way. */
function normaliseEmail(email: string): string {
  return email.trim().toLowerCase();
}

/**
 * Create an account.
 *
 * Unlike login, this one CAN say "that email is already taken" - it has
 * to, or the person cannot understand why signup failed. That does reveal
 * whether an address has an account here, which is a small, well-known and
 * unavoidable trade-off on any signup form.
 */
export async function createAccount(input: {
  email: string;
  password: string;
  displayName: string;
}): Promise<AuthResult> {
  const email = normaliseEmail(input.email);
  const displayName = input.displayName.trim();

  if (!emailLooksReal(email)) {
    return { ok: false, reason: 'That does not look like an email address.' };
  }
  if (displayName.length === 0) {
    return { ok: false, reason: 'Please enter a name.' };
  }
  if (displayName.length > 60) {
    return { ok: false, reason: 'That name is too long (60 characters maximum).' };
  }

  const badPassword = passwordProblem(input.password);
  if (badPassword) {
    return { ok: false, reason: badPassword };
  }

  const passwordHash = await bcrypt.hash(input.password, BCRYPT_COST);

  try {
    const { rows } = await pool.query(
      `
      INSERT INTO app_user (email, password_hash, display_name)
      VALUES ($1, $2, $3)
      RETURNING user_id, email, display_name, created_at
      `,
      [email, passwordHash, displayName],
    );

    const user = toPublicUser(rows[0]);
    return { ok: true, user, token: issueToken(user.userId) };
  } catch (err: unknown) {
    // 23505 is PostgreSQL's "unique constraint violated" code. Letting the
    // database decide this, rather than checking for the email first,
    // avoids a race where two signups for the same address both look free
    // and then one crashes.
    if (typeof err === 'object' && err !== null && (err as { code?: string }).code === '23505') {
      return { ok: false, reason: 'An account with that email already exists.' };
    }
    throw err;
  }
}

// A real bcrypt hash of a throwaway string, used only to burn time on the
// "no such account" path - see checkLogin. It is never a valid password
// for anyone, because no account uses this hash.
const DUMMY_HASH_FOR_TIMING = bcrypt.hashSync('not-a-real-password', BCRYPT_COST);

/**
 * Check an email and password, and hand back a token if they match.
 *
 * TWO THINGS HERE ARE DELIBERATE AND LOOK ODD
 *
 * 1. The same message, "Email or password is incorrect", is returned
 *    whether the email is unknown or the password is simply wrong. Saying
 *    "no account with that email" would turn this endpoint into a way of
 *    testing which addresses have accounts - useful to nobody except
 *    someone building a target list.
 *
 * 2. When the email is unknown, a bcrypt comparison is still run against a
 *    throwaway hash before answering. Without it, an unknown email would
 *    answer in about a millisecond while a known one took a tenth of a
 *    second, and that difference alone would give away exactly what the
 *    identical message is there to hide.
 */
export async function checkLogin(input: {
  email: string;
  password: string;
}): Promise<AuthResult> {
  const email = normaliseEmail(input.email);
  const sameAnswerForBothFailures = 'Email or password is incorrect.';

  const { rows } = await pool.query(
    `
    SELECT user_id, email, display_name, password_hash, created_at
    FROM app_user
    WHERE lower(email) = $1
    `,
    [email],
  );

  if (rows.length === 0) {
    await bcrypt.compare(input.password, DUMMY_HASH_FOR_TIMING);
    return { ok: false, reason: sameAnswerForBothFailures };
  }

  const row = rows[0];
  const passwordMatches = await bcrypt.compare(input.password, row.password_hash);
  if (!passwordMatches) {
    return { ok: false, reason: sameAnswerForBothFailures };
  }

  // Recorded after the password is confirmed, so a failed guess never
  // moves the timestamp.
  await pool.query(`UPDATE app_user SET last_login_at = now() WHERE user_id = $1`, [row.user_id]);

  const user = toPublicUser(row);
  return { ok: true, user, token: issueToken(user.userId) };
}

/**
 * Read a token and say which account it belongs to, or null if it is
 * missing, expired, tampered with, or signed with a different key.
 *
 * Deliberately returns null rather than throwing. Every caller has to
 * handle "not logged in" anyway, and an exception for the ordinary case of
 * an expired token would just be noise in the logs.
 */
export function userIdFromToken(token: string | undefined): string | null {
  if (!token) return null;

  try {
    const payload = jwt.verify(token, tokenSigningKey());
    if (typeof payload === 'object' && payload !== null && typeof payload.sub === 'string') {
      return payload.sub;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Pull the token out of an `Authorization: Bearer <token>` header.
 *
 * Split into its own function because the header is a string from the
 * outside world and can be anything at all - missing, empty, the wrong
 * scheme, or just the word "Bearer" on its own.
 */
export function tokenFromAuthorizationHeader(header: string | undefined): string | undefined {
  if (!header) return undefined;

  const [scheme, value] = header.split(' ');
  if (scheme?.toLowerCase() !== 'bearer') return undefined;
  if (!value || value.length === 0) return undefined;

  return value;
}

/** Look up the account behind a token, for "who am I" style requests. */
export async function findUserById(userId: string): Promise<PublicUser | null> {
  const { rows } = await pool.query(
    `SELECT user_id, email, display_name, created_at FROM app_user WHERE user_id = $1`,
    [userId],
  );
  if (rows.length === 0) return null;
  return toPublicUser(rows[0]);
}
