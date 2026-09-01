import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { openDatabase } from '../src/db/client.js'
import { migrate, migrationStatus } from '../src/db/migrate.js'
import { test, assertEqual, assertThrows } from './helpers.js'

function tempMigrations(files: Record<string, string>): string {
  const dir = mkdtempSync(join(tmpdir(), 'ce-migrations-'))
  for (const [name, sql] of Object.entries(files)) writeFileSync(join(dir, name), sql)
  return dir
}

test('applies pending migrations in order', () => {
  const dir = tempMigrations({
    '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);',
    '0002_b.sql': 'CREATE TABLE b (id TEXT PRIMARY KEY REFERENCES a(id));',
  })
  const db = openDatabase(':memory:')
  const applied = migrate(db, dir)
  assertEqual(applied.length, 2)
  assertEqual(applied[0], '0001_a.sql')
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('a','b')")
    .all()
  assertEqual(tables.length, 2)
  db.close()
  rmSync(dir, { recursive: true })
})

test('is idempotent - running twice applies nothing the second time', () => {
  const dir = tempMigrations({ '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);' })
  const db = openDatabase(':memory:')
  assertEqual(migrate(db, dir).length, 1)
  assertEqual(migrate(db, dir).length, 0)
  db.close()
  rmSync(dir, { recursive: true })
})

test('rejects a migration edited after it was applied', () => {
  // This is what makes append-only enforceable rather than a convention.
  const dir = tempMigrations({ '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);' })
  const db = openDatabase(':memory:')
  migrate(db, dir)
  writeFileSync(join(dir, '0001_a.sql'), 'CREATE TABLE a (id TEXT PRIMARY KEY, extra TEXT);')
  assertThrows(() => migrate(db, dir), 'expected a checksum mismatch to throw')
  db.close()
  rmSync(dir, { recursive: true })
})

test('a failed migration leaves no partial state', () => {
  const dir = tempMigrations({
    '0001_ok.sql': 'CREATE TABLE ok (id TEXT PRIMARY KEY);',
    '0002_bad.sql': 'CREATE TABLE good (id TEXT PRIMARY KEY); THIS IS NOT SQL;',
  })
  const db = openDatabase(':memory:')
  assertThrows(() => migrate(db, dir))
  const good = db.prepare("SELECT name FROM sqlite_master WHERE name='good'").all()
  assertEqual(good.length, 0, 'the partial migration should have rolled back')
  const recorded = db.prepare('SELECT COUNT(*) AS n FROM _migrations').get() as { n: number }
  assertEqual(recorded.n, 1, 'only the successful migration should be recorded')
  db.close()
  rmSync(dir, { recursive: true })
})

test('status reports applied and pending', () => {
  const both = tempMigrations({
    '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);',
    '0002_b.sql': 'CREATE TABLE b (id TEXT PRIMARY KEY);',
  })
  const firstOnly = tempMigrations({ '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);' })
  const db = openDatabase(':memory:')
  migrate(db, firstOnly)
  const status = migrationStatus(db, both)
  assertEqual(status.length, 2)
  assertEqual(status[0]!.applied, true)
  assertEqual(status[1]!.applied, false)
  db.close()
  rmSync(both, { recursive: true })
  rmSync(firstOnly, { recursive: true })
})
