import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { OVERDUE_AFTER_MINUTES } from '../src/routes/reservations.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  admin: Record<string, string>
  cashier: Record<string, string>
  branchId: string
  sectionId: string
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

  const sectionId = (
    db.prepare('SELECT id FROM sections WHERE branch_id = ?').get(branchId) as { id: string }
  ).id

  return { app, db, admin, cashier, branchId, sectionId }
}

async function login(app: FastifyInstance, username: string, password: string) {
  const res = await app.inject({ method: 'POST', url: '/auth/login', payload: { username, password } })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
}

async function makeTable(ctx: Ctx, name: string, seats = 4): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/tables',
    headers: ctx.admin,
    payload: { sectionId: ctx.sectionId, name, seats },
  })
  if (res.statusCode !== 201) throw new Error(`table failed: ${res.body}`)
  return (res.json() as { table: { id: string } }).table.id
}

/**
 * Midday of the current *business* day.
 *
 * Not midday of the current calendar day. The trading day starts at 05:00, so
 * between midnight and 05:00 the business date is still yesterday's — and
 * midday by the wall clock then falls on the *next* business date. A booking
 * made there is invisible to a list query asking for today, and the suite
 * failed every night in that window and passed the rest of the day.
 *
 * Anchoring on the business date makes the hour the suite runs irrelevant.
 */
function atMidday(offsetMinutes = 0): string {
  const now = new Date()

  // Before the day starts, the business date is the previous calendar day.
  const [startHour, startMinute] = SEEDED_DAY_START.split(':').map(Number)
  const beforeDayStart =
    now.getHours() < startHour ||
    (now.getHours() === startHour && now.getMinutes() < startMinute)

  const when = new Date(now)
  if (beforeDayStart) when.setDate(when.getDate() - 1)
  when.setHours(12, 0, 0, 0)
  when.setMinutes(when.getMinutes() + offsetMinutes)
  return when.toISOString()
}

/** Matches the seeded `business_day_start`. */
const SEEDED_DAY_START = '05:00'

interface BookingResponse {
  reservation: {
    id: string
    status: string
    orderId: string | null
    tables: { id: string; name: string }[]
    isOverdue: boolean
    partySize: number
    notes: string | null
    seatCount: number
  }
  warnings: string[]
}

async function book(
  ctx: Ctx,
  tableIds: string[],
  overrides: Record<string, unknown> = {},
): Promise<BookingResponse> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/reservations',
    headers: ctx.cashier,
    payload: {
      customerName: 'Ravi',
      customerPhone: '9876543210',
      partySize: 4,
      reservedAt: atMidday(),
      tableIds,
      ...overrides,
    },
  })
  if (res.statusCode !== 201) throw new Error(`booking failed: ${res.body}`)
  return res.json() as BookingResponse
}

function tableStatus(ctx: Ctx, tableId: string): string {
  return (ctx.db.prepare('SELECT status FROM tables WHERE id = ?').get(tableId) as { status: string })
    .status
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- creating (FR-V1, FR-V2, FR-V3) ---

test('a booking records the customer, party size and time', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  const { reservation } = await book(ctx, [table])
  assertEqual(reservation.status, 'booked')
  assertEqual(reservation.partySize, 4)
  assertEqual(reservation.tables.length, 1)
  assertEqual(reservation.orderId, null)
  await close(ctx)
})

test('one booking holds several tables — a party of 12 is not three bookings', async () => {
  const ctx = await setup()
  const tables = [await makeTable(ctx, 'T1'), await makeTable(ctx, 'T2'), await makeTable(ctx, 'T3')]

  const { reservation } = await book(ctx, tables, { partySize: 12 })
  assertEqual(reservation.tables.length, 3)
  assertEqual(reservation.seatCount, 12, 'three 4-seat tables')

  const count = ctx.db.prepare('SELECT COUNT(*) AS n FROM reservations').get() as { n: number }
  assertEqual(count.n, 1, 'one booking, not three')
  await close(ctx)
})

test('booked tables show as reserved on the floor', async () => {
  const ctx = await setup()
  const one = await makeTable(ctx, 'T1')
  const two = await makeTable(ctx, 'T2')
  await book(ctx, [one, two])

  assertEqual(tableStatus(ctx, one), 'reserved')
  assertEqual(tableStatus(ctx, two), 'reserved')
  await close(ctx)
})

test('the same table listed twice books once', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table, table])
  assertEqual(reservation.tables.length, 1)
  await close(ctx)
})

test('a booking on a table that does not exist is refused', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/reservations',
    headers: ctx.cashier,
    payload: {
      customerName: 'Ravi',
      partySize: 2,
      reservedAt: atMidday(),
      tableIds: ['11111111-1111-4111-8111-111111111111'],
    },
  })
  assertEqual(res.statusCode, 404)
  await close(ctx)
})

test('a booking with no name is refused', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/reservations',
    headers: ctx.cashier,
    // Whitespace, not empty: `.min(1)` before `.trim()` would let this through.
    payload: { customerName: '   ', partySize: 2, reservedAt: atMidday(), tableIds: [table] },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

test('a booking with no tables is refused', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/reservations',
    headers: ctx.cashier,
    payload: { customerName: 'Ravi', partySize: 2, reservedAt: atMidday(), tableIds: [] },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

// --- the day's list (FR-V4) ---

test("today's bookings come back in time order, not entry order", async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  await book(ctx, [table], { customerName: 'Late', reservedAt: atMidday(120) })
  await book(ctx, [table], { customerName: 'Early', reservedAt: atMidday(-120) })

  const res = await ctx.app.inject({ method: 'GET', url: '/reservations', headers: ctx.cashier })
  const names = (res.json() as { reservations: { customerName: string }[] }).reservations.map(
    (r) => r.customerName,
  )
  assertEqual(names.join(','), 'Early,Late')
  await close(ctx)
})

test('the list summarises covers and counts by status', async () => {
  const ctx = await setup()
  const one = await makeTable(ctx, 'T1')
  const two = await makeTable(ctx, 'T2')

  await book(ctx, [one], { partySize: 4 })
  const cancelled = await book(ctx, [two], { partySize: 6 })
  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${cancelled.reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  const res = await ctx.app.inject({ method: 'GET', url: '/reservations', headers: ctx.cashier })
  const summary = (res.json() as { summary: Record<string, number> }).summary
  assertEqual(summary.booked, 1)
  assertEqual(summary.cancelled, 1)
  // A cancelled booking is not a cover the kitchen should expect.
  assertEqual(summary.covers, 4)
  await close(ctx)
})

test('a booking is filed on the trading day of its time, not the day it was entered', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  // 1 AM belongs to the previous trading day under the 5 AM cutoff.
  const oneAm = new Date()
  oneAm.setHours(1, 0, 0, 0)
  const { reservation } = await book(ctx, [table], { reservedAt: oneAm.toISOString() })

  const expected = new Date(oneAm)
  expected.setDate(expected.getDate() - 1)
  const yyyymmdd = `${expected.getFullYear()}-${String(expected.getMonth() + 1).padStart(2, '0')}-${String(expected.getDate()).padStart(2, '0')}`

  const row = ctx.db
    .prepare('SELECT business_date FROM reservations WHERE id = ?')
    .get(reservation.id) as { business_date: string }
  assertEqual(row.business_date, yyyymmdd)
  await close(ctx)
})

// --- seating (FR-V5) ---

test('seating a booking opens an order and occupies the table', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  assertEqual(res.statusCode, 200)

  const body = res.json() as { reservation: { status: string; orderId: string }; orderId: string }
  assertEqual(body.reservation.status, 'seated')
  assertEqual(body.reservation.orderId, body.orderId)
  assertEqual(tableStatus(ctx, table), 'occupied')

  const order = ctx.db
    .prepare('SELECT status, type, customer_name FROM orders WHERE id = ?')
    .get(body.orderId) as { status: string; type: string; customer_name: string }
  assertEqual(order.status, 'open')
  assertEqual(order.type, 'dine_in')
  // The customer carries across, so the bill shows who it belongs to.
  assertEqual(order.customer_name, 'Ravi')
  await close(ctx)
})

test('seating a multi-table booking frees the tables the party did not take', async () => {
  const ctx = await setup()
  const one = await makeTable(ctx, 'T1')
  const two = await makeTable(ctx, 'T2')
  const { reservation } = await book(ctx, [one, two])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: { tableId: one },
  })

  assertEqual(tableStatus(ctx, one), 'occupied')
  // Held only by a booking that is no longer `booked`, so it is bookable again
  // rather than stranded as reserved for the rest of the night.
  assertEqual(tableStatus(ctx, two), 'free')
  await close(ctx)
})

test('a booking cannot be seated at a table it does not hold', async () => {
  const ctx = await setup()
  const booked = await makeTable(ctx, 'T1')
  const other = await makeTable(ctx, 'T2')
  const { reservation } = await book(ctx, [booked])

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: { tableId: other },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

test('seating twice is refused rather than opening a second order', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  const url = `/reservations/${reservation.id}/seat`
  await ctx.app.inject({ method: 'POST', url, headers: ctx.cashier, payload: {} })
  const second = await ctx.app.inject({ method: 'POST', url, headers: ctx.cashier, payload: {} })

  assertEqual(second.statusCode, 409)
  const orders = ctx.db.prepare('SELECT COUNT(*) AS n FROM orders').get() as { n: number }
  assertEqual(orders.n, 1)
  await close(ctx)
})

test('a cancelled booking cannot be seated', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })
  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

// --- no-show and cancel (FR-V6) ---

test('marking a no-show releases the table', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])
  assertEqual(tableStatus(ctx, table), 'reserved')

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/no-show`,
    headers: ctx.cashier,
    payload: {},
  })
  assertEqual(res.statusCode, 200)
  assertEqual((res.json() as BookingResponse).reservation.status, 'no_show')
  assertEqual(tableStatus(ctx, table), 'free')
  await close(ctx)
})

test('cancelling releases the table and keeps the reason', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table], { notes: 'window seat' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: { reason: 'called to cancel' },
  })

  const body = res.json() as BookingResponse
  assertEqual(body.reservation.status, 'cancelled')
  assertEqual(body.reservation.notes, 'window seat — Cancelled: called to cancel')
  assertEqual(tableStatus(ctx, table), 'free')
  await close(ctx)
})

test('cancelling does not free a table another booking still holds', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const first = await book(ctx, [table], { reservedAt: atMidday() })
  await book(ctx, [table], { customerName: 'Later', reservedAt: atMidday(180) })

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${first.reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  assertEqual(tableStatus(ctx, table), 'reserved', 'the evening booking still holds it')
  await close(ctx)
})

test('a seated booking cannot be marked a no-show', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/no-show`,
    headers: ctx.cashier,
    payload: {},
  })
  assertEqual(res.statusCode, 409)
  // The table stays occupied — the party is sitting there.
  assertEqual(tableStatus(ctx, table), 'occupied')
  await close(ctx)
})

// --- walk-ins warn but are never blocked (FR-V7) ---

test('a walk-in on a booked table is seated, with a warning', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  await book(ctx, [table], { customerName: 'Priya' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: { type: 'dine_in', tableId: table },
  })

  assertEqual(res.statusCode, 201, 'the walk-in is seated, not refused')
  const warnings = (res.json() as { warnings: string[] }).warnings
  assertEqual(warnings.length, 1)
  assertEqual(warnings[0]!.includes('Priya'), true)
  await close(ctx)
})

test('a walk-in is not warned about a booking that was cancelled', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table], { customerName: 'Priya' })

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: { type: 'dine_in', tableId: table },
  })
  // The link row survives cancellation for reporting, so the status filter is
  // the only thing keeping a dead booking from warning about a free table.
  assertEqual((res.json() as { warnings: string[] }).warnings.length, 0)
  await close(ctx)
})

test('a walk-in on a free table warns about nothing', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: { type: 'dine_in', tableId: table },
  })
  assertEqual((res.json() as { warnings: string[] }).warnings.length, 0)
  await close(ctx)
})

// --- editing (FR-V8) ---

test('a booking can be edited while it is still booked', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  const res = await ctx.app.inject({
    method: 'PATCH',
    url: `/reservations/${reservation.id}`,
    headers: ctx.cashier,
    payload: { partySize: 8, customerName: 'Ravi Kumar' },
  })

  const body = res.json() as BookingResponse
  assertEqual(body.reservation.partySize, 8)
  await close(ctx)
})

test('changing the table list frees the old table and reserves the new one', async () => {
  const ctx = await setup()
  const one = await makeTable(ctx, 'T1')
  const two = await makeTable(ctx, 'T2')
  const { reservation } = await book(ctx, [one])
  assertEqual(tableStatus(ctx, one), 'reserved')

  await ctx.app.inject({
    method: 'PATCH',
    url: `/reservations/${reservation.id}`,
    headers: ctx.cashier,
    payload: { tableIds: [two] },
  })

  assertEqual(tableStatus(ctx, one), 'free', 'the dropped table is bookable again')
  assertEqual(tableStatus(ctx, two), 'reserved')
  await close(ctx)
})

test('a seated booking can no longer be edited', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: `/reservations/${reservation.id}`,
    headers: ctx.cashier,
    payload: { partySize: 2 },
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

// --- kept for reporting (FR-V9) ---

test('a cancelled booking stays in the record', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  const row = ctx.db
    .prepare('SELECT status, deleted_at FROM reservations WHERE id = ?')
    .get(reservation.id) as { status: string; deleted_at: string | null }
  assertEqual(row.status, 'cancelled')
  assertEqual(row.deleted_at, null, 'cancelled is a status, not a deletion')
  await close(ctx)
})

test('removing a booking soft-deletes it and frees its table', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/reservations/${reservation.id}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 200)

  const row = ctx.db
    .prepare('SELECT deleted_at FROM reservations WHERE id = ?')
    .get(reservation.id) as { deleted_at: string | null }
  assertEqual(row.deleted_at === null, false, 'the row survives, flagged deleted')
  assertEqual(tableStatus(ctx, table), 'free')
  await close(ctx)
})

test('a seated booking cannot be removed — it is part of the day', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/reservations/${reservation.id}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a cashier cannot remove a booking', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/reservations/${reservation.id}`,
    headers: ctx.cashier,
  })
  assertEqual(res.statusCode, 403)
  await close(ctx)
})

// --- overlapping bookings warn (FR-V10) ---

test('booking a table already booked for a nearby time warns', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  await book(ctx, [table], { customerName: 'Priya' })

  const second = await book(ctx, [table], { customerName: 'Ravi', reservedAt: atMidday(30) })
  assertEqual(second.warnings.length, 1)
  assertEqual(second.warnings[0]!.includes('Priya'), true)

  // A warning, not a refusal — the booking is saved.
  const count = ctx.db.prepare('SELECT COUNT(*) AS n FROM reservations').get() as { n: number }
  assertEqual(count.n, 2)
  await close(ctx)
})

test('a booking hours later on the same table does not warn', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  await book(ctx, [table], { customerName: 'Priya' })

  const second = await book(ctx, [table], { customerName: 'Ravi', reservedAt: atMidday(240) })
  assertEqual(second.warnings.length, 0, 'lunch and dinner do not clash')
  await close(ctx)
})

test('a cancelled booking no longer clashes with a new one', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const first = await book(ctx, [table], { customerName: 'Priya' })

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${first.reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  const second = await book(ctx, [table], { customerName: 'Ravi', reservedAt: atMidday(30) })
  assertEqual(second.warnings.length, 0)
  await close(ctx)
})

// --- overdue (FR-V11) ---

test('a booking well past its time is flagged overdue', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  const late = new Date(Date.now() - (OVERDUE_AFTER_MINUTES + 10) * 60_000)
  const { reservation } = await book(ctx, [table], { reservedAt: late.toISOString() })
  assertEqual(reservation.isOverdue, true)
  await close(ctx)
})

test('a booking a few minutes late is not yet chased', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  const late = new Date(Date.now() - (OVERDUE_AFTER_MINUTES - 5) * 60_000)
  const { reservation } = await book(ctx, [table], { reservedAt: late.toISOString() })
  assertEqual(reservation.isOverdue, false)
  await close(ctx)
})

test('a seated booking is never overdue, however late the party was', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')

  const late = new Date(Date.now() - 180 * 60_000)
  const { reservation } = await book(ctx, [table], { reservedAt: late.toISOString() })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  assertEqual((res.json() as BookingResponse).reservation.isOverdue, false)
  await close(ctx)
})

// --- deleting a table a booking holds (FR-V12) ---

test('deleting a booked table warns and drops it from the booking', async () => {
  const ctx = await setup()
  const one = await makeTable(ctx, 'T1')
  const two = await makeTable(ctx, 'T2')
  const { reservation } = await book(ctx, [one, two], { customerName: 'Priya' })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/tables/${one}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 200)

  const warnings = (res.json() as { warnings: string[] }).warnings
  assertEqual(warnings.length, 1)
  assertEqual(warnings[0]!.includes('Priya'), true)

  const after = await ctx.app.inject({
    method: 'GET',
    url: `/reservations/${reservation.id}`,
    headers: ctx.cashier,
  })
  const tables = (after.json() as BookingResponse).reservation.tables
  assertEqual(tables.length, 1, 'the booking keeps its remaining table')
  await close(ctx)
})

test('deleting a table says nothing about bookings already cancelled', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table], { customerName: 'Priya' })

  await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/cancel`,
    headers: ctx.cashier,
    payload: {},
  })

  const res = await ctx.app.inject({ method: 'DELETE', url: `/tables/${table}`, headers: ctx.admin })
  // Nobody needs chasing about a table lost from a booking that is not happening.
  assertEqual((res.json() as { warnings: string[] }).warnings.length, 0)
  await close(ctx)
})

test('a booking whose tables were all deleted cannot be seated', async () => {
  const ctx = await setup()
  const table = await makeTable(ctx, 'T1')
  const { reservation } = await book(ctx, [table])

  await ctx.app.inject({ method: 'DELETE', url: `/tables/${table}`, headers: ctx.admin })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/reservations/${reservation.id}/seat`,
    headers: ctx.cashier,
    payload: {},
  })
  // Refused with an explanation rather than crashing on an empty table list.
  assertEqual(res.statusCode, 409)
  await close(ctx)
})
