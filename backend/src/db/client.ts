import Database from 'better-sqlite3'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

export type Db = Database.Database

/**
 * Opens the local SQLite database with the pragmas this system depends on.
 *
 * `:memory:` is supported for tests.
 */
export function openDatabase(path: string): Db {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })

  const db = new Database(path)

  // WAL: a power cut mid-service must not lose the last committed bill.
  db.pragma('journal_mode = WAL')
  // FULL would be safest but costs an fsync per write; NORMAL under WAL survives
  // application crashes, losing at most the last transaction on OS-level failure.
  db.pragma('synchronous = NORMAL')
  db.pragma('foreign_keys = ON')
  // Capped for the 4GB target machine — 8MB is ample for this working set.
  db.pragma('cache_size = -8000')
  db.pragma('busy_timeout = 5000')

  return db
}
