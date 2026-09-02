import { randomUUID } from 'node:crypto'
import type { Sql } from 'postgres'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { loadEnv } from '../src/lib/env.js'
import { pushPending } from '../src/sync/push.js'
import { isEmptyDatabase, findCloudBranch, pullAll } from '../src/sync/pull.js'
import { SYNC_TABLES } from '../src/sync/tables.js'
import { test, serialTest, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

// Read through loadEnv so `.env` is loaded: the call above passes an explicit
// source, which deliberately skips the dotenv read.
const CLOUD_URL = loadEnv().CLOUD_DATABASE_URL

// --- no database needed ---

test('a freshly migrated database reads as empty', () => {
  const db = openDatabase(':memory:')
  migrate(db)
  assertEqual(isEmptyDatabase(db), true, 'migrated but unseeded database is empty')
  db.close()
})

test('a seeded database does not read as empty', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  assertEqual(isEmptyDatabase(db), false, 'seeded database is not empty')
  db.close()
})

test('pull order is the same dependency order push uses', () => {
  // Restore inserts parents first for the same reason push does. If these ever
  // diverge, one of the two is wrong.
  const position = new Map(SYNC_TABLES.map((t, i) => [t.name, i]))
  const parents: Record<string, string[]> = {
    orders: ['branches', 'users', 'tables'],
    order_items: ['orders', 'menu_item_variants'],
    bills: ['branches', 'orders', 'users'],
    payments: ['branches', 'bills', 'users'],
  }

  for (const [child, required] of Object.entries(parents)) {
    const childAt = position.get(child)!
    for (const parent of required) {
      const parentAt = position.get(parent)!
      if (parentAt >= childAt) {
        throw new Error(`${parent} must be pulled before ${child}`)
      }
    }
  }
})

// --- cloud round trip ---

if (!CLOUD_URL) {
  test('cloud restore tests skipped (no CLOUD_DATABASE_URL)', () => {})
} else {
  serialTest('restore refuses to overwrite a database that has data', async () => {
    const { db, sql } = await cloudFixture()
    try {
      // The database is seeded, so it is in service. Restoring over it would
      // destroy whatever has not yet reached the cloud.
      let threw = false
      try {
        await pullAll(db, sql)
      } catch {
        threw = true
      }
      assertEqual(threw, true, 'pullAll throws on a non-empty database')
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('a lost database is restored from the cloud with its money intact', async () => {
    const { db, sql, branchId, userId } = await cloudFixture()
    try {
      const { billTotal, paidTotal } = seedOrderAndBill(db, branchId, userId)

      const pushed = await pushPending(db, sql)
      assertEqual(pushed.errors.length, 0, `push clean: ${JSON.stringify(pushed.errors)}`)

      const localCounts = countAll(db)

      // The disk fails. A brand new database, migrated but never seeded.
      const fresh = openDatabase(':memory:')
      migrate(fresh)
      assertEqual(isEmptyDatabase(fresh), true, 'the replacement starts empty')

      const branch = await findCloudBranch(sql)
      assertEqual(branch?.id, branchId, 'the cloud branch is found')
      assertEqual(branch?.billCount, 1, 'the bill count is reported before restoring')

      const result = await pullAll(fresh, sql)
      assertEqual(result.errors.length, 0, `restore clean: ${JSON.stringify(result.errors)}`)

      // Every table came back at the same row count.
      const restoredCounts = countAll(fresh)
      for (const [table, count] of Object.entries(localCounts)) {
        assertEqual(restoredCounts[table], count, `${table} row count matches`)
      }

      // The numbers that matter. Integer paise, compared exactly.
      const bill = fresh
        .prepare('SELECT total, amount_paid, payment_status FROM bills LIMIT 1')
        .get() as { total: number; amount_paid: number; payment_status: string }
      assertEqual(bill.total, billTotal, 'bill total survives the round trip')
      assertEqual(bill.amount_paid, paidTotal, 'amount paid survives the round trip')
      assertEqual(bill.payment_status, 'paid', 'payment status survives the round trip')

      // Snapshot columns are the whole point of the snapshot rule: a restored
      // bill must still say what it said when it was printed.
      const item = fresh
        .prepare('SELECT item_name, unit_price, tax_rate, line_total FROM order_items LIMIT 1')
        .get() as { item_name: string; unit_price: number; tax_rate: number; line_total: number }
      assertEqual(item.item_name, 'Chicken Biryani', 'item name snapshot restored')
      assertEqual(item.unit_price, 25000, 'unit price snapshot restored')
      assertEqual(item.tax_rate, 500, 'tax rate snapshot restored')

      fresh.close()
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('restored rows are stamped synced and do not push back', async () => {
    const { db, sql, branchId, userId } = await cloudFixture()
    try {
      seedOrderAndBill(db, branchId, userId)
      await pushPending(db, sql)

      const fresh = openDatabase(':memory:')
      migrate(fresh)
      await pullAll(fresh, sql)

      // No tracked row is pending after a restore. Without the synced_at stamp
      // the entire history would be re-uploaded on the first cycle.
      //
      // Untracked tables (settings, reservation_tables) are excluded: they carry
      // no sync columns and are pushed whole every cycle by design, so they
      // always re-push and say nothing about whether the stamping worked.
      const pendingTracked = SYNC_TABLES.filter((t) => t.tracked).reduce((sum, t) => {
        const row = fresh
          .prepare(`SELECT COUNT(*) AS n FROM ${t.name} WHERE synced_at IS NULL`)
          .get() as { n: number }
        return sum + row.n
      }, 0)
      assertEqual(pendingTracked, 0, 'a restore leaves no tracked row pending')

      const unstamped = fresh
        .prepare('SELECT COUNT(*) AS n FROM bills WHERE synced_at IS NULL')
        .get() as { n: number }
      assertEqual(unstamped.n, 0, 'restored bills carry a synced_at stamp')

      fresh.close()
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('booleans come back as SQLite integers, not Postgres true', async () => {
    const { db, sql } = await cloudFixture()
    try {
      await pushPending(db, sql)

      const fresh = openDatabase(':memory:')
      migrate(fresh)
      await pullAll(fresh, sql)

      // Postgres hands back real booleans; better-sqlite3 refuses to bind them.
      // If the conversion is missing this test fails at pullAll, not here.
      const branch = fresh
        .prepare('SELECT is_active, print_logo FROM branches LIMIT 1')
        .get() as { is_active: unknown; print_logo: unknown }
      assertEqual(typeof branch.is_active, 'number', 'is_active is an integer')
      assertEqual(branch.is_active, 1, 'is_active is 1, not true')
      assertEqual(typeof branch.print_logo, 'number', 'print_logo is an integer')

      const user = fresh
        .prepare('SELECT must_change_password FROM users LIMIT 1')
        .get() as { must_change_password: unknown }
      assertEqual(typeof user.must_change_password, 'number', 'must_change_password is an integer')

      fresh.close()
    } finally {
      await cleanup(db, sql)
    }
  })

  serialTest('an empty cloud reports no branch to restore', async () => {
    const { db, sql } = await cloudFixture()
    try {
      // cloudFixture truncates, and nothing has been pushed: a genuine first
      // install, which must seed normally rather than restore.
      const branch = await findCloudBranch(sql)
      assertEqual(branch, null, 'no branch found in an empty cloud')
    } finally {
      await cleanup(db, sql)
    }
  })
}

/** Creates one order, one bill and one payment, and returns the money. */
function seedOrderAndBill(
  db: Db,
  branchId: string,
  userId: string,
): { billTotal: number; paidTotal: number } {
  const now = new Date().toISOString()
  const businessDate = now.slice(0, 10)

  const categoryId = randomUUID()
  const itemId = randomUUID()
  const variantId = randomUUID()
  const orderId = randomUUID()
  const orderItemId = randomUUID()
  const billId = randomUUID()
  const paymentId = randomUUID()

  // ₹250.00 inclusive at 5% — base 23810, tax 1190, total 25000.
  const unitPrice = 25000
  const lineBase = 23810
  const lineTax = 1190
  const billTotal = 25000
  const paidTotal = 25000

  db.transaction(() => {
    db.prepare(
      `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
       VALUES (?, ?, 'Biryani', 0, 1, ?, ?)`,
    ).run(categoryId, branchId, now, now)

    db.prepare(
      `INSERT INTO menu_items (id, branch_id, category_id, name, tax_rate, is_available,
                               sort_order, created_at, updated_at)
       VALUES (?, ?, ?, 'Chicken Biryani', 500, 1, 0, ?, ?)`,
    ).run(itemId, branchId, categoryId, now, now)

    db.prepare(
      `INSERT INTO menu_item_variants (id, menu_item_id, name, price, sort_order,
                                       is_available, created_at, updated_at)
       VALUES (?, ?, 'Full', ?, 0, 1, ?, ?)`,
    ).run(variantId, itemId, unitPrice, now, now)

    // Takeaway: a dine-in order requires a table, and the table is not what this
    // test is about.
    db.prepare(
      `INSERT INTO orders (id, branch_id, order_no, business_date, type, status,
                           version, created_by, created_at, updated_at)
       VALUES (?, ?, 1, ?, 'takeaway', 'billed', 1, ?, ?, ?)`,
    ).run(orderId, branchId, businessDate, userId, now, now)

    db.prepare(
      `INSERT INTO order_items (id, order_id, variant_id, item_name, variant_name,
                                unit_price, tax_rate, qty, line_base, line_tax,
                                line_total, created_at, updated_at)
       VALUES (?, ?, ?, 'Chicken Biryani', 'Full', ?, 500, 1, ?, ?, ?, ?, ?)`,
    ).run(orderItemId, orderId, variantId, unitPrice, lineBase, lineTax, unitPrice, now, now)

    db.prepare(
      `INSERT INTO bills (id, branch_id, order_id, bill_no, bill_period, bill_number,
                          business_date, subtotal, discount_amount, cgst, sgst,
                          round_off, total, amount_paid, payment_status, tax_mode,
                          created_by, created_at, updated_at)
       VALUES (?, ?, ?, '1', ?, 1, ?, ?, 0, 595, 595, 0, ?, ?, 'paid', 'inclusive', ?, ?, ?)`,
    ).run(
      billId, branchId, orderId, businessDate, businessDate,
      lineBase, billTotal, paidTotal, userId, now, now,
    )

    db.prepare(
      `INSERT INTO payments (id, branch_id, bill_id, mode, amount, paid_at,
                             business_date, created_by, created_at, updated_at)
       VALUES (?, ?, ?, 'cash', ?, ?, ?, ?, ?, ?)`,
    ).run(paymentId, branchId, billId, paidTotal, now, businessDate, userId, now, now)
  })()

  return { billTotal, paidTotal }
}

function countAll(db: Db): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const table of SYNC_TABLES) {
    const row = db.prepare(`SELECT COUNT(*) AS n FROM ${table.name}`).get() as { n: number }
    counts[table.name] = row.n
  }
  return counts
}

async function cloudFixture(): Promise<{ db: Db; sql: Sql; branchId: string; userId: string }> {
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
