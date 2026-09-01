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
