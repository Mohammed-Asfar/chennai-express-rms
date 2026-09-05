/**
 * Amending a bill that already exists.
 *
 * The bill is overwritten in place: same number, new totals, no second
 * document. What that costs is the original figures, so every amendment writes
 * a `bill_amendments` row holding the whole bill before and after — the only
 * place the original total survives once `bills` has moved on.
 */
import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { setSetting } from '../src/lib/settings.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  admin: Record<string, string>
  cashier: Record<string, string>
  /** Chicken Biryani at 320.00, no tax. */
  full: string
  /** Masala Tea at 20.00, no tax. */
  tea: string
  /** Bottled Water at 40.00, taxed at 18%. */
  water: string
}

async function login(app: FastifyInstance, username: string, password: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username, password },
  })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
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
    payload: { username: 'cash', password: 'cash123', fullName: 'Cash', role: 'cashier' },
  })
  const cashier = await login(app, 'cash', 'cash123')

  const category = await app.inject({
    method: 'POST',
    url: '/categories',
    headers: admin,
    payload: { name: 'Food' },
  })
  const categoryId = (category.json() as { category: { id: string } }).category.id

  // taxRate is passed explicitly, including the zero: leaving it out falls back
  // to the branch's default_tax_rate, and these tests are about what a discount
  // does to a total rather than about the branch's tax settings.
  const make = async (name: string, price: number, taxRate = 0): Promise<string> => {
    const res = await app.inject({
      method: 'POST',
      url: '/menu-items',
      headers: admin,
      payload: { categoryId, name, price, taxRate },
    })
    return (res.json() as { item: { variants: { id: string }[] } }).item.variants[0]!.id
  }

  return {
    app,
    db,
    admin,
    cashier,
    full: await make('Chicken Biryani', 32_000),
    tea: await make('Masala Tea', 2_000),
    water: await make('Bottled Water', 4_000, 1_800),
  }
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

interface BillPayload {
  id: string
  billNumber: string
  subtotal: number
  discountAmount: number
  cgst: number
  sgst: number
  total: number
  amountPaid: number
  outstanding: number
  paymentStatus: string
  customerName: string | null
  customerPhone: string | null
}

async function makeOrder(ctx: Ctx, lines: { variantId: string; qty: number }[]): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: { type: 'takeaway' },
  })
  const orderId = (res.json() as { order: { id: string } }).order.id

  for (const line of lines) {
    await ctx.app.inject({
      method: 'POST',
      url: `/orders/${orderId}/items`,
      headers: ctx.cashier,
      payload: { variantId: line.variantId, qty: line.qty },
    })
  }
  return orderId
}

async function makeBill(ctx: Ctx, orderId: string): Promise<BillPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: ctx.cashier,
    payload: { orderId },
  })
  if (res.statusCode !== 201) throw new Error(`bill failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { bill: BillPayload }).bill
}

async function pay(ctx: Ctx, billId: string, amount: number): Promise<BillPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${billId}/payments`,
    headers: ctx.cashier,
    payload: { mode: 'cash', amount },
  })
  if (res.statusCode !== 201) throw new Error(`payment failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { bill: BillPayload }).bill
}

async function amend(
  ctx: Ctx,
  billId: string,
  payload: Record<string, unknown>,
  auth?: Record<string, string>,
) {
  return ctx.app.inject({
    method: 'PATCH',
    url: `/bills/${billId}`,
    headers: auth ?? ctx.admin,
    payload,
  })
}

async function reopen(ctx: Ctx, billId: string) {
  return ctx.app.inject({
    method: 'POST',
    url: `/bills/${billId}/reopen`,
    headers: ctx.admin,
  })
}

interface Amendment {
  kind: string
  totalBefore: number | null
  totalAfter: number | null
  wasPrinted: boolean
  wasPaid: boolean
  reason: string | null
  amendedBy: string | null
}

async function history(ctx: Ctx, billId: string): Promise<Amendment[]> {
  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${billId}/amendments`,
    headers: ctx.admin,
  })
  if (res.statusCode !== 200) throw new Error(`history failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { amendments: Amendment[] }).amendments
}

// --- the totals ---

test('amending the discount recalculates and keeps the bill number', async () => {
  // The point of editing in place: the customer is not handed a second piece of
  // paper with a different number for the same meal.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  assertEqual(bill.total, 32_000)

  const res = await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 2_000 })
  assertEqual(res.statusCode, 200)

  const after = (res.json() as { bill: BillPayload }).bill
  assertEqual(after.billNumber, bill.billNumber, 'the number is unchanged')
  assertEqual(after.discountAmount, 2_000)
  assertEqual(after.total, 30_000)
  await close(ctx)
})

test('tax is recomputed on the discounted amount, not the original', async () => {
  // The rule that produces wrong bills if broken. An amendment must not become
  // the one path that taxes the pre-discount total.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.water, qty: 1 }]))
  const taxBefore = bill.cgst + bill.sgst

  const res = await amend(ctx, bill.id, { discountType: 'percent', discountValue: 5_000 })
  const after = (res.json() as { bill: BillPayload }).bill
  const taxAfter = after.cgst + after.sgst

  // Half off, so the tax on what remains is half what it was.
  assertEqual(taxAfter, Math.round(taxBefore / 2), 'tax follows the discounted base')
  await close(ctx)
})

test('editing items and recalculating brings the bill in step', async () => {
  // Items live on the order, so the whole flow is: reopen, change a line,
  // recalculate.
  const ctx = await setup()
  const orderId = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, orderId)
  assertEqual(bill.total, 32_000)

  assertEqual((await reopen(ctx, bill.id)).statusCode, 200)

  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${orderId}/items`,
    headers: ctx.cashier,
    payload: { variantId: ctx.tea, qty: 1 },
  })

  const res = await amend(ctx, bill.id, { recalculate: true })
  const after = (res.json() as { bill: BillPayload }).bill

  assertEqual(after.total, 34_000, 'the tea is on the bill')
  assertEqual(after.billNumber, bill.billNumber, 'still the same bill')
  await close(ctx)
})

// --- payment, which is derived from a total that just moved ---

test('a paid bill that grows is partly paid again', async () => {
  // Left alone it would still read "paid" while money was outstanding.
  const ctx = await setup()
  const orderId = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, orderId)
  assertEqual((await pay(ctx, bill.id, 32_000)).paymentStatus, 'paid')

  await reopen(ctx, bill.id)
  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${orderId}/items`,
    headers: ctx.cashier,
    payload: { variantId: ctx.tea, qty: 1 },
  })

  const res = await amend(ctx, bill.id, { recalculate: true })
  const after = (res.json() as { bill: BillPayload }).bill

  assertEqual(after.total, 34_000)
  assertEqual(after.amountPaid, 32_000, 'what was taken is untouched')
  assertEqual(after.paymentStatus, 'partial', 'no longer settled')
  assertEqual(after.outstanding, 2_000)
  await close(ctx)
})

test('a paid bill reduced below what was taken shows change owed', async () => {
  // Negative outstanding is how staff find out they owe the customer change.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await pay(ctx, bill.id, 32_000)

  const res = await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 5_000 })
  const after = (res.json() as { bill: BillPayload }).bill

  assertEqual(after.total, 27_000)
  assertEqual(after.amountPaid, 32_000, 'the payment is not rewritten')
  assertEqual(after.outstanding, -5_000, 'change is owed')
  await close(ctx)
})

// --- the history, which is the only record of what was overwritten ---

test('an amendment records what the bill said before', async () => {
  // bills holds only the latest state. Without this row an edited bill cannot
  // be reconciled against anything.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  await amend(ctx, bill.id, {
    discountType: 'fixed',
    discountValue: 2_000,
    reason: 'Regular customer',
  })

  const rows = await history(ctx, bill.id)
  assertEqual(rows.length, 1)
  assertEqual(rows[0]!.kind, 'discount')
  assertEqual(rows[0]!.totalBefore, 32_000, 'the original total survives')
  assertEqual(rows[0]!.totalAfter, 30_000)
  assertEqual(rows[0]!.reason, 'Regular customer')
  assertEqual(rows[0]!.amendedBy, 'admin', 'who changed it')
  await close(ctx)
})

test('an amendment records that the bill had already been paid', async () => {
  // The case that matters at reconciliation: a bill nobody had seen is a draft
  // being corrected; one already settled now disagrees with what was collected.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))
  await pay(ctx, bill.id, 32_000)

  await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 1_000 })

  const rows = await history(ctx, bill.id)
  assertEqual(rows[0]!.wasPaid, true, 'flagged as changed after payment')
  await close(ctx)
})

test('amendments accumulate rather than replacing each other', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 1_000 })
  await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 2_000 })
  await amend(ctx, bill.id, { customerName: 'Ravi' })

  const rows = await history(ctx, bill.id)
  assertEqual(rows.length, 3)
  assertEqual(rows[0]!.kind, 'customer', 'newest first')
  await close(ctx)
})

// --- details, and the refusals ---

test('customer details can be corrected without touching the total', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const res = await amend(ctx, bill.id, { customerPhone: '9940817315' })
  assertEqual(res.statusCode, 200)

  const after = (res.json() as { bill: BillPayload }).bill
  assertEqual(after.customerPhone, '9940817315')
  assertEqual(after.total, 32_000, 'no money moved')

  const rows = await history(ctx, bill.id)
  assertEqual(rows[0]!.kind, 'customer')
  assertEqual(rows[0]!.totalBefore, null, 'no total recorded for a detail edit')
  await close(ctx)
})

test('a cashier cannot amend a bill', async () => {
  // Same reasoning as voiding: changing a total after the fact is an admin act.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const res = await amend(
    ctx,
    bill.id,
    { discountType: 'fixed', discountValue: 1_000 },
    ctx.cashier,
  )
  if (res.statusCode === 200) throw new Error('a cashier amended a bill')
  await close(ctx)
})

test('a voided bill cannot be amended', async () => {
  // It is withdrawn and its order is already open. Amending would resurrect a
  // number the record says was cancelled.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong table' },
  })

  const res = await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 1_000 })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a reopened order marks the bill total as out of date', async () => {
  // The till has to know, or it shows a settled-looking figure while the lines
  // behind it have already moved — and someone takes payment against it.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const before = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.admin,
  })
  assertEqual(
    (before.json() as { bill: { orderReopened: boolean } }).bill.orderReopened,
    false,
    'a settled bill is not flagged',
  )

  await reopen(ctx, bill.id)

  const after = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.admin,
  })
  assertEqual(
    (after.json() as { bill: { orderReopened: boolean } }).bill.orderReopened,
    true,
    'flagged while the order is open',
  )
  await close(ctx)
})

test('the bill reports how many times it has been amended', async () => {
  // Drives whether the history is offered at all: most bills are never
  // changed, and a section on all of them would be noise.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const count = async () => {
    const res = await ctx.app.inject({
      method: 'GET',
      url: `/bills/${bill.id}`,
      headers: ctx.admin,
    })
    return (res.json() as { bill: { amendmentCount: number } }).bill.amendmentCount
  }

  assertEqual(await count(), 0)
  await amend(ctx, bill.id, { discountType: 'fixed', discountValue: 1_000 })
  assertEqual(await count(), 1)
  await amend(ctx, bill.id, { customerName: 'Ravi' })
  assertEqual(await count(), 2)
  await close(ctx)
})

test('recalculating closes the order again', async () => {
  // Left open, the till showed "this total is out of date" for ever — over a
  // figure that had just been brought up to date — and held back Take payment
  // with it.
  const ctx = await setup()
  const orderId = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, orderId)

  await reopen(ctx, bill.id)
  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${orderId}/items`,
    headers: ctx.cashier,
    payload: { variantId: ctx.tea, qty: 1 },
  })
  await amend(ctx, bill.id, { recalculate: true })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.admin,
  })
  assertEqual(
    (res.json() as { bill: { orderReopened: boolean } }).bill.orderReopened,
    false,
    'the banner clears once the total is in step',
  )

  const row = ctx.db.prepare('SELECT status FROM orders WHERE id = ?').get(orderId) as {
    status: string
  }
  assertEqual(row.status, 'billed')
  await close(ctx)
})

test('a recalculate that moved nothing writes no history row', async () => {
  // Reopening and then changing your mind is common. Recording it fills the
  // history with "1074.00 -> 1074.00" rows saying only that a button was
  // pressed, in the one place that has to stay readable.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  await reopen(ctx, bill.id)
  await amend(ctx, bill.id, { recalculate: true })

  assertEqual((await history(ctx, bill.id)).length, 0, 'nothing changed, nothing recorded')
  await close(ctx)
})

test('a recalculate that moved nothing still closes the order', async () => {
  // The history row is skipped; the order still has to come back to billed or
  // the bill is left flagged stale for ever.
  const ctx = await setup()
  const orderId = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, orderId)

  await reopen(ctx, bill.id)
  await amend(ctx, bill.id, { recalculate: true })

  const row = ctx.db.prepare('SELECT status FROM orders WHERE id = ?').get(orderId) as {
    status: string
  }
  assertEqual(row.status, 'billed')
  await close(ctx)
})

test('an amendment that changes nothing is refused', async () => {
  // A no-op would write a history row saying nothing happened.
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]))

  const res = await amend(ctx, bill.id, {})
  assertEqual(res.statusCode, 400)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'NOTHING_TO_AMEND')
  await close(ctx)
})
