import type { Sql } from 'postgres'
import type { Db } from '../db/client.js'
import type { Env } from '../lib/env.js'
import { pushPending, syncCounts, type PushResult } from './push.js'

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
  private running = false
  /** Set when a write lands mid-cycle, so its rows are not missed. */
  private pendingSignal = false
  private stopped = false

  private lastSuccessAt: string | null = null
  private lastAttemptAt: string | null = null
  private lastError: string | null = null
  private consecutiveFailures = 0

  constructor(
    private readonly db: Db,
    private readonly env: Env,
    private readonly log: Logger,
    private readonly options: {
      debounceMs?: number
      heartbeatMs?: number
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

    // Whatever was pending when the process last stopped.
    void this.runCycle('startup')

    const heartbeat = this.options.heartbeatMs ?? 5 * 60_000
    this.heartbeatTimer = setInterval(() => {
      void this.runCycle('heartbeat')
    }, heartbeat)
    this.heartbeatTimer.unref?.()
  }

  stop(): void {
    this.stopped = true
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer)
    this.debounceTimer = null
    this.heartbeatTimer = null
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
    this.debounceTimer.unref?.()
  }

  /** Forces a cycle now, for the manual retry action. */
  async syncNow(): Promise<PushResult | null> {
    if (!this.enabled) return null
    return this.runCycle('manual')
  }

  status(): SyncStatus {
    const counts = this.enabled
      ? syncCounts(this.db)
      : { pending: 0, quarantined: 0 }

    return {
      enabled: this.enabled,
      running: this.running,
      lastSuccessAt: this.lastSuccessAt,
      lastAttemptAt: this.lastAttemptAt,
      lastError: this.lastError,
      ...counts,
      consecutiveFailures: this.consecutiveFailures,
    }
  }

  private async runCycle(trigger: string): Promise<PushResult | null> {
    if (this.running || this.stopped || !this.enabled) {
      // A write during a cycle must not be lost; catch it on the way out.
      if (this.running) this.pendingSignal = true
      return null
    }

    this.running = true
    this.lastAttemptAt = new Date().toISOString()

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

      this.lastSuccessAt = new Date().toISOString()
      this.lastError = result.errors[0]?.message ?? null

      // Recovering from an outage counts as a reconnect: drain the backlog
      // rather than waiting for the next heartbeat.
      const wasOffline = this.consecutiveFailures > 0
      this.consecutiveFailures = 0

      if (result.pushed > 0 || result.failed > 0) {
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
      return null
    } finally {
      if (sql) await sql.end({ timeout: 5 }).catch(() => undefined)
      this.running = false

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
