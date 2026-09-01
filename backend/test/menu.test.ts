import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  admin: Record<string, string>
  cashier: Record<string, string>
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })

  const admin = await login(app, 'admin', 'admin123')
  await app.inject({
    method: 'POST',
    url: '/users',
    headers: admin,
    payload: { username: 'cash', password: 'cash123', fullName: 'Cash', role: 'cashier' },
  })
  const cashier = await login(app, 'cash', 'cash123')

  return { app, db, admin, cashier }
}

async function login(
  app: FastifyInstance,
  username: string,
  password: string,
): Promise<Record<string, string>> {
  const res = await app.inject({ method: 'POST', url: '/auth/login', payload: { username, password } })
  return { authorization: `Bearer ${(res.json() as { token: string }).token}` }
}

async function makeCategory(ctx: Ctx, name: string): Promise<string> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/categories',
    headers: ctx.admin,
    payload: { name },
  })
  return (res.json() as { category: { id: string } }).category.id
}

interface ItemPayload {
  id: string
  name: string
  taxRate: number
  isAvailable: boolean
  variants: { id: string; name: string; price: number; isAvailable: boolean }[]
}

async function makeItem(
  ctx: Ctx,
  payload: Record<string, unknown>,
): Promise<ItemPayload> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: ctx.admin,
    payload,
  })
  if (res.statusCode !== 201) throw new Error(`create failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { item: ItemPayload }).item
}

const close = async (ctx: Ctx) => {
  await ctx.app.close()
  ctx.db.close()
}

// --- categories ---

test('an admin can create and list categories', async () => {
  const ctx = await setup()
  await makeCategory(ctx, 'Starters')
  await makeCategory(ctx, 'Biryani')

  const res = await ctx.app.inject({ method: 'GET', url: '/categories', headers: ctx.admin })
  const body = res.json() as { categories: { name: string; sortOrder: number }[] }
  assertEqual(body.categories.length, 2)
  assertEqual(body.categories[0]!.sortOrder, 0)
  assertEqual(body.categories[1]!.sortOrder, 1, 'sort order auto-increments')
  await close(ctx)
})

test('a cashier can read the menu but not change it', async () => {
  const ctx = await setup()
  await makeCategory(ctx, 'Starters')

  assertEqual(
    (await ctx.app.inject({ method: 'GET', url: '/categories', headers: ctx.cashier })).statusCode,
    200,
    'cashiers take orders, so they must read the menu',
  )
  assertEqual(
    (
      await ctx.app.inject({
        method: 'POST',
        url: '/categories',
        headers: ctx.cashier,
        payload: { name: 'Sneaky' },
      })
    ).statusCode,
    403,
  )
  await close(ctx)
})

test('duplicate category names are rejected, case-insensitively', async () => {
  const ctx = await setup()
  await makeCategory(ctx, 'Starters')

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/categories',
    headers: ctx.admin,
    payload: { name: 'starters' },
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'CATEGORY_EXISTS')
  await close(ctx)
})

test('a category with items cannot be deleted', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')
  await makeItem(ctx, { categoryId, name: 'Chicken Biryani', price: 32_000 })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/categories/${categoryId}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'CATEGORY_NOT_EMPTY')
  await close(ctx)
})

test('an empty category can be deleted and disappears from the list', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Temporary')

  assertEqual(
    (await ctx.app.inject({ method: 'DELETE', url: `/categories/${categoryId}`, headers: ctx.admin }))
      .statusCode,
    200,
  )
  const list = await ctx.app.inject({ method: 'GET', url: '/categories', headers: ctx.admin })
  assertEqual((list.json() as { categories: unknown[] }).categories.length, 0)
  await close(ctx)
})

test('reordering categories rewrites their sort order', async () => {
  const ctx = await setup()
  const a = await makeCategory(ctx, 'A')
  const b = await makeCategory(ctx, 'B')
  const c = await makeCategory(ctx, 'C')

  await ctx.app.inject({
    method: 'POST',
    url: '/categories/reorder',
    headers: ctx.admin,
    payload: { ids: [c, a, b] },
  })

  const res = await ctx.app.inject({ method: 'GET', url: '/categories', headers: ctx.admin })
  const names = (res.json() as { categories: { name: string }[] }).categories.map((x) => x.name)
  assertEqual(names.join(','), 'C,A,B')
  await close(ctx)
})

// --- menu items and variants ---

test('an item with no portions gets a single Standard variant', async () => {
  // FR-M5: order lines always reference a variant, so there is one code path.
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Beverages')
  const item = await makeItem(ctx, { categoryId, name: 'Masala Tea', price: 2_000 })

  assertEqual(item.variants.length, 1)
  assertEqual(item.variants[0]!.name, 'Standard')
  assertEqual(item.variants[0]!.price, 2_000)
  await close(ctx)
})

test('an item can be created with several portions', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')
  const item = await makeItem(ctx, {
    categoryId,
    name: 'Chicken Biryani',
    variants: [
      { name: 'Half', price: 18_000 },
      { name: 'Full', price: 32_000 },
    ],
  })

  assertEqual(item.variants.length, 2)
  assertEqual(item.variants[0]!.name, 'Half')
  assertEqual(item.variants[1]!.price, 32_000)
  await close(ctx)
})

test('an item inherits the branch tax rate, and can override it', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Food')

  const inherited = await makeItem(ctx, { categoryId, name: 'Idli', price: 4_000 })
  assertEqual(inherited.taxRate, 500, 'defaults to the seeded 5%')

  const overridden = await makeItem(ctx, {
    categoryId,
    name: 'Bottled Water',
    price: 2_000,
    taxRate: 1_800,
  })
  assertEqual(overridden.taxRate, 1_800)
  await close(ctx)
})

test('duplicate portion names on one item are rejected', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: ctx.admin,
    payload: {
      categoryId,
      name: 'Mutton Biryani',
      variants: [
        { name: 'Full', price: 40_000 },
        { name: 'full', price: 42_000 },
      ],
    },
  })
  assertEqual(res.statusCode, 400)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'DUPLICATE_VARIANT')
  await close(ctx)
})

test('a portion can be added to an existing item', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')
  const item = await makeItem(ctx, { categoryId, name: 'Egg Biryani', price: 20_000 })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/menu-items/${item.id}/variants`,
    headers: ctx.admin,
    payload: { name: 'Family Pack', price: 60_000 },
  })
  assertEqual(res.statusCode, 201)
  assertEqual((res.json() as { item: ItemPayload }).item.variants.length, 2)
  await close(ctx)
})

test('the last portion cannot be deleted', async () => {
  // FR-M6: an item with no portions could not be ordered at all.
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Beverages')
  const item = await makeItem(ctx, { categoryId, name: 'Filter Coffee', price: 3_000 })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/menu-items/${item.id}/variants/${item.variants[0]!.id}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 409)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'LAST_VARIANT')
  await close(ctx)
})

test('a portion can be deleted while others remain', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')
  const item = await makeItem(ctx, {
    categoryId,
    name: 'Veg Biryani',
    variants: [
      { name: 'Half', price: 14_000 },
      { name: 'Full', price: 24_000 },
    ],
  })

  const res = await ctx.app.inject({
    method: 'DELETE',
    url: `/menu-items/${item.id}/variants/${item.variants[0]!.id}`,
    headers: ctx.admin,
  })
  assertEqual(res.statusCode, 200)
  assertEqual((res.json() as { item: ItemPayload }).item.variants.length, 1)
  await close(ctx)
})

test('one portion can be marked sold out while another stays available', async () => {
  // FR-M9: Full sold out, Half still selling.
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Biryani')
  const item = await makeItem(ctx, {
    categoryId,
    name: 'Prawn Biryani',
    variants: [
      { name: 'Half', price: 22_000 },
      { name: 'Full', price: 38_000 },
    ],
  })

  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.id}/variants/${item.variants[1]!.id}`,
    headers: ctx.admin,
    payload: { isAvailable: false },
  })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/menu-items/${item.id}`,
    headers: ctx.admin,
  })
  const variants = (res.json() as { item: ItemPayload }).item.variants
  assertEqual(variants[0]!.isAvailable, true)
  assertEqual(variants[1]!.isAvailable, false)
  await close(ctx)
})

test('an unavailable item still appears on the menu', async () => {
  // FR-M8: it stays listed, it just cannot be ordered.
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Specials')
  const item = await makeItem(ctx, { categoryId, name: 'Sunday Special', price: 15_000 })

  await ctx.app.inject({
    method: 'PATCH',
    url: `/menu-items/${item.id}`,
    headers: ctx.admin,
    payload: { isAvailable: false },
  })

  const all = await ctx.app.inject({ method: 'GET', url: '/menu-items', headers: ctx.admin })
  assertEqual((all.json() as { items: unknown[] }).items.length, 1)

  const available = await ctx.app.inject({
    method: 'GET',
    url: '/menu-items?availableOnly=true',
    headers: ctx.admin,
  })
  assertEqual((available.json() as { items: unknown[] }).items.length, 0)
  await close(ctx)
})

test('a deleted item is soft-deleted, so order history stays resolvable', async () => {
  // FR-M11: order lines reference a variant id.
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Old Menu')
  const item = await makeItem(ctx, { categoryId, name: 'Discontinued Dish', price: 10_000 })

  await ctx.app.inject({ method: 'DELETE', url: `/menu-items/${item.id}`, headers: ctx.admin })

  const list = await ctx.app.inject({ method: 'GET', url: '/menu-items', headers: ctx.admin })
  assertEqual((list.json() as { items: unknown[] }).items.length, 0, 'hidden from the menu')

  const row = ctx.db.prepare('SELECT deleted_at FROM menu_items WHERE id = ?').get(item.id) as {
    deleted_at: string | null
  }
  if (row.deleted_at === null) throw new Error('the row was hard-deleted')

  const variants = ctx.db
    .prepare('SELECT deleted_at FROM menu_item_variants WHERE menu_item_id = ?')
    .all(item.id) as { deleted_at: string | null }[]
  if (variants.some((v) => v.deleted_at === null)) {
    throw new Error('variants were left live under a deleted item')
  }
  await close(ctx)
})

test('prices are stored as integer paise exactly as sent', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Food')
  const item = await makeItem(ctx, { categoryId, name: 'Ghee Roast', price: 18_550 })

  const stored = ctx.db
    .prepare('SELECT price FROM menu_item_variants WHERE menu_item_id = ?')
    .get(item.id) as { price: number }
  assertEqual(stored.price, 18_550, 'Rs185.50 is 18550 paise')
  if (!Number.isInteger(stored.price)) throw new Error('price is not an integer')
  await close(ctx)
})

test('a negative price is rejected', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Food')

  const res = await ctx.app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: ctx.admin,
    payload: { categoryId, name: 'Impossible', price: -100 },
  })
  assertEqual(res.statusCode, 400)
  await close(ctx)
})

test('an item cannot be created in a category that does not exist', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/menu-items',
    headers: ctx.admin,
    payload: {
      categoryId: '00000000-0000-4000-8000-000000000000',
      name: 'Orphan',
      price: 1_000,
    },
  })
  assertEqual(res.statusCode, 404)
  await close(ctx)
})

test('items can be filtered by category', async () => {
  const ctx = await setup()
  const biryani = await makeCategory(ctx, 'Biryani')
  const drinks = await makeCategory(ctx, 'Drinks')
  await makeItem(ctx, { categoryId: biryani, name: 'Chicken Biryani', price: 32_000 })
  await makeItem(ctx, { categoryId: drinks, name: 'Lime Soda', price: 5_000 })

  const res = await ctx.app.inject({
    method: 'GET',
    url: `/menu-items?categoryId=${drinks}`,
    headers: ctx.admin,
  })
  const items = (res.json() as { items: { name: string }[] }).items
  assertEqual(items.length, 1)
  assertEqual(items[0]!.name, 'Lime Soda')
  await close(ctx)
})

test('a cashier cannot create or reprice menu items', async () => {
  const ctx = await setup()
  const categoryId = await makeCategory(ctx, 'Food')
  const item = await makeItem(ctx, { categoryId, name: 'Dosa', price: 8_000 })

  assertEqual(
    (
      await ctx.app.inject({
        method: 'POST',
        url: '/menu-items',
        headers: ctx.cashier,
        payload: { categoryId, name: 'Free Dosa', price: 0 },
      })
    ).statusCode,
    403,
  )
  assertEqual(
    (
      await ctx.app.inject({
        method: 'PATCH',
        url: `/menu-items/${item.id}/variants/${item.variants[0]!.id}`,
        headers: ctx.cashier,
        payload: { price: 1 },
      })
    ).statusCode,
    403,
  )
  await close(ctx)
})
