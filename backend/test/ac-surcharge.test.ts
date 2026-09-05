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
  /** An AC section charging Rs10 a plate, and a table in it. */
  acTable: string
  /** A section charging nothing extra, and a table in it. */
  plainTable: string
  acSectionId: string
  /** Chicken Soup, Standard at Rs75. */
  soup: string
  soupItemId: string
  /** Masala Tea, Standard at Rs20. */
  tea: string
  teaItemId: string
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  const { branchId } = await seedIfEmpty(db, env)
  setSetting(db, branchId, 'tax_mode', 'exclusive')

  const app = await buildServer({ db, env })
  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const auth = { authorization: `Bearer ${(login.json() as { token: string }).token}` }

  const post = (url: string, payload: Record<string, unknown>) =>
    app.inject({ method: 'POST', url, headers: auth, payload })

  const acSection = await post('/sections', { name: 'AC', surcharge: 1_000 })
  const acSectionId = (acSection.json() as { section: { id: string } }).section.id

  const plainSection = await post('/sections', { name: 'Non-AC' })
  const plainSectionId = (plainSection.json() as { section: { id: string } }).section.id

  const acTableRes = await post('/tables', { sectionId: acSectionId, name: 'AC1', seats: 4 })
  const plainTableRes = await post('/tables', { sectionId: plainSectionId, name: 'N1', seats: 4 })

  const category = await post('/categories', { name: 'Food' })
  const categoryId = (category.json() as { category: { id: string } }).category.id

  const soupRes = await post('/menu-items', {
    categoryId,
    name: 'Chicken Soup',
    price: 7_500,
  })
  const soupItem = (soupRes.json() as { item: { id: string; variants: { id: string }[] } }).item

  const teaRes = await post('/menu-items', {
    categoryId,
    name: 'Masala Tea',
    price: 2_000,
  })
  const teaItem = (teaRes.json() as { item: { id: string; variants: { id: string }[] } }).item

  return {
    app,
    db,
    auth,
    acSectionId,
    acTable: (acTableRes.json() as { table: { id: string } }).table.id,
    plainTable: (plainTableRes.json() as { table: { id: string } }).table.id,
    soup: soupItem.variants[0]!.id,
    soupItemId: soupItem.id,
    tea: teaItem.variants[0]!.id,
    teaItemId: teaItem.id,
  }
}

interface OrderPayload {
  id: string
  items: { itemName: string; unitPrice: number; qty: number; lineTotal: number }[]
  subtotal: number
  total: number
}

async function orderAt(
  ctx: Ctx,
  tableId: string | null,
  lines: { variantId: string; qty?: number }[],
): Promise<OrderPayload> {
  const created = await ctx.app.inject({
    method: 'POST',
    url: '/orders',
    headers: ctx.auth,
    payload: tableId === null ? { type: 'takeaway' } : { type: 'dine_in', tableId },
  })
  const order = (created.json() as { order: { id: string } }).order

  let latest = created
  for (const line of lines) {
    latest = await ctx.app.inject({
      method: 'POST',
      url: `/orders/${order.id}/items`,
      headers: ctx.auth,
      payload: { variantId: line.variantId, qty: line.qty ?? 1 },
    })
  }

  return (latest.json() as { order: OrderPayload }).order
}

// --- the price that gets charged ---

test('an item at an AC table costs the surcharge more', async () => {
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])

  assertEqual(order.items[0]!.unitPrice, 8_500, 'Rs75 soup at Rs85')
  await ctx.app.close()
})

test('the same item elsewhere costs the menu price', async () => {
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.plainTable, [{ variantId: ctx.soup }])

  assertEqual(order.items[0]!.unitPrice, 7_500)
  await ctx.app.close()
})

test('a takeaway pays the menu price', async () => {
  // No table means no air-conditioned room to charge for.
  const ctx = await setup()
  const order = await orderAt(ctx, null, [{ variantId: ctx.soup }])

  assertEqual(order.items[0]!.unitPrice, 7_500)
  await ctx.app.close()
})

test('the surcharge is per item, not per order', async () => {
  // Three soups carry Rs30 between them. Adding it once would undercharge.
  // Asserted on the base rather than lineTotal, which in exclusive mode also
  // carries the GST on top.
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup, qty: 3 }])

  assertEqual(order.subtotal, 25_500, '3 x Rs85 before tax')
  assertEqual(order.items[0]!.unitPrice * order.items[0]!.qty, 25_500)
  await ctx.app.close()
})

test('tax is computed on the surcharged price', async () => {
  // The whole reason the surcharge goes into unit_price rather than onto the
  // bill: GST is owed on what the customer actually paid.
  const ctx = await setup()
  const db = ctx.db
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])

  const line = db
    .prepare('SELECT unit_price, line_base, line_tax FROM order_items WHERE order_id = ?')
    .get(order.id) as { unit_price: number; line_base: number; line_tax: number }

  assertEqual(line.unit_price, 8_500)
  assertEqual(line.line_base, 8_500, 'exclusive: base is the charged price')
  await ctx.app.close()
})

// --- the item override ---

test('an item exempted with zero stays at the menu price', async () => {
  const ctx = await setup()
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${ctx.teaItemId}`,
    headers: ctx.auth,
    payload: { acSurcharge: 0 },
  })

  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.tea }])
  assertEqual(order.items[0]!.unitPrice, 2_000, 'tea stays Rs20 in the AC room')
  await ctx.app.close()
})

test('an item can charge its own amount instead', async () => {
  const ctx = await setup()
  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${ctx.soupItemId}`,
    headers: ctx.auth,
    payload: { acSurcharge: 2_500 },
  })

  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])
  assertEqual(order.items[0]!.unitPrice, 10_000, 'Rs75 + its own Rs25')
  await ctx.app.close()
})

test('an override survives the round trip, including zero', async () => {
  // Zero and null are different states. If the API collapses them, an exempt
  // item silently starts taking the section's amount again.
  const ctx = await setup()

  const zeroed = await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${ctx.teaItemId}`,
    headers: ctx.auth,
    payload: { acSurcharge: 0 },
  })
  assertEqual((zeroed.json() as { item: { acSurcharge: number | null } }).item.acSurcharge, 0)

  const cleared = await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${ctx.teaItemId}`,
    headers: ctx.auth,
    payload: { acSurcharge: null },
  })
  assertEqual(
    (cleared.json() as { item: { acSurcharge: number | null } }).item.acSurcharge,
    null,
    'back to following its section',
  )

  await ctx.app.close()
})

test('clearing an override puts the item back on its section', async () => {
  const ctx = await setup()
  const patch = async (value: number | null) =>
    ctx.app.inject({
      method: 'PATCH',
      url: `/menu-items/${ctx.teaItemId}`,
      headers: ctx.auth,
      payload: { acSurcharge: value },
    })

  await patch(0)
  await patch(null)

  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.tea }])
  assertEqual(order.items[0]!.unitPrice, 3_000, 'Rs20 tea taking the section Rs10 again')
  await ctx.app.close()
})

// --- the snapshot rule ---

test('changing a section does not reprice food already ordered', async () => {
  // The rule the whole design rests on. A party mid-meal must not have their
  // placed order rewritten because an admin edited a setting.
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])
  assertEqual(order.items[0]!.unitPrice, 8_500)

  await ctx.app.inject({
    method: 'PATCH',
    url: `/sections/${ctx.acSectionId}`,
    headers: ctx.auth,
    payload: { surcharge: 5_000 },
  })

  const after = await ctx.app.inject({
    method: 'GET',
    url: `/orders/${order.id}`,
    headers: ctx.auth,
  })
  const items = (after.json() as { order: OrderPayload }).order.items
  assertEqual(items[0]!.unitPrice, 8_500, 'still what it was ordered at')

  await ctx.app.close()
})

test('a new line after the change takes the new amount', async () => {
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])

  await ctx.app.inject({
    method: 'PATCH',
    url: `/sections/${ctx.acSectionId}`,
    headers: ctx.auth,
    payload: { surcharge: 5_000 },
  })

  const added = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.tea, qty: 1 },
  })

  const items = (added.json() as { order: OrderPayload }).order.items
  const teaLine = items.find((i) => i.itemName === 'Masala Tea')!
  assertEqual(teaLine.unitPrice, 7_000, 'Rs20 tea plus the new Rs50')

  await ctx.app.close()
})

test('two adds at the same price merge into one line', async () => {
  // The merge matches on unit_price, which now carries the surcharge. Both
  // adds compute the same figure, so they must still merge.
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [
    { variantId: ctx.soup },
    { variantId: ctx.soup },
  ])

  assertEqual(order.items.length, 1)
  assertEqual(order.items[0]!.qty, 2)
  assertEqual(order.items[0]!.unitPrice, 8_500)
  await ctx.app.close()
})

test('adds either side of a change stay separate lines', async () => {
  // Each carries its own price, so they cannot share a line. Collapsing them
  // would reprice one of the two.
  const ctx = await setup()
  const order = await orderAt(ctx, ctx.acTable, [{ variantId: ctx.soup }])

  await ctx.app.inject({
    method: 'PATCH',
    url: `/sections/${ctx.acSectionId}`,
    headers: ctx.auth,
    payload: { surcharge: 5_000 },
  })

  const added = await ctx.app.inject({
    method: 'POST',
    url: `/orders/${order.id}/items`,
    headers: ctx.auth,
    payload: { variantId: ctx.soup, qty: 1 },
  })

  const items = (added.json() as { order: OrderPayload }).order.items
  assertEqual(items.length, 2, 'two prices, two lines')
  assertEqual(items[0]!.unitPrice + items[1]!.unitPrice, 8_500 + 12_500)
  await ctx.app.close()
})

// --- the section API ---

test('a section defaults to charging nothing extra', async () => {
  // The day this ships, no price moves anywhere until someone sets one.
  const ctx = await setup()
  const created = await ctx.app.inject({
    method: 'POST',
    url: '/sections',
    headers: ctx.auth,
    payload: { name: 'Terrace' },
  })

  assertEqual((created.json() as { section: { surcharge: number } }).section.surcharge, 0)
  await ctx.app.close()
})

test('a negative surcharge is refused', async () => {
  // It would be a discount that skips the discount rules — unrecorded, and
  // able to take a line below zero.
  const ctx = await setup()
  const created = await ctx.app.inject({
    method: 'POST',
    url: '/sections',
    headers: ctx.auth,
    payload: { name: 'Odd', surcharge: -1_000 },
  })

  assertEqual(created.statusCode, 400)
  await ctx.app.close()
})

test('a fractional surcharge is refused', async () => {
  const ctx = await setup()
  const created = await ctx.app.inject({
    method: 'POST',
    url: '/sections',
    headers: ctx.auth,
    payload: { name: 'Odd', surcharge: 10.5 },
  })

  assertEqual(created.statusCode, 400)
  await ctx.app.close()
})
