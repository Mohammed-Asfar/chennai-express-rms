import { randomUUID } from 'node:crypto'
import type { Sql } from 'postgres'
import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { pushPending, syncCounts, retryQuarantined } from '../src/sync/push.js'
import { SYNC_TABLES, NEVER_SYNCED, MAX_SYNC_ATTEMPTS, backoffMs } from '../src/sync/tables.js'
import { SyncWorker } from '../src/sync/worker.js'
import { test, serialTest, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

/** Cloud tests need a reachable Postgres; they are skipped without one. */
const CLOUD_URL = process.env.CLOUD_DATABASE_URL
const silentLog = { info: () => {}, warn: () => {}, debug: () => {} }

// --- registry rules, no database needed ---

test('push order places every child after its parents', () => {
  // Order is a foreign-key constraint, not a preference.
  const position = new Map(SYNC_TABLES.map((t, i) => [t.name, i]))
  const parents: Record<string, string[]> = {
    users: ['branches'],
    sections: ['branches'],
    tables: ['branches', 'sections'],
    categories: ['branches'],
    menu_items: ['branches', 'categories'],
    menu_item_variants: ['menu_items'],
    reservations: ['branches', 'users'],
    reservation_tables: ['reservations', 'tables'],
    orders: ['branches', 'users', 'tables'],
    order_items: ['orders', 'menu_item_variants'],
    bills: ['branches', 'orders', 'users'],
    payments: ['branches', 'bills', 'users'],
    settings: ['branches'],
  }

  for (const [child, required] of Object.entries(parents)) {
    const childAt = position.get(child)
    if (childAt === undefined) throw new Error(`${child} is missing from SYNC_TABLES`)
    for (const parent of required) {
      const parentAt = position.get(parent)
      if (parentAt === undefined) throw new Error(`${parent} is missing from SYNC_TABLES`)
      if (parentAt > childAt) {
        throw new Error(`${child} is pushed before its parent ${parent}`)
      }
    }
  }
})

test('branch-local and cloud-only tables never sync', () => {
  const synced = new Set(SYNC_TABLES.map((t) => t.name))
  for (const name of NEVER_SYNCED) {
    if (synced.has(name)) throw new Error(`${name} must not be in SYNC_TABLES`)
  }
})

test('backoff grows and then caps', () => {
  assertEqual(backoffMs(0), 30_000)
  assertEqual(backoffMs(1), 60_000)
  assertEqual(backoffMs(2), 120_000)
  assertEqual(backoffMs(3), 240_000)
  assertEqual(backoffMs(4), 480_000)
  // A restaurant offline for a day must not hammer a dead connection.
  assertEqual(backoffMs(9), backoffMs(4), 'capped')
})

// --- worker behaviour without a cloud ---

test('the worker is disabled when no cloud is configured', () => {
  const db = openDatabase(':memory:')
  migrate(db)
  const worker = new SyncWorker(db, env, silentLog)

  assertEqual(worker.enabled, false)
  assertEqual(worker.status().enabled, false)
  // A signal on a disabled worker must be a harmless no-op.
  worker.signal()
  worker.stop()
  db.close()
})

test('a write marks its row unsynced', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const row = db.prepare('SELECT synced_at, sync_attempts FROM branches LIMIT 1').get() as {
    synced_at: string | null
    sync_attempts: number
  }
  assertEqual(row.synced_at, null, 'a new row is pending')
  assertEqual(row.sync_attempts, 0)
  db.close()
})

test('counts separate pending from quarantined', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const before = syncCounts(db)
  if (before.pending === 0) throw new Error('seeded rows should be pending')
  assertEqual(before.quarantined, 0)

  db.prepare('UPDATE branches SET sync_attempts = ?').run(MAX_SYNC_ATTEMPTS)
  const after = syncCounts(db)
  assertEqual(after.quarantined, 1, 'a row past the limit is quarantined, not pending')
  assertEqual(after.pending, before.pending - 1)
  db.close()
})

test('retry clears quarantine', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  db.prepare('UPDATE branches SET sync_attempts = ?, sync_error = ?').run(
    MAX_SYNC_ATTEMPTS,
    'boom',
  )
  assertEqual(syncCounts(db).quarantined, 1)

  const reset = retryQuarantined(db)
  assertEqual(reset, 1)
  assertEqual(syncCounts(db).quarantined, 0)
  db.close()
})

test('an unreachable cloud never throws into billing', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const offline = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })
  // Injected rather than dialling a dead port: how long a real TCP attempt takes
  // is the operating system's business, not this test's.
  const worker = new SyncWorker(db, offline, silentLog, {
    batchSize: 10,
    connect: () => Promise.reject(new Error('ECONNREFUSED 127.0.0.1:1')),
  })

  // Must resolve, not reject.
  const result = await worker.syncNow()
  assertEqual(result, null, 'a failed cycle reports null rather than throwing')

  const status = worker.status()
  assertEqual(status.enabled, true)
  if (status.consecutiveFailures < 1) throw new Error('the failure was not recorded')
  if (status.lastError === null) throw new Error('no error was recorded for the UI')

  worker.stop()
  db.close()
})

test('sync status is visible through the API', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app: FastifyInstance = await buildServer({ db, env })

  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const auth = { authorization: `Bearer ${(login.json() as { token: string }).token}` }

  const res = await app.inject({ method: 'GET', url: '/sync/status', headers: auth })
  assertEqual(res.statusCode, 200)
  const body = res.json() as { enabled: boolean; pending: number; quarantined: number }
  assertEqual(body.enabled, false, 'no cloud configured in this test env')
  assertEqual(body.quarantined, 0)

  await app.close()
  db.close()
})

test('sync status requires authentication', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app: FastifyInstance = await buildServer({ db, env })

  assertEqual((await app.inject({ method: 'GET', url: '/sync/status' })).statusCode, 401)

  await app.close()
  db.close()
})

// --- against a real Postgres ---

if (CLOUD_URL) {
  serialTest('rows push to the cloud and are stamped', async () => {
    const { db, sql, branchId } = await cloudFixture()
    try {
      const result = await pushPending(db, sql)
      assertEqual(result.failed, 0, `errors: ${JSON.stringify(result.errors)}`)
      if (result.pushed === 0) throw new Error('nothing was pushed')

      const cloudBranch = (await sql`SELECT name FROM branches WHERE id = ${branchId}`) as unknown as
        { name: string }[]
      assertEqual(cloudBranch.length, 1, 'the branch reached the cloud')

      const local = db.prepare('SELECT synced_at FROM branches WHERE id = ?').get(branchId) as {
        synced_at: string | null
      }
      if (local.synced_at === null) throw new Error('synced_at was not stamped')

      // Tracked tables have nothing left to do. `settings` is untracked (composite
      // key, no synced_at) so it re-pushes every cycle — harmless, because the
      // upsert is idempotent.
      const second = await pushPending(db, sql)
      assertEqual(second.failed, 0)

      const stillPending = db
        .prepare('SELECT COUNT(*) AS n FROM branches WHERE synced_at IS NULL')
        .get() as { n: number }
      assertEqual(stillPending.n, 0, 'tracked rows are not re-pushed')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('pushing the same row twice does not duplicate it', async () => {
    // The connection can die after Postgres commits but before SQLite records
    // synced_at; the next cycle must overwrite rather than fail.
    const { db, sql, branchId } = await cloudFixture()
    try {
      await pushPending(db, sql)

      db.prepare('UPDATE branches SET synced_at = NULL WHERE id = ?').run(branchId)
      const second = await pushPending(db, sql)
      assertEqual(second.failed, 0, `errors: ${JSON.stringify(second.errors)}`)

      const rows = (await sql`SELECT COUNT(*)::int AS n FROM branches WHERE id = ${branchId}`) as
        unknown as { n: number }[]
      assertEqual(rows[0]!.n, 1, 'the upsert overwrote instead of duplicating')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('an edit re-syncs and overwrites the cloud copy', async () => {
    const { db, sql, branchId } = await cloudFixture()
    try {
      await pushPending(db, sql)

      db.prepare('UPDATE branches SET name = ?, synced_at = NULL WHERE id = ?').run(
        'Renamed Branch',
        branchId,
      )
      await pushPending(db, sql)

      const rows = (await sql`SELECT name FROM branches WHERE id = ${branchId}`) as unknown as
        { name: string }[]
      assertEqual(rows[0]!.name, 'Renamed Branch')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('a soft delete reaches the cloud rather than the row vanishing', async () => {
    const { db, sql, branchId } = await cloudFixture()
    try {
      await pushPending(db, sql)

      const categoryId = randomUUID()
      const now = new Date().toISOString()
      db.prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, 'Temporary', 0, 1, ?, ?)`,
      ).run(categoryId, branchId, now, now)
      await pushPending(db, sql)

      db.prepare(
        'UPDATE categories SET deleted_at = ?, synced_at = NULL WHERE id = ?',
      ).run(now, categoryId)
      await pushPending(db, sql)

      const rows = (await sql`
        SELECT deleted_at FROM categories WHERE id = ${categoryId}
      `) as unknown as { deleted_at: Date | null }[]
      assertEqual(rows.length, 1, 'the row is still present')
      if (rows[0]!.deleted_at === null) throw new Error('the deletion did not reach the cloud')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('a bad row is quarantined without blocking the rest', async () => {
    const { db, sql, branchId } = await cloudFixture()
    try {
      await pushPending(db, sql)

      // A category whose branch exists locally but not in the cloud, so the push
      // fails on the cloud's foreign key rather than SQLite's.
      const orphan = randomUUID()
      const good = randomUUID()
      const ghostBranch = randomUUID()
      const now = new Date().toISOString()

      db.prepare(
        `INSERT INTO branches (id, name, print_logo, is_active, created_at, updated_at, synced_at)
         VALUES (?, 'Ghost', 1, 1, ?, ?, ?)`,
      ).run(ghostBranch, now, now, now) // pre-stamped, so it never reaches the cloud

      db.prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, 'Orphan', 0, 1, ?, ?)`,
      ).run(orphan, ghostBranch, now, now)
      db.prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, 'Good', 1, 1, ?, ?)`,
      ).run(good, branchId, now, now)

      const result = await pushPending(db, sql)
      assertEqual(result.failed, 1, 'only the orphan failed')

      // The healthy row still got through — one bad row must not block the queue.
      const cloudGood = (await sql`SELECT COUNT(*)::int AS n FROM categories WHERE id = ${good}`) as
        unknown as { n: number }[]
      assertEqual(cloudGood[0]!.n, 1, 'the good row reached the cloud despite the bad one')

      const failed = db
        .prepare('SELECT sync_attempts, sync_error FROM categories WHERE id = ?')
        .get(orphan) as { sync_attempts: number; sync_error: string | null }
      assertEqual(failed.sync_attempts, 1)
      if (failed.sync_error === null) throw new Error('no error recorded for diagnosis')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('a full order pushes in dependency order', async () => {
    const { db, sql, branchId, userId } = await cloudFixture()
    try {
      const now = new Date().toISOString()
      const sectionId = db.prepare('SELECT id FROM sections LIMIT 1').get() as { id: string }
      const tableId = randomUUID()
      const categoryId = randomUUID()
      const itemId = randomUUID()
      const variantId = randomUUID()
      const orderId = randomUUID()

      db.prepare(
        `INSERT INTO tables (id, branch_id, section_id, name, seats, status, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, ?, 'T1', 4, 'occupied', 0, 1, ?, ?)`,
      ).run(tableId, branchId, sectionId.id, now, now)
      db.prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, 'Biryani', 0, 1, ?, ?)`,
      ).run(categoryId, branchId, now, now)
      db.prepare(
        `INSERT INTO menu_items (id, branch_id, category_id, name, tax_rate, is_available, sort_order, created_at, updated_at)
         VALUES (?, ?, ?, 'Chicken Biryani', 500, 1, 0, ?, ?)`,
      ).run(itemId, branchId, categoryId, now, now)
      db.prepare(
        `INSERT INTO menu_item_variants (id, menu_item_id, name, price, sort_order, is_available, created_at, updated_at)
         VALUES (?, ?, 'Full', 32000, 0, 1, ?, ?)`,
      ).run(variantId, itemId, now, now)
      db.prepare(
        `INSERT INTO orders (id, branch_id, order_no, business_date, type, table_id, status, version, created_by, created_at, updated_at)
         VALUES (?, ?, 1, '2026-09-01', 'dine_in', ?, 'open', 1, ?, ?, ?)`,
      ).run(orderId, branchId, tableId, userId, now, now)
      db.prepare(
        `INSERT INTO order_items (id, order_id, variant_id, item_name, variant_name, unit_price,
                                  tax_rate, qty, line_base, line_tax, line_total, created_at, updated_at)
         VALUES (?, ?, ?, 'Chicken Biryani', 'Full', 32000, 500, 2, 60952, 3048, 64000, ?, ?)`,
      ).run(randomUUID(), orderId, variantId, now, now)

      const result = await pushPending(db, sql)
      assertEqual(result.failed, 0, `errors: ${JSON.stringify(result.errors)}`)

      const lines = (await sql`
        SELECT COUNT(*)::int AS n FROM order_items WHERE order_id = ${orderId}
      `) as unknown as { n: number }[]
      assertEqual(lines[0]!.n, 1, 'the line arrived after its order')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('print_jobs never reaches the cloud', async () => {
    const { db, sql, branchId } = await cloudFixture()
    try {
      const now = new Date().toISOString()
      db.prepare(
        `INSERT INTO print_jobs (id, branch_id, type, payload, status, attempts, created_at, updated_at)
         VALUES (?, ?, 'bill', '{}', 'pending', 0, ?, ?)`,
      ).run(randomUUID(), branchId, now, now)

      const result = await pushPending(db, sql)
      assertEqual(result.failed, 0)

      // The cloud has no such table at all (dropped in migration 0003).
      const exists = (await sql`
        SELECT COUNT(*)::int AS n FROM pg_tables WHERE tablename = 'print_jobs'
      `) as unknown as { n: number }[]
      assertEqual(exists[0]!.n, 0, 'print state is branch-local')
    } finally {
      await cleanup(db, sql)
    }
  })
}

/** A migrated, seeded SQLite database plus a clean cloud schema. */
async function cloudFixture(): Promise<{
  db: Db
  sql: Sql
  branchId: string
  userId: string
}> {
  const { default: postgres } = await import('postgres')
  const sql = postgres(CLOUD_URL!, { max: 1, connect_timeout: 10, onnotice: () => undefined })

  await truncateCloud(sql)

  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  const userId = (db.prepare('SELECT id FROM users LIMIT 1').get() as { id: string }).id

  return { db, sql, branchId, userId }
}

async function truncateCloud(sql: Sql): Promise<void> {
  const names = SYNC_TABLES.map((t) => t.name).join(', ')
  await sql.unsafe(`TRUNCATE ${names} RESTART IDENTITY CASCADE`)
}

async function cleanup(db: Db, sql: Sql): Promise<void> {
  await truncateCloud(sql).catch(() => undefined)
  await sql.end({ timeout: 5 }).catch(() => undefined)
  db.close()
}
