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

async function login(
  app: FastifyInstance,
  username: string,
  password: string,
): Promise<Record<string, string>> {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username, password },
  })
  const { token } = res.json() as { token: string }
  return { authorization: `Bearer ${token}` }
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

async function close(ctx: Ctx): Promise<void> {
  await ctx.app.close()
  ctx.db.close()
}

interface Settings {
  taxMode: string
  defaultTaxRate: number
  businessDayStart: string
  billPrefix: string
  billResetPeriod: string
  billNumberFormat: string
  billNumberPad: number
  billFooter: string
  roundOffEnabled: boolean
}

async function patch(
  ctx: Ctx,
  payload: Record<string, unknown>,
  headers = ctx.admin,
): Promise<{ status: number; settings: Settings | undefined; code: string | undefined }> {
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: '/settings',
    headers,
    payload,
  })
  const body = res.json() as { settings?: Settings; error?: { code: string } }
  return { status: res.statusCode, settings: body.settings, code: body.error?.code }
}

// --- reading ---

test('settings come back with sane defaults', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({ method: 'GET', url: '/settings', headers: ctx.cashier })
  const { settings } = res.json() as { settings: Settings }

  assertEqual(settings.taxMode, 'inclusive')
  assertEqual(settings.defaultTaxRate, 500, '5% in basis points')
  assertEqual(settings.businessDayStart, '05:00')
  await close(ctx)
})

test('a cashier can read settings but not change them', async () => {
  // The till needs the tax mode to show correct figures, so reading is open.
  const ctx = await setup()
  const read = await ctx.app.inject({ method: 'GET', url: '/settings', headers: ctx.cashier })
  assertEqual(read.statusCode, 200)

  const write = await patch(ctx, { defaultTaxRate: 1800 }, ctx.cashier)
  assertEqual(write.status, 403, 'only an admin changes how bills are calculated')
  await close(ctx)
})

// --- tax ---

test('the tax rate is stored as basis points', async () => {
  const ctx = await setup()
  const result = await patch(ctx, { defaultTaxRate: 1800 })
  assertEqual(result.settings!.defaultTaxRate, 1800, '18%')
  await close(ctx)
})

test('a tax rate above 100 percent is rejected', async () => {
  // 10000 basis points is 100%. Anything beyond is a typo, and it would show up
  // as an overcharge rather than an error.
  const ctx = await setup()
  const result = await patch(ctx, { defaultTaxRate: 10_001 })
  assertEqual(result.status, 400)
  await close(ctx)
})

test('changing the tax mode does not touch settings already read', async () => {
  const ctx = await setup()
  const changed = await patch(ctx, { taxMode: 'exclusive' })
  assertEqual(changed.settings!.taxMode, 'exclusive')
  await close(ctx)
})

// --- bill numbering ---

test('a format without {NO} is refused', async () => {
  // Every bill in the period would otherwise print the same string, which is
  // not something anyone notices until an audit.
  const ctx = await setup()
  const result = await patch(ctx, { billNumberFormat: '{PREFIX}{YYYY}' })
  assertEqual(result.status, 400)
  assertEqual(result.code, 'FORMAT_MISSING_NUMBER')
  await close(ctx)
})

test('a format with {NO} is accepted', async () => {
  const ctx = await setup()
  const result = await patch(ctx, { billNumberFormat: '{PREFIX}/{FY}/{NO}' })
  assertEqual(result.settings!.billNumberFormat, '{PREFIX}/{FY}/{NO}')
  await close(ctx)
})

test('the preview shows what a bill number would look like', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/settings/bill-number-preview',
    headers: ctx.admin,
    payload: { format: '{PREFIX}-{NO}', prefix: 'CE', pad: 4 },
  })
  const { preview } = res.json() as { preview: string }
  assertEqual(preview, 'CE-0042', 'sample bill 42, padded to four')
  await close(ctx)
})

test('padding widens the number without changing it', async () => {
  const ctx = await setup()
  const narrow = await ctx.app.inject({
    method: 'POST',
    url: '/settings/bill-number-preview',
    headers: ctx.admin,
    payload: { format: '{NO}', prefix: '', pad: 3 },
  })
  const wide = await ctx.app.inject({
    method: 'POST',
    url: '/settings/bill-number-preview',
    headers: ctx.admin,
    payload: { format: '{NO}', prefix: '', pad: 6 },
  })
  assertEqual((narrow.json() as { preview: string }).preview, '042')
  assertEqual((wide.json() as { preview: string }).preview, '000042')
  await close(ctx)
})

// --- business day ---

test('the business day start must be a real time', async () => {
  const ctx = await setup()
  assertEqual((await patch(ctx, { businessDayStart: '25:00' })).status, 400, 'hour 25')
  assertEqual((await patch(ctx, { businessDayStart: '05:99' })).status, 400, 'minute 99')
  assertEqual((await patch(ctx, { businessDayStart: '5:00' })).status, 400, 'unpadded')
  assertEqual((await patch(ctx, { businessDayStart: '04:30' })).settings!.businessDayStart, '04:30')
  await close(ctx)
})

// --- branch details, which print on the bill ---

test('branch details can be set and read back', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: '/branch',
    headers: ctx.admin,
    payload: {
      name: 'Chennai Express',
      address: '12 Mount Road, Chennai',
      phone: '04412345678',
      gstin: '33ABCDE1234F1Z5',
    },
  })
  const { branch } = res.json() as {
    branch: { name: string; address: string; gstin: string }
  }
  assertEqual(branch.name, 'Chennai Express')
  assertEqual(branch.gstin, '33ABCDE1234F1Z5')
  await close(ctx)
})

test('a GSTIN is stored uppercase', async () => {
  // Case-insensitive in law, but printed uppercase on every invoice — mixed
  // case on a tax document reads as an error.
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: '/branch',
    headers: ctx.admin,
    payload: { gstin: '33abcde1234f1z5' },
  })
  const { branch } = res.json() as { branch: { gstin: string } }
  assertEqual(branch.gstin, '33ABCDE1234F1Z5')
  await close(ctx)
})

test('a malformed GSTIN is rejected', async () => {
  const ctx = await setup()
  for (const bad of ['33ABCDE1234F1Z', 'ABCDE1234F1Z5XX', '3333333333333333']) {
    const res = await ctx.app.inject({
      method: 'PATCH',
      url: '/branch',
      headers: ctx.admin,
      payload: { gstin: bad },
    })
    assertEqual(res.statusCode, 400, `"${bad}" should be refused`)
  }
  await close(ctx)
})

test('the GSTIN can be cleared', async () => {
  // A restaurant below the registration threshold has none to print.
  const ctx = await setup()
  await ctx.app.inject({
    method: 'PATCH',
    url: '/branch',
    headers: ctx.admin,
    payload: { gstin: '33ABCDE1234F1Z5' },
  })
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: '/branch',
    headers: ctx.admin,
    payload: { gstin: null },
  })
  const { branch } = res.json() as { branch: { gstin: string | null } }
  assertEqual(branch.gstin, null)
  await close(ctx)
})

test('only an admin changes branch details', async () => {
  const ctx = await setup()
  const res = await ctx.app.inject({
    method: 'PATCH',
    url: '/branch',
    headers: ctx.cashier,
    payload: { name: 'Renamed' },
  })
  assertEqual(res.statusCode, 403)
  await close(ctx)
})
