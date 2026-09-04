import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { test, assertEqual, assertThrows } from './helpers.js'

const now = new Date().toISOString()

/** A migrated in-memory database with a branch and an admin user. */
function freshDb(): Db {
  const db = openDatabase(':memory:')
  migrate(db)
  db.prepare(
    `INSERT INTO branches (id, name, print_logo, is_active, created_at, updated_at)
     VALUES ('b1', 'Chennai Express', 1, 1, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO users (id, branch_id, username, password_hash, full_name, role,
                        is_active, must_change_password, created_at, updated_at)
     VALUES ('u1', 'b1', 'admin', 'x', 'Admin', 'admin', 1, 0, ?, ?)`,
  ).run(now, now)
  return db
}

function insertOrder(db: Db, id: string, orderNo: number, status = 'billed'): void {
  db.prepare(
    `INSERT INTO orders (id, branch_id, order_no, business_date, type, status,
                         version, created_by, created_at, updated_at)
     VALUES (?, 'b1', ?, '2026-09-01', 'takeaway', ?, 1, 'u1', ?, ?)`,
  ).run(id, orderNo, status, now, now)
}

function insertBill(db: Db, id: string, orderId: string, billNo: number, total = 10_500): void {
  db.prepare(
    `INSERT INTO bills (id, branch_id, order_id, bill_no, business_date, subtotal,
                        total, tax_mode, created_by, created_at, updated_at)
     VALUES (?, 'b1', ?, ?, '2026-09-01', 10000, ?, 'exclusive', 'u1', ?, ?)`,
  ).run(id, orderId, billNo, total, now, now)
}

test('the real schema migrates cleanly', () => {
  const db = freshDb()
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    .all()
    .map((r) => (r as { name: string }).name)
    .sort()

  const expected = [
    '_migrations', 'bills', 'branches', 'categories', 'export_log', 'license_state',
    'menu_item_variants', 'menu_items',
    'order_items', 'orders', 'payments', 'print_jobs', 'printers', 'purge_log',
    'reservation_tables',
    'reservations', 'sections', 'settings', 'tables', 'users',
  ]
  assertEqual(tables.join(','), expected.join(','))
  db.close()
})

test('foreign keys are enforced', () => {
  const db = freshDb()
  assertThrows(
    () =>
      db
        .prepare(
          `INSERT INTO sections (id, branch_id, name, sort_order, is_active, created_at, updated_at)
           VALUES ('s1', 'no-such-branch', 'AC', 0, 1, ?, ?)`,
        )
        .run(now, now),
    'a section referencing a missing branch should fail',
  )
  db.close()
})

test('a dine-in order must have a table, takeaway need not', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1, 'open') // takeaway with no table is allowed

  assertThrows(
    () =>
      db
        .prepare(
          `INSERT INTO orders (id, branch_id, order_no, business_date, type, status,
                               version, created_by, created_at, updated_at)
           VALUES ('o2', 'b1', 2, '2026-09-01', 'dine_in', 'open', 1, 'u1', ?, ?)`,
        )
        .run(now, now),
    'dine_in without a table_id should violate the CHECK constraint',
  )
  db.close()
})

test('bill numbers are unique per branch per business day', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1)
  insertOrder(db, 'o2', 2)
  insertBill(db, 'bill1', 'o1', 1)
  assertThrows(() => insertBill(db, 'bill2', 'o2', 1), 'a duplicate bill_no should fail')
  db.close()
})

test('one bill per order', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1)
  insertBill(db, 'bill1', 'o1', 1)
  assertThrows(() => insertBill(db, 'bill2', 'o1', 2), 'a second bill for one order should fail')
  db.close()
})

test('order line quantity and price must be sane', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1, 'open')
  db.prepare(
    `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
     VALUES ('c1', 'b1', 'Biryani', 0, 1, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO menu_items (id, branch_id, category_id, name, tax_rate, is_available,
                             sort_order, created_at, updated_at)
     VALUES ('m1', 'b1', 'c1', 'Chicken Biryani', 500, 1, 0, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO menu_item_variants (id, menu_item_id, name, price, sort_order,
                                     is_available, created_at, updated_at)
     VALUES ('v1', 'm1', 'Full', 32000, 0, 1, ?, ?)`,
  ).run(now, now)

  const line = (id: string, qty: number) =>
    db
      .prepare(
        `INSERT INTO order_items (id, order_id, variant_id, item_name, variant_name,
                                  unit_price, tax_rate, qty, created_at, updated_at)
         VALUES (?, 'o1', 'v1', 'Chicken Biryani', 'Full', 32000, 500, ?, ?, ?)`,
      )
      .run(id, qty, now, now)

  line('li1', 2)
  assertThrows(() => line('li2', 0), 'a zero quantity should violate the CHECK')
  db.close()
})

test('a payment must be positive', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1)
  insertBill(db, 'bill1', 'o1', 1)
  assertThrows(
    () =>
      db
        .prepare(
          `INSERT INTO payments (id, branch_id, bill_id, mode, amount, paid_at,
                                 business_date, created_by, created_at, updated_at)
           VALUES ('p1', 'b1', 'bill1', 'cash', 0, ?, '2026-09-01', 'u1', ?, ?)`,
        )
        .run(now, now, now),
    'a zero payment should violate the CHECK',
  )
  db.close()
})

test('a bill supports several payments', () => {
  const db = freshDb()
  insertOrder(db, 'o1', 1)
  insertBill(db, 'bill1', 'o1', 1, 80_000)

  const pay = (id: string, mode: string, amount: number) =>
    db
      .prepare(
        `INSERT INTO payments (id, branch_id, bill_id, mode, amount, paid_at,
                               business_date, created_by, created_at, updated_at)
         VALUES (?, 'b1', 'bill1', ?, ?, ?, '2026-09-01', 'u1', ?, ?)`,
      )
      .run(id, mode, amount, now, now, now)

  pay('p1', 'cash', 50_000)
  pay('p2', 'card', 30_000)

  const sum = db
    .prepare('SELECT SUM(amount) AS total FROM payments WHERE bill_id = ? AND reversed_at IS NULL')
    .get('bill1') as { total: number }
  assertEqual(sum.total, 80_000, 'Rs500 cash + Rs300 card should settle an Rs800 bill')
  db.close()
})

test('a table can hold several open orders', () => {
  const db = freshDb()
  db.prepare(
    `INSERT INTO sections (id, branch_id, name, sort_order, is_active, created_at, updated_at)
     VALUES ('s1', 'b1', 'AC', 0, 1, ?, ?)`,
  ).run(now, now)
  db.prepare(
    `INSERT INTO tables (id, branch_id, section_id, name, seats, status, sort_order,
                         is_active, created_at, updated_at)
     VALUES ('t1', 'b1', 's1', 'T1', 4, 'free', 0, 1, ?, ?)`,
  ).run(now, now)

  const order = (id: string, no: number, seat: string) =>
    db
      .prepare(
        `INSERT INTO orders (id, branch_id, order_no, business_date, type, table_id,
                             seat_label, status, version, created_by, created_at, updated_at)
         VALUES (?, 'b1', ?, '2026-09-01', 'dine_in', 't1', ?, 'open', 1, 'u1', ?, ?)`,
      )
      .run(id, no, seat, now, now)

  order('o1', 1, 'A')
  order('o2', 2, 'B')

  const open = db
    .prepare(
      `SELECT COUNT(*) AS n FROM orders
       WHERE table_id = 't1' AND status = 'open' AND deleted_at IS NULL`,
    )
    .get() as { n: number }
  assertEqual(open.n, 2, 'two parties should be able to share a table')
  db.close()
})

test('enum columns reject unknown values', () => {
  const db = freshDb()
  assertThrows(
    () =>
      db
        .prepare(
          `INSERT INTO printers (id, branch_id, name, connection, address, role,
                                 paper_width, is_active, created_at, updated_at)
           VALUES ('pr1', 'b1', 'Billing', 'bluetooth', 'x', 'bill', '80mm', 1, ?, ?)`,
        )
        .run(now, now),
    'an unsupported connection type should be rejected',
  )
  db.close()
})
