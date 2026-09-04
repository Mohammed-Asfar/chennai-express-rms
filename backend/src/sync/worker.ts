import type { Sql } from 'postgres'
import type { Db } from '../db/client.js'
import type { Env } from '../lib/env.js'
import { pushPending, syncCounts, lastSyncedAt, type PushResult } from './push.js'
import { readCloudStorage, type CloudStorage } from './storage.js'

export interface SyncStatus {
  enabled: boolean
  running: boolean
  lastSuccessAt: string | null
  lastAttemptAt: string | null
  lastError: string | null
  pending: number
  quarantined: number
  /** Consecutive failed cycles — drives the reconnect detection. */
  consecutiveFailures: number

  /**
   * Whether the cloud copy can be trusted to be current.
   *
   * False the moment anything is stuck, so the UI has one field to read rather
   * than re-deriving the rule and getting it subtly different.
   */
  healthy: boolean

  /**
   * Why it is unhealthy, in words a restaurant owner can act on. Null when
   * healthy.
   */
  problem: string | null
}

interface Logger {
  info(obj: object, msg?: string): void
  warn(obj: object, msg?: string): void
  debug(obj: object, msg?: string): void
}

/**
 * Pushes local changes to the cloud.
 *
 * Event-driven with a safety net: a debounce after each write, an idle
 * heartbeat, and an immediate drain at startup. A fixed interval alone is
 * wrong in both directions — wasteful when idle, laggy right after a bill.
 *
 * Nothing here can block billing. Every failure is swallowed into status.
 */
export class SyncWorker {
  private debounceTimer: NodeJS.Timeout | null = null
  private heartbeatTimer: NodeJS.Timeout | null = null
  private retryTimer: NodeJS.Timeout | null = null
  private running = false
  /** Set when a write lands mid-cycle, so its rows are not missed. */
  private pendingSignal = false
  private stopped = false

  private lastSuccessAt: string | null = null
  private lastAttemptAt: string | null = null
  private lastError: string | null = null
  private consecutiveFailures = 0

  /** Screens waiting to be told the state changed. */
  private readonly listeners = new Set<(status: SyncStatus) => void>()

  constructor(
    private readonly db: Db,
    private readonly env: Env,
    private readonly log: Logger,
    private readonly options: {
      debounceMs?: number
      heartbeatMs?: number
      retryBaseMs?: number
      batchSize?: number
      /** Injectable for tests. */
      connect?: () => Promise<Sql>
    } = {},
  ) {}

  get enabled(): boolean {
    return this.env.CLOUD_DATABASE_URL !== undefined
  }

  /** Runs an immediate drain, then starts the heartbeat. */
  start(): void {
    if (!this.enabled) {
      this.log.info({}, 'sync disabled - CLOUD_DATABASE_URL is not set')
      return
    }

    // A development server shares the production cloud only when told to.
    //
    // `pnpm run dev` uses its own SQLite but the same .env, so it pushed to the
    // same branch as the installed till. Both then allocated order numbers from
    // one sequence and both issued a #1 for the same trading day — which the
    // unique index on (branch_id, business_date, order_no) rejected, stalling
    // the real till's sync behind test data.
    //
    // Refusing by default is right: a developer who has not thought about this
    // wants an offline dev server, not a second till competing with a live one.
    if (this.env.NODE_ENV === 'development' && process.env.SYNC_IN_DEV !== 'true') {
      this.log.warn(
        {},
        'sync disabled in development - set SYNC_IN_DEV=true to push to the cloud from a dev server',
      )
      return
    }

    // Whatever was pending when the process last stopped.
    void this.runCycle('startup')

    // Five minutes, not one.
    //
    // A bill does not wait for this. Every successful write signals the worker
    // through the server's onResponse hook, so a payment pushes about two
    // seconds after it is taken, and a failed cycle retries on its own backoff.
    // The heartbeat only covers what those miss: a batch capped at 200 rows
    // leaving more behind, a row written straight into SQLite by a script, and
    // — the reason it runs at all on a till doing nothing — confirming the
    // cloud is still reachable, which is what the backup screen reports.
    //
    // At a minute that check ran sixty times an hour and kept the cloud awake
    // about 17% of every hour a till was switched on. None of those wake-ups
    // moved a row. The cost of five is that a till sitting idle can take five
    // minutes to notice the cloud has gone; one taking orders still notices in
    // two seconds, because a write dials immediately either way.
    //
    // Not unref'd: an unref'd timer does not hold the process open, and on an
    // otherwise idle event loop it can be left unscheduled — the backup must
    // keep running whether or not anything else is happening.
    const heartbeat = this.options.heartbeatMs ?? 5 * 60_000
    this.heartbeatTimer = setInterval(() => {
      void this.runCycle('heartbeat')
    }, heartbeat)
  }

  stop(): void {
    this.stopped = true
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer)
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.debounceTimer = null
    this.heartbeatTimer = null
    this.retryTimer = null
  }

  /**
   * Called by routes after a write commits.
   *
   * Debounced, so a burst of order edits becomes one push rather than ten.
   * Cheap and synchronous — a route must never wait on sync.
   */
  signal(): void {
    if (!this.enabled || this.stopped) return

    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null
      void this.runCycle('write')
    }, this.options.debounceMs ?? 2_000)
  }

  /**
   * Comes back after a failed cycle, sooner than the heartbeat.
   *
   * Backs off as failures mount — 15s, 30s, 60s, up to two minutes — so a
   * brief outage recovers almost immediately while a cloud that is down for
   * the night is not dialled every fifteen seconds.
   */
  private scheduleRetry(): void {
    if (this.stopped || !this.enabled) return
    if (this.retryTimer) return

    const base = this.options.retryBaseMs ?? RETRY_BASE_MS
    const delay = Math.min(
      base * 2 ** Math.min(this.consecutiveFailures - 1, 3),
      RETRY_MAX_MS,
    )

    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      void this.runCycle('retry')
    }, delay)
  }

  /**
   * Watches for state changes, pushed rather than polled.
   *
   * Returns the unsubscribe. The current status is not sent here — the caller
   * sends it once on connect, so a listener always has something to draw
   * before the first change arrives.
   */
  watch(listener: (status: SyncStatus) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * Tells every watcher the state moved.
   *
   * Never throws into a cycle: a screen that has gone away, or a socket that
   * fails mid-write, must not abort a backup.
   */
  private broadcast(): void {
    if (this.listeners.size === 0) return

    const status = this.status()
    for (const listener of this.listeners) {
      try {
        listener(status)
      } catch (error) {
        this.log.warn(
          { err: error instanceof Error ? error.message : String(error) },
          'a sync watcher threw',
        )
      }
    }
  }

  /** Forces a cycle now, for the manual retry action. */
  async syncNow(): Promise<PushResult | null> {
    if (!this.enabled) return null
    return this.runCycle('manual')
  }

  /**
   * How much room the cloud copy is using.
   *
   * Its own connection rather than the cycle's: this is asked for by someone
   * looking at a screen, and it must not wait on a push that could be pumping
   * a week's backlog. Null when there is no cloud, or it cannot be reached —
   * a storage figure is never worth an error in front of a user.
   */
  async storage(): Promise<CloudStorage | null> {
    if (!this.enabled) return null

    let sql: Sql | null = null
    try {
      sql = await this.connect()
      return await readCloudStorage(this.db, sql)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.log.warn({ err: message }, 'could not read cloud storage')
      return null
    } finally {
      if (sql) await sql.end({ timeout: 5 }).catch(() => undefined)
    }
  }

  status(): SyncStatus {
    const counts = this.enabled
      ? syncCounts(this.db)
      : { pending: 0, quarantined: 0 }

    // The rows are the record; this worker's memory is only a cache of it that
    // empties on every restart. Taking the later of the two means a till
    // restarted mid-service reports when the backup actually happened rather
    // than "Never".
    const stamped = this.enabled ? lastSyncedAt(this.db) : null
    const lastSuccessAt = later(this.lastSuccessAt, stamped)

    return {
      enabled: this.enabled,
      running: this.running,
      lastSuccessAt,
      // Falls back to the push time: after a restart nothing has been checked
      // in this process, but the last check demonstrably reached the cloud.
      lastAttemptAt: this.lastAttemptAt ?? lastSuccessAt,
      lastError: this.lastError,
      ...counts,
      consecutiveFailures: this.consecutiveFailures,
      ...this.health(counts, lastSuccessAt),
    }
  }

  /**
   * The one-line verdict, worst problem first.
   *
   * Quarantine outranks a failing connection: an outage fixes itself when the
   * internet returns, but quarantined rows are given up on and stay lost until
   * someone retries them.
   */
  private health(
    counts: { pending: number; quarantined: number },
    lastSuccessAt: string | null,
  ): {
    healthy: boolean
    problem: string | null
  } {
    if (!this.enabled) {
      return { healthy: false, problem: 'Cloud backup is not set up on this machine.' }
    }
    if (counts.quarantined > 0) {
      return {
        healthy: false,
        problem:
          `${counts.quarantined} record${counts.quarantined === 1 ? '' : 's'} the cloud kept ` +
          'refusing. They stay on this PC only until you retry them.',
      }
    }
    if (this.consecutiveFailures > 0) {
      return {
        healthy: false,
        problem: 'Cannot reach the cloud. Sales are safe on this PC and will send when it returns.',
      }
    }
    // Nothing has ever reached the cloud, so there is no backup at all yet —
    // distinct from a backlog that is merely waiting for the next cycle.
    if (lastSuccessAt === null && counts.pending > 0) {
      return { healthy: false, problem: 'Nothing has been backed up to the cloud yet.' }
    }
    return { healthy: true, problem: null }
  }

  private async runCycle(trigger: string): Promise<PushResult | null> {
    if (this.running || this.stopped || !this.enabled) {
      // A write during a cycle must not be lost; catch it on the way out.
      if (this.running) this.pendingSignal = true
      return null
    }

    this.running = true
    this.lastAttemptAt = new Date().toISOString()
    // Before the attempt as well as after: a cycle can take seconds against a
    // dead connection, and a screen showing "checking" beats one that looks
    // frozen until the timeout expires.
    this.broadcast()

    let sql: Sql | null = null
    try {
      sql = await this.connect()
      // Probe first: `postgres` defers connecting until the first query, and
      // pushPending swallows per-table errors. Without this, an unreachable
      // cloud would look like a successful cycle that pushed nothing.
      await sql`SELECT 1`

      const result = await pushPending(this.db, sql, {
        ...(this.options.batchSize !== undefined ? { batchSize: this.options.batchSize } : {}),
      })

      this.lastError = result.errors[0]?.message ?? null

      // Reaching the cloud is not the same as syncing to it. A schema drift
      // rejects every row while the connection itself is perfectly healthy, so
      // counting that as success reported "all synced" while nothing moved —
      // exactly the silent failure this status exists to prevent.
      const wasOffline = this.consecutiveFailures > 0
      const rejected = result.errors.length > 0

      if (rejected) {
        this.consecutiveFailures += 1
        // Same reasoning as an unreachable cloud: come back sooner than the
        // heartbeat, on a growing delay so a permanent fault is not hammered.
        this.scheduleRetry()
      } else {
        this.lastSuccessAt = new Date().toISOString()
        // Recovering from an outage counts as a reconnect: drain the backlog
        // rather than waiting for the next heartbeat.
        this.consecutiveFailures = 0
      }

      if (rejected) {
        this.log.warn(
          { trigger, ...result, errors: result.errors.length, err: this.lastError },
          'sync cycle reached the cloud but rows were rejected',
        )
      } else if (result.pushed > 0 || result.failed > 0) {
        this.log.info(
          { trigger, ...result, errors: result.errors.length },
          'sync cycle complete',
        )
      } else {
        this.log.debug({ trigger }, 'sync cycle - nothing pending')
      }

      if (wasOffline && result.pushed > 0) this.pendingSignal = true
      return result
    } catch (error) {
      // Unreachable cloud, bad credentials, DNS failure. Not billing's problem.
      this.consecutiveFailures += 1
      this.lastError = error instanceof Error ? error.message : String(error)
      this.log.warn(
        { trigger, err: this.lastError, consecutiveFailures: this.consecutiveFailures },
        'sync cycle failed',
      )
      // Try again on a backoff rather than waiting out the heartbeat. Without
      // this a five second outage cost five minutes: nothing rescheduled, so
      // the next attempt was whenever the heartbeat next came round, and the
      // backlog sat there long after the cloud was back.
      this.scheduleRetry()
      return null
    } finally {
      if (sql) await sql.end({ timeout: 5 }).catch(() => undefined)
      this.running = false

      // In `finally`, so a screen is told the outcome whether the cycle
      // succeeded, was rejected, or threw.
      this.broadcast()

      if (this.pendingSignal && !this.stopped) {
        this.pendingSignal = false
        this.signal()
      }
    }
  }

  private async connect(): Promise<Sql> {
    if (this.options.connect) return this.options.connect()

    const { default: postgres } = await import('postgres')
    return postgres(this.env.CLOUD_DATABASE_URL!, {
      max: 1,
      idle_timeout: 10,
      // Short: an unreachable cloud must not hold a cycle open. Billing does
      // not wait on this, but a stuck cycle would delay the next one.
      connect_timeout: 5,
      onnotice: () => undefined,
    })
  }
}

/**
 * The later of two ISO-8601 timestamps, either of which may be absent.
 *
 * Both are UTC, so string comparison is chronological and there is no need to
 * parse into Date objects to find out which came first.
 */
function later(a: string | null, b: string | null): string | null {
  if (a === null) return b
  if (b === null) return a
  return a > b ? a : b
}

/**
 * First retry delay after a failed cycle. Doubles up to [RETRY_MAX_MS].
 *
 * Five seconds because most failures are a blink — a wifi router restarting,
 * a laptop waking. Recovering from those should feel instant rather than
 * leaving someone staring at a red screen wondering if it is stuck.
 */
const RETRY_BASE_MS = 5_000

/** A cloud down for the night must not be dialled every fifteen seconds. */
const RETRY_MAX_MS = 120_000
