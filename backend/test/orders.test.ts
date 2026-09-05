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
  auth: Record<string, string>
  branchId: string
  tableId: string
  /** Chicken Biryani: Half 180, Full 320. */
  half: string
  full: string
  /** Masala Tea, single Standard variant at 20. */
  tea: string
}

async function setup(taxMode: 'inclusive' | 'exclusive' = 'exclusive'): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  setSetting(db, branchId, 'tax_mode', taxMode)

  const app = await buildServer({ db, env })
  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const auth = { authorization: `Bearer ${(login.json() as { token: string }).token}` }

  const sections = await app.inject({ method: 'GET', url: '/sections', headers: auth })
  const sectionId = (sections.json() as { sections: { id: string }[] }).sections[0]!.id

  const table = await app.inject({
    method: 'POST',
    url: '/tables',
    headers: auth,
    payload: { sectionId, name: 'T1', seats: 4 },
  })
  const tableId = (table.json() as { table: { id: string } }).table.id

  const category = await app.inject({
    method: 'POST',
    url: '/categories',
    headers: auth,
    payload: { name: 'Biryani' },
  })
  const categoryId = (category.json() as { category: { id: string } }).category.id

  const biryani = await app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: auth,
    payload: {
      categoryId,
      name: 'Chicken Biryani',
      variants: [
        { name: 'Half', price: 18_000 },
        { name: 'Full', price: 32_000 },
      ],
    },
  })
  const variants = (biryani.json() as { item: { variants: { id: string; name: string }[] } }).item
    .variants

  const teaItem = await app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: auth,
    payload: { categoryId, name: 'Masala Tea', price: 2_000 },
  })
  const tea = (teaItem.json() as { item: { variants: { id: string }[] } }).item.variants[0]!.id

  return {
    app,
    db,
    auth,
    branchId,
    tableId,
    half: variants.find((v) => v.name === 'Half')!.id,
    full: variants.find((v) => v.name === 'Full')!.id,
    tea,
  }
}

interface OrderPayload {
  id: string
  orderNo: number
  status: string
  version: number
  seatLabel: string | null
  items: {
    id: string
    itemName: string
    variantName: string
    unitPrice: number
    taxRate: number
    qty: number
    lineTotal: number
    notes: string | null
  }[]
  subtotal: number
  tax: number
  total: number
  itemCount: number
}

async function newOrder(ctx: Ctx, payload: Record<string, unknown>): Promise<OrderPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.auth,
    payload,
  })
  if (res.statusCode !== 201) throw new Error(`order failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { order: OrderPayload }).order
}

async function addItem(
  ctx: Ctx,
  orderId: string,
  payload: Record<string, unknown>,
): Promise<OrderPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${orderId}/items`,
    headers: ctx.auth,
    payload,
  })
  if (res.statusCode !== 201) throw new Error(`add item failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { order: OrderPayload }).order
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- creating orders ---

test('a dine-in order attaches to a table and occupies it', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId })

  assertEqual(order.orderNo, 1)
  assertEqual(order.status, 'open')

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual((table.json() as { table: { status: string } }).table.status, 'occupied')
  await close(ctx)
})

test('a takeaway order needs no table', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway', customerName: 'Ravi' })
  assertEqual(order.status, 'open')
  await close(ctx)
})

test('a dine-in order without a table is rejected', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.auth,
    payload: { type: 'dine_in' },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

test('order numbers increment per day', async () => {
  const ctx = await setup()
  assertEqual((await newOrder(ctx, { type: 'takeaway' })).orderNo, 1)
  assertEqual((await newOrder(ctx, { type: 'takeaway' })).orderNo, 2)
  assertEqual((await newOrder(ctx, { type: 'takeaway' })).orderNo, 3)
  await close(ctx)
})

test('two parties can share a table, each with its own order', async () => {
  const ctx = await setup()
  const a = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'A' })
  const b = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'B' })

  assertEqual(a.seatLabel, 'A')
  assertEqual(b.seatLabel, 'B')

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual((table.json() as { table: { partyCount: number } }).table.partyCount, 2)
  await close(ctx)
})

test('parties sharing a table are billed separately', async () => {
  // The half that costs money if it is wrong. Two parties on one table must not
  // see each other's items, and settling one must not settle the other — a
  // shared table that produced a shared bill would hand one party the other's
  // food to pay for.
  const ctx = await setup()
  const a = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'A' })
  const b = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'B' })

  await addItem(ctx, a.id, { variantId: ctx.full, qty: 2 })
  await addItem(ctx, b.id, { variantId: ctx.full, qty: 1 })

  const billOf = async (orderId: string) => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/bills',
      headers: ctx.auth,
      payload: { orderId },
    })
    if (res.statusCode !== 201) throw new Error(`bill failed: ${res.body}`)
    return (res.json() as { bill: { id: string; total: number; orderId: string } }).bill
  }

  const billA = await billOf(a.id)
  const billB = await billOf(b.id)

  if (billA.id === billB.id) throw new Error('one bill covered both parties')
  assertEqual(billA.orderId, a.id, 'bill A belongs to order A')
  assertEqual(billB.orderId, b.id, 'bill B belongs to order B')

  // Two of the same item against one: A must be exactly twice B.
  assertEqual(billA.total, billB.total * 2, 'each party pays for its own items only')
  await close(ctx)
})

// --- items and snapshots ---

test('adding an item snapshots its name, price and tax rate', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const updated = await addItem(ctx, order.id, { variantId: ctx.full, qty: 2 })

  const line = updated.items[0]!
  assertEqual(line.itemName, 'Chicken Biryani')
  assertEqual(line.variantName, 'Full')
  assertEqual(line.unitPrice, 32_000)
  assertEqual(line.taxRate, 500)
  assertEqual(line.qty, 2)
  await close(ctx)
})

test('repricing the menu never alters a line already added', async () => {
  // FR-O9: the single most important rule for billing history.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.full) as { menu_item_id: string }

  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}/variants/${ctx.full}`,
    headers: ctx.auth,
    payload: { price: 99_000 },
  })

  const res = await ctx.app.inject({ method: 'GET', url: `/orders/${order.id}`, headers: ctx.auth })
  const line = (res.json() as { order: OrderPayload }).order.items[0]!
  assertEqual(line.unitPrice, 32_000, 'the order keeps the price it was placed at')
  await close(ctx)
})

test('renaming a dish never alters a line already added', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.tea, qty: 1 })

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.tea) as { menu_item_id: string }
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}`,
    headers: ctx.auth,
    payload: { name: 'Special Tea' },
  })

  const res = await ctx.app.inject({ method: 'GET', url: `/orders/${order.id}`, headers: ctx.auth })
  assertEqual((res.json() as { order: OrderPayload }).order.items[0]!.itemName, 'Masala Tea')
  await close(ctx)
})

test('adding the same variant twice merges into one line', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })
  const updated = await addItem(ctx, order.id, { variantId: ctx.full, qty: 2 })

  assertEqual(updated.items.length, 1)
  assertEqual(updated.items[0]!.qty, 3)
  await close(ctx)
})

test('a repriced re-add becomes a separate line', async () => {
  // Merging would force one of the two prices onto both, rewriting history.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.full) as { menu_item_id: string }
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}/variants/${ctx.full}`,
    headers: ctx.auth,
    payload: { price: 35_000 },
  })

  const updated = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })
  assertEqual(updated.items.length, 2)
  assertEqual(updated.items[0]!.unitPrice, 32_000)
  assertEqual(updated.items[1]!.unitPrice, 35_000)
  await close(ctx)
})

test('different notes keep lines separate', async () => {
  // The kitchen needs "no onion" on its own ticket line.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1, notes: 'no onion' })
  const updated = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  assertEqual(updated.items.length, 2)
  await close(ctx)
})

test('quantity can be changed and the line recalculates', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const withItem = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const res = await ctx.app.inject({
    method: 'PATCH',
    url: `/orders/${order.id}/items/${withItem.items[0]!.id}`,
    headers: ctx.auth,
    payload: { qty: 4 },
  })
  const updated = (res.json() as { order: OrderPayload }).order
  assertEqual(updated.items[0]!.qty, 4)
  assertEqual(updated.items[0]!.lineTotal, 32_000 * 4 + 6_400, 'exclusive 5% on 128000')
  await close(ctx)
})

test('a line can be removed', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const withItems = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })
  await addItem(ctx, order.id, { variantId: ctx.tea, qty: 1 })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/orders/${order.id}/items/${withItems.items[0]!.id}`,
    headers: ctx.auth,
  })
  assertEqual((res.json() as { order: OrderPayload }).order.items.length, 1)
  await close(ctx)
})

test('a bodyless DELETE that declares JSON still works', async () => {
  // The Flutter client sets Content-Type on every request. Fastify rejects a
  // JSON content-type with no body, which surfaced as "an unexpected error"
  // when a cashier tried to remove a line.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const withItems = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/orders/${order.id}/items/${withItems.items[0]!.id}`,
    headers: { ...ctx.auth, 'content-type': 'application/json' },
  })
  assertEqual(res.statusCode, 200, 'removing a line must not need a request body')
  assertEqual((res.json() as { order: OrderPayload }).order.items.length, 0)
  await close(ctx)
})

test('a client error is not reported as a server crash', async () => {
  // A 400 dressed up as a 500 sends whoever reads the log hunting for a server
  // bug that is not there.
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: { ...ctx.auth, 'content-type': 'application/json' },
    payload: '{ not json',
  })
  assertEqual(res.statusCode >= 400 && res.statusCode < 500, true, `got ${res.statusCode}`)
  await close(ctx)
})

test('an unavailable item cannot be ordered', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.full) as { menu_item_id: string }
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}`,
    headers: ctx.auth,
    payload: { isAvailable: false },
  })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.full, qty: 1 },
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'ITEM_UNAVAILABLE')
  await close(ctx)
})

test('a sold-out portion cannot be ordered while another still can', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })

  const item = ctx.db
    .prepare('SELECT menu_item_id FROM menu_item_variants WHERE id = ?')
    .get(ctx.full) as { menu_item_id: string }
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.menu_item_id}/variants/${ctx.full}`,
    headers: ctx.auth,
    payload: { isAvailable: false },
  })

  const soldOut = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.full, qty: 1 },
  })
  assertEqual(soldOut.statusCode, 409)
  assertEqual((soldOut.json() as { error: { code: string } }).error.code, 'VARIANT_UNAVAILABLE')

  const stillOk = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.half, qty: 1 },
  })
  assertEqual(stillOk.statusCode, 201, 'Half is still selling')
  await close(ctx)
})

// --- totals ---

test('order totals sum the lines, exclusive tax', async () => {
  const ctx = await setup('exclusive')
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 2 })
  const updated = await addItem(ctx, order.id, { variantId: ctx.tea, qty: 3 })

  // 2 x 32000 = 64000, 3 x 2000 = 6000; 5% on each
  assertEqual(updated.subtotal, 70_000)
  assertEqual(updated.tax, 3_200 + 300)
  assertEqual(updated.total, 73_500)
  assertEqual(updated.itemCount, 5)
  await close(ctx)
})

test('order totals sum the lines, inclusive tax', async () => {
  const ctx = await setup('inclusive')
  const order = await newOrder(ctx, { type: 'takeaway' })
  const updated = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  assertEqual(updated.total, 32_000, 'the customer pays the menu price')
  assertEqual(updated.subtotal + updated.tax, updated.total)
  await close(ctx)
})

// --- lifecycle ---

test('cancelling an order frees the table and records a reason', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Customer left' },
  })
  assertEqual(res.statusCode, 200)

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual((table.json() as { table: { status: string } }).table.status, 'free')

  const row = ctx.db
    .prepare('SELECT status, cancel_reason, deleted_at FROM orders WHERE id = ?')
    .get(order.id) as { status: string; cancel_reason: string; deleted_at: string | null }
  assertEqual(row.status, 'cancelled')
  assertEqual(row.cancel_reason, 'Customer left')
  if (row.deleted_at === null) throw new Error('a cancelled order should be soft-deleted')
  await close(ctx)
})

test('an order cancels without a reason', async () => {
  // Requiring one taught staff to type anything at all to get past the box,
  // which filled the record with noise that reads like data. The common
  // cancellation is an order opened on the wrong table seconds earlier.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: {},
  })
  assertEqual(res.statusCode, 200)

  const row = ctx.db
    .prepare('SELECT status, cancel_reason FROM orders WHERE id = ?')
    .get(order.id) as { status: string; cancel_reason: string | null }
  assertEqual(row.status, 'cancelled')
  assertEqual(row.cancel_reason, null, 'no reason recorded, rather than an empty one')

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual(
    (table.json() as { table: { status: string } }).table.status,
    'free',
    'the table is freed either way',
  )
  await close(ctx)
})

test('a blank reason is stored as none at all', async () => {
  // '' would read as a reason that happens to be empty, and a report would
  // show it as one.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })

  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: '   ' },
  })

  const row = ctx.db
    .prepare('SELECT cancel_reason FROM orders WHERE id = ?')
    .get(order.id) as { cancel_reason: string | null }
  assertEqual(row.cancel_reason, null)
  await close(ctx)
})

test('a reason is still kept when one is given', async () => {
  // Optional does not mean discarded — the times someone writes a real note
  // are exactly the times it matters.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })

  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Kitchen out of stock' },
  })

  const row = ctx.db
    .prepare('SELECT cancel_reason FROM orders WHERE id = ?')
    .get(order.id) as { cancel_reason: string | null }
  assertEqual(row.cancel_reason, 'Kitchen out of stock')
  await close(ctx)
})

test('cancelling one party leaves the table occupied by the other', async () => {
  const ctx = await setup()
  const a = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'A' })
  await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'B' })

  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${a.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Mis-tap' },
  })

  const table = await ctx.app.inject({
    method: 'GET',
    url: `/tables/${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual((table.json() as { table: { status: string } }).table.status, 'occupied')
  await close(ctx)
})

test('a cancelled order cannot be modified', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Test' },
  })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.full, qty: 1 },
  })
  assertEqual(res.statusCode, 409)
  await close(ctx)
})

test('a billed order cannot be modified', async () => {
  // FR-O14: it is a financial record now.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.tea, qty: 1 })
  ctx.db.prepare("UPDATE orders SET status = 'billed' WHERE id = ?").run(order.id)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.full, qty: 1 },
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'ORDER_NOT_OPEN')
  await close(ctx)
})

test('cancelling reports whether the kitchen needs telling', async () => {
  // FR-P19: a printed KOT means they are already cooking.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const withItem = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  ctx.db
    .prepare('UPDATE order_items SET kot_printed_at = ? WHERE id = ?')
    .run(new Date().toISOString(), withItem.items[0]!.id)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Customer changed mind' },
  })
  assertEqual((res.json() as { kotCancellationNeeded: boolean }).kotCancellationNeeded, true)
  await close(ctx)
})

test('removing a printed line reports that the kitchen is already cooking it', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const withItem = await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  ctx.db
    .prepare('UPDATE order_items SET kot_printed_at = ? WHERE id = ?')
    .run(new Date().toISOString(), withItem.items[0]!.id)

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/orders/${order.id}/items/${withItem.items[0]!.id}`,
    headers: ctx.auth,
  })
  assertEqual((res.json() as { kotAlreadyPrinted: boolean }).kotAlreadyPrinted, true)
  await close(ctx)
})

// --- KOT: a second ticket carries only what the kitchen has not seen ---

/** A kitchen printer, so the KOT route has somewhere to send to. */
async function addKotPrinter(ctx: Ctx): Promise<void> {
  await ctx.app.inject({
    method: 'POST',
    url: '/printers',
    headers: ctx.auth,
    payload: {
      name: 'Kitchen',
      connection: 'network',
      address: '127.0.0.1:9100',
      role: 'kot',
      paperWidth: '80mm',
    },
  })
}

/**
 * The words on the most recent print job, as the kitchen would read them.
 *
 * The payload column holds base64 — decoded first, then the ESC/POS control
 * bytes are stripped, so searching for a dish name is not defeated by a
 * formatting command sitting in the middle of it.
 */
function lastJobText(ctx: Ctx): string {
  const row = ctx.db
    .prepare('SELECT payload FROM print_jobs ORDER BY created_at DESC, rowid DESC LIMIT 1')
    .get() as { payload: string } | undefined
  if (!row) return ''
  return Buffer.from(row.payload, 'base64')
    .toString('utf8')
    .replace(/[\x00-\x1f]/g, ' ')
}

test('a second KOT prints only the items added since the first', async () => {
  // The question this answers: reprinting the whole order would have the
  // kitchen cook the first dishes twice, and a restaurant discovers that at
  // the pass, mid-service.
  const ctx = await setup()
  await addKotPrinter(ctx)

  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const first = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/kot`,
    headers: ctx.auth,
  })
  assertEqual(first.statusCode, 200)

  // A second dish, ordered after the first ticket went to the kitchen.
  await addItem(ctx, order.id, { variantId: ctx.half, qty: 1 })

  const second = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/kot`,
    headers: ctx.auth,
  })
  assertEqual(second.statusCode, 200)

  const text = lastJobText(ctx)

  assertEqual(text.includes('ADDED ITEMS'), true, 'headed as an addition, not a fresh order')
  assertEqual(
    text.includes('Half'),
    true,
    'the newly added portion is on the ticket',
  )
  assertEqual(
    text.includes('Full'),
    false,
    'the portion already cooking is NOT repeated',
  )

  await close(ctx)
})

test('a KOT with nothing new is refused', async () => {
  // Pressing the button twice must not send a blank ticket the kitchen has to
  // interpret.
  const ctx = await setup()
  await addKotPrinter(ctx)

  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  await ctx.app.inject({ method: 'POST', url: `/orders/${order.id}/kot`, headers: ctx.auth })
  const again = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/kot`,
    headers: ctx.auth,
  })

  assertEqual(again.statusCode, 409)
  assertEqual((again.json() as { error: { code: string } }).error.code, 'NOTHING_TO_SEND')
  await close(ctx)
})

test('the first KOT is headed as a new order, not an addition', async () => {
  const ctx = await setup()
  await addKotPrinter(ctx)

  const order = await newOrder(ctx, { type: 'takeaway' })
  await addItem(ctx, order.id, { variantId: ctx.full, qty: 1 })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/kot`,
    headers: ctx.auth,
  })
  const text = lastJobText(ctx)

  assertEqual(text.includes('ADDED ITEMS'), false, 'not an addition')
  assertEqual(text.includes('KOT'), true, 'a fresh ticket')
  await close(ctx)
})

// --- concurrency ---

test('a stale version is rejected rather than overwriting', async () => {
  // FR-O15: two terminals must not silently clobber each other.
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId })

  await ctx.app.inject({
    method: 'PATCH',
    url: `/orders/${order.id}`,
    headers: ctx.auth,
    payload: { seatLabel: 'A', version: order.version },
  })

  // Second terminal still holds the original version.
  const stale = await ctx.app.inject({
    method: 'PATCH',
    url: `/orders/${order.id}`,
    headers: ctx.auth,
    payload: { seatLabel: 'B', version: order.version },
  })
  assertEqual(stale.statusCode, 409)
  assertEqual((stale.json() as { error: { code: string } }).error.code, 'ORDER_MODIFIED')
  await close(ctx)
})

test('the version increases as an order changes', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  const after = await addItem(ctx, order.id, { variantId: ctx.tea, qty: 1 })
  if (after.version <= order.version) throw new Error('version did not advance')
  await close(ctx)
})

// --- listing ---

test('open orders can be listed for a table', async () => {
  const ctx = await setup()
  await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'A' })
  await newOrder(ctx, { type: 'dine_in', tableId: ctx.tableId, seatLabel: 'B' })
  await newOrder(ctx, { type: 'takeaway' })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/orders?status=open&tableId=${ctx.tableId}`,
    headers: ctx.auth,
  })
  assertEqual((res.json() as { orders: unknown[] }).orders.length, 2)
  await close(ctx)
})

test('a cancelled order is hidden from listings', async () => {
  const ctx = await setup()
  const order = await newOrder(ctx, { type: 'takeaway' })
  await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/cancel`,
    headers: ctx.auth,
    payload: { reason: 'Test' },
  })

  const res = await ctx.app.inject({ method: 'GET', url: '/orders', headers: ctx.auth })
  assertEqual((res.json() as { orders: unknown[] }).orders.length, 0)
  await close(ctx)
})
