import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import type { Sql } from 'postgres'
import { resolveMigrationsDir, contentChecksum, checksumMatches } from './migrate.js'

const MIGRATIONS_DIR = resolveMigrationsDir('postgres')

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
      // Line endings normalised, same as the SQLite runner: git rewrites them
      // on checkout, and a migration's identity is its SQL rather than the
      // bytes one machine happened to receive.
      return { version, name, sql, checksum: contentChecksum(sql) }
    })
}

/**
 * Applies pending Postgres migrations to the cloud database.
 *
 * Mirrors the SQLite runner: append-only, checksum-verified, one transaction per
 * migration. A migration edited after it was applied is a hard error — that is
 * what makes append-only enforceable rather than a convention.
 */
export async function migrateCloud(sql: Sql, dir = MIGRATIONS_DIR): Promise<string[]> {
  await sql.unsafe(`
    CREATE TABLE IF NOT EXISTS _migrations (
      version    TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      checksum   TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL
    )
  `)

  const files = loadMigrationFiles(dir)
  const rows = (await sql`SELECT version, checksum FROM _migrations`) as unknown as {
    version: string
    checksum: string
  }[]
  const applied = new Map(rows.map((r) => [r.version, r.checksum]))

  for (const file of files) {
    const previous = applied.get(file.version)
    if (previous !== undefined && !checksumMatches(previous, file.sql)) {
      throw new Error(
        `Migration ${file.name} has changed since it was applied to the cloud.\n` +
          `Migrations are append-only — fix forward with a new migration instead.`,
      )
    }
  }

  const pending = files.filter((f) => !applied.has(f.version))

  for (const file of pending) {
    // A failed migration must leave no partial state.
    await sql.begin(async (tx) => {
      await tx.unsafe(file.sql)
      await tx`
        INSERT INTO _migrations (version, name, checksum, applied_at)
        VALUES (${file.version}, ${file.name}, ${file.checksum}, NOW())
      `
    })
  }

  return pending.map((f) => f.name)
}

export async function cloudMigrationStatus(
  sql: Sql,
  dir = MIGRATIONS_DIR,
): Promise<{ version: string; name: string; applied: boolean }[]> {
  await sql.unsafe(`
    CREATE TABLE IF NOT EXISTS _migrations (
      version    TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      checksum   TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL
    )
  `)

  const rows = (await sql`SELECT version FROM _migrations`) as unknown as { version: string }[]
  const applied = new Set(rows.map((r) => r.version))

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
  const { default: postgres } = await import('postgres')

  const env = loadEnv()
  if (!env.CLOUD_DATABASE_URL) {
    console.error('CLOUD_DATABASE_URL is not set — nothing to migrate.')
    process.exit(1)
  }

  const sql = postgres(env.CLOUD_DATABASE_URL, { max: 1, connect_timeout: 10 })
  try {
    if (process.argv.includes('--status')) {
      for (const m of await cloudMigrationStatus(sql)) {
        console.log(`${m.applied ? '✓' : ' '} ${m.name}`)
      }
    } else {
      const ran = await migrateCloud(sql)
      console.log(
        ran.length === 0
          ? 'No pending cloud migrations.'
          : `Applied to cloud:\n${ran.map((n) => `  ${n}`).join('\n')}`,
      )
    }
  } finally {
    await sql.end({ timeout: 5 })
  }
}
