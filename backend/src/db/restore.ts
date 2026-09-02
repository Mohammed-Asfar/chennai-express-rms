import type { Db } from './client.js'
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

/**
 * Restores from the cloud on first boot, if there is anything to restore.
 *
 * Runs before `seedIfEmpty`, and the order is the whole point: seeding an empty
 * database creates a branch with a fresh uuid, and once that exists the real
 * branch in the cloud can never be reclaimed — the till would push a second
 * branch alongside its own history.
 *
 * Best-effort by design. No cloud, no network, or a cloud with nothing in it all
 * fall through to normal seeding. A restaurant with no internet on the morning of
 * a reinstall must still be able to open.
 */
export async function restoreIfEmpty(db: Db, env: Env): Promise<RestoreOutcome> {
  if (!isEmptyDatabase(db)) return { attempted: false, restored: false, reason: 'not empty' }
  if (!env.CLOUD_DATABASE_URL) {
    return { attempted: false, restored: false, reason: 'no cloud configured' }
  }

  const { default: postgres } = await import('postgres')
  const sql = postgres(env.CLOUD_DATABASE_URL, {
    max: 1,
    idle_timeout: 20,
    connect_timeout: 10,
  })

  try {
    const branch = await findCloudBranch(sql)
    if (!branch) {
      return { attempted: true, restored: false, reason: 'cloud has no branch' }
    }

    const result = await pullAll(db, sql)

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
    return {
      attempted: true,
      restored: false,
      reason: error instanceof Error ? error.message : String(error),
    }
  } finally {
    await sql.end({ timeout: 5 })
  }
}
