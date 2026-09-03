import { createHash, randomBytes } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import type { Db } from '../db/client.js'

/**
 * Licence keys, machine binding, and the grace period.
 *
 * The rule this file exists to enforce: **an activation check never stops a
 * restaurant billing because the internet is down.** A licence that cannot be
 * verified is trusted for GRACE_DAYS, and only then does the till stop. A dead
 * Neon, a flat ADSL line, or a slow morning must all resolve to "keep working".
 */

/** Days a branch keeps billing without reaching the cloud. */
export const GRACE_DAYS = 7

/** Days left at which the UI starts warning. */
export const WARN_WITHIN_DAYS = 3

export type LicenseStatus = 'active' | 'revoked'

export interface LicenseState {
  key: string
  branchCode: string
  restaurant: string
  fingerprint: string
  status: LicenseStatus
  activatedAt: string
  lastVerifiedAt: string
}

export interface LicenseVerdict {
  /** False only when the app must refuse to run. */
  allowed: boolean
  activated: boolean
  status: LicenseStatus | null
  branchCode: string | null
  restaurant: string | null
  /** Whole days left before billing stops. Null when not in a grace period. */
  graceDaysRemaining: number | null
  /** True when the client should be told something, without being blocked. */
  warn: boolean
  /** Shown to staff. Never a raw error string. */
  message: string | null
  lastVerifiedAt: string | null
}

// --- key format ---

/** Ambiguous characters are omitted: no O/0, no I/1, no S/5. */
const ALPHABET = 'ABCDEFGHJKLMNPQRTUVWXYZ2346789'
const GROUPS = 3
const GROUP_LENGTH = 4

/**
 * Mints a key of the form CX-XXXX-XXXX-XXXX.
 *
 * Read aloud over a phone and typed by hand, so the alphabet avoids characters
 * that get misheard or mistyped. 30^12 is ample — these are handed out one at a
 * time, not guessed at scale, and the fingerprint binding is the real control.
 */
export function mintKey(): string {
  const groups: string[] = []
  for (let g = 0; g < GROUPS; g++) {
    let group = ''
    // rejection-free: 30 divides evenly into the 240 values below the cutoff, so
    // no character is more likely than another.
    const bytes = randomBytes(GROUP_LENGTH * 2)
    let i = 0
    while (group.length < GROUP_LENGTH) {
      const byte = bytes[i++]!
      if (byte >= 240) continue
      group += ALPHABET[byte % ALPHABET.length]
    }
    groups.push(group)
  }
  return `CX-${groups.join('-')}`
}

/**
 * Accepts a key the way a person typed it.
 *
 * Lowercase, missing dashes, and pasted whitespace are all normalised rather than
 * rejected — someone reading a key off a WhatsApp message should not have to fight
 * the field.
 */
export function normaliseKey(input: string): string | null {
  const cleaned = input.toUpperCase().replace(/[^A-Z0-9]/g, '')
  if (!cleaned.startsWith('CX')) return null

  const body = cleaned.slice(2)
  if (body.length !== GROUPS * GROUP_LENGTH) return null
  for (const char of body) {
    if (!ALPHABET.includes(char)) return null
  }

  const groups: string[] = []
  for (let g = 0; g < GROUPS; g++) {
    groups.push(body.slice(g * GROUP_LENGTH, (g + 1) * GROUP_LENGTH))
  }
  return `CX-${groups.join('-')}`
}

// --- machine fingerprint ---

let cachedFingerprint: string | null = null

/**
 * A stable identifier for this PC.
 *
 * Windows `MachineGuid` is written at install time and survives reboots, app
 * updates and hardware changes short of a reinstall. It is hashed rather than
 * stored raw: the cloud has no need for the actual GUID, and a hash cannot be
 * turned back into something that identifies the machine elsewhere.
 *
 * Falls back to a hostname-derived value off Windows so tests and development on
 * other platforms still work. That fallback is weaker, which is acceptable — the
 * product ships on Windows.
 */
export function machineFingerprint(): string {
  if (cachedFingerprint) return cachedFingerprint

  let raw: string
  try {
    if (process.platform === 'win32') {
      const output = execFileSync(
        'reg',
        ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid'],
        { encoding: 'utf8', windowsHide: true, timeout: 5000 },
      )
      const match = output.match(/MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)/)
      if (!match?.[1]) throw new Error('MachineGuid not found')
      raw = match[1]
    } else {
      raw = `${process.platform}:${process.env.HOSTNAME ?? process.env.HOST ?? 'unknown'}`
    }
  } catch {
    // A machine whose GUID cannot be read still has to run. Hostname is weaker but
    // refusing to start would be worse than a licence bound to something softer.
    raw = `fallback:${process.platform}:${process.env.COMPUTERNAME ?? 'unknown'}`
  }

  cachedFingerprint = createHash('sha256').update(raw).digest('hex')
  return cachedFingerprint
}

/** Tests need a predictable value. */
export function setFingerprintForTesting(value: string | null): void {
  cachedFingerprint = value
}

// --- local state ---

export function readLicenseState(db: Db): LicenseState | null {
  const row = db
    .prepare(
      `SELECT key, branch_code, restaurant, fingerprint, status,
              activated_at, last_verified_at
         FROM license_state WHERE id = 1`,
    )
    .get() as
    | {
        key: string
        branch_code: string
        restaurant: string
        fingerprint: string
        status: LicenseStatus
        activated_at: string
        last_verified_at: string
      }
    | undefined

  if (!row) return null

  return {
    key: row.key,
    branchCode: row.branch_code,
    restaurant: row.restaurant,
    fingerprint: row.fingerprint,
    status: row.status,
    activatedAt: row.activated_at,
    lastVerifiedAt: row.last_verified_at,
  }
}

/**
 * A cloud timestamp as the text SQLite stores.
 *
 * postgres decodes TIMESTAMPTZ into a Date; better-sqlite3 binds only numbers,
 * strings, bigints, buffers and null. This is the same class of mismatch as the
 * boolean conversion on sync push — what Postgres returns is not what SQLite
 * accepts — and it lives here, beside the write that would otherwise throw.
 */
export function claimedTimestamp(value: Date | string | null): string | null {
  if (value === null) return null
  return value instanceof Date ? value.toISOString() : value
}

export function writeLicenseState(db: Db, state: LicenseState, now = new Date()): void {
  const at = now.toISOString()
  db.prepare(
    `INSERT INTO license_state
       (id, key, branch_code, restaurant, fingerprint, status,
        activated_at, last_verified_at, created_at, updated_at)
     VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (id) DO UPDATE SET
       key = excluded.key,
       branch_code = excluded.branch_code,
       restaurant = excluded.restaurant,
       fingerprint = excluded.fingerprint,
       status = excluded.status,
       activated_at = excluded.activated_at,
       last_verified_at = excluded.last_verified_at,
       updated_at = excluded.updated_at`,
  ).run(
    state.key,
    state.branchCode,
    state.restaurant,
    state.fingerprint,
    state.status,
    state.activatedAt,
    state.lastVerifiedAt,
    at,
    at,
  )
}

/** Stamps a successful cloud check without touching anything else. */
export function markVerified(db: Db, status: LicenseStatus, now = new Date()): void {
  const at = now.toISOString()
  db.prepare(
    `UPDATE license_state SET status = ?, last_verified_at = ?, updated_at = ? WHERE id = 1`,
  ).run(status, at, at)
}

// --- the verdict ---

/**
 * Decides whether the app may run.
 *
 * Everything here is computed from the cached state, so it works with no network.
 * The cloud's job is only to keep that cache fresh.
 */
export function evaluate(state: LicenseState | null, now = new Date()): LicenseVerdict {
  if (!state) {
    return {
      allowed: false,
      activated: false,
      status: null,
      branchCode: null,
      restaurant: null,
      graceDaysRemaining: null,
      warn: false,
      message: 'This installation has not been activated yet.',
      lastVerifiedAt: null,
    }
  }

  const base = {
    activated: true,
    status: state.status,
    branchCode: state.branchCode,
    restaurant: state.restaurant,
    lastVerifiedAt: state.lastVerifiedAt,
  }

  const elapsedDays = daysBetween(state.lastVerifiedAt, now)
  const remaining = Math.max(0, GRACE_DAYS - Math.floor(elapsedDays))

  if (state.status === 'revoked') {
    // Revocation still honours the grace period. Cutting a restaurant off mid
    // service on the day someone flips a flag is how a billing system loses a
    // day's takings; a week's notice is enough to settle an unpaid invoice.
    return {
      ...base,
      allowed: remaining > 0,
      graceDaysRemaining: remaining,
      warn: true,
      message:
        remaining > 0
          ? `This licence has been withdrawn. Billing stops in ${remaining} ${plural(remaining, 'day')}. Please contact support.`
          : 'This licence has been withdrawn. Please contact support to continue.',
    }
  }

  // Active, but the cloud has not confirmed it recently.
  if (remaining <= 0) {
    return {
      ...base,
      allowed: false,
      graceDaysRemaining: 0,
      warn: true,
      message:
        'This installation has not reached the licence server for over a week. ' +
        'Connect it to the internet to continue.',
    }
  }

  const stale = elapsedDays >= 1
  return {
    ...base,
    allowed: true,
    graceDaysRemaining: stale ? remaining : null,
    warn: stale && remaining <= WARN_WITHIN_DAYS,
    message:
      stale && remaining <= WARN_WITHIN_DAYS
        ? `Could not reach the licence server. Billing stops in ${remaining} ${plural(remaining, 'day')} unless this PC gets internet access.`
        : null,
  }
}

function daysBetween(fromIso: string, now: Date): number {
  const from = Date.parse(fromIso)
  if (Number.isNaN(from)) return Number.POSITIVE_INFINITY
  return (now.getTime() - from) / 86_400_000
}

function plural(n: number, word: string): string {
  return n === 1 ? word : `${word}s`
}
