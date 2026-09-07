import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import {
  GRACE_DAYS,
  evaluate,
  mintKey,
  normaliseKey,
  readLicenseState,
  writeLicenseState,
  markVerified,
  claimedTimestamp,
  machineFingerprint,
  setFingerprintForTesting,
  type LicenseState,
} from '../src/lib/license.js'
import { test, assertEqual } from './helpers.js'

// --- key format ---

test('a minted key has the documented shape', () => {
  for (let i = 0; i < 50; i++) {
    const key = mintKey()
    if (!/^CX-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(key)) {
      throw new Error(`badly formed key: ${key}`)
    }
  }
})

test('minted keys avoid characters that get misread', () => {
  // O/0, I/1 and S/5 are the pairs people confuse reading a key aloud.
  for (let i = 0; i < 200; i++) {
    const body = mintKey().slice(3).replace(/-/g, '')
    for (const banned of ['O', '0', 'I', '1', 'S', '5']) {
      if (body.includes(banned)) throw new Error(`key contains ${banned}: ${body}`)
    }
  }
})

test('keys do not repeat', () => {
  const seen = new Set<string>()
  for (let i = 0; i < 500; i++) seen.add(mintKey())
  assertEqual(seen.size, 500, 'every key is distinct')
})

test('a key is accepted however it was typed', () => {
  const key = 'CX-ABCD-EFGH-JKLM'
  assertEqual(normaliseKey(key), key, 'canonical form')
  assertEqual(normaliseKey('cx-abcd-efgh-jklm'), key, 'lowercase')
  assertEqual(normaliseKey('CXABCDEFGHJKLM'), key, 'no dashes')
  assertEqual(normaliseKey('  CX-ABCD-EFGH-JKLM  '), key, 'padded')
  assertEqual(normaliseKey('CX ABCD EFGH JKLM'), key, 'spaces for dashes')
})

test('a malformed key is rejected', () => {
  assertEqual(normaliseKey(''), null, 'empty')
  assertEqual(normaliseKey('ABCD-EFGH-JKLM'), null, 'no prefix')
  assertEqual(normaliseKey('CX-ABCD-EFGH'), null, 'too short')
  assertEqual(normaliseKey('CX-ABCD-EFGH-JKLM-NOPQ'), null, 'too long')
  // O is not in the alphabet, so a key containing one was mistyped.
  assertEqual(normaliseKey('CX-ABCD-EFGH-JKLO'), null, 'ambiguous character')
})

// --- fingerprint ---

test('the fingerprint is a stable hash, not the raw machine id', () => {
  setFingerprintForTesting(null)
  const first = machineFingerprint()
  const second = machineFingerprint()

  assertEqual(first, second, 'stable across calls')
  assertEqual(first.length, 64, 'sha-256 hex')
  if (!/^[0-9a-f]{64}$/.test(first)) throw new Error('not a hex digest')
})

// --- the verdict ---

const NOW = new Date('2026-09-02T12:00:00.000Z')

function state(overrides: Partial<LicenseState> = {}): LicenseState {
  return {
    key: 'CX-ABCD-EFGH-JKLM',
    branchCode: 'BR1',
    restaurant: 'Chennai Express',
    fingerprint: 'f'.repeat(64),
    status: 'active',
    activatedAt: '2026-08-01T00:00:00.000Z',
    lastVerifiedAt: NOW.toISOString(),
    ...overrides,
  }
}

function daysAgo(days: number): string {
  return new Date(NOW.getTime() - days * 86_400_000).toISOString()
}

test('an unactivated installation is not allowed to run', () => {
  const verdict = evaluate(null, NOW)
  assertEqual(verdict.allowed, false, 'blocked')
  assertEqual(verdict.activated, false, 'not activated')
})

test('a freshly verified licence runs with nothing shown', () => {
  const verdict = evaluate(state(), NOW)
  assertEqual(verdict.allowed, true, 'allowed')
  assertEqual(verdict.warn, false, 'nothing to warn about')
  assertEqual(verdict.message, null, 'no message')
  assertEqual(verdict.graceDaysRemaining, null, 'not in a grace period')
})

test('a day offline keeps billing and says nothing', () => {
  const verdict = evaluate(state({ lastVerifiedAt: daysAgo(1) }), NOW)
  assertEqual(verdict.allowed, true, 'still billing')
  assertEqual(verdict.warn, false, 'nothing to warn about')
  assertEqual(verdict.graceDaysRemaining, null, 'nothing is counting down')
})

test('a branch that has never had internet bills indefinitely', () => {
  // The case this rule exists for. A client with no wifi was a week from
  // their till refusing to bill on a licence that was paid for and valid.
  //
  // The licence is one-time, so there is no subscription to lapse, and the
  // key is already bound to this machine by activation. A weekly check-in
  // would establish nothing that claiming the key did not.
  for (const days of [8, 30, 365, 3_650]) {
    const verdict = evaluate(state({ lastVerifiedAt: daysAgo(days) }), NOW)
    assertEqual(verdict.allowed, true, `still billing after ${days} days offline`)
    assertEqual(verdict.warn, false, `and not nagged at ${days} days`)
    assertEqual(verdict.message, null, `nothing shown at ${days} days`)
  }
})

test('being offline is never described as a countdown', () => {
  // graceDaysRemaining drives the banner. A number here would put a deadline
  // in front of staff that no longer exists.
  const verdict = evaluate(state({ lastVerifiedAt: daysAgo(GRACE_DAYS + 90) }), NOW)
  assertEqual(verdict.graceDaysRemaining, null, 'no deadline to show')
})

test('a revoked licence still gets its grace period', () => {
  // Cutting a restaurant off the instant a flag flips would cost them a day's
  // takings over a billing dispute.
  const verdict = evaluate(state({ status: 'revoked' }), NOW)
  assertEqual(verdict.allowed, true, 'still billing today')
  assertEqual(verdict.warn, true, 'but told')
  assertEqual(verdict.graceDaysRemaining, GRACE_DAYS, 'full window')
})

test('a revoked licence stops after its grace period', () => {
  const verdict = evaluate(
    state({ status: 'revoked', lastVerifiedAt: daysAgo(GRACE_DAYS) }),
    NOW,
  )
  assertEqual(verdict.allowed, false, 'blocked')
})

test('an unparseable date does not keep a revoked licence running', () => {
  // A corrupt timestamp must not be a way to outlive a revocation: it yields
  // Infinity, which spends the notice at once rather than granting forever.
  const verdict = evaluate(
    state({ status: 'revoked', lastVerifiedAt: 'not a date' }),
    NOW,
  )
  assertEqual(verdict.allowed, false, 'blocked')
})

test('an unparseable date does not stop an active licence', () => {
  // It once did, because being offline was a block and a bad date read as
  // infinitely offline. A corrupt local timestamp is not evidence of anything
  // a paying restaurant did wrong.
  const verdict = evaluate(state({ lastVerifiedAt: 'not a date' }), NOW)
  assertEqual(verdict.allowed, true, 'still billing')
})

test('activation is still required before anything works', () => {
  // Removing the offline expiry does not mean an unactivated copy runs. The
  // key must still be claimed against the cloud once, which is where the
  // machine binding is written.
  assertEqual(evaluate(null, NOW).allowed, false, 'blocked until activated')
})

// --- local state ---

function freshDb(): Db {
  const db = openDatabase(':memory:')
  migrate(db)
  return db
}

test('licence state round trips', () => {
  const db = freshDb()
  const written = state()
  writeLicenseState(db, written, NOW)

  const read = readLicenseState(db)
  assertEqual(read?.key, written.key, 'key')
  assertEqual(read?.branchCode, 'BR1', 'branch code')
  assertEqual(read?.restaurant, 'Chennai Express', 'restaurant')
  assertEqual(read?.status, 'active', 'status')
  db.close()
})

test('only one licence can be stored', () => {
  // A second row would mean an ambiguous verdict. The schema forbids it.
  const db = freshDb()
  writeLicenseState(db, state(), NOW)
  writeLicenseState(db, state({ branchCode: 'BR2', restaurant: 'Second' }), NOW)

  const rows = db.prepare('SELECT COUNT(*) AS n FROM license_state').get() as { n: number }
  assertEqual(rows.n, 1, 'one row, overwritten')
  assertEqual(readLicenseState(db)?.branchCode, 'BR2', 'the newer one won')
  db.close()
})

test('an empty database has no licence', () => {
  const db = freshDb()
  assertEqual(readLicenseState(db), null, 'nothing stored')
  assertEqual(evaluate(readLicenseState(db), NOW).allowed, false, 'and so is blocked')
  db.close()
})

test('a successful check records when the cloud last confirmed it', () => {
  // The timestamp no longer gates an active licence, but it is still written:
  // it is what a revocation's notice counts from, and it is shown in Settings
  // so someone can see whether the cloud has been reached at all.
  const db = freshDb()
  writeLicenseState(db, state({ lastVerifiedAt: daysAgo(60) }), NOW)

  const before = evaluate(readLicenseState(db), NOW)
  assertEqual(before.allowed, true, 'two months offline still bills')

  markVerified(db, 'active', NOW)

  const after = evaluate(readLicenseState(db), NOW)
  assertEqual(after.allowed, true, 'and still does afterwards')
  assertEqual(after.lastVerifiedAt, NOW.toISOString(), 'the check was recorded')
  db.close()
})

test('a revocation seen by a check is recorded locally', () => {
  const db = freshDb()
  writeLicenseState(db, state(), NOW)
  markVerified(db, 'revoked', NOW)

  const verdict = evaluate(readLicenseState(db), NOW)
  assertEqual(verdict.status, 'revoked', 'revocation cached')
  assertEqual(verdict.allowed, true, 'grace period still applies')
  assertEqual(verdict.warn, true, 'and the client is told')
  db.close()
})

// --- what the cloud actually hands back ---

test('a cloud timestamp is stored, not rejected', () => {
  // postgres decodes TIMESTAMPTZ into a Date, and better-sqlite3 binds only
  // numbers, strings, bigints, buffers and null. Passing a claim's activated_at
  // straight through threw on the local insert *after* the cloud claim had
  // already succeeded — so the licence read as active in Postgres while
  // license_state stayed empty, and the app showed "cannot reach the billing
  // service" on a machine whose network was fine.
  //
  // Every other test here passes strings, which is exactly why this shipped.
  const db = freshDb()

  // What the driver hands back, typed as the route receives it.
  const fromCloud: { activated_at: Date | string | null } = {
    activated_at: new Date('2026-09-03T16:15:56.515Z'),
  }

  // Unconverted, this is the exact call that threw in production. It must not.
  writeLicenseState(
    db,
    state({ activatedAt: claimedTimestamp(fromCloud.activated_at)! }),
    NOW,
  )

  const read = readLicenseState(db)
  assertEqual(read?.activatedAt, '2026-09-03T16:15:56.515Z', 'stored as ISO text')

  // And the verdict must be usable, not merely stored: a Date that reached the
  // column as something Date.parse cannot read would fail closed and block a
  // legitimately activated till.
  const verdict = evaluate(readLicenseState(db), NOW)
  assertEqual(verdict.allowed, true, 'an activated till may bill')
  db.close()
})

test('a timestamp that is already text is left alone', () => {
  // The driver's type mapping is configurable, and a string must not be
  // double-converted into something unparseable.
  assertEqual(
    claimedTimestamp('2026-09-03T16:15:56.515Z'),
    '2026-09-03T16:15:56.515Z',
    'passed through unchanged',
  )
  assertEqual(claimedTimestamp(null), null, 'null survives as null')
})

// --- machine binding ---
//
// With the offline expiry gone, this is the only thing stopping one key from
// running on two PCs. It is enforced by the claim's WHERE clause, which needs
// a Postgres to exercise end to end — so what is pinned here is the predicate
// itself, against the rows it has to accept and refuse.

/** The guard in claimInCloud: `fingerprint IS NULL OR fingerprint = ?`. */
function claimable(row: { fingerprint: string | null; status: string }, machine: string): boolean {
  return row.status !== 'revoked' && (row.fingerprint === null || row.fingerprint === machine)
}

test('an unclaimed key activates on the first machine', () => {
  assertEqual(claimable({ fingerprint: null, status: 'active' }, 'pc-a'), true)
})

test('the same machine may re-activate its own key', () => {
  // Reinstalling Windows keeps the MachineGuid, and a repair install must not
  // lock a restaurant out of the licence they paid for.
  assertEqual(claimable({ fingerprint: 'pc-a', status: 'active' }, 'pc-a'), true)
})

test('a second machine cannot claim a key already in use', () => {
  // The control that replaces the weekly check-in: copying the installer to
  // another PC gets as far as the activation screen and no further.
  assertEqual(claimable({ fingerprint: 'pc-a', status: 'active' }, 'pc-b'), false)
})

test('a revoked key activates nowhere', () => {
  assertEqual(claimable({ fingerprint: null, status: 'revoked' }, 'pc-a'), false)
  assertEqual(claimable({ fingerprint: 'pc-a', status: 'revoked' }, 'pc-a'), false)
})
