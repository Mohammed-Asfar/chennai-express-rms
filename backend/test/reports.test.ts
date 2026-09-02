import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { setSetting } from '../src/lib/settings.js'
import { currentBusinessDate } from '../src/lib/business-date.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  branchId: string
  admin: Record<string, string>
  cashier: Record<string, string>
  cashierId: string
  tableId: string
  sectionId: string
  today: string
  full: string
  tea: string
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  setSetting(db, branchId, 'tax_mode', 'exclusive')
  setSetting(db, branchId, 'round_off_enabled', '0')

  const app = await buildServer({ db, env })
  const admin = await login(app, 'admin', 'admin123')
  await app.inject({
    method: 'POST',
    url: '/users',
    headers: admin,
    payload: { username: 'cash', password: 'cash123', fullName: 'Cash Desk', role: 'cashier' },
  })
  const cashier = await login(app, 'cash', 'cash123')
  const cashierId = (
    db.prepare('SELECT id FROM users WHERE username = ?').get('cash') as { id: string }
  ).id

  const sections = await app.inject({ method: 'GET', url: '/sections', headers: admin })
  const sectionId = (sections.json() as { sections: { id: string }[] }).sections[0]!.id
  const table = await app.inject({
    method: 'POST',
    url: '/tables',
    headers: admin,
    payload: { sectionId, name: 'T1' },
  })
  const tableId = (table.json() as { table: { id: string } }).table.id

  const category = await app.inject({
    method: 'POST',
    url: '/categories',
    headers: admin,
    payload: { name: 'Food' },
  })
  const categoryId = (category.json() as { category: { id: string } }).category.id

  const make = async (name: string, price: number): Promise<string> => {
    const res = await app.inject({
      method: 'POST',
      url: '/menu-items',
      headers: admin,
      payload: { categoryId, name, price },
    })
    return (res.json() as { item: { variants: { id: string }[] } }).item.variants[0]!.id
  }

  return {
    app,
    db,
    branchId,
    admin,
    cashier,
    cashierId,
    tableId,
    sectionId,
    today: currentBusinessDate(db, branchId),
    full: await make('Chicken Biryani', 32_000),
    tea: await make('Masala Tea', 2_000),
  }
}

async function login(app: FastifyInstance, username: string, password: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username, password },
  })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
}

interface BillPayload {
  id: string
  billNumber: string
  businessDate: string
  total: number
  discountAmount: number
  amountPaid: number
  outstanding: number
  paymentStatus: string
  payments: { id: string; mode: string; amount: number }[]
}

async function makeOrder(
  ctx: Ctx,
  lines: { variantId: string; qty: number }[],
  options: { dineIn?: boolean; headers?: Record<string, string> } = {},
): Promise<string> {
  const headers = options.headers ?? ctx.cashier
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers,
    payload: options.dineIn ? { type: 'dine_in', tableId: ctx.tableId } : { type: 'takeaway' },
  })
  const orderId = (res.json() as { order: { id: string } }).order.id

  for (const line of lines) {
    await ctx.app.inject({
      method: 'POST',
      url: `/orders/${orderId}/items`,
      headers,
      payload: { variantId: line.variantId, qty: line.qty },
    })
  }
  return orderId
}

async function makeBill(
  ctx: Ctx,
  orderId: string,
  payload: Record<string, unknown> = {},
  headers?: Record<string, string>,
): Promise<BillPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: headers ?? ctx.cashier,
    payload: { orderId, ...payload },
  })
  if (res.statusCode !== 201) throw new Error(`bill failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { bill: BillPayload }).bill
}

async function pay(
  ctx: Ctx,
  billId: string,
  payload: Record<string, unknown>,
): Promise<BillPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${billId}/payments`,
    headers: ctx.cashier,
    payload,
  })
  if (res.statusCode !== 201) throw new Error(`payment failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { bill: BillPayload }).bill
}

/**
 * Backdates a bill and its order to another trading day.
 *
 * The route always stamps today, so a multi-day report cannot be built through
 * the API alone.
 */
function moveBillToDate(ctx: Ctx, billId: string, businessDate: string): void {
  const bill = ctx.db.prepare('SELECT order_id FROM bills WHERE id = ?').get(billId) as {
    order_id: string
  }
  ctx.db.prepare('UPDATE bills SET business_date = ? WHERE id = ?').run(businessDate, billId)
  ctx.db
    .prepare('UPDATE orders SET business_date = ? WHERE id = ?')
    .run(businessDate, bill.order_id)
  ctx.db
    .prepare('UPDATE payments SET business_date = ? WHERE bill_id = ?')
    .run(businessDate, billId)
}

/** Moves only the payment, leaving the sale where it was. */
function movePaymentToDate(ctx: Ctx, paymentId: string, businessDate: string): void {
  ctx.db.prepare('UPDATE payments SET business_date = ? WHERE id = ?').run(businessDate, paymentId)
}

interface Summary {
  range: { from: string; to: string }
  sales: {
    billCount: number
    totalSales: number
    averageBillValue: number
    discountTotal: number
    collected: number
    outstanding: number
  }
  collections: { total: number; byMode: { mode: string; count: number; amount: number }[] }
  byOrderType: { type: string; billCount: number; totalSales: number }[]
  bySection: { sectionId: string | null; sectionName: string | null; totalSales: number }[]
  discounts: {
    total: number
    byUser: { userId: string; username: string; fullName: string; discountTotal: number }[]
  }
  voided: { billCount: number; total: number; bills: { billNumber: string; reason: string }[] }
  cancelled: { orderCount: number; total: number; orders: { orderNo: number; value: number }[] }
}

async function summary(ctx: Ctx, query = ''): Promise<Summary> {
  const res = await ctx.app.inject({
    method: 'GET',
    url: `/reports/summary${query}`,
    headers: ctx.admin,
  })
  if (res.statusCode !== 200) throw new Error(`summary failed: ${res.statusCode} ${res.body}`)
  return res.json() as Summary
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- FR-R1, FR-R12: daily summary ---

test('the daily summary totals sales, counts bills and averages them', async () => {
  const ctx = await setup()
  // 32000 + 5% = 33600, twice; 2000 + 5% = 2100.
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  const report = await summary(ctx)
  assertEqual(report.sales.billCount, 3)
  assertEqual(report.sales.totalSales, 69_300)
  assertEqual(report.sales.averageBillValue, 23_100)
  assertEqual(report.range.from, ctx.today, 'the report states the business day it covers')
  assertEqual(report.range.to, ctx.today)
  await close(ctx)
})

test('a day with no bills reports zero rather than dividing by zero', async () => {
  const ctx = await setup()
  const report = await summary(ctx)
  assertEqual(report.sales.billCount, 0)
  assertEqual(report.sales.totalSales, 0)
  assertEqual(report.sales.averageBillValue, 0)
  await close(ctx)
})

// --- FR-R2: date ranges ---

test('a range spans several business days, and a single day excludes the rest', async () => {
  const ctx = await setup()
  const monday = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const tuesday = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  moveBillToDate(ctx, monday.id, '2026-03-02')
  moveBillToDate(ctx, tuesday.id, '2026-03-03')

  const span = await summary(ctx, '?from=2026-03-02&to=2026-03-03')
  assertEqual(span.sales.billCount, 2)
  assertEqual(span.sales.totalSales, 35_700)

  const oneDay = await summary(ctx, '?from=2026-03-02&to=2026-03-02')
  assertEqual(oneDay.sales.billCount, 1)
  assertEqual(oneDay.sales.totalSales, 33_600)

  const outside = await summary(ctx, '?from=2026-03-04&to=2026-03-05')
  assertEqual(outside.sales.billCount, 0)
  await close(ctx)
})

// --- FR-R4: payment modes ---

test('a split bill counts in both payment modes and sums to the bill', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await pay(ctx, bill.id, { mode: 'cash', amount: 20_000 })
  await pay(ctx, bill.id, { mode: 'upi', amount: 13_600 })

  const report = await summary(ctx)
  const byMode = new Map(report.collections.byMode.map((row) => [row.mode, row.amount]))
  assertEqual(byMode.get('cash'), 20_000)
  assertEqual(byMode.get('upi'), 13_600)
  assertEqual(report.collections.total, 33_600, 'the two modes sum back to the bill')
  await close(ctx)
})

// --- FR-R5: cash date is not the sale date ---

test('cash collection follows the payment business date, not the bill date', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: 33_600 })

  // The sale stays on Monday; the money arrives on Wednesday.
  moveBillToDate(ctx, bill.id, '2026-03-02')
  movePaymentToDate(ctx, paid.payments[0]!.id, '2026-03-04')

  const monday = await summary(ctx, '?from=2026-03-02&to=2026-03-02')
  assertEqual(monday.sales.totalSales, 33_600, 'the sale is Monday’s')
  assertEqual(monday.collections.total, 0, 'no cash came in on Monday')

  const wednesday = await summary(ctx, '?from=2026-03-04&to=2026-03-04')
  assertEqual(wednesday.sales.totalSales, 0, 'no sale happened on Wednesday')
  assertEqual(wednesday.collections.total, 33_600, 'the cash is Wednesday’s')
  await close(ctx)
})

test('a reversed payment does not count toward collections', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: 33_600 })

  const reversal = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'card, not cash' },
  })
  assertEqual(reversal.statusCode, 200)
  await pay(ctx, bill.id, { mode: 'card', amount: 33_600 })

  const report = await summary(ctx)
  assertEqual(report.collections.total, 33_600, 'only the corrected payment counts')
  const byMode = new Map(report.collections.byMode.map((row) => [row.mode, row.amount]))
  assertEqual(byMode.get('cash'), undefined)
  assertEqual(byMode.get('card'), 33_600)
  await close(ctx)
})

// --- FR-R9, FR-R11: voided and cancelled ---

test('a voided bill leaves sales but still appears in the voided report', async () => {
  const ctx = await setup()
  const kept = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const doomed = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  const voided = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${doomed.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'rung up twice' },
  })
  assertEqual(voided.statusCode, 200)

  const report = await summary(ctx)
  assertEqual(report.sales.billCount, 1, 'only the live bill is a sale')
  assertEqual(report.sales.totalSales, kept.total)
  assertEqual(report.voided.billCount, 1)
  assertEqual(report.voided.total, 2_100)
  assertEqual(report.voided.bills[0]!.reason, 'rung up twice')
  await close(ctx)
})

test('a cancelled order is reported with its value, not silently dropped', async () => {
  const ctx = await setup()
  const orderId = await makeOrder(ctx, [{ variantId: ctx.full, qty: 2 }])
  const cancelled = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${orderId}/cancel`,
    headers: ctx.cashier,
    payload: { reason: 'walked out' },
  })
  assertEqual(cancelled.statusCode, 200)

  const report = await summary(ctx)
  assertEqual(report.sales.billCount, 0)
  assertEqual(report.cancelled.orderCount, 1)
  assertEqual(report.cancelled.total, 67_200, 'the lines were worth this when it was killed')
  await close(ctx)
})

// --- FR-R7, FR-R8: order type and section ---

test('dine-in and takeaway are split, and takeaway has no section', async () => {
  const ctx = await setup()
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }], { dineIn: true }))
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  const report = await summary(ctx)
  const byType = new Map(report.byOrderType.map((row) => [row.type, row]))
  assertEqual(byType.get('dine_in')!.billCount, 1)
  assertEqual(byType.get('dine_in')!.totalSales, 33_600)
  assertEqual(byType.get('takeaway')!.billCount, 1)
  assertEqual(byType.get('takeaway')!.totalSales, 2_100)

  const seated = report.bySection.find((row) => row.sectionId !== null)
  assertEqual(seated!.totalSales, 33_600)
  const unseated = report.bySection.find((row) => row.sectionId === null)
  assertEqual(unseated!.sectionName, null, 'takeaway belongs to no section')
  assertEqual(unseated!.totalSales, 2_100)
  assertEqual(
    report.bySection.reduce((sum, row) => sum + row.totalSales, 0),
    report.sales.totalSales,
    'the sections sum back to total sales',
  )
  await close(ctx)
})

// --- FR-R10: discounts by user ---

test('a discount is reported against the user who applied it', async () => {
  const ctx = await setup()
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]), {
    discountType: 'fixed',
    discountValue: 2_000,
  })
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  const report = await summary(ctx)
  assertEqual(report.discounts.total, 2_000)
  assertEqual(report.discounts.byUser.length, 1, 'the undiscounted bill adds no row')
  assertEqual(report.discounts.byUser[0]!.username, 'cash')
  assertEqual(report.discounts.byUser[0]!.fullName, 'Cash Desk')
  assertEqual(report.discounts.byUser[0]!.userId, ctx.cashierId)
  assertEqual(report.discounts.byUser[0]!.discountTotal, 2_000)
  await close(ctx)
})

// --- FR-R3: item-wise ---

test('item-wise sales aggregate quantity and revenue across bills', async () => {
  const ctx = await setup()
  await makeBill(ctx, await makeOrder(ctx, [
    { variantId: ctx.full, qty: 2 },
    { variantId: ctx.tea, qty: 1 },
  ]))
  await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const res = await ctx.app.inject({ method: 'GET', url: '/reports/items', headers: ctx.admin })
  assertEqual(res.statusCode, 200)
  const body = res.json() as {
    range: { from: string; to: string }
    items: { itemName: string; qty: number; revenue: number; gross: number }[]
    totals: { qty: number; revenue: number }
  }

  const biryani = body.items.find((row) => row.itemName === 'Chicken Biryani')!
  assertEqual(biryani.qty, 3, 'both bills contribute')
  assertEqual(biryani.revenue, 96_000)
  assertEqual(biryani.gross, 100_800)

  const tea = body.items.find((row) => row.itemName === 'Masala Tea')!
  assertEqual(tea.qty, 1)
  assertEqual(tea.revenue, 2_000)

  assertEqual(body.totals.qty, 4)
  assertEqual(body.totals.revenue, 98_000)
  assertEqual(body.range.from, ctx.today)
  await close(ctx)
})

test('item-wise sales exclude a voided bill', async () => {
  const ctx = await setup()
  const doomed = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${doomed.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'mistake' },
  })

  const res = await ctx.app.inject({ method: 'GET', url: '/reports/items', headers: ctx.admin })
  assertEqual((res.json() as { items: unknown[] }).items.length, 0)
  await close(ctx)
})

// --- FR-R6: outstanding ---

test('outstanding lists a partly-paid bill with its balance and age', async () => {
  const ctx = await setup()
  const partial = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await pay(ctx, partial.id, { mode: 'cash', amount: 10_000 })

  const settled = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  await pay(ctx, settled.id, { mode: 'cash', amount: settled.total })

  const res = await ctx.app.inject({
    method: 'GET',
    url: '/reports/outstanding',
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 200)
  const body = res.json() as {
    asOf: string
    billCount: number
    total: number
    bills: { id: string; outstanding: number; paymentStatus: string; ageDays: number }[]
  }

  assertEqual(body.billCount, 1, 'a paid bill is not outstanding')
  assertEqual(body.bills[0]!.id, partial.id)
  assertEqual(body.bills[0]!.outstanding, 23_600)
  assertEqual(body.bills[0]!.paymentStatus, 'partial')
  assertEqual(body.bills[0]!.ageDays, 0)
  assertEqual(body.total, 23_600)
  assertEqual(body.asOf, ctx.today)
  await close(ctx)
})

test('an older unpaid bill is aged in days and still listed', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const threeDaysAgo = new Date(`${ctx.today}T00:00:00Z`)
  threeDaysAgo.setUTCDate(threeDaysAgo.getUTCDate() - 3)
  moveBillToDate(ctx, bill.id, threeDaysAgo.toISOString().slice(0, 10))

  const res = await ctx.app.inject({
    method: 'GET',
    url: '/reports/outstanding',
    headers: ctx.admin,
  })
  const body = res.json() as { billCount: number; bills: { ageDays: number }[] }
  assertEqual(body.billCount, 1, 'an old debt is still owed today')
  assertEqual(body.bills[0]!.ageDays, 3)
  await close(ctx)
})

// --- access ---

test('reports are admin-only', async () => {
  const ctx = await setup()
  for (const url of ['/reports/summary', '/reports/items', '/reports/outstanding']) {
    const res = await ctx.app.inject({ method: 'GET', url, headers: ctx.cashier })
    assertEqual(res.statusCode, 403, `${url} must refuse a cashier`)
  }
  await close(ctx)
})

test('a malformed date is rejected rather than silently ignored', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'GET',
    url: '/reports/summary?from=last-tuesday',
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

// --- daily series ---

interface Daily {
  range: { from: string; to: string }
  days: { businessDate: string; billCount: number; totalSales: number; collected: number }[]
}

async function daily(ctx: Ctx, query = ''): Promise<Daily> {
  const res = await ctx.app.inject({
    method: 'GET',
    url: `/reports/daily${query}`,
    headers: ctx.admin,
  })
  if (res.statusCode !== 200) throw new Error(`daily failed: ${res.statusCode} ${res.body}`)
  return res.json() as Daily
}

test('the daily series returns one row per business day, in order', async () => {
  const ctx = await setup()
  const first = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  const second = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  moveBillToDate(ctx, first.id, '2026-03-02')
  moveBillToDate(ctx, second.id, '2026-03-04')

  const report = await daily(ctx, '?from=2026-03-02&to=2026-03-04')
  assertEqual(report.days.length, 3, 'three days requested, three rows returned')
  assertEqual(report.days[0]!.businessDate, '2026-03-02')
  assertEqual(report.days[1]!.businessDate, '2026-03-03')
  assertEqual(report.days[2]!.businessDate, '2026-03-04')
  assertEqual(report.days[0]!.totalSales, 33_600)
  assertEqual(report.days[2]!.totalSales, 2_100)
  await close(ctx)
})

test('a closed day is an explicit zero row, not a gap in the series', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  moveBillToDate(ctx, bill.id, '2026-03-02')

  // A missing 3 March would be drawn as a straight line across a shut door.
  const report = await daily(ctx, '?from=2026-03-02&to=2026-03-03')
  assertEqual(report.days.length, 2)
  assertEqual(report.days[1]!.businessDate, '2026-03-03')
  assertEqual(report.days[1]!.billCount, 0)
  assertEqual(report.days[1]!.totalSales, 0)
  assertEqual(report.days[1]!.collected, 0)
  await close(ctx)
})

test('the daily totals sum back to the summary for the same range', async () => {
  const ctx = await setup()
  const first = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 2 }]))
  const second = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 3 }]))
  await pay(ctx, second.id, { mode: 'cash', amount: 6_300 })
  moveBillToDate(ctx, first.id, '2026-03-02')
  moveBillToDate(ctx, second.id, '2026-03-03')

  const query = '?from=2026-03-01&to=2026-03-05'
  const series = await daily(ctx, query)
  const totals = await summary(ctx, query)

  const summed = series.days.reduce((sum, day) => sum + day.totalSales, 0)
  const bills = series.days.reduce((sum, day) => sum + day.billCount, 0)
  const collected = series.days.reduce((sum, day) => sum + day.collected, 0)

  assertEqual(summed, totals.sales.totalSales, 'the series must reconcile with the headline')
  assertEqual(bills, totals.sales.billCount)
  assertEqual(collected, totals.sales.collected)
  await close(ctx)
})

test('the daily series is admin-only and validates its dates', async () => {
  const ctx = await setup()
  const refused = await ctx.app.inject({
    method: 'GET',
    url: '/reports/daily',
    headers: ctx.cashier,
  })
  assertEqual(refused.statusCode, 403)

  const malformed = await ctx.app.inject({
    method: 'GET',
    url: '/reports/daily?from=last-tuesday',
    headers: ctx.admin,
  })
  assertEqual(malformed.statusCode, 400)
  await close(ctx)
})
