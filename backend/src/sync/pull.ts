import type { Sql } from 'postgres'
import type { Db } from '../db/client.js'
import { SYNC_TABLES, type SyncTable } from './tables.js'

/**
 * Restores a lost local database from the cloud.
 *
 * This is the other half of `push.ts`, and it runs in exactly one situation: the
 * SQLite file is gone or empty and the cloud still holds this branch. A hard disk
 * fails, someone reinstalls Windows, an antivirus quarantines the data directory
 * — without this the till starts over with a new branch id and every past bill is
 * orphaned in Postgres.
 *
 * It is deliberately not a general-purpose two-way sync. Pulling into a database
 * that already has rows would have to reconcile edits made on both sides, and
 * there is no correct answer to "the same bill was changed in two places" for a
 * financial record. So it refuses to run unless the local database is empty.
 */

export interface PullResult {
  restored: number
  /** Per-table row counts, in the order they were written. */
  tables: { table: string; rows: number }[]
  errors: { table: string; message: string }[]
}

export interface CloudBranch {
  id: string
  name: string
  billCount: number
  lastBillAt: string | null
}

export interface PullOptions {
  /** Rows per round trip. Keeps memory flat on a few years of bills. */
  batchSize?: number
  now?: Date
  /** Reports progress so a long restore can show something other than a spinner. */
  onProgress?: (table: string, done: number, total: number) => void
}

/**
 * True when this database has never been used.
 *
 * Checked against `branches` because `seedIfEmpty` uses the same test: if a branch
 * exists the till is already in service, and a restore would be a data-losing
 * mistake rather than a recovery.
 */
export function isEmptyDatabase(db: Db): boolean {
  const row = db.prepare('SELECT id FROM branches LIMIT 1').get() as { id: string } | undefined
  return row === undefined
}

/**
 * Looks for a branch in the cloud worth restoring.
 *
 * Returns the oldest branch, not the newest: repeated test installs against one
 * cloud database leave several, and the first one created is the real branch.
 * Returns null when the cloud is empty, which is a genuine first install.
 */
export async function findCloudBranch(sql: Sql): Promise<CloudBranch | null> {
  const rows = await sql<{ id: string; name: string; created_at: Date }[]>`
    SELECT id, name, created_at
    FROM branches
    WHERE deleted_at IS NULL
    ORDER BY created_at ASC
    LIMIT 1
  `

  const branch = rows[0]
  if (!branch) return null

  // Shown to staff before anything is written, so the count has to be real.
  const stats = await sql<{ count: string; last_at: Date | null }[]>`
    SELECT COUNT(*) AS count, MAX(created_at) AS last_at
    FROM bills
    WHERE branch_id = ${branch.id} AND deleted_at IS NULL
  `

  return {
    id: branch.id,
    name: branch.name,
    billCount: Number(stats[0]?.count ?? 0),
    lastBillAt: stats[0]?.last_at?.toISOString() ?? null,
  }
}

/**
 * Copies every synced table down from the cloud.
 *
 * Table order is the same foreign-key constraint push obeys, for the same reason:
 * a child inserted before its parent is rejected. `SYNC_TABLES` is already sorted
 * parents-first, so it is walked forwards.
 *
 * Throws if the local database is not empty. Callers must check first.
 */
export async function pullAll(
  db: Db,
  sql: Sql,
  options: PullOptions = {},
): Promise<PullResult> {
  if (!isEmptyDatabase(db)) {
    throw new Error('Refusing to restore over a database that already has data')
  }

  const batchSize = options.batchSize ?? 500
  // Restored rows are already in the cloud, so they are stamped as synced. Without
  // this the first cycle would push the entire history straight back up — thousands
  // of pointless upserts, and every row's `updated_at` churned in Postgres.
  const syncedAt = (options.now ?? new Date()).toISOString()

  const result: PullResult = { restored: 0, tables: [], errors: [] }

  // Foreign keys are enforced per-statement in SQLite, and a parent row can be
  // legitimately absent mid-restore (an order referencing a table row not yet
  // written). They are re-enabled and verified below.
  db.pragma('foreign_keys = OFF')

  try {
    for (const table of SYNC_TABLES) {
      try {
        const rows = await pullTable(db, sql, table, batchSize, syncedAt, options.onProgress)
        result.restored += rows
        result.tables.push({ table: table.name, rows })
      } catch (error) {
        // Record and continue: a partial restore that recovers the menu and most
        // bills beats an all-or-nothing failure that leaves the till empty.
        result.errors.push({ table: table.name, message: messageOf(error) })
      }
    }
  } finally {
    db.pragma('foreign_keys = ON')
  }

  // A dangling reference means the restore produced a database the app cannot
  // trust. Better to surface it than to discover it at billing time.
  const violations = db.pragma('foreign_key_check') as unknown[]
  if (violations.length > 0) {
    result.errors.push({
      table: 'foreign_key_check',
      message: `${violations.length} foreign key violations after restore`,
    })
  }

  return result
}

async function pullTable(
  db: Db,
  sql: Sql,
  table: SyncTable,
  batchSize: number,
  syncedAt: string,
  onProgress?: (table: string, done: number, total: number) => void,
): Promise<number> {
  const countRows = await sql<{ count: string }[]>`
    SELECT COUNT(*) AS count FROM ${sql(table.name)}
  `
  const total = Number(countRows[0]?.count ?? 0)
  if (total === 0) return 0

  // Tracked tables carry sync bookkeeping that is local-only — the cloud has no
  // opinion on it, so it is set rather than copied.
  const columns = table.tracked
    ? [...table.columns, 'synced_at', 'sync_attempts', 'sync_error']
    : [...table.columns]

  const placeholders = columns.map(() => '?').join(', ')
  const insert = db.prepare(
    `INSERT OR REPLACE INTO ${table.name} (${columns.join(', ')}) VALUES (${placeholders})`,
  )

  // Ordered by primary key so paging is stable: without ORDER BY, Postgres may
  // return a row twice across two OFFSET queries and miss another entirely.
  const orderBy = table.conflictKeys.join(', ')
  let done = 0

  while (done < total) {
    const batch = await sql<Record<string, unknown>[]>`
      SELECT ${sql(table.columns)}
      FROM ${sql(table.name)}
      ORDER BY ${sql.unsafe(orderBy)}
      LIMIT ${batchSize} OFFSET ${done}
    `
    if (batch.length === 0) break

    db.transaction(() => {
      for (const row of batch) {
        const values = table.columns.map((column) => toSqlite(row[column]))
        if (table.tracked) {
          // Already in the cloud: stamped synced, no attempts, no error.
          values.push(syncedAt, 0, null)
        }
        insert.run(values)
      }
    })()

    done += batch.length
    onProgress?.(table.name, done, total)
  }

  return done
}

/**
 * Converts a Postgres value to what SQLite can bind.
 *
 * The mirror of the boolean conversion push performs. Postgres hands back real
 * booleans for `is_active`, `print_logo` and friends, and better-sqlite3 rejects
 * them outright rather than coercing — so `true` must become `1` here or the
 * restore fails on the first branch row.
 */
function toSqlite(value: unknown): string | number | Buffer | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'boolean') return value ? 1 : 0
  // TIMESTAMPTZ comes back as a Date; SQLite stores UTC ISO-8601 text.
  if (value instanceof Date) return value.toISOString()
  if (Buffer.isBuffer(value)) return value
  if (typeof value === 'number' || typeof value === 'string') return value
  // json/jsonb columns (bills.tax_breakdown) arrive parsed.
  return JSON.stringify(value)
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
