import type { Sql } from 'postgres'
import type { Db } from '../db/client.js'
import { MAX_SYNC_ATTEMPTS, SYNC_TABLES, backoffMs, type SyncTable } from './tables.js'

export interface PushResult {
  pushed: number
  failed: number
  quarantined: number
  /** Tables that hit an error this run, with the first message seen. */
  errors: { table: string; message: string }[]
}

export interface PushOptions {
  /** Rows per batch. A week offline could accumulate thousands. */
  batchSize?: number
  now?: Date
}

/**
 * Pushes pending rows to the cloud.
 *
 * Never throws: sync failure must be invisible to billing. Everything is
 * reported in the result instead.
 */
export async function pushPending(
  db: Db,
  sql: Sql,
  options: PushOptions = {},
): Promise<PushResult> {
  const batchSize = options.batchSize ?? 200
  const now = options.now ?? new Date()
  const result: PushResult = { pushed: 0, failed: 0, quarantined: 0, errors: [] }

  // Strictly in order: a child arriving before its parent is rejected.
  for (const table of SYNC_TABLES) {
    try {
      const outcome = await pushTable(db, sql, table, batchSize, now)
      result.pushed += outcome.pushed
      result.failed += outcome.failed
      result.quarantined += outcome.quarantined
      if (outcome.error) result.errors.push({ table: table.name, message: outcome.error })
    } catch (error) {
      // A whole-table failure (connection lost mid-run) stops this cycle for
      // this table but must not abandon the tables already pushed.
      result.errors.push({ table: table.name, message: messageOf(error) })
      result.failed += 1
    }
  }

  return result
}

interface TableOutcome {
  pushed: number
  failed: number
  quarantined: number
  error?: string
}

async function pushTable(
  db: Db,
  sql: Sql,
  table: SyncTable,
  batchSize: number,
  now: Date,
): Promise<TableOutcome> {
  const outcome: TableOutcome = { pushed: 0, failed: 0, quarantined: 0 }
  const rows = selectPending(db, table, batchSize, now)
  if (rows.length === 0) return outcome

  try {
    // One statement per batch. A partial batch failure falls back to per-row
    // below, so a single bad row cannot cost the whole batch.
    await upsertBatch(sql, table, rows)
    markSynced(db, table, rows, now)
    outcome.pushed = rows.length
    return outcome
  } catch (batchError) {
    // Isolate the bad row rather than blaming all of them.
    for (const row of rows) {
      try {
        await upsertBatch(sql, table, [row])
        markSynced(db, table, [row], now)
        outcome.pushed += 1
      } catch (rowError) {
        const message = messageOf(rowError)
        outcome.failed += 1
        if (table.tracked) {
          const attempts = recordFailure(db, table, row, message, now)
          if (attempts >= MAX_SYNC_ATTEMPTS) outcome.quarantined += 1
        }
        outcome.error ??= message
      }
    }
    outcome.error ??= messageOf(batchError)
    return outcome
  }
}

type Row = Record<string, unknown>

/**
 * Pending rows, skipping quarantined ones and those still in backoff.
 *
 * Ordered by `updated_at` so a row's own history reaches the cloud in sequence.
 */
function selectPending(db: Db, table: SyncTable, limit: number, now: Date): Row[] {
  const columns = table.columns.join(', ')

  if (!table.tracked) {
    // Link tables have no sync columns; push them whole and rely on the upsert
    // being idempotent. They are tiny.
    return db.prepare(`SELECT ${columns} FROM ${table.name} LIMIT ?`).all(limit) as Row[]
  }

  return db
    .prepare(
      `SELECT ${columns}, sync_attempts, updated_at FROM ${table.name}
       WHERE synced_at IS NULL
         AND sync_attempts < ?
         AND (sync_attempts = 0 OR updated_at <= ?)
       ORDER BY updated_at
       LIMIT ?`,
    )
    .all(MAX_SYNC_ATTEMPTS, backoffCutoff(now), limit) as Row[]
}

/**
 * A row that failed recently should wait. Using the widest backoff as a single
 * cutoff keeps the query simple; a row is retried once it is older than that.
 */
function backoffCutoff(now: Date): string {
  return new Date(now.getTime() - backoffMs(0)).toISOString()
}

/**
 * Columns that are BOOLEAN in Postgres but INTEGER 0/1 in SQLite.
 *
 * Without conversion the driver sends the integer and Postgres coerces it
 * silently to the wrong value — `1` arrives as `false`. That is corruption the
 * cloud reports would show as real data.
 */
const BOOLEAN_COLUMNS = new Set([
  'print_logo',
  'is_active',
  'is_available',
  'must_change_password',
])

async function upsertBatch(sql: Sql, table: SyncTable, rows: Row[]): Promise<void> {
  const columns = table.columns
  const updatable = columns.filter((c) => !table.conflictKeys.includes(c))

  // Built as text with an explicit conflict target: the tagged-template helper
  // does not produce a valid ON CONFLICT clause for a dynamic key list.
  const placeholders = columns.map((_, index) => `$${index + 1}`).join(', ')
  const conflict = table.conflictKeys.join(', ')

  // Idempotent by construction: if the connection dies after Postgres commits
  // but before SQLite records synced_at, the next cycle overwrites this row
  // rather than failing on a duplicate key.
  const action =
    updatable.length === 0
      ? 'DO NOTHING'
      : `DO UPDATE SET ${updatable.map((c) => `${c} = EXCLUDED.${c}`).join(', ')}`

  const text =
    `INSERT INTO ${table.name} (${columns.join(', ')}) VALUES (${placeholders}) ` +
    `ON CONFLICT (${conflict}) ${action}`

  // One statement per row rather than a multi-row VALUES list: the batch is
  // still one round trip per row, but a single malformed row is isolated by the
  // caller's per-row retry instead of costing the whole batch.
  for (const row of rows) {
    await sql.unsafe(text, columns.map((column) => normalise(column, row[column])) as never[])
  }
}

/**
 * Bridges the two dialects.
 *
 * SQLite has no boolean type and no NULL/undefined distinction for a missing
 * column; Postgres rejects `undefined` outright and coerces integers into
 * BOOLEAN columns incorrectly.
 */
function normalise(column: string, value: unknown): unknown {
  if (value === undefined) return null
  if (BOOLEAN_COLUMNS.has(column) && typeof value === 'number') return value === 1
  return value
}

function markSynced(db: Db, table: SyncTable, rows: Row[], now: Date): void {
  if (!table.tracked) return

  const stamp = now.toISOString()
  const update = db.prepare(
    `UPDATE ${table.name} SET synced_at = ?, sync_attempts = 0, sync_error = NULL
     WHERE ${keyClause(table)}`,
  )

  db.transaction(() => {
    for (const row of rows) update.run(stamp, ...table.conflictKeys.map((k) => row[k]))
  })()
}

/** Records a failure and returns the new attempt count. */
function recordFailure(
  db: Db,
  table: SyncTable,
  row: Row,
  message: string,
  _now: Date,
): number {
  db.prepare(
    `UPDATE ${table.name} SET sync_attempts = sync_attempts + 1, sync_error = ?
     WHERE ${keyClause(table)}`,
  ).run(message.slice(0, 500), ...table.conflictKeys.map((k) => row[k]))

  const updated = db
    .prepare(`SELECT sync_attempts FROM ${table.name} WHERE ${keyClause(table)}`)
    .get(...table.conflictKeys.map((k) => row[k])) as { sync_attempts: number } | undefined

  return updated?.sync_attempts ?? 0
}

function keyClause(table: SyncTable): string {
  return table.conflictKeys.map((k) => `${k} = ?`).join(' AND ')
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Counts for the status endpoint. */
/**
 * When a row was most recently stamped as synced.
 *
 * Read from the data rather than remembered in the worker. The worker's own
 * `lastSuccessAt` starts null on every boot, so after a restart the screen said
 * the backup had happened "Never" while the database plainly held bills pushed
 * seconds earlier. The rows are the record; memory is just a cache of it.
 */
export function lastSyncedAt(db: Db): string | null {
  let latest: string | null = null

  for (const table of SYNC_TABLES) {
    if (!table.tracked) continue
    const row = db
      .prepare(`SELECT MAX(synced_at) AS at FROM ${table.name}`)
      .get() as { at: string | null }

    // ISO-8601 UTC throughout, so string comparison is chronological.
    if (row.at !== null && (latest === null || row.at > latest)) latest = row.at
  }
  return latest
}

export function syncCounts(db: Db): { pending: number; quarantined: number } {
  let pending = 0
  let quarantined = 0

  for (const table of SYNC_TABLES) {
    if (!table.tracked) continue
    const row = db
      .prepare(
        `SELECT
           SUM(CASE WHEN synced_at IS NULL AND sync_attempts <  ? THEN 1 ELSE 0 END) AS pending,
           SUM(CASE WHEN synced_at IS NULL AND sync_attempts >= ? THEN 1 ELSE 0 END) AS quarantined
         FROM ${table.name}`,
      )
      .get(MAX_SYNC_ATTEMPTS, MAX_SYNC_ATTEMPTS) as {
      pending: number | null
      quarantined: number | null
    }
    pending += row.pending ?? 0
    quarantined += row.quarantined ?? 0
  }

  return { pending, quarantined }
}

/**
 * Re-pushes the master rows every business row points at.
 *
 * A row stamped `synced_at` is never looked at again, so if the cloud copy is
 * missing — restored from an older backup, wiped, or never actually committed —
 * the branch has no way to notice. Every child then fails its foreign key
 * forever while the parent sits marked as done.
 *
 * That is not hypothetical: a live branch had its admin user stamped synced but
 * absent from the cloud, and every order, bill and payment referencing it was
 * rejected until the stamp was cleared by hand.
 *
 * Only the small master tables. The pushes are idempotent upserts, so this
 * costs a few dozen rows and repairs the parents the rest depend on. Business
 * rows are deliberately excluded: re-pushing thousands of bills to fix a
 * missing user would be a self-inflicted outage.
 */
export function resyncMasterData(db: Db): number {
  const MASTER = ['branches', 'users', 'sections', 'tables', 'categories']
  let reset = 0

  for (const table of SYNC_TABLES) {
    if (!table.tracked || !MASTER.includes(table.name)) continue
    const info = db
      .prepare(
        `UPDATE ${table.name} SET synced_at = NULL, sync_attempts = 0, sync_error = NULL
         WHERE deleted_at IS NULL`,
      )
      .run()
    reset += info.changes
  }
  return reset
}

/** Clears quarantine so the next cycle retries. */
export function retryQuarantined(db: Db): number {
  let reset = 0
  for (const table of SYNC_TABLES) {
    if (!table.tracked) continue
    const info = db
      .prepare(
        `UPDATE ${table.name} SET sync_attempts = 0, sync_error = NULL
         WHERE synced_at IS NULL AND sync_attempts >= ?`,
      )
      .run(MAX_SYNC_ATTEMPTS)
    reset += info.changes
  }
  return reset
}
