import Database from 'better-sqlite3'
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../db/migrations/sqlite')

export interface AppliedMigration {
  version: string
  applied_at: string
  checksum: string
}

interface MigrationFile {
  version: string
  name: string
  sql: string
  checksum: string
}

function loadMigrationFiles(dir = MIGRATIONS_DIR): MigrationFile[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((name) => {
      const sql = readFileSync(join(dir, name), 'utf8')
      const version = name.split('_')[0]
      if (!version) throw new Error(`Migration filename must start with a version: ${name}`)
      return { version, name, sql, checksum: sha256(sql) }
    })
}

function sha256(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex')
}

export function ensureMigrationsTable(db: Database.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS _migrations (
      version    TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      checksum   TEXT NOT NULL,
      applied_at TEXT NOT NULL
    )
  `)
}

/**
 * Applies pending migrations.
 *
 * A migration already applied whose file has since changed is a hard error, not a
 * warning — that is what makes "append-only" enforceable rather than a convention.
 */
export function migrate(db: Database.Database, dir = MIGRATIONS_DIR): string[] {
  ensureMigrationsTable(db)

  const files = loadMigrationFiles(dir)
  const applied = new Map(
    db.prepare('SELECT version, checksum FROM _migrations').all().map((r) => {
      const row = r as { version: string; checksum: string }
      return [row.version, row.checksum]
    }),
  )

  for (const file of files) {
    const previous = applied.get(file.version)
    if (previous !== undefined && previous !== file.checksum) {
      throw new Error(
        `Migration ${file.name} has changed since it was applied.\n` +
          `Migrations are append-only — fix forward with a new migration instead.\n` +
          `  expected checksum: ${previous}\n` +
          `  file checksum:     ${file.checksum}`,
      )
    }
  }

  const pending = files.filter((f) => !applied.has(f.version))
  const record = db.prepare(
    'INSERT INTO _migrations (version, name, checksum, applied_at) VALUES (?, ?, ?, ?)',
  )

  for (const file of pending) {
    // Each migration runs in its own transaction: a failure leaves no partial state.
    db.transaction(() => {
      db.exec(file.sql)
      record.run(file.version, file.name, file.checksum, new Date().toISOString())
    })()
  }

  return pending.map((f) => f.name)
}

export function migrationStatus(
  db: Database.Database,
  dir = MIGRATIONS_DIR,
): { version: string; name: string; applied: boolean }[] {
  ensureMigrationsTable(db)
  const applied = new Set(
    db.prepare('SELECT version FROM _migrations').all().map((r) => (r as { version: string }).version),
  )
  return loadMigrationFiles(dir).map((f) => ({
    version: f.version,
    name: f.name,
    applied: applied.has(f.version),
  }))
}

// CLI entry point
const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href

if (invokedDirectly) {
  const { loadEnv } = await import('../lib/env.js')
  const { openDatabase } = await import('./client.js')
  const env = loadEnv()
  const db = openDatabase(env.DB_PATH)

  if (process.argv.includes('--status')) {
    for (const m of migrationStatus(db)) {
      console.log(`${m.applied ? '✓' : ' '} ${m.name}`)
    }
  } else {
    const ran = migrate(db)
    console.log(ran.length === 0 ? 'No pending migrations.' : `Applied:\n${ran.map((n) => `  ${n}`).join('\n')}`)
  }
  db.close()
}
