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
  tableId: string
  full: string
  tea: string
  water: string
}

async function setup(
  taxMode: 'inclusive' | 'exclusive' = 'exclusive',
  roundOff = false,
): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  setSetting(db, branchId, 'tax_mode', taxMode)
  setSetting(db, branchId, 'round_off_enabled', roundOff ? '1' : '0')

  const app = await buildServer({ db, env })
  const admin = await login(app, 'admin', 'admin123')
  await app.inject({
    method: 'POST',
    url: '/users',
    headers: admin,
    payload: { username: 'cash', password: 'cash123', fullName: 'Cash', role: 'cashier' },
  })
  const cashier = await login(app, 'cash', 'cash123')

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

  const make = async (name: string, price: number, taxRate?: number): Promise<string> => {
    const res = await app.inject({
      method: 'POST',
      url: '/menu-items',
      headers: admin,
      payload: { categoryId, name, price, ...(taxRate ? { taxRate } : {}) },
    })
    return (res.json() as { item: { variants: { id: string }[] } }).item.variants[0]!.id
  }

  return {
    app,
    db,
    admin,
    cashier,
    tableId,
    full: await make('Chicken Biryani', 32_000),
    tea: await make('Masala Tea', 2_000),
    water: await make('Bottled Water', 4_000, 1_800),
  }
}

async function login(app: FastifyInstance, username: string, password: string) {
  const res = await app.inject({ method: 'POST', url: '/auth/login', payload: { username, password } })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
}

interface BillPayload {
  id: string
  billNo: number
  billNumber: string
  billPeriod: string
  businessDate: string
  subtotal: number
  discountAmount: number
  cgst: number
  sgst: number
  roundOff: number
  total: number
  amountPaid: number
  outstanding: number
  paymentStatus: string
  reprintCount: number
  settledAt: string | null
  taxBreakdown: { rate: number; base: number; cgst: number; sgst: number }[]
  payments: { id: string; mode: string; amount: number; reversedAt: string | null }[]
}

/** An open order with the given lines. */
async function makeOrder(
  ctx: Ctx,
  lines: { variantId: string; qty: number }[],
  options: { dineIn?: boolean } = {},
): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: options.dineIn
      ? { type: 'dine_in', tableId: ctx.tableId }
      : { type: 'takeaway' },
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

async function makeBill(
  ctx: Ctx,
  orderId: string,
  payload: Record<string, unknown> = {},
): Promise<BillPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: ctx.cashier,
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

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- generating a bill ---

test('a bill totals the order, exclusive tax', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 2 }])
  const bill = await makeBill(ctx, order)

  assertEqual(bill.billNo, 1)
  assertEqual(bill.subtotal, 64_000)
  assertEqual(bill.cgst + bill.sgst, 3_200)
  assertEqual(bill.total, 67_200)
  assertEqual(bill.paymentStatus, 'unpaid')
  await close(ctx)
})

test('a bill totals the order, inclusive tax', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 2 }])
  const bill = await makeBill(ctx, order)

  assertEqual(bill.total, 64_000, 'the customer pays the menu price')
  assertEqual(bill.subtotal + bill.cgst + bill.sgst, bill.total)
  await close(ctx)
})

test('bill numbers increment per day', async () => {
  const ctx = await setup()
  assertEqual((await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))).billNo, 1)
  assertEqual((await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))).billNo, 2)
  await close(ctx)
})

test('billing closes the order and frees the table', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }], { dineIn: true })
  await makeBill(ctx, order)

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.cashier,
  })
  assertEqual((table.json() as { table: { status: string } }).table.status, 'free')

  const orderRow = ctx.db.prepare('SELECT status FROM orders WHERE id = ?').get(order) as {
    status: string
  }
  assertEqual(orderRow.status, 'billed')
  await close(ctx)
})

test('an unpaid bill does not hold its table', async () => {
  // The balance follows the bill, not the table — a guest who leaves owing
  // money must not block seating.
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }], { dineIn: true })
  const bill = await makeBill(ctx, order)
  assertEqual(bill.paymentStatus, 'unpaid')

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.cashier,
  })
  assertEqual((table.json() as { table: { status: string } }).table.status, 'free')
  await close(ctx)
})

test('an empty order cannot be billed', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.cashier,
    payload: { type: 'takeaway' },
  })
  const orderId = (res.json() as { order: { id: string } }).order.id

  const bill = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: ctx.cashier,
    payload: { orderId },
  })
  assertEqual(bill.statusCode, 400)
  assertEqual((bill.json() as { error: { code: string } }).error.code, 'EMPTY_ORDER')
  await close(ctx)
})

test('an order cannot be billed twice', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  await makeBill(ctx, order)

  const second = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: ctx.cashier,
    payload: { orderId: order },
  })
  assertEqual(second.statusCode, 409)
  await close(ctx)
})

test('the list carries the order number beside the bill number', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const list = await ctx.app.inject({ method: 'GET', url: '/bills', headers: ctx.cashier })
  const rows = (list.json() as { bills: { id: string; orderNo: number | null }[] }).bills
  const row = rows.find((r) => r.id === bill.id)
  if (!row) throw new Error('the new bill is missing from the list')

  const expected = ctx.db
    .prepare('SELECT order_no FROM orders WHERE id = ?')
    .get(order) as { order_no: number }
  assertEqual(row.orderNo, expected.order_no, 'the list joins the order number in')
  await close(ctx)
})

test('the list says whether each bill was dine-in or takeaway', async () => {
  // The bills list marks the two apart with an icon. Only the single-bill
  // route joined the type in, so every row in the list read as null and the
  // icon would have shown the same shape for everything.
  const ctx = await setup()
  const takeaway = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const dineIn = await makeBill(
    ctx,
    await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }], { dineIn: true }),
  )

  const rows = (
    await list(ctx)
  ).bills as unknown as { id: string; orderType: string | null }[]

  assertEqual(rows.find((r) => r.id === takeaway.id)?.orderType, 'takeaway')
  assertEqual(rows.find((r) => r.id === dineIn.id)?.orderType, 'dine_in')
  await close(ctx)
})

test('the list summary still totals correctly with the order join', async () => {
  const ctx = await setup()
  const first = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const second = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const a = await makeBill(ctx, first)
  const b = await makeBill(ctx, second)

  const list = await ctx.app.inject({ method: 'GET', url: '/bills', headers: ctx.cashier })
  const body = list.json() as {
    bills: { id: string }[]
    summary: { count: number; total: number }
  }

  // A LEFT JOIN that matched more than one order row would double both.
  assertEqual(body.bills.filter((r) => r.id === a.id).length, 1, 'no duplicated rows')
  assertEqual(body.summary.count, body.bills.length, 'the count matches the rows')
  assertEqual(body.summary.total, a.total + b.total, 'the join does not inflate takings')
  await close(ctx)
})

test('preview does not create a bill', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])

  const preview = await ctx.app.inject({
    method: 'POST',
    url: '/bills/preview',
    headers: ctx.cashier,
    payload: { orderId: order, discountType: 'percent', discountValue: 1_000 },
  })
  assertEqual(preview.statusCode, 200)
  assertEqual((preview.json() as { preview: { discountAmount: number } }).preview.discountAmount, 3_200)

  const bills = ctx.db.prepare('SELECT COUNT(*) AS n FROM bills').get() as { n: number }
  assertEqual(bills.n, 0, 'nothing was persisted')
  await close(ctx)
})

// --- discounts ---

test('a fixed discount is applied before tax', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order, { discountType: 'fixed', discountValue: 2_000 })

  assertEqual(bill.discountAmount, 2_000)
  assertEqual(bill.subtotal, 30_000, 'taxable base is discounted')
  assertEqual(bill.cgst + bill.sgst, 1_500, '5% of Rs300, not Rs320')
  assertEqual(bill.total, 31_500)
  await close(ctx)
})

test('a percentage discount uses basis points', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order, { discountType: 'percent', discountValue: 1_000 })
  assertEqual(bill.discountAmount, 3_200, '10% of Rs320')
  await close(ctx)
})

test('a discount larger than the bill is rejected', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/bills',
    headers: ctx.cashier,
    payload: { orderId: order, discountType: 'fixed', discountValue: 999_999 },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

// --- mixed rates ---

test('a bill with two tax rates groups them for the printout', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [
    { variantId: ctx.full, qty: 1 },
    { variantId: ctx.water, qty: 1 },
  ])
  const bill = await makeBill(ctx, order)

  assertEqual(bill.taxBreakdown.length, 2)
  const five = bill.taxBreakdown.find((g) => g.rate === 500)!
  const eighteen = bill.taxBreakdown.find((g) => g.rate === 1_800)!
  assertEqual(five.base, 32_000)
  assertEqual(eighteen.base, 4_000)
  assertEqual(bill.cgst + bill.sgst, 1_600 + 720)
  await close(ctx)
})

// --- round off ---

test('round off applies when enabled', async () => {
  const ctx = await setup('exclusive', true)
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 3 }])
  const bill = await makeBill(ctx, order)
  assertEqual(bill.total % 100, 0, 'rounded to a whole rupee')
  assertEqual(bill.subtotal + bill.cgst + bill.sgst + bill.roundOff, bill.total)
  await close(ctx)
})

// --- payments ---

test('a single payment settles the bill', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })
  assertEqual(paid.paymentStatus, 'paid')
  assertEqual(paid.amountPaid, bill.total)
  assertEqual(paid.outstanding, 0)
  if (paid.settledAt === null) throw new Error('settledAt was not set')
  await close(ctx)
})

test('a bill can be split across cash and card', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]) // Rs320
  const bill = await makeBill(ctx, order)

  const partial = await pay(ctx, bill.id, { mode: 'cash', amount: 20_000 })
  assertEqual(partial.paymentStatus, 'partial')
  assertEqual(partial.outstanding, 12_000)

  const settled = await pay(ctx, bill.id, { mode: 'card', amount: 12_000 })
  assertEqual(settled.paymentStatus, 'paid')
  assertEqual(settled.payments.length, 2)
  assertEqual(settled.payments.map((p) => p.mode).join(','), 'cash,card')
  await close(ctx)
})

test('a bill can be left partly paid', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const partial = await pay(ctx, bill.id, { mode: 'cash', amount: 10_000 })

  assertEqual(partial.paymentStatus, 'partial')
  assertEqual(partial.settledAt, null, 'not settled while money is outstanding')

  const outstanding = await ctx.app.inject({
    method: 'GET',
    url: '/bills?unpaid=true',
    headers: ctx.cashier,
  })
  assertEqual((outstanding.json() as { bills: unknown[] }).bills.length, 1)
  await close(ctx)
})

test('overpayment is rejected', async () => {
  // Change is handled at the drawer, not recorded as a payment.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments`,
    headers: ctx.cashier,
    payload: { mode: 'cash', amount: bill.total + 1 },
  })
  assertEqual(res.statusCode, 400)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'OVERPAYMENT')
  await close(ctx)
})

test('a payment is reversed, never deleted', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'Recorded as cash, was card' },
  })
  const after = (res.json() as { bill: BillPayload }).bill

  assertEqual(after.paymentStatus, 'unpaid', 'the reversal is not counted')
  assertEqual(after.amountPaid, 0)
  assertEqual(after.payments.length, 1, 'the row stays for audit')
  if (after.payments[0]!.reversedAt === null) throw new Error('reversal not recorded')
  await close(ctx)
})

test('the corrected payment settles the bill after a reversal', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'Wrong mode' },
  })
  const corrected = await pay(ctx, bill.id, { mode: 'card', amount: bill.total })

  assertEqual(corrected.paymentStatus, 'paid')
  assertEqual(corrected.payments.length, 2, 'both the reversal and the correction remain')
  await close(ctx)
})

test('a payment cannot be reversed twice', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })
  const url = `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`

  await ctx.app.inject({ method: 'POST', url, headers: ctx.cashier, payload: { reason: 'a' } })
  const second = await ctx.app.inject({
    method: 'POST',
    url,
    headers: ctx.cashier,
    payload: { reason: 'b' },
  })
  assertEqual(second.statusCode, 409)
  await close(ctx)
})

// --- voiding ---

test('an admin can void a bill, reopening its order', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }], { dineIn: true })
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong table' },
  })
  assertEqual(res.statusCode, 200)

  const orderRow = ctx.db.prepare('SELECT status FROM orders WHERE id = ?').get(order) as {
    status: string
  }
  assertEqual(orderRow.status, 'open', 'the order reopens for correction')

  const billRow = ctx.db
    .prepare('SELECT voided_at, deleted_at, bill_no FROM bills WHERE id = ?')
    .get(bill.id) as { voided_at: string | null; deleted_at: string | null; bill_no: number }
  if (billRow.voided_at === null) throw new Error('void not recorded')
  if (billRow.deleted_at === null) throw new Error('a voided bill should be soft-deleted')
  assertEqual(billRow.bill_no, 1, 'the number stays consumed, leaving no gap')
  await close(ctx)
})

test('a cashier cannot void a bill', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.cashier,
    payload: { reason: 'Nope' },
  })
  assertEqual(res.statusCode, 403)
  await close(ctx)
})

test('a bill with live payments cannot be voided', async () => {
  // Money must not sit recorded against a sale that no longer exists.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Mistake' },
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'BILL_HAS_PAYMENTS')
  await close(ctx)
})

test('a paid bill can be voided when the reversal is asked for', async () => {
  // Undoing the whole sale in one act. Refusing outright meant reversing each
  // payment by hand first, and a failure midway left the bill neither paid
  // nor voided.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Rung up on the wrong table', reversePayments: true },
  })
  assertEqual(res.statusCode, 200)

  const row = ctx.db
    .prepare('SELECT voided_at, amount_paid, payment_status FROM bills WHERE id = ?')
    .get(bill.id) as { voided_at: string | null; amount_paid: number; payment_status: string }

  if (row.voided_at === null) throw new Error('void not recorded')
  assertEqual(row.amount_paid, 0, 'derived from live payments, which are now none')
  assertEqual(row.payment_status, 'unpaid')
  await close(ctx)
})

test('the reversed payments stay on the record', async () => {
  // Reversed, never deleted. The rows are the audit trail — without them
  // there is nothing showing the money was ever taken.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: 10_000 })
  await pay(ctx, bill.id, { mode: 'cash', amount: bill.total - 10_000 })

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong table', reversePayments: true },
  })

  const rows = ctx.db
    .prepare('SELECT reversed_at, reverse_reason FROM payments WHERE bill_id = ?')
    .all(bill.id) as { reversed_at: string | null; reverse_reason: string | null }[]

  assertEqual(rows.length, 2, 'both still there')
  for (const row of rows) {
    if (row.reversed_at === null) throw new Error('a payment was left standing')
    assertEqual(row.reverse_reason, 'Wrong table', 'why, on every one')
  }
  await close(ctx)
})

test('voiding a paid bill reopens its order', async () => {
  // The same as any void: the order comes back so it can be corrected and
  // billed again, rather than the table being stranded.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong table', reversePayments: true },
  })

  const row = ctx.db
    .prepare('SELECT status FROM orders WHERE id = ?')
    .get(order) as { status: string }
  assertEqual(row.status, 'open')
  await close(ctx)
})

test('an already reversed payment is not reversed twice', async () => {
  // Reversing it again would overwrite who did it and why, losing the first
  // reason. The update only touches payments still standing.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const paymentId = paid.payments[0]!.id
  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paymentId}/reverse`,
    headers: ctx.admin,
    payload: { reason: 'Taken in error' },
  })

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Void reason', reversePayments: true },
  })

  const row = ctx.db
    .prepare('SELECT reverse_reason FROM payments WHERE id = ?')
    .get(paymentId) as { reverse_reason: string }
  assertEqual(row.reverse_reason, 'Taken in error', 'the original reason survives')
  await close(ctx)
})

test('a cashier still cannot void a paid bill', async () => {
  // The flag does not widen who may do this.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.cashier,
    payload: { reason: 'Mistake', reversePayments: true },
  })
  assertEqual(res.statusCode, 403)
  await close(ctx)
})

test('an unpaid bill is unaffected by the flag', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Nothing was taken', reversePayments: true },
  })
  assertEqual(res.statusCode, 200)
  await close(ctx)
})

test('a voided bill accepts no further payment', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Cancelled' },
  })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments`,
    headers: ctx.cashier,
    payload: { mode: 'cash', amount: 100 },
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a voided bill is excluded from listings', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Test' },
  })

  const list = await ctx.app.inject({ method: 'GET', url: '/bills', headers: ctx.cashier })
  assertEqual((list.json() as { bills: unknown[] }).bills.length, 0)
  await close(ctx)
})

test('a reopened order can be corrected and re-billed', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const first = await makeBill(ctx, order)
  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${first.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong item' },
  })

  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order}/items`,
    headers: ctx.cashier,
    payload: { variantId: ctx.tea, qty: 1 },
  })
  const second = await makeBill(ctx, order)

  assertEqual(second.billNo, 2, 'a new number, the old one stays consumed')
  assertEqual(second.subtotal, 34_000)
  await close(ctx)
})

// --- reprint ---

test('a reprint is counted and marked as a duplicate', async () => {
  // A reprint that looks identical to the original is a way to present one
  // sale as two.
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/reprint`,
    headers: ctx.cashier,
  })
  const body = res.json() as { bill: BillPayload; isDuplicate: boolean }
  assertEqual(body.isDuplicate, true)
  assertEqual(body.bill.reprintCount, 1)
  await close(ctx)
})

// --- snapshots ---

test('repricing the menu never changes an existing bill', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.full) as { menu_item_id: string }
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}/variants/${ctx.full}`,
    headers: ctx.admin,
    payload: { price: 99_000 },
  })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.cashier,
  })
  assertEqual((res.json() as { bill: BillPayload }).bill.total, bill.total)
  await close(ctx)
})

test('changing tax mode never changes an existing bill', async () => {
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const branchId = (ctx.db.prepare('SELECT id FROM branches LIMIT 1').get() as { id: string }).id
  setSetting(ctx.db, branchId, 'tax_mode', 'inclusive')

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.cashier,
  })
  const after = (res.json() as { bill: BillPayload & { taxMode: string } }).bill
  assertEqual(after.total, bill.total)
  assertEqual((after as unknown as { taxMode: string }).taxMode, 'exclusive', 'snapshotted')
  await close(ctx)
})

// --- configurable numbering ---

/** Sets a numbering option and returns the branch id. */
function configureNumbering(ctx: Ctx, options: Record<string, string>): void {
  const branchId = (ctx.db.prepare('SELECT id FROM branches LIMIT 1').get() as { id: string }).id
  for (const [key, value] of Object.entries(options)) {
    setSetting(ctx.db, branchId, key as never, value)
  }
}

test('daily reset gives each bill a per-day sequence', async () => {
  const ctx = await setup()
  configureNumbering(ctx, { bill_reset_period: 'daily' })

  const first = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const second = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  assertEqual(first.billNo, 1)
  assertEqual(second.billNo, 2)
  assertEqual(first.billPeriod, first.businessDate, 'the period is the date')
  await close(ctx)
})

test('a new period restarts the sequence', async () => {
  const ctx = await setup()
  configureNumbering(ctx, { bill_reset_period: 'daily' })
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(bill.billNo, 1)

  // Move the existing bill into a previous period, as a new day would.
  ctx.db.prepare("UPDATE bills SET bill_period = '2020-01-01'").run()

  const next = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(next.billNo, 1, 'the new period starts again at 1')
  await close(ctx)
})

test('monthly reset keeps numbering across days in the month', async () => {
  const ctx = await setup()
  configureNumbering(ctx, { bill_reset_period: 'monthly' })

  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(bill.billPeriod, bill.businessDate.slice(0, 7), 'keyed on the month')
  await close(ctx)
})

test('financial year reset keys on the April boundary', async () => {
  const ctx = await setup()
  configureNumbering(ctx, { bill_reset_period: 'financial_year' })

  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  // The seeded business date is in September, so FY 2026-27.
  assertEqual(bill.billPeriod, '2026-27')
  await close(ctx)
})

test('never reset keeps one continuous sequence', async () => {
  const ctx = await setup()
  configureNumbering(ctx, { bill_reset_period: 'never' })

  const first = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(first.billPeriod, 'all')

  // Even a different business date shares the sequence.
  ctx.db.prepare("UPDATE bills SET business_date = '2020-01-01'").run()
  const second = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(second.billNo, 2, 'numbering continues regardless of date')
  await close(ctx)
})

test('the printed number follows the configured format', async () => {
  const ctx = await setup()
  configureNumbering(ctx, {
    bill_reset_period: 'financial_year',
    bill_number_format: '{PREFIX}/{FY}/{NO}',
    bill_prefix: 'CE',
    bill_number_pad: '4',
  })

  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(bill.billNumber, 'CE/2026-27/0001')
  await close(ctx)
})

test('a stored bill number survives a later format change', async () => {
  // A reprint must show what the original showed.
  const ctx = await setup()
  configureNumbering(ctx, { bill_number_format: '{PREFIX}-{NO}', bill_prefix: 'OLD' })
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  assertEqual(bill.billNumber, 'OLD-0001')

  configureNumbering(ctx, { bill_number_format: '{PREFIX}/{YYYY}/{NO}', bill_prefix: 'NEW' })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.cashier,
  })
  assertEqual(
    (res.json() as { bill: BillPayload }).bill.billNumber,
    'OLD-0001',
    'the original formatting is preserved',
  )
  await close(ctx)
})

test('two bills cannot share a number within a period', async () => {
  const ctx = await setup()
  const bill = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const row = ctx.db.prepare('SELECT bill_period FROM bills WHERE id = ?').get(bill.id) as {
    bill_period: string
  }

  let threw = false
  try {
    ctx.db
      .prepare(
        `INSERT INTO bills (id, branch_id, order_id, bill_no, bill_period, bill_number,
                            business_date, subtotal, total, tax_mode, created_by,
                            created_at, updated_at)
         SELECT 'dupe', branch_id, order_id, bill_no, bill_period, bill_number, business_date,
                subtotal, total, tax_mode, created_by, created_at, updated_at
         FROM bills WHERE id = ?`,
      )
      .run(bill.id)
  } catch {
    threw = true
  }
  assertEqual(threw, true, `a duplicate bill_no in period ${row.bill_period} must be rejected`)
  await close(ctx)
})

// --- listing by business date ---

/** Moves a bill onto another trading day, to test date filtering. */
function backdate(ctx: Ctx, billId: string, businessDate: string): void {
  ctx.db.prepare('UPDATE bills SET business_date = ? WHERE id = ?').run(businessDate, billId)
}

interface ListResult {
  bills: BillPayload[]
  summary: { count: number; total: number; collected: number; outstanding: number }
}

async function list(ctx: Ctx, query = ''): Promise<ListResult> {
  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills${query}`,
    headers: ctx.cashier,
  })
  if (res.statusCode !== 200) throw new Error(`list failed: ${res.statusCode} ${res.body}`)
  return res.json() as ListResult
}

test('bills default to today, not everything ever billed', async () => {
  const ctx = await setup()
  const today = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const old = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  backdate(ctx, old.id, '2020-01-01')

  const result = await list(ctx)
  assertEqual(result.bills.length, 1, 'only today')
  assertEqual(result.bills[0]!.id, today.id)
  await close(ctx)
})

test('a date range is inclusive at both ends', async () => {
  const ctx = await setup()
  const a = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const b = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const c = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  backdate(ctx, a.id, '2026-03-01')
  backdate(ctx, b.id, '2026-03-05')
  backdate(ctx, c.id, '2026-03-10')

  const result = await list(ctx, '?from=2026-03-01&to=2026-03-05')
  assertEqual(result.bills.length, 2, 'both endpoints are included')

  const single = await list(ctx, '?from=2026-03-05&to=2026-03-05')
  assertEqual(single.bills.length, 1, 'a one-day range works')
  await close(ctx)
})

test('an open-ended range means everything since a date', async () => {
  const ctx = await setup()
  const old = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const recent = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  backdate(ctx, old.id, '2020-01-01')
  backdate(ctx, recent.id, '2026-06-01')

  const since = await list(ctx, '?from=2026-01-01')
  assertEqual(since.bills.length, 1)
  assertEqual(since.bills[0]!.id, recent.id)
  await close(ctx)
})

test('the summary totals the whole match, and tracks what is still due', async () => {
  const ctx = await setup()
  const first = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 2 }]))
  const second = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  await pay(ctx, first.id, { mode: 'cash', amount: first.total })

  const result = await list(ctx)
  assertEqual(result.summary.count, 2)
  assertEqual(result.summary.total, first.total + second.total, 'billed')
  assertEqual(result.summary.collected, first.total, 'only what was actually paid')
  assertEqual(result.summary.outstanding, second.total, 'the rest is still due')
  await close(ctx)
})

test('a voided bill leaves the list and the takings', async () => {
  const ctx = await setup()
  const kept = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))
  const voided = await makeBill(ctx, await makeOrder(ctx, [{ variantId: ctx.tea, qty: 1 }]))

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${voided.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Wrong table' },
  })

  const result = await list(ctx)
  assertEqual(result.bills.length, 1, 'the voided bill is gone')
  assertEqual(result.bills[0]!.id, kept.id)
  // A voided bill counted in the day's takings would overstate the till.
  assertEqual(result.summary.total, kept.total)
  await close(ctx)
})

test('a bill carries its own line items, snapshotted at the time', async () => {
  const ctx = await setup()
  const order = await makeOrder(ctx, [{ variantId: ctx.tea, qty: 3 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.cashier,
  })
  const detail = (res.json() as {
    bill: { items: { itemName: string; qty: number; unitPrice: number }[]; orderNo: number }
  }).bill

  assertEqual(detail.items.length, 1)
  assertEqual(detail.items[0]!.qty, 3)
  assertEqual(typeof detail.orderNo, 'number', 'the order number is shown on the detail')

  const originalName = detail.items[0]!.itemName
  const originalPrice = detail.items[0]!.unitPrice

  // Renaming and repricing the dish must not rewrite a bill already issued.
  ctx.db
    .prepare('UPDATE menu_items SET name = ? WHERE name = ?')
    .run('Renamed Later', originalName)
  ctx.db
    .prepare('UPDATE menu_item_variants SET price = price + 5000 WHERE id = ?')
    .run(ctx.tea)

  const after = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${bill.id}`,
    headers: ctx.cashier,
  })
  const reread = (after.json() as {
    bill: { items: { itemName: string; unitPrice: number }[] }
  }).bill

  assertEqual(reread.items[0]!.itemName, originalName, 'the printed name is preserved')
  assertEqual(reread.items[0]!.unitPrice, originalPrice, 'the charged price is preserved')
  await close(ctx)
})

test('a bill printed unpaid can be settled afterwards', async () => {
  // The table is handed its bill, then pays at the counter later. Nothing about
  // having printed it may stop the payment being taken.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  assertEqual(bill.paymentStatus, 'unpaid')
  assertEqual(bill.outstanding, bill.total)

  const settled = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })
  assertEqual(settled.paymentStatus, 'paid')
  assertEqual(settled.outstanding, 0)
  await close(ctx)
})

test('an unpaid bill can be settled in stages', async () => {
  // Two people splitting the bill after it was printed for the table.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]) // Rs320
  const bill = await makeBill(ctx, order)

  const first = await pay(ctx, bill.id, { mode: 'cash', amount: 15_000 })
  assertEqual(first.paymentStatus, 'partial')
  assertEqual(first.outstanding, 17_000)

  const second = await pay(ctx, bill.id, { mode: 'upi', amount: 17_000 })
  assertEqual(second.paymentStatus, 'paid')
  assertEqual(second.outstanding, 0)
  await close(ctx)
})

test('paying more than is left on a part-paid bill is refused', async () => {
  // The dialog prefills the outstanding amount, but it can be edited. The rule
  // belongs to the backend, so the reason reaches the cashier.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  await pay(ctx, bill.id, { mode: 'cash', amount: 20_000 })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments`,
    headers: ctx.cashier,
    payload: { mode: 'card', amount: 20_000 },
  })
  assertEqual(res.statusCode, 400, 'only 120.00 was still due')
  await close(ctx)
})

test('a reversed payment stays on the bill, marked', async () => {
  // The detail dialog lists it struck through. If the backend dropped it, a
  // corrected bill would look like it was always right — the audit trail is
  // the whole reason reversal exists rather than deletion.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  const reversed = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'Recorded as cash, was card' },
  })
  assertEqual(reversed.statusCode, 200)

  const after = (reversed.json() as { bill: { payments: { reversedAt: string | null }[] } }).bill
  assertEqual(after.payments.length, 1, 'the row is kept')
  assertEqual(after.payments[0]!.reversedAt !== null, true, 'and marked reversed')
  await close(ctx)
})

test('reversing a payment reopens the bill for payment', async () => {
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })
  assertEqual(paid.paymentStatus, 'paid')

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'Wrong mode' },
  })
  const after = (res.json() as { bill: { paymentStatus: string; outstanding: number } }).bill
  assertEqual(after.paymentStatus, 'unpaid')
  assertEqual(after.outstanding, bill.total, 'the money is owed again')
  await close(ctx)
})

test('a bill can be voided once its payments are reversed', async () => {
  // The order the UI walks a cashier through: reverse, then void.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)
  const paid = await pay(ctx, bill.id, { mode: 'cash', amount: bill.total })

  await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/payments/${paid.payments[0]!.id}/reverse`,
    headers: ctx.cashier,
    payload: { reason: 'Billed the wrong table' },
  })

  const voided = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.admin,
    payload: { reason: 'Billed the wrong table' },
  })
  assertEqual(voided.statusCode, 200)
  await close(ctx)
})

test('a cashier cannot void a bill', async () => {
  // Voiding erases a sale from the day's takings, so it is the owner's call.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/bills/${bill.id}/void`,
    headers: ctx.cashier,
    payload: { reason: 'Mistake' },
  })
  assertEqual(res.statusCode, 403)
  await close(ctx)
})

test('voiding without a reason is refused', async () => {
  // "Voided" with no explanation is what an auditor asks about, and by then
  // nobody remembers.
  const ctx = await setup('inclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  for (const payload of [{}, { reason: '' }, { reason: '   ' }]) {
    const res = await ctx.app.inject({
      method: 'POST',
      url: `/bills/${bill.id}/void`,
      headers: ctx.admin,
      payload,
    })
    assertEqual(res.statusCode, 400, `accepted ${JSON.stringify(payload)}`)
  }
  await close(ctx)
})

test('with GST switched off a bill carries no tax at all', async () => {
  // Not merely hidden: the line is snapshotted at zero, so the figures a
  // restaurant below the registration threshold records are genuinely
  // tax-free and reconcile without a tax component.
  const ctx = await setup('exclusive')

  await ctx.app.inject({
    method: 'PATCH',
    url: '/settings',
    headers: ctx.admin,
    payload: { gstEnabled: false },
  })

  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const bill = await makeBill(ctx, order)

  assertEqual(bill.cgst, 0)
  assertEqual(bill.sgst, 0)
  assertEqual(bill.total, bill.subtotal, 'nothing was added on top')
  await close(ctx)
})

test('switching GST off does not rewrite bills already issued', async () => {
  // A bill records what the customer was charged. Changing a setting today
  // must not make last month's tax disappear from the record.
  const ctx = await setup('exclusive')
  const order = await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }])
  const taxed = await makeBill(ctx, order)
  assertEqual(taxed.cgst + taxed.sgst > 0, true, 'charged tax while GST was on')

  await ctx.app.inject({
    method: 'PATCH',
    url: '/settings',
    headers: ctx.admin,
    payload: { gstEnabled: false },
  })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/bills/${taxed.id}`,
    headers: ctx.cashier,
  })
  const after = (res.json() as { bill: { cgst: number; sgst: number } }).bill
  assertEqual(after.cgst, taxed.cgst, 'the tax it charged is unchanged')
  assertEqual(after.sgst, taxed.sgst)
  await close(ctx)
})

test('turning GST back on taxes new lines again', async () => {
  const ctx = await setup('exclusive')

  await ctx.app.inject({
    method: 'PATCH',
    url: '/settings',
    headers: ctx.admin,
    payload: { gstEnabled: false },
  })
  const untaxed = await makeBill(
    ctx,
    await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]),
  )
  assertEqual(untaxed.cgst + untaxed.sgst, 0)

  await ctx.app.inject({
    method: 'PATCH',
    url: '/settings',
    headers: ctx.admin,
    payload: { gstEnabled: true },
  })
  const taxed = await makeBill(
    ctx,
    await makeOrder(ctx, [{ variantId: ctx.full, qty: 1 }]),
  )
  assertEqual(taxed.cgst + taxed.sgst > 0, true)
  await close(ctx)
})

test('GST is on unless it has been switched off', async () => {
  // The expensive direction to be wrong is under-charging tax, so a branch
  // that never touched the setting still bills GST.
  const ctx = await setup('exclusive')
  const res = await ctx.app.inject({
    method: 'GET',
    url: '/settings',
    headers: ctx.cashier,
  })
  const settings = (res.json() as { settings: { gstEnabled: boolean } }).settings
  assertEqual(settings.gstEnabled, true)
  await close(ctx)
})
