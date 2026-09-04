import { openDatabase } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

async function setup() {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })
  return { app, db }
}

// --- the error shape the client can actually read ---

test('a rejected key is reported as a structured error', async () => {
  // The client reads `error` as an object: `json['error'] as Map?`. These routes
  // sent a bare string, so the cast yielded null, the real message was thrown
  // away, and the screen showed "Cannot reach the billing service on this PC" —
  // for a key that had been read, understood and refused by a backend that
  // answered in milliseconds.
  const { app, db } = await setup()

  const res = await app.inject({
    method: 'POST',
    url: '/activation/claim',
    payload: { key: 'CX-AAAA-BBBB-CCCC' },
  })

  // 400 when no cloud is configured in tests, 403 when one is. Either way the
  // shape is what this asserts.
  const body = res.json() as { error?: { code?: string; message?: string } | string }

  if (typeof body.error === 'string') {
    throw new Error('error must be an object, not a string — the client cannot read a string')
  }
  if (!body.error?.message) throw new Error('no message for the screen to show')
  if (!body.error?.code) throw new Error('no code for the client to branch on')

  await app.close()
  db.close()
})

test('an empty key is refused with a message, not a crash', async () => {
  const { app, db } = await setup()

  const res = await app.inject({ method: 'POST', url: '/activation/claim', payload: {} })
  assertEqual(res.statusCode, 400, 'a missing key is a bad request')

  const body = res.json() as { error?: { code?: string; message?: string } }
  assertEqual(body.error?.code, 'KEY_REQUIRED', 'named so the client can branch on it')
  if (!body.error?.message) throw new Error('no message for the screen')

  await app.close()
  db.close()
})

test('a malformed key is told so plainly', async () => {
  // Distinct from a rejected one: "that is not a key" and "that key is not
  // yours" are different problems, and only the first is a typing mistake.
  const { app, db } = await setup()

  const res = await app.inject({
    method: 'POST',
    url: '/activation/claim',
    payload: { key: 'nonsense' },
  })
  assertEqual(res.statusCode, 400)

  const body = res.json() as { error?: { code?: string } }
  assertEqual(body.error?.code, 'KEY_MALFORMED')

  await app.close()
  db.close()
})

test('status answers without a licence rather than failing', async () => {
  // This runs before anyone can sign in, on a machine that has never been
  // activated. It has to return a verdict, never an error.
  const { app, db } = await setup()

  const res = await app.inject({ method: 'GET', url: '/activation/status' })
  assertEqual(res.statusCode, 200)

  const body = res.json() as { allowed: boolean; activated: boolean }
  assertEqual(body.allowed, false, 'an unactivated till may not bill')
  assertEqual(body.activated, false)

  await app.close()
  db.close()
})
