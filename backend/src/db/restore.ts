import { existsSync, renameSync, rmSync, statSync } from 'node:fs'
import { openDatabase, type Db } from './client.js'
import { migrate } from './migrate.js'
import type { Env } from '../lib/env.js'
import { findCloudBranch, isEmptyDatabase, pullAll, type PullResult } from '../sync/pull.js'

export interface RestoreOutcome {
  attempted: boolean
  restored: boolean
  branchName?: string
  billCount?: number
  result?: PullResult
  /** Why nothing was restored. Absent on success. */
  reason?: string
}

/** Suffix for the database being built. Never opened by the app. */
const STAGING_SUFFIX = '.restoring'

/**
 * Restores from the cloud on first boot, if there is anything to restore.
 *
 * Runs before the main database handle is opened, and before seeding. Seeding an
 * empty database mints a branch with a fresh uuid, and once that exists the real
 * branch in the cloud can never be reclaimed — the till would push a second
 * branch alongside its own history, orphaning every past bill.
 *
 * **Atomic.** Rows are pulled into a staging file, which replaces the live
 * database only once the pull has finished. A restore killed halfway — a crash, a
 * power cut, Ctrl-C, a dev-mode watch restart — leaves the live path untouched, so
 * the next boot sees an empty database and tries again.
 *
 * Without this the interrupted case is unrecoverable: a half-written database has
 * a `branches` row, so `isEmptyDatabase` is false, so restore refuses to run and
 * seeding also skips. The till comes up permanently missing most of its history
 * with nothing to indicate why.
 *
 * Best-effort otherwise. No cloud, no network, or a cloud with nothing in it all
 * fall through to normal seeding. A restaurant with no internet on the morning of
 * a reinstall must still be able to open.
 */
export async function restoreIfEmpty(env: Env): Promise<RestoreOutcome> {
  // `:memory:` has no file to stage or swap, and nothing to lose on a crash.
  if (env.DB_PATH === ':memory:') {
    return { attempted: false, restored: false, reason: 'in-memory database' }
  }

  if (!isEmptyPath(env.DB_PATH)) {
    return { attempted: false, restored: false, reason: 'not empty' }
  }
  if (!env.CLOUD_DATABASE_URL) {
    return { attempted: false, restored: false, reason: 'no cloud configured' }
  }

  const staging = env.DB_PATH + STAGING_SUFFIX
  // A staging file left by an interrupted attempt is rubbish, not a resume point:
  // it may hold half a table with no record of how far it got.
  discard(staging)

  const { default: postgres } = await import('postgres')
  const sql = postgres(env.CLOUD_DATABASE_URL, {
    max: 1,
    idle_timeout: 20,
    connect_timeout: 10,
  })

  let staged: Db | null = null

  try {
    const branch = await findCloudBranch(sql)
    if (!branch) {
      return { attempted: true, restored: false, reason: 'cloud has no branch' }
    }

    staged = openDatabase(staging)
    migrate(staged)

    const result = await pullAll(staged, sql)

    // A restore that produced a broken database must not replace anything. Better
    // to seed a clean till than to swap in something that fails at billing time.
    if (result.errors.length > 0) {
      staged.close()
      staged = null
      discard(staging)
      return {
        attempted: true,
        restored: false,
        reason: `restore incomplete: ${result.errors.map((e) => `${e.table}: ${e.message}`).join('; ')}`,
      }
    }

    // Checkpoint and close before renaming: WAL content still sitting in the
    // sidecar would be lost, and the swapped-in file would be missing rows.
    staged.pragma('wal_checkpoint(TRUNCATE)')
    staged.close()
    staged = null

    swapIntoPlace(staging, env.DB_PATH)

    return {
      attempted: true,
      restored: true,
      branchName: branch.name,
      billCount: branch.billCount,
      result,
    }
  } catch (error) {
    // Startup must not die because the cloud was unreachable. Seeding takes over,
    // and the operator sees the warning in the log.
    if (staged) {
      try {
        staged.close()
      } catch {
        // Already closed or never opened cleanly; the discard below is what matters.
      }
    }
    discard(staging)
    return {
      attempted: true,
      restored: false,
      reason: error instanceof Error ? error.message : String(error),
    }
  } finally {
    await sql.end({ timeout: 5 })
  }
}

/**
 * True when there is no usable database at this path.
 *
 * Checked without opening the live file, so a restore decision costs nothing on
 * every normal boot. A zero-byte file counts as absent: that is what an
 * interrupted create leaves behind.
 */
function isEmptyPath(path: string): boolean {
  if (!existsSync(path)) return true
  if (statSync(path).size === 0) return true

  const db = openDatabase(path)
  try {
    // Migrations may never have run here, in which case there is no branches
    // table to read and the database is empty by definition.
    const table = db
      .prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'branches'`)
      .get()
    if (!table) return true
    return isEmptyDatabase(db)
  } finally {
    db.close()
  }
}

/** Moves the staged database over the live path, sidecars included. */
function swapIntoPlace(staging: string, live: string): void {
  // The live file is absent or empty here — isEmptyPath said so — but its WAL and
  // shm sidecars may exist and would be read against the new file if left behind.
  for (const suffix of ['-wal', '-shm']) {
    rmSync(live + suffix, { force: true })
  }
  rmSync(live, { force: true })

  // Same directory, so this is a rename within one filesystem: atomic, not a copy.
  renameSync(staging, live)

  // The staged database was checkpointed and closed, so these hold nothing worth
  // keeping. Removing them stops SQLite reading a stale sidecar against the file.
  for (const suffix of ['-wal', '-shm']) {
    rmSync(staging + suffix, { force: true })
  }
}

/** Removes a staging database and its sidecars. Never throws. */
function discard(staging: string): void {
  for (const suffix of ['', '-wal', '-shm']) {
    rmSync(staging + suffix, { force: true })
  }
}
