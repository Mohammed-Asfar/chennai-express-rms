import { randomUUID } from 'node:crypto'
import type { Sql } from 'postgres'
import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import {
  pushPending,
  syncCounts,
  retryQuarantined,
  resyncMasterData,
  lastSyncedAt,
} from '../src/sync/push.js'
import { SYNC_TABLES, NEVER_SYNCED, MAX_SYNC_ATTEMPTS, backoffMs } from '../src/sync/tables.js'
import { setSetting } from '../src/lib/settings.js'
import { SyncWorker } from '../src/sync/worker.js'
import { test, serialTest, assertEqual } from './helpers.js'
import { testCloudUrl } from './cloud-guard.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

/**
 * Cloud tests need a Postgres of their own — they truncate every synced table.
 * Skipped unless TEST_CLOUD_DATABASE_URL is set. Never CLOUD_DATABASE_URL: that is
 * the database the app syncs to, and truncating it has cost real data before.
 */
const CLOUD_URL = testCloudUrl()
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

/**
 * A cloud that answers but rejects every row.
 *
 * This is schema drift: the branch has a column the cloud has not been
 * migrated for. The connection is perfectly healthy, which is precisely why it
 * went unnoticed on a real till for days.
 */
function rejectingCloud(message: string): () => Promise<Sql> {
  const sql = ((strings: unknown, ..._values: unknown[]) => {
    // The `SELECT 1` probe must succeed — the cloud is reachable.
    const text = Array.isArray(strings) ? String((strings as string[])[0]) : String(strings)
    if (text.includes('SELECT 1')) return Promise.resolve([{ '?column?': 1 }])
    return Promise.reject(new Error(message))
  }) as unknown as Sql

  // Cast through unknown: these stubs satisfy what the worker calls, not the
  // full tagged-template surface of the real driver.
  sql.unsafe = (() => Promise.reject(new Error(message))) as unknown as Sql['unsafe']
  sql.end = (() => Promise.resolve()) as unknown as Sql['end']
  sql.begin = ((fn: (t: Sql) => unknown) => Promise.resolve(fn(sql))) as unknown as Sql['begin']

  return () => Promise.resolve(sql)
}

test('a restarted worker reports when the backup really happened', async () => {
  // The worker keeps lastSuccessAt in memory, which empties on every restart.
  // A till restarted mid-service said the backup had happened "Never" while
  // the database plainly held rows stamped seconds earlier.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const stamp = '2026-09-02T12:07:47.174Z'
  db.prepare('UPDATE branches SET synced_at = ?').run(stamp)

  const cloudEnv = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://stand-in/none',
  })
  // Fresh worker, nothing in memory — exactly the state after a restart.
  const worker = new SyncWorker(db, cloudEnv, silentLog, {})
  const status = worker.status()

  assertEqual(status.lastSuccessAt, stamp, 'read from the rows, not from memory')
  assertEqual(status.lastAttemptAt, stamp, 'the last check demonstrably reached the cloud')

  worker.stop()
  db.close()
})

test('the newest stamp across every table wins', async () => {
  // Tables sync at different times. The screen wants the most recent, not
  // whichever table happens to be checked first.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  db.prepare('UPDATE branches SET synced_at = ?').run('2026-09-01T08:00:00.000Z')
  db.prepare('UPDATE users SET synced_at = ?').run('2026-09-02T17:30:00.000Z')
  db.prepare('UPDATE sections SET synced_at = ?').run('2026-09-02T09:00:00.000Z')

  assertEqual(lastSyncedAt(db), '2026-09-02T17:30:00.000Z')
  db.close()
})

test('nothing synced yet reads as never, not as an epoch', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  // Seeded rows are all pending, so nothing carries a stamp.
  assertEqual(lastSyncedAt(db), null)
  db.close()
})

test('a failed cycle comes back on its own', async () => {
  // The gap this closes: nothing rescheduled after a failure, so a cloud that
  // went down for five seconds stayed unsynced until the next heartbeat. The
  // backlog sat there long after the cloud was back.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const cloudEnv = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://stand-in/none',
  })

  let attempts = 0
  const worker = new SyncWorker(db, cloudEnv, silentLog, {
    // Short enough to observe, long enough not to race the assertion.
    retryBaseMs: 40,
    heartbeatMs: 60_000,
    connect: () => {
      attempts += 1
      return Promise.reject(new Error('ECONNREFUSED'))
    },
  })

  await worker.syncNow()
  assertEqual(attempts, 1, 'the first attempt ran')

  // Long enough for the scheduled retry, far short of the heartbeat.
  await new Promise((resolve) => setTimeout(resolve, 250))

  if (attempts < 2) {
    throw new Error(`no retry was scheduled: still ${attempts} attempt(s)`)
  }

  worker.stop()
  db.close()
})

test('a stopped worker schedules nothing further', async () => {
  // A retry firing after shutdown would keep the process alive and dial a
  // cloud nobody is waiting on.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const cloudEnv = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://stand-in/none',
  })

  let attempts = 0
  const worker = new SyncWorker(db, cloudEnv, silentLog, {
    retryBaseMs: 30,
    connect: () => {
      attempts += 1
      return Promise.reject(new Error('ECONNREFUSED'))
    },
  })

  await worker.syncNow()
  worker.stop()
  const afterStop = attempts

  await new Promise((resolve) => setTimeout(resolve, 150))
  assertEqual(attempts, afterStop, 'no further attempts after stop')

  db.close()
})

test('storage is not offered when there is no cloud', async () => {
  // Nothing to measure, and a zero would render as a full disk.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const worker = new SyncWorker(db, env, silentLog, {})
  assertEqual(await worker.storage(), null)

  worker.stop()
  db.close()
})

test('an unreachable cloud reports unknown storage rather than throwing', async () => {
  // A size that cannot be read is not a fault worth an error in front of
  // someone looking at a backup screen.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const offline = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })
  const worker = new SyncWorker(db, offline, silentLog, {
    connect: () => Promise.reject(new Error('ECONNREFUSED')),
  })

  assertEqual(await worker.storage(), null)

  worker.stop()
  db.close()
})

test('a repair re-pushes master data that the cloud is missing', async () => {
  // The live fault: the admin user was stamped synced but absent from the
  // cloud, so every order, bill and payment referencing it was rejected on a
  // foreign key — forever, because a stamped row is never looked at again.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const stamp = new Date().toISOString()
  // settings included: it became tracked, so its seeded rows now count towards
  // pending like any other. Leaving it out made this read "everything is
  // synced" while nine rows waited.
  for (const table of ['branches', 'users', 'sections', 'tables', 'categories', 'settings']) {
    db.prepare(`UPDATE ${table} SET synced_at = ?`).run(stamp)
  }
  assertEqual(syncCounts(db).pending, 0, 'everything starts stamped as synced')

  const repaired = resyncMasterData(db)
  if (repaired < 2) throw new Error(`expected the branch and user back in the queue, got ${repaired}`)

  const user = db.prepare("SELECT synced_at FROM users WHERE username = 'admin'").get() as {
    synced_at: string | null
  }
  assertEqual(user.synced_at, null, 'the user is queued to push again')

  db.close()
})

test('a repair leaves the business backlog alone', async () => {
  // Re-pushing thousands of bills to fix one missing user would be a
  // self-inflicted outage, so only the small master tables are touched.
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)

  const userId = (db.prepare('SELECT id FROM users LIMIT 1').get() as { id: string }).id
  const stamp = new Date().toISOString()
  db.prepare(
    `INSERT INTO orders (id, branch_id, order_no, business_date, type, status, version,
                         created_by, created_at, updated_at, synced_at)
     VALUES (?, ?, 1, '2026-09-02', 'takeaway', 'open', 1, ?, ?, ?, ?)`,
  ).run(randomUUID(), branchId, userId, stamp, stamp, stamp)

  resyncMasterData(db)

  const order = db.prepare('SELECT synced_at FROM orders LIMIT 1').get() as {
    synced_at: string | null
  }
  if (order.synced_at === null) throw new Error('a synced order must not be re-queued')

  db.close()
})

test('a repair skips rows that were deleted', async () => {
  // A soft-deleted table has already pushed its deletion. Re-queueing it would
  // send the same tombstone again for nothing.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const now = new Date().toISOString()
  db.prepare('UPDATE sections SET synced_at = ?, deleted_at = ?').run(now, now)

  resyncMasterData(db)

  const section = db.prepare('SELECT synced_at FROM sections LIMIT 1').get() as {
    synced_at: string | null
  }
  if (section.synced_at === null) throw new Error('a deleted section must not be re-queued')

  db.close()
})

test('a reachable cloud that rejects every row is not reported as healthy', async () => {
  // The defect this guards: a live branch synced nothing for days because the
  // cloud was missing a migration, while the status said everything was fine.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const cloudEnv = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://stand-in/none',
  })
  const worker = new SyncWorker(db, cloudEnv, silentLog, {
    batchSize: 10,
    connect: rejectingCloud('column "tagline" of relation "branches" does not exist'),
  })

  await worker.syncNow()
  const status = worker.status()

  assertEqual(status.healthy, false, 'rejected rows must not read as a healthy sync')
  assertEqual(status.lastSuccessAt, null, 'nothing reached the cloud, so there was no success')
  if (status.consecutiveFailures < 1) throw new Error('the rejection was not counted as a failure')
  if (status.problem === null) throw new Error('an unhealthy sync must say what is wrong')

  worker.stop()
  db.close()
})

test('an unreachable cloud is unhealthy and says the sales are safe locally', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const offline = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })
  const worker = new SyncWorker(db, offline, silentLog, {
    batchSize: 10,
    connect: () => Promise.reject(new Error('ECONNREFUSED')),
  })

  await worker.syncNow()
  const status = worker.status()

  assertEqual(status.healthy, false)
  // The owner needs to know their takings are not lost, not just that a
  // technical thing failed.
  if (!status.problem?.includes('safe on this PC')) {
    throw new Error(`unhelpful message: ${status.problem}`)
  }

  worker.stop()
  db.close()
})

test('sync switched off is unhealthy rather than quietly fine', async () => {
  // No CLOUD_DATABASE_URL means there is no backup at all. Reporting that as
  // healthy would be the most dangerous reading of the three.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const worker = new SyncWorker(db, env, silentLog, {})
  const status = worker.status()

  assertEqual(status.enabled, false)
  assertEqual(status.healthy, false)
  if (status.problem === null) throw new Error('it must say cloud backup is not set up')

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

// --- a dev server must not push to a live branch ---

test('a dev server does not reach the cloud unless asked', async () => {
  // `pnpm run dev` uses its own SQLite but the same .env, so it pushed to the
  // same cloud branch as the installed till. Both then allocated order numbers
  // from one sequence, both issued a #1 for the same trading day, and the
  // unique index rejected the real till's push — its sync stalled behind test
  // data it had no way to see.
  const db = openDatabase(':memory:')
  migrate(db)

  const dev = loadEnv({
    NODE_ENV: 'development',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })

  let connected = false
  const before = process.env.SYNC_IN_DEV
  delete process.env.SYNC_IN_DEV

  try {
    const worker = new SyncWorker(db, dev, silentLog, {
      batchSize: 10,
      connect: () => {
        connected = true
        return Promise.reject(new Error('should not have been called'))
      },
    })
    worker.start()
    await Promise.resolve()
    worker.stop()

    assertEqual(connected, false, 'start() did not dial the cloud')
  } finally {
    if (before === undefined) delete process.env.SYNC_IN_DEV
    else process.env.SYNC_IN_DEV = before
  }

  db.close()
})

test('SYNC_IN_DEV=true opts a dev server in', async () => {
  // Deliberately still possible: testing the sync path itself needs it, and a
  // developer who sets this has been told what it means.
  const db = openDatabase(':memory:')
  migrate(db)

  const dev = loadEnv({
    NODE_ENV: 'development',
    DB_PATH: ':memory:',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })

  let connected = false
  const before = process.env.SYNC_IN_DEV
  process.env.SYNC_IN_DEV = 'true'

  try {
    const worker = new SyncWorker(db, dev, silentLog, {
      batchSize: 10,
      connect: () => {
        connected = true
        return Promise.reject(new Error('ECONNREFUSED'))
      },
    })
    worker.start()
    await worker.syncNow()
    worker.stop()

    assertEqual(connected, true, 'the cloud was dialled when opted in')
  } finally {
    if (before === undefined) delete process.env.SYNC_IN_DEV
    else process.env.SYNC_IN_DEV = before
  }

  db.close()
})

// --- settings push on change, not on every cycle ---

test('a settings row is pending once, then stays quiet', () => {
  // settings used to be untracked, which means "push the whole table every
  // cycle": ten rows upserted to the cloud once a minute, for ever, changed or
  // not. It also left the worker unable to tell an idle cycle from a busy one,
  // because there was always something pending to send.
  const db = openDatabase(':memory:')
  migrate(db)

  const now = new Date().toISOString()
  db.prepare(
    `INSERT INTO branches (id, name, print_logo, is_active, created_at, updated_at)
     VALUES ('b1', 'Test', 1, 1, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO settings (branch_id, key, value, created_at, updated_at)
     VALUES ('b1', 'tax_mode', 'exclusive', ?, ?)`,
  ).run(now, now)

  const settings = SYNC_TABLES.find((t) => t.name === 'settings')!
  assertEqual(settings.tracked, true, 'settings is tracked')

  // Counted on settings alone: the branch row this needs as a parent is itself
  // unsynced, and syncCounts covers every table.
  const pendingSettings = () =>
    (db.prepare('SELECT count(*) n FROM settings WHERE synced_at IS NULL').get() as { n: number }).n

  // Unsent, so it is pending.
  assertEqual(pendingSettings(), 1, 'a new setting is queued')

  // Stamped, so it is not.
  db.prepare('UPDATE settings SET synced_at = ?').run(now)
  assertEqual(pendingSettings(), 0, 'a pushed setting stops being sent')

  db.close()
})

test('changing a setting queues it again', () => {
  // The other half: tracking is only useful if a real edit still gets through.
  // setSetting clears synced_at on write, which is what puts it back in the
  // queue — without that, tracking would mean settings never sync at all.
  const db = openDatabase(':memory:')
  migrate(db)

  const now = new Date().toISOString()
  db.prepare(
    `INSERT INTO branches (id, name, print_logo, is_active, created_at, updated_at)
     VALUES ('b1', 'Test', 1, 1, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO settings (branch_id, key, value, created_at, updated_at, synced_at)
     VALUES ('b1', 'tax_mode', 'exclusive', ?, ?, ?)`,
  ).run(now, now, now)

  const pendingSettings = () =>
    (db.prepare('SELECT count(*) n FROM settings WHERE synced_at IS NULL').get() as { n: number }).n

  assertEqual(pendingSettings(), 0, 'starts settled')

  setSetting(db, 'b1', 'tax_mode', 'inclusive')
  assertEqual(pendingSettings(), 1, 'an edit is queued to push')

  db.close()
})
