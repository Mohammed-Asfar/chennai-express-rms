import type { FastifyInstance } from 'fastify'
import { randomUUID } from 'node:crypto'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { refreshTableStatus } from '../src/routes/tables.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  admin: Record<string, string>
  cashier: Record<string, string>
  branchId: string
  userId: string
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })

  const admin = await login(app, 'admin', 'admin123')
  await app.inject({
    method: 'POST',
    url: '/users',
    headers: admin,
    payload: { username: 'cash', password: 'cash123', fullName: 'Cash', role: 'cashier' },
  })
  const cashier = await login(app, 'cash', 'cash123')

  const userId = (db.prepare("SELECT id FROM users WHERE username = 'admin'").get() as { id: string })
    .id

  return { app, db, admin, cashier, branchId, userId }
}

async function login(app: FastifyInstance, username: string, password: string) {
  const res = await app.inject({ method: 'POST', url: '/auth/login', payload: { username, password } })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
}

async function makeSection(ctx: Ctx, name: string): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/sections',
    headers: ctx.admin,
    payload: { name },
  })
  if (res.statusCode !== 201) throw new Error(`section failed: ${res.body}`)
  return (res.json() as { section: { id: string } }).section.id
}

async function makeTable(ctx: Ctx, sectionId: string, name: string, seats = 4): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/tables',
    headers: ctx.admin,
    payload: { sectionId, name, seats },
  })
  if (res.statusCode !== 201) throw new Error(`table failed: ${res.body}`)
  return (res.json() as { table: { id: string } }).table.id
}

/** Inserts an open order directly — the orders API is the next build step. */
function seatParty(ctx: Ctx, tableId: string, orderNo: number, seatLabel: string | null): string {
  const id = randomUUID()
  const now = new Date().toISOString()
  ctx.db
    .prepare(
      `INSERT INTO orders (id, branch_id, order_no, business_date, type, table_id, seat_label,
                           status, version, created_by, created_at, updated_at)
       VALUES (?, ?, ?, '2026-09-01', 'dine_in', ?, ?, 'open', 1, ?, ?, ?)`,
    )
    .run(id, ctx.branchId, orderNo, tableId, seatLabel, ctx.userId, now, now)
  refreshTableStatus(ctx.db, tableId)
  return id
}

function closeOrder(ctx: Ctx, orderId: string, tableId: string): void {
  ctx.db.prepare("UPDATE orders SET status = 'billed' WHERE id = ?").run(orderId)
  refreshTableStatus(ctx.db, tableId)
}

function tableStatus(ctx: Ctx, tableId: string): string {
  return (ctx.db.prepare('SELECT status FROM tables WHERE id = ?').get(tableId) as { status: string })
    .status
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- sections ---

test('the seeded branch already has a Main section', async () => {
  // Tables require a section, so one must exist before any table can be created.
  const ctx = await setup()
  const res = await ctx.app.inject({ method: 'GET', url: '/sections', headers: ctx.admin })
  const sections = (res.json() as { sections: { name: string }[] }).sections
  assertEqual(sections.length, 1)
  assertEqual(sections[0]!.name, 'Main')
  await close(ctx)
})

test('an admin can create sections like AC and Non-AC', async () => {
  const ctx = await setup()
  await makeSection(ctx, 'AC')
  await makeSection(ctx, 'Terrace')

  const res = await ctx.app.inject({ method: 'GET', url: '/sections', headers: ctx.admin })
  const names = (res.json() as { sections: { name: string }[] }).sections.map((s) => s.name)
  assertEqual(names.join(','), 'Main,AC,Terrace')
  await close(ctx)
})

test('duplicate section names are rejected case-insensitively', async () => {
  const ctx = await setup()
  await makeSection(ctx, 'AC')
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/sections',
    headers: ctx.admin,
    payload: { name: 'ac' },
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a section holding tables cannot be deleted', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  await makeTable(ctx, section, 'A1')

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/sections/${section}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'SECTION_NOT_EMPTY')
  await close(ctx)
})

test('the last section cannot be deleted', async () => {
  // Every table belongs to a section; with none left, no table could be created.
  const ctx = await setup()
  const list = await ctx.app.inject({ method: 'GET', url: '/sections', headers: ctx.admin })
  const main = (list.json() as { sections: { id: string }[] }).sections[0]!.id

  const res = await ctx.app.inject({ method: 'DELETE', url: `/sections/${main}`, headers: ctx.admin })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'LAST_SECTION')
  await close(ctx)
})

// --- tables ---

test('a table is created free and in its section', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'A1', 6)

  const res = await ctx.app.inject({ method: 'GET', url: `/tables/${id}`, headers: ctx.admin })
  const table = (res.json() as { table: { status: string; seats: number; partyCount: number } }).table
  assertEqual(table.status, 'free')
  assertEqual(table.seats, 6)
  assertEqual(table.partyCount, 0)
  await close(ctx)
})

test('duplicate table names are rejected', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  await makeTable(ctx, section, 'T1')

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/tables',
    headers: ctx.admin,
    payload: { sectionId: section, name: 't1' },
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a table cannot be created in a section that does not exist', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/tables',
    headers: ctx.admin,
    payload: { sectionId: '00000000-0000-4000-8000-000000000000', name: 'Ghost' },
  })
  assertEqual(res.statusCode, 404)
  await close(ctx)
})

test('a table can be moved to another section', async () => {
  const ctx = await setup()
  const ac = await makeSection(ctx, 'AC')
  const terrace = await makeSection(ctx, 'Terrace')
  const id = await makeTable(ctx, ac, 'T1')

  await ctx.app.inject({
    method: 'PATCH',
    url: `/tables/${id}`,
    headers: ctx.admin,
    payload: { sectionId: terrace },
  })

  const res = await ctx.app.inject({ method: 'GET', url: `/tables/${id}`, headers: ctx.admin })
  assertEqual((res.json() as { table: { sectionId: string } }).table.sectionId, terrace)
  await close(ctx)
})

// --- status, derived from open orders ---

test('a table becomes occupied when its first order opens', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T1')

  assertEqual(tableStatus(ctx, id), 'free')
  seatParty(ctx, id, 1, 'A')
  assertEqual(tableStatus(ctx, id), 'occupied')
  await close(ctx)
})

test('a table stays occupied while a second party is still seated', async () => {
  // The rule that a bare `status = free` on settle would break.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T5')

  const first = seatParty(ctx, id, 1, 'A')
  seatParty(ctx, id, 2, 'B')
  assertEqual(tableStatus(ctx, id), 'occupied')

  closeOrder(ctx, first, id)
  assertEqual(tableStatus(ctx, id), 'occupied', 'party B is still eating')
  await close(ctx)
})

test('a table frees only when the last open order closes', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T5')

  const a = seatParty(ctx, id, 1, 'A')
  const b = seatParty(ctx, id, 2, 'B')
  closeOrder(ctx, a, id)
  closeOrder(ctx, b, id)

  assertEqual(tableStatus(ctx, id), 'free')
  await close(ctx)
})

test('the floor screen shows each seated party with its seat label', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T5')
  seatParty(ctx, id, 1, 'A')
  seatParty(ctx, id, 2, 'B')

  const res = await ctx.app.inject({ method: 'GET', url: '/floor', headers: ctx.cashier })
  const sections = (res.json() as {
    sections: { name: string; tables: { name: string; partyCount: number; parties: { seatLabel: string }[] }[] }[]
  }).sections

  const table = sections.flatMap((s) => s.tables).find((t) => t.name === 'T5')!
  assertEqual(table.partyCount, 2)
  assertEqual(table.parties.map((p) => p.seatLabel).join(','), 'A,B')
  await close(ctx)
})

test('a table with an open order cannot be deleted', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T1')
  seatParty(ctx, id, 1, null)

  const res = await ctx.app.inject({ method: 'DELETE', url: `/tables/${id}`, headers: ctx.admin })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'TABLE_IN_USE')
  await close(ctx)
})

test('a free table can be deleted', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'Spare')

  assertEqual(
    (await ctx.app.inject({ method: 'DELETE', url: `/tables/${id}`, headers: ctx.admin })).statusCode,
    200,
  )
  const list = await ctx.app.inject({ method: 'GET', url: '/tables', headers: ctx.admin })
  assertEqual((list.json() as { tables: unknown[] }).tables.length, 0)
  await close(ctx)
})

test('a client cannot set table status directly', async () => {
  // Status is derived from open orders; a client-set value would desync the floor.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T1')

  await ctx.app.inject({
    method: 'PATCH',
    url: `/tables/${id}`,
    headers: ctx.admin,
    payload: { status: 'occupied', seats: 8 },
  })

  assertEqual(tableStatus(ctx, id), 'free', 'the status field was ignored')
  const res = await ctx.app.inject({ method: 'GET', url: `/tables/${id}`, headers: ctx.admin })
  assertEqual((res.json() as { table: { seats: number } }).table.seats, 8, 'other fields applied')
  await close(ctx)
})

test('deleting a table releases it from any booking', async () => {
  // FR-V12: a reservation must not point at a table that no longer exists.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T9')

  const reservationId = randomUUID()
  const now = new Date().toISOString()
  ctx.db
    .prepare(
      `INSERT INTO reservations (id, branch_id, customer_name, party_size, reserved_at,
                                 business_date, status, created_by, created_at, updated_at)
       VALUES (?, ?, 'Ravi', 4, ?, '2026-09-01', 'booked', ?, ?, ?)`,
    )
    .run(reservationId, ctx.branchId, now, ctx.userId, now, now)
  ctx.db
    .prepare('INSERT INTO reservation_tables (reservation_id, table_id) VALUES (?, ?)')
    .run(reservationId, id)

  await ctx.app.inject({ method: 'DELETE', url: `/tables/${id}`, headers: ctx.admin })

  const links = ctx.db
    .prepare('SELECT COUNT(*) AS n FROM reservation_tables WHERE table_id = ?')
    .get(id) as { n: number }
  assertEqual(links.n, 0)
  await close(ctx)
})

test('a booked table shows as reserved, and occupied outranks it', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T7')

  const reservationId = randomUUID()
  const now = new Date().toISOString()
  ctx.db
    .prepare(
      `INSERT INTO reservations (id, branch_id, customer_name, party_size, reserved_at,
                                 business_date, status, created_by, created_at, updated_at)
       VALUES (?, ?, 'Priya', 2, ?, '2026-09-01', 'booked', ?, ?, ?)`,
    )
    .run(reservationId, ctx.branchId, now, ctx.userId, now, now)
  ctx.db
    .prepare('INSERT INTO reservation_tables (reservation_id, table_id) VALUES (?, ?)')
    .run(reservationId, id)

  refreshTableStatus(ctx.db, id)
  assertEqual(tableStatus(ctx, id), 'reserved')

  // A walk-in is warned but not blocked — and the table then reads occupied.
  seatParty(ctx, id, 1, null)
  assertEqual(tableStatus(ctx, id), 'occupied')
  await close(ctx)
})

test('a cashier can read the floor but not change tables', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  await makeTable(ctx, section, 'T1')

  assertEqual(
    (await ctx.app.inject({ method: 'GET', url: '/floor', headers: ctx.cashier })).statusCode,
    200,
  )
  assertEqual(
    (
      await ctx.app.inject({
        method: 'POST',
        url: '/tables',
        headers: ctx.cashier,
        payload: { sectionId: section, name: 'Sneaky' },
      })
    ).statusCode,
    403,
  )
  await close(ctx)
})

test('reordering tables rewrites their sort order', async () => {
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const a = await makeTable(ctx, section, 'A')
  const b = await makeTable(ctx, section, 'B')
  const c = await makeTable(ctx, section, 'C')

  await ctx.app.inject({
    method: 'POST',
    url: '/tables/reorder',
    headers: ctx.admin,
    payload: { ids: [c, b, a] },
  })

  const res = await ctx.app.inject({ method: 'GET', url: '/tables', headers: ctx.admin })
  const names = (res.json() as { tables: { name: string }[] }).tables.map((t) => t.name)
  assertEqual(names.join(','), 'C,B,A')
  await close(ctx)
})

test('tables can be filtered by section', async () => {
  const ctx = await setup()
  const ac = await makeSection(ctx, 'AC')
  const terrace = await makeSection(ctx, 'Terrace')
  await makeTable(ctx, ac, 'A1')
  await makeTable(ctx, terrace, 'T1')

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/tables?sectionId=${terrace}`,
    headers: ctx.admin,
  })
  const tables = (res.json() as { tables: { name: string }[] }).tables
  assertEqual(tables.length, 1)
  assertEqual(tables[0]!.name, 'T1')
  await close(ctx)
})

/** Adds a line to an order, so it stops counting as empty. */
function addLine(ctx: Ctx, orderId: string): void {
  const now = new Date().toISOString()
  // The column is a required foreign key. This suite seeds no menu, so one
  // variant is made on demand; the line's own values are snapshotted anyway.
  let variant = ctx.db
    .prepare('SELECT id FROM menu_item_variants LIMIT 1')
    .get() as { id: string } | undefined

  if (!variant) {
    const categoryId = randomUUID()
    const itemId = randomUUID()
    const variantId = randomUUID()
    ctx.db
      .prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, 'Tiffin', 0, 1, ?, ?)`,
      )
      .run(categoryId, ctx.branchId, now, now)
    ctx.db
      .prepare(
        `INSERT INTO menu_items (id, branch_id, category_id, name, tax_rate,
                                 is_available, sort_order, created_at, updated_at)
         VALUES (?, ?, ?, 'Idli', 500, 1, 0, ?, ?)`,
      )
      .run(itemId, ctx.branchId, categoryId, now, now)
    ctx.db
      .prepare(
        `INSERT INTO menu_item_variants (id, menu_item_id, name, price,
                                         is_available, sort_order, created_at, updated_at)
         VALUES (?, ?, 'Standard', 3000, 1, 0, ?, ?)`,
      )
      .run(variantId, itemId, now, now)
    variant = { id: variantId }
  }

  ctx.db
    .prepare(
      `INSERT INTO order_items (id, order_id, variant_id, item_name, variant_name,
                                unit_price, tax_rate, qty, line_base, line_tax,
                                line_total, created_at, updated_at)
       VALUES (?, ?, ?, 'Idli', 'Standard', 3000, 500, 1, 3000, 0, 3000, ?, ?)`,
    )
    .run(randomUUID(), orderId, variant.id, now, now)
}

test('a seated party reports how many items are on it', async () => {
  // The floor offers to free a table only when nothing was ordered. Without a
  // count it cannot tell a mis-tap from a party mid-meal.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T9')
  const empty = seatParty(ctx, id, 1, 'A')
  const fed = seatParty(ctx, id, 2, 'B')
  addLine(ctx, fed)
  addLine(ctx, fed)

  const res = await ctx.app.inject({ method: 'GET', url: '/floor', headers: ctx.cashier })
  const sections = (res.json() as {
    sections: { tables: { name: string; parties: { orderId: string; itemCount: number }[] }[] }[]
  }).sections
  const table = sections.flatMap((s) => s.tables).find((t) => t.name === 'T9')!

  const counts = new Map(table.parties.map((p) => [p.orderId, p.itemCount]))
  assertEqual(counts.get(empty), 0, 'nothing ordered')
  assertEqual(counts.get(fed), 2, 'two lines')
  await close(ctx)
})

test('a removed line stops counting towards the item count', async () => {
  // Otherwise a table where everything was taken back off the order could not
  // be freed, because it would still look occupied.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T10')
  const order = seatParty(ctx, id, 1, null)
  addLine(ctx, order)

  ctx.db
    .prepare('UPDATE order_items SET deleted_at = ? WHERE order_id = ?')
    .run(new Date().toISOString(), order)

  const res = await ctx.app.inject({ method: 'GET', url: '/floor', headers: ctx.cashier })
  const sections = (res.json() as {
    sections: { tables: { name: string; parties: { itemCount: number }[] }[] }[]
  }).sections
  const table = sections.flatMap((s) => s.tables).find((t) => t.name === 'T10')!
  assertEqual(table.parties[0]!.itemCount, 0)
  await close(ctx)
})

test('cancelling the empty order frees the table', async () => {
  // What "Free this table" does. The table must go back to free on its own,
  // from the order being cancelled — not by being set directly.
  const ctx = await setup()
  const section = await makeSection(ctx, 'AC')
  const id = await makeTable(ctx, section, 'T11')
  const order = seatParty(ctx, id, 1, null)
  assertEqual(tableStatus(ctx, id), 'occupied')

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order}/cancel`,
    headers: ctx.cashier,
    payload: { reason: 'Discarded before anything was ordered' },
  })
  assertEqual(res.statusCode, 200)
  assertEqual(tableStatus(ctx, id), 'free')
  await close(ctx)
})
