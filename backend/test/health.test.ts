import { openDatabase } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:' })

test('GET /health reports ok when the database is reachable', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  const app = await buildServer({ db, env })

  const res = await app.inject({ method: 'GET', url: '/health' })
  assertEqual(res.statusCode, 200)

  const body = res.json() as {
    status: string
    database: { connected: boolean; migrationsApplied: number }
  }
  assertEqual(body.status, 'ok')
  assertEqual(body.database.connected, true)
  assertEqual(body.database.migrationsApplied, 1)

  await app.close()
  db.close()
})

test('GET /health reports degraded when the database is closed', async () => {
  // The Flutter client holds no data, so a dead backend means a dead UI. This
  // endpoint has to distinguish "up" from "up but broken".
  const db = openDatabase(':memory:')
  migrate(db)
  const app = await buildServer({ db, env })
  db.close()

  const res = await app.inject({ method: 'GET', url: '/health' })
  assertEqual(res.statusCode, 503)
  assertEqual((res.json() as { status: string }).status, 'degraded')

  await app.close()
})

test('an unknown route returns a structured 404', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  const app = await buildServer({ db, env })

  const res = await app.inject({ method: 'GET', url: '/nope' })
  assertEqual(res.statusCode, 404)
  assertEqual((res.json() as { error: { code: string } }).error.code, 'NOT_FOUND')

  await app.close()
  db.close()
})
