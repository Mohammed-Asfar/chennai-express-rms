import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import {
  claimedTimestamp,
  evaluate,
  machineFingerprint,
  markVerified,
  normaliseKey,
  readLicenseState,
  writeLicenseState,
  type LicenseStatus,
} from '../lib/license.js'

/**
 * Activation.
 *
 * Unauthenticated by necessity: it runs before anyone can sign in. It exposes
 * nothing that is not already on the machine — the caller must supply a valid key
 * to learn anything, and a wrong key returns the same message every time.
 *
 * The Neon connection string never leaves the backend, exactly as the update check
 * does not.
 */
export async function activationRoutes(app: FastifyInstance): Promise<void> {
  const claimSchema = z.object({
    key: z.string().min(1).max(64),
  })

  /** What the app asks on every launch. Never fails; it returns a verdict. */
  app.get('/activation/status', async () => {
    const state = readLicenseState(app.db)

    // Refresh in the background. The response is answered from the cache either
    // way, so a slow or dead cloud cannot delay the login screen.
    if (state) void refresh(app, state.key, state.fingerprint)

    return evaluate(state)
  })

  app.post('/activation/claim', async (request, reply) => {
    const parsed = claimSchema.safeParse(request.body)
    if (!parsed.success) {
      return reply.status(400).send({ error: 'Enter your activation key.' })
    }

    const key = normaliseKey(parsed.data.key)
    if (!key) {
      return reply.status(400).send({ error: 'That key is not valid. Check and try again.' })
    }

    if (!app.env.CLOUD_DATABASE_URL) {
      return reply.status(503).send({
        error: 'Activation is not available on this installation.',
      })
    }

    const existing = readLicenseState(app.db)
    if (existing && existing.key !== key) {
      return reply.status(409).send({
        error: 'This installation is already activated with a different key.',
      })
    }

    const fingerprint = machineFingerprint()

    // Whether the cloud was reached, so the failure below can name the right
    // cause. A claim that succeeds in Postgres and then fails to write locally
    // reported "check this PC's internet connection" — with the licence already
    // activated in the cloud and the network demonstrably fine. The message sent
    // the search to firewalls and connection strings; the fault was a Date the
    // local insert would not accept.
    let reachedCloud = false

    try {
      const claimed = await claimInCloud(app, key, fingerprint)
      reachedCloud = true

      if (!claimed) {
        // One message for every failure: wrong key, already on another machine,
        // revoked. Telling a caller which one lets them probe for valid keys.
        return reply.status(403).send({
          error: 'That key could not be activated. It may be in use on another PC.',
        })
      }

      writeLicenseState(app.db, {
        key,
        branchCode: claimed.branch_code,
        restaurant: claimed.restaurant,
        fingerprint,
        status: claimed.status as LicenseStatus,
        activatedAt: claimedTimestamp(claimed.activated_at) ?? new Date().toISOString(),
        lastVerifiedAt: new Date().toISOString(),
      })

      request.log.info({ branchCode: claimed.branch_code }, 'activated')
      return evaluate(readLicenseState(app.db))
    } catch (error) {
      request.log.error({ err: error, reachedCloud }, 'activation failed')

      if (reachedCloud) {
        // The licence is claimed in the cloud but the local cache was not
        // written. Blaming the network would be false, and it is what made this
        // fault so hard to find. Retrying is genuinely the right advice: the
        // claim is idempotent for this machine's own fingerprint, so a second
        // attempt re-runs the local write against a row that already matches.
        return reply.status(500).send({
          error: 'The licence was verified but could not be saved on this PC. Try again.',
        })
      }

      return reply.status(503).send({
        error: 'Could not reach the licence server. Check this PC’s internet connection.',
      })
    }
  })
}

interface ClaimedRow {
  branch_code: string
  restaurant: string
  status: string

  // A Date, not a string. postgres decodes TIMESTAMPTZ into a Date object, and
  // better-sqlite3 binds only numbers, strings, bigints, buffers and null — so
  // passing this through unconverted throws on the local write, after the cloud
  // claim has already succeeded. Use claimedTimestamp() to read it.
  activated_at: Date | string | null
}

/**
 * Claims a key for this machine, atomically.
 *
 * One statement. Two PCs racing with the same key cannot both win: the first
 * writes its fingerprint, and the second no longer matches the WHERE clause and
 * gets zero rows. A read-then-write would let both through.
 *
 * An already-activated machine re-running this is a no-op that returns its own row
 * — that is what makes a repeated launch or a reinstall on the same PC harmless.
 */
async function claimInCloud(
  app: FastifyInstance,
  key: string,
  fingerprint: string,
): Promise<ClaimedRow | null> {
  const { default: postgres } = await import('postgres')
  const sql = postgres(app.env.CLOUD_DATABASE_URL!, {
    max: 1,
    idle_timeout: 5,
    connect_timeout: 8,
  })

  try {
    const rows = await sql<ClaimedRow[]>`
      UPDATE licenses
         SET fingerprint  = ${fingerprint},
             status       = 'active',
             activated_at = COALESCE(activated_at, now()),
             last_seen_at = now(),
             updated_at   = now()
       WHERE key = ${key}
         AND status <> 'revoked'
         AND (fingerprint IS NULL OR fingerprint = ${fingerprint})
      RETURNING branch_code, restaurant, status, activated_at
    `
    return rows[0] ?? null
  } finally {
    await sql.end({ timeout: 3 })
  }
}

/**
 * Re-checks a licence and updates the cache.
 *
 * Deliberately silent. A failure leaves `last_verified_at` alone, so the grace
 * period counts down rather than resetting — an install that never reaches the
 * cloud again does eventually stop, but not today and not mid-service.
 */
async function refresh(app: FastifyInstance, key: string, fingerprint: string): Promise<void> {
  if (!app.env.CLOUD_DATABASE_URL) return

  try {
    const { default: postgres } = await import('postgres')
    const sql = postgres(app.env.CLOUD_DATABASE_URL, {
      max: 1,
      idle_timeout: 5,
      connect_timeout: 8,
    })

    try {
      const rows = await sql<{ status: string }[]>`
        UPDATE licenses
           SET last_seen_at = now()
         WHERE key = ${key} AND fingerprint = ${fingerprint}
        RETURNING status
      `

      const status = rows[0]?.status
      if (status === 'active' || status === 'revoked') {
        markVerified(app.db, status)
      } else if (rows.length === 0) {
        // The row is gone, or this machine no longer matches. Treat it as revoked
        // so the grace period starts, rather than trusting a stale cache forever.
        markVerified(app.db, 'revoked')
      }
    } finally {
      await sql.end({ timeout: 3 })
    }
  } catch {
    // Offline. The cache stands and the grace period keeps counting.
  }
}
