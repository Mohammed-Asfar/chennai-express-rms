import { randomUUID } from 'node:crypto'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { loadEnv } from '../src/lib/env.js'
import { previewPurge, purgeLocal, recordExport } from '../src/db/purge.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  db: Db
  branchId: string
  userId: string
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  const user = db.prepare('SELECT id FROM users LIMIT 1').get() as { id: string }
  return { db, branchId, userId: user.id }
}

/** A billed order on a given business date, with one line and one payment. */
function bill(ctx: Ctx, businessDate: string, total = 10_000): string {
  const now = new Date().toISOString()
  const orderId = randomUUID()
  const billId = randomUUID()

  ctx.db
    .prepare(
      `INSERT INTO orders (id, branch_id, order_no, business_date, type, status, created_by, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'takeaway', 'billed', ?, ?, ?)`,
    )
    .run(orderId, ctx.branchId, Math.floor(Math.random() * 100000), businessDate, ctx.userId, now, now)

  const variant = ctx.db.prepare('SELECT id FROM menu_item_variants LIMIT 1').get() as
    | { id: string }
    | undefined

  if (variant) {
    ctx.db
      .prepare(
        `INSERT INTO order_items
           (id, order_id, variant_id, item_name, variant_name, unit_price, tax_rate, qty,
            line_base, line_tax, line_total, created_at, updated_at)
         VALUES (?, ?, ?, 'Test', 'Regular', ?, 0, 1, ?, 0, ?, ?, ?)`,
      )
      .run(randomUUID(), orderId, variant.id, total, total, total, now, now)
  }

  ctx.db
    .prepare(
      `INSERT INTO bills
         (id, branch_id, order_id, bill_no, bill_period, bill_number, business_date,
          subtotal, total, tax_mode, created_by, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'exclusive', ?, ?, ?)`,
    )
    .run(
      billId, ctx.branchId, orderId, Math.floor(Math.random() * 100000),
      businessDate, `T/${billId.slice(0, 6)}`, businessDate,
      total, total, ctx.userId, now, now,
    )

  ctx.db
    .prepare(
      `INSERT INTO payments
         (id, branch_id, bill_id, mode, amount, paid_at, business_date, created_by, created_at, updated_at)
       VALUES (?, ?, ?, 'cash', ?, ?, ?, ?, ?, ?)`,
    )
    .run(randomUUID(), ctx.branchId, billId, total, now, businessDate, ctx.userId, now, now)

  return billId
}

// --- what goes, and what must not ---

test('a purge removes the range and nothing outside it', async () => {
  const ctx = await setup()
  bill(ctx, '2026-01-15')
  bill(ctx, '2026-02-20')
  const keep = bill(ctx, '2026-06-01')

  const result = purgeLocal(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-03-31' }, ctx.userId)

  assertEqual(result.bills, 2, 'both January and February bills went')
  assertEqual(
    (ctx.db.prepare('SELECT count(*) n FROM bills').get() as { n: number }).n,
    1,
    'June survived',
  )
  assertEqual(
    (ctx.db.prepare('SELECT count(*) n FROM bills WHERE id = ?').get(keep) as { n: number }).n,
    1,
    'and it is the right one',
  )
  ctx.db.close()
})

test('a purge never touches the menu, tables or settings', async () => {
  // The whole point of the feature is reclaiming space from trading data. A
  // till that lost its menu would stop working rather than merely forget, and
  // rebuilding 184 items by hand is not a recovery anyone would accept.
  const ctx = await setup()
  bill(ctx, '2026-01-15')

  const protectedTables = [
    'menu_items', 'menu_item_variants', 'categories',
    'tables', 'sections', 'settings', 'users', 'branches',
  ]

  const count = (table: string): number =>
    (ctx.db.prepare(`SELECT count(*) n FROM ${table}`).get() as { n: number }).n

  const before = new Map(protectedTables.map((t) => [t, count(t)]))

  purgeLocal(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-12-31' }, ctx.userId)

  for (const [table, expected] of before) {
    assertEqual(count(table), expected, `${table} is untouched`)
  }
  ctx.db.close()
})

test('order items and payments go with their bill', async () => {
  // Orphans are worse than the rows themselves: an order_item with no order is
  // invisible to every report and still occupies the disk this was meant to
  // reclaim.
  const ctx = await setup()
  bill(ctx, '2026-01-15')

  purgeLocal(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-01-31' }, ctx.userId)

  assertEqual(
    (ctx.db.prepare('SELECT count(*) n FROM order_items').get() as { n: number }).n,
    0,
    'no orphaned line items',
  )
  assertEqual(
    (ctx.db.prepare('SELECT count(*) n FROM payments').get() as { n: number }).n,
    0,
    'no orphaned payments',
  )
  assertEqual(
    (ctx.db.prepare('SELECT count(*) n FROM orders').get() as { n: number }).n,
    0,
    'no orphaned orders',
  )
  ctx.db.close()
})

// --- the record of the gap ---

test('a purge writes down what it removed', async () => {
  // Six years of retention is the rule, and this is the exception to it. A gap
  // in the bill numbers with no explanation is indistinguishable from data
  // loss, so the log is written in the same transaction as the deletion.
  const ctx = await setup()
  bill(ctx, '2026-01-15')
  bill(ctx, '2026-01-16')

  purgeLocal(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-01-31' }, ctx.userId)

  const log = ctx.db.prepare('SELECT * FROM purge_log').get() as {
    from_date: string
    to_date: string
    bills_removed: number
    was_exported: number
  }

  assertEqual(log.from_date, '2026-01-01')
  assertEqual(log.to_date, '2026-01-31')
  assertEqual(log.bills_removed, 2, 'what went is recorded')
  assertEqual(log.was_exported, 0, 'and that nobody had exported it')
  ctx.db.close()
})

// --- the warning ---

test('an unexported range is reported as unexported', async () => {
  const ctx = await setup()
  bill(ctx, '2026-01-15')

  const preview = previewPurge(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-01-31' })

  assertEqual(preview.bills, 1, 'the count is what will actually go')
  assertEqual(preview.exported, false)
  assertEqual(preview.missingExports.length, 3, 'all three exports are missing')
  ctx.db.close()
})

test('an export covering the range clears the warning', async () => {
  const ctx = await setup()
  bill(ctx, '2026-01-15')
  const range = { from: '2026-01-01', to: '2026-01-31' }

  for (const kind of ['bills', 'bill_items', 'payments'] as const) {
    recordExport(ctx.db, ctx.branchId, kind, range, 1, ctx.userId)
  }

  assertEqual(previewPurge(ctx.db, ctx.branchId, range).exported, true)
  ctx.db.close()
})

test('an export of part of the range does not count', async () => {
  // Exporting January and then clearing January to March would lose February
  // and March with the screen reporting everything was safe.
  const ctx = await setup()
  bill(ctx, '2026-02-15')

  for (const kind of ['bills', 'bill_items', 'payments'] as const) {
    recordExport(ctx.db, ctx.branchId, kind, { from: '2026-01-01', to: '2026-01-31' }, 1, ctx.userId)
  }

  const preview = previewPurge(ctx.db, ctx.branchId, { from: '2026-01-01', to: '2026-03-31' })
  assertEqual(preview.exported, false, 'a partial export is not a copy')
  ctx.db.close()
})

test('a wider export than the range counts', async () => {
  // Exporting the whole year and clearing one month of it is fine — the data
  // is demonstrably in a file.
  const ctx = await setup()
  bill(ctx, '2026-02-15')
  const wide = { from: '2026-01-01', to: '2026-12-31' }

  for (const kind of ['bills', 'bill_items', 'payments'] as const) {
    recordExport(ctx.db, ctx.branchId, kind, wide, 10, ctx.userId)
  }

  const preview = previewPurge(ctx.db, ctx.branchId, { from: '2026-02-01', to: '2026-02-28' })
  assertEqual(preview.exported, true)
  ctx.db.close()
})

test('the preview count matches what the purge removes', async () => {
  // The operator confirms a number. It has to be the number that goes, or the
  // confirmation is theatre.
  const ctx = await setup()
  bill(ctx, '2026-01-10')
  bill(ctx, '2026-01-20')
  bill(ctx, '2026-01-30')
  bill(ctx, '2026-05-01')

  const range = { from: '2026-01-01', to: '2026-01-31' }
  const preview = previewPurge(ctx.db, ctx.branchId, range)
  const result = purgeLocal(ctx.db, ctx.branchId, range, ctx.userId)

  assertEqual(result.bills, preview.bills, 'bills')
  assertEqual(result.orders, preview.orders, 'orders')
  assertEqual(result.payments, preview.payments, 'payments')
  assertEqual(result.bills, 3, 'and it is the January ones')
  ctx.db.close()
})
