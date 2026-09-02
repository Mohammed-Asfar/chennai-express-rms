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

test('a day offline keeps billing and says nothing yet', () => {
  // The point of the grace period: a normal internet outage is invisible.
  const verdict = evaluate(state({ lastVerifiedAt: daysAgo(1) }), NOW)
  assertEqual(verdict.allowed, true, 'still billing')
  assertEqual(verdict.warn, false, 'no warning this early')
  assertEqual(verdict.graceDaysRemaining, GRACE_DAYS - 1, 'days counted')
})

test('the warning starts only in the last three days', () => {
  const quiet = evaluate(state({ lastVerifiedAt: daysAgo(3) }), NOW)
  assertEqual(quiet.warn, false, 'four days left is not yet a warning')

  const warned = evaluate(state({ lastVerifiedAt: daysAgo(5) }), NOW)
  assertEqual(warned.allowed, true, 'still billing')
  assertEqual(warned.warn, true, 'now warning')
  assertEqual(warned.graceDaysRemaining, 2, 'two days left')
})

test('billing stops once the grace period is spent', () => {
  const verdict = evaluate(state({ lastVerifiedAt: daysAgo(GRACE_DAYS + 1) }), NOW)
  assertEqual(verdict.allowed, false, 'blocked')
  assertEqual(verdict.graceDaysRemaining, 0, 'nothing left')
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

test('an unparseable verification date does not grant an unlimited licence', () => {
  // A corrupted timestamp must fail closed, not open.
  const verdict = evaluate(state({ lastVerifiedAt: 'not a date' }), NOW)
  assertEqual(verdict.allowed, false, 'blocked rather than trusted')
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

test('a successful check moves the grace window forward', () => {
  const db = freshDb()
  writeLicenseState(db, state({ lastVerifiedAt: daysAgo(6) }), NOW)

  const before = evaluate(readLicenseState(db), NOW)
  assertEqual(before.warn, true, 'nearly out of grace')

  markVerified(db, 'active', NOW)

  const after = evaluate(readLicenseState(db), NOW)
  assertEqual(after.warn, false, 'the window reset')
  assertEqual(after.graceDaysRemaining, null, 'no longer counting down')
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
