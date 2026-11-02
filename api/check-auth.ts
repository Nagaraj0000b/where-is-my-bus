// Prove the account logic is right BEFORE putting it behind an API.
//
//   node api/check-auth.ts
//
// AGENTS.md working convention #4: "Script first, service second." Same
// idea as check-eta.ts and check-journey.ts - this calls src/auth.ts
// directly and asks "is the logic right", with no HTTP anywhere near it.
//
// Auth is worth checking hard because its failures are silent. A wrong ETA
// is visibly wrong the moment a bus turns up late; a password stored
// badly, or a token that can be forged, looks exactly like a working login
// right up until it matters. So the checks below care much more about the
// ways it should REFUSE than the way it should succeed.
//
// Everything it creates is deleted again at the end, so it is safe to
// re-run as often as you like.

import { pool } from './src/db.ts';
import {
  createAccount,
  checkLogin,
  userIdFromToken,
  tokenFromAuthorizationHeader,
  findUserById,
} from './src/auth.ts';

let passed = 0;
let failed = 0;

function check(name: string, condition: boolean, detail = '') {
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name}${detail ? ' - ' + detail : ''}`);
  }
}

function section(title: string) {
  console.log('\n' + title);
}

// Every account this script makes uses this suffix, so the cleanup at the
// end can find them all and cannot possibly touch a real account.
const TEST_SUFFIX = '@check-auth.invalid';
const testEmail = `wimb-test-${Date.now()}${TEST_SUFFIX}`;
const goodPassword = 'a-long-enough-password';

async function main() {
  // -------------------------------------------------------------------
  section('1. Creating an account');
  // -------------------------------------------------------------------
  const created = await createAccount({
    email: testEmail,
    password: goodPassword,
    displayName: 'Test Person',
  });

  check('a valid signup succeeds', created.ok, created.ok ? '' : created.reason);
  if (!created.ok) {
    console.log('\nCannot continue without an account.');
    await cleanUp();
    process.exit(1);
  }

  check('it hands back a token', created.token.length > 20);
  check('it hands back the display name', created.user.displayName === 'Test Person');
  check('the email came back lowercased', created.user.email === testEmail.toLowerCase());

  // The whole point of toPublicUser. If a hash can reach this object it
  // can reach an HTTP response.
  check(
    'the password hash is NOT in the returned user',
    !JSON.stringify(created.user).toLowerCase().includes('hash') &&
      !JSON.stringify(created.user).includes('$2'),
    JSON.stringify(created.user),
  );

  // -------------------------------------------------------------------
  section('2. The password is not stored as the password');
  // -------------------------------------------------------------------
  const stored = await pool.query(
    `SELECT password_hash FROM app_user WHERE user_id = $1`,
    [created.user.userId],
  );
  const hash = stored.rows[0].password_hash as string;

  check('the plain password is nowhere in the database row', !hash.includes(goodPassword));
  check('what is stored looks like a bcrypt hash', hash.startsWith('$2'), hash.slice(0, 4));
  check('the hash is the expected length', hash.length === 60, `got ${hash.length}`);
  // Cost 12 is the security decision in auth.ts. If someone lowers it, this
  // fails loudly rather than quietly weakening every password in the table.
  check('the hash records cost 12', hash.startsWith('$2b$12$') || hash.startsWith('$2a$12$'),
    hash.slice(0, 7));

  // -------------------------------------------------------------------
  section('3. Signup refuses what it should');
  // -------------------------------------------------------------------
  const duplicate = await createAccount({
    email: testEmail.toUpperCase(), // same address, shouted
    password: goodPassword,
    displayName: 'Impostor',
  });
  check('the same email in capitals is still a duplicate', !duplicate.ok,
    duplicate.ok ? 'it created a second account' : '');

  const shortPassword = await createAccount({
    email: `short-${Date.now()}${TEST_SUFFIX}`,
    password: 'abc123',
    displayName: 'Test Person',
  });
  check('a 6-character password is refused', !shortPassword.ok);

  const notAnEmail = await createAccount({
    email: 'nagga-at-example',
    password: goodPassword,
    displayName: 'Test Person',
  });
  check('a string with no @ is refused', !notAnEmail.ok);

  const blankName = await createAccount({
    email: `blank-${Date.now()}${TEST_SUFFIX}`,
    password: goodPassword,
    displayName: '   ',
  });
  check('a blank display name is refused', !blankName.ok);

  // bcrypt ignores everything past 72 bytes. If this were allowed through,
  // two different long passwords would open the same account.
  const tooLong = await createAccount({
    email: `long-${Date.now()}${TEST_SUFFIX}`,
    password: 'x'.repeat(80),
    displayName: 'Test Person',
  });
  check('a password over bcrypt 72-byte limit is refused, not truncated', !tooLong.ok);

  // -------------------------------------------------------------------
  section('4. Logging in');
  // -------------------------------------------------------------------
  const goodLogin = await checkLogin({ email: testEmail, password: goodPassword });
  check('the right password logs in', goodLogin.ok, goodLogin.ok ? '' : goodLogin.reason);

  const capitalised = await checkLogin({
    email: testEmail.toUpperCase(),
    password: goodPassword,
  });
  check('email is case-insensitive at login', capitalised.ok);

  const spaced = await checkLogin({ email: `  ${testEmail}  `, password: goodPassword });
  check('surrounding spaces in the email are ignored', spaced.ok);

  const wrongPassword = await checkLogin({ email: testEmail, password: 'wrong-password-here' });
  check('the wrong password is refused', !wrongPassword.ok);

  // Password checks must be case-sensitive - this would be a catastrophic
  // bug and it is exactly the sort of thing a sloppy comparison introduces.
  const shoutedPassword = await checkLogin({
    email: testEmail,
    password: goodPassword.toUpperCase(),
  });
  check('the password IS case-sensitive', !shoutedPassword.ok);

  const emptyPassword = await checkLogin({ email: testEmail, password: '' });
  check('an empty password is refused', !emptyPassword.ok);

  // -------------------------------------------------------------------
  section('5. A failed login does not say WHICH part was wrong');
  // -------------------------------------------------------------------
  const unknownEmail = await checkLogin({
    email: `nobody-${Date.now()}${TEST_SUFFIX}`,
    password: goodPassword,
  });
  check('an unknown email is refused', !unknownEmail.ok);

  // The reason both refusals exist. If these two strings differ, the login
  // endpoint becomes a tool for discovering which emails have accounts.
  if (!unknownEmail.ok && !wrongPassword.ok) {
    check(
      'unknown email and wrong password give the IDENTICAL message',
      unknownEmail.reason === wrongPassword.reason,
      `"${unknownEmail.reason}" vs "${wrongPassword.reason}"`,
    );
  }

  // -------------------------------------------------------------------
  section('6. An unknown email takes about as long as a known one');
  // -------------------------------------------------------------------
  // Guards the dummy-hash comparison in checkLogin. Without it the unknown
  // path returns in ~1ms and the known path in ~100ms, and that gap alone
  // reveals what the identical message above is hiding.
  const knownStart = Date.now();
  await checkLogin({ email: testEmail, password: 'wrong-password-here' });
  const knownMs = Date.now() - knownStart;

  const unknownStart = Date.now();
  await checkLogin({ email: `ghost-${Date.now()}${TEST_SUFFIX}`, password: 'wrong-password-here' });
  const unknownMs = Date.now() - unknownStart;

  console.log(`  known email took ${knownMs}ms, unknown took ${unknownMs}ms`);
  // Generous bounds on purpose - this is checking that the dummy compare
  // happens at all, not measuring it precisely on a laptop that is also
  // running Docker.
  check('the unknown-email path is not suspiciously fast', unknownMs > knownMs / 4,
    `${unknownMs}ms vs ${knownMs}ms`);

  // -------------------------------------------------------------------
  section('7. Tokens');
  // -------------------------------------------------------------------
  const token = created.token;

  check('a fresh token names the right account', userIdFromToken(token) === created.user.userId);
  check('a missing token gives nobody', userIdFromToken(undefined) === null);
  check('an empty token gives nobody', userIdFromToken('') === null);
  check('a random string gives nobody', userIdFromToken('not-a-token') === null);

  // A JWT is three dot-separated parts, the last being the signature.
  // Changing one character of it must invalidate the whole token - this is
  // the check that proves tokens cannot simply be edited by hand.
  const parts = token.split('.');
  const tamperedSignature = `${parts[0]}.${parts[1]}.${parts[2].slice(0, -1)}X`;
  check('a token with one altered signature character is rejected',
    userIdFromToken(tamperedSignature) === null);

  // The payload carries the user id. Swapping it for someone else's id
  // must fail, or anyone could log in as anyone.
  const forgedPayload = Buffer.from(
    JSON.stringify({ sub: '00000000-0000-0000-0000-000000000000' }),
  ).toString('base64url');
  const forgedToken = `${parts[0]}.${forgedPayload}.${parts[2]}`;
  check('a token with a swapped user id is rejected', userIdFromToken(forgedToken) === null);

  // The classic JWT attack: set the algorithm to "none" and drop the
  // signature, hoping the library takes the token's word for it.
  const noneHeader = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
  const noneToken = `${noneHeader}.${parts[1]}.`;
  check('an "alg: none" unsigned token is rejected', userIdFromToken(noneToken) === null);

  // -------------------------------------------------------------------
  section('8. Reading the Authorization header');
  // -------------------------------------------------------------------
  check('a normal Bearer header works',
    tokenFromAuthorizationHeader(`Bearer ${token}`) === token);
  check('the scheme is case-insensitive',
    tokenFromAuthorizationHeader(`bearer ${token}`) === token);
  check('a missing header gives nothing',
    tokenFromAuthorizationHeader(undefined) === undefined);
  check('the word Bearer alone gives nothing',
    tokenFromAuthorizationHeader('Bearer') === undefined);
  check('Bearer with nothing after it gives nothing',
    tokenFromAuthorizationHeader('Bearer ') === undefined);
  check('a different scheme is not accepted',
    tokenFromAuthorizationHeader(`Basic ${token}`) === undefined);
  check('a bare token with no scheme is not accepted',
    tokenFromAuthorizationHeader(token) === undefined);

  // -------------------------------------------------------------------
  section('9. Looking an account up again');
  // -------------------------------------------------------------------
  const found = await findUserById(created.user.userId);
  check('the account can be found by its id', found !== null);
  check('it is the same person', found?.email === testEmail.toLowerCase());
  check('an unknown id finds nobody',
    (await findUserById('00000000-0000-0000-0000-000000000000')) === null);

  // -------------------------------------------------------------------
  section('10. Logging in records the time');
  // -------------------------------------------------------------------
  const loginTime = await pool.query(
    `SELECT last_login_at FROM app_user WHERE user_id = $1`,
    [created.user.userId],
  );
  check('last_login_at was set by the successful login',
    loginTime.rows[0].last_login_at !== null);

  // -------------------------------------------------------------------
  await cleanUp();
  console.log(`\n${passed} passed, ${failed} failed`);
  await pool.end();
  process.exit(failed === 0 ? 0 : 1);
}

/**
 * Delete every account this script created. Matches on the reserved
 * .invalid domain, which by definition can never be a real address, so
 * this cannot delete a genuine account even if one exists.
 */
async function cleanUp() {
  const { rowCount } = await pool.query(
    `DELETE FROM app_user WHERE email LIKE $1`,
    [`%${TEST_SUFFIX}`],
  );
  console.log(`\n  (cleaned up ${rowCount} test account${rowCount === 1 ? '' : 's'})`);
}

main().catch(async (e) => {
  console.error(e);
  try {
    await cleanUp();
  } catch {
    // Already failing; a cleanup failure on top is not worth masking the
    // real error with.
  }
  process.exit(1);
});
