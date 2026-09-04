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

test('a line-ending change is not an edit', () => {
  // git's core.autocrlf rewrites line endings on checkout, so the same
  // migration hashed one way on the machine that ran it and another on the next
  // machine to check it out. The guard then refused to start a till that was
  // perfectly healthy — and it surfaced as a failed release build, not as
  // anything a restaurant could act on.
  const sql = 'CREATE TABLE a (\n  id TEXT PRIMARY KEY,\n  name TEXT\n);\n'
  const dir = tempMigrations({ '0001_a.sql': sql })
  const db = openDatabase(':memory:')
  migrate(db, dir)

  writeFileSync(join(dir, '0001_a.sql'), sql.replace(/\n/g, '\r\n'))
  const again = migrate(db, dir)

  assertEqual(again.length, 0, 'CRLF is the same migration, already applied')
  db.close()
  rmSync(dir, { recursive: true })
})

test('a database that recorded a CRLF checksum still starts', () => {
  // Tills in the field recorded whichever form they happened to see. Pinning
  // the files to LF fixes new installations and would strand those, so the
  // stored hash is accepted under either convention.
  const crlf = 'CREATE TABLE a (\r\n  id TEXT PRIMARY KEY\r\n);\r\n'
  const dir = tempMigrations({ '0001_a.sql': crlf })
  const db = openDatabase(':memory:')
  migrate(db, dir)

  writeFileSync(join(dir, '0001_a.sql'), crlf.replace(/\r\n/g, '\n'))
  const again = migrate(db, dir)

  assertEqual(again.length, 0, 'the LF file matches the CRLF hash on record')
  db.close()
  rmSync(dir, { recursive: true })
})

test('a real edit is still rejected when only line endings are forgiven', () => {
  // The point of normalising is to stop false alarms, not to stop checking.
  const dir = tempMigrations({ '0001_a.sql': 'CREATE TABLE a (id TEXT PRIMARY KEY);\n' })
  const db = openDatabase(':memory:')
  migrate(db, dir)

  writeFileSync(join(dir, '0001_a.sql'), 'CREATE TABLE a (id TEXT PRIMARY KEY, extra TEXT);\r\n')
  assertThrows(() => migrate(db, dir), 'a changed statement still throws')
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
