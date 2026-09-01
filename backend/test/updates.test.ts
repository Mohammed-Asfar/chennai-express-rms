import { openDatabase } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { APP_BUILD_NUMBER, APP_VERSION, evaluateRelease } from '../src/lib/version.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

const release = (overrides: Partial<Parameters<typeof evaluateRelease>[1]> = {}) => ({
  version: '1.1.0',
  buildNumber: 2,
  downloadUrl: 'https://example.test/setup.exe',
  fileSize: 1024,
  sha256: 'abc',
  releaseNotes: 'Fixes',
  isMandatory: false,
  minSupportedBuild: 0,
  releasedAt: '2026-09-01T00:00:00.000Z',
  ...overrides,
})

// --- version comparison ---

test('a newer build is an update', () => {
  const result = evaluateRelease(1, release({ buildNumber: 2 }))
  assertEqual(result.updateAvailable, true)
  assertEqual(result.isForced, false)
})

test('the same build is not an update', () => {
  assertEqual(evaluateRelease(2, release({ buildNumber: 2 })).updateAvailable, false)
})

test('an older build is not an update', () => {
  // Guards against a rollback in the cloud pushing clients backwards.
  assertEqual(evaluateRelease(5, release({ buildNumber: 3 })).updateAvailable, false)
})

test('no release means no update', () => {
  assertEqual(evaluateRelease(1, null).updateAvailable, false)
})

test('a mandatory release is forced', () => {
  const result = evaluateRelease(1, release({ buildNumber: 2, isMandatory: true }))
  assertEqual(result.updateAvailable, true)
  assertEqual(result.isForced, true)
})

test('a build below the minimum supported is forced', () => {
  // The case that matters after a billing-math fix: an old build must not keep
  // producing wrong bills because staff dismissed a dialog.
  const result = evaluateRelease(1, release({ buildNumber: 5, minSupportedBuild: 3 }))
  assertEqual(result.updateAvailable, true)
  assertEqual(result.isForced, true)
})

test('a build at or above the minimum is optional', () => {
  const result = evaluateRelease(3, release({ buildNumber: 5, minSupportedBuild: 3 }))
  assertEqual(result.updateAvailable, true)
  assertEqual(result.isForced, false)
})

test('an outdated build is not forced when the newest release is not newer', () => {
  // minSupportedBuild only bites when there is somewhere to upgrade to.
  assertEqual(evaluateRelease(1, release({ buildNumber: 1, minSupportedBuild: 5 })).isForced, false)
})

// --- endpoints ---

test('GET /version reports the running build without auth', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })

  const res = await app.inject({ method: 'GET', url: '/version' })
  assertEqual(res.statusCode, 200)
  const body = res.json() as { version: string; buildNumber: number }
  assertEqual(body.version, APP_VERSION)
  assertEqual(body.buildNumber, APP_BUILD_NUMBER)

  await app.close()
  db.close()
})

test('the update check requires authentication', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })

  assertEqual((await app.inject({ method: 'GET', url: '/updates/check' })).statusCode, 401)

  await app.close()
  db.close()
})

test('the update check reports no update when the cloud is not configured', async () => {
  // A restaurant with no cloud set up must not see an error — it simply has no
  // updates available.
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })

  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const token = (login.json() as { token: string }).token

  const res = await app.inject({
    method: 'GET',
    url: '/updates/check',
    headers: { authorization: `Bearer ${token}` },
  })

  assertEqual(res.statusCode, 200, 'a missing cloud config is not an error')
  const body = res.json() as { updateAvailable: boolean; isForced: boolean; release: unknown }
  assertEqual(body.updateAvailable, false)
  assertEqual(body.isForced, false)
  assertEqual(body.release, null)

  await app.close()
  db.close()
})

test('an unreachable cloud reports no update rather than failing', async () => {
  // An update check must never stand between staff and a bill.
  const offlineEnv = loadEnv({
    NODE_ENV: 'test',
    DB_PATH: ':memory:',
    SEED_ADMIN_PASSWORD: 'admin123',
    CLOUD_DATABASE_URL: 'postgres://nobody:nothing@127.0.0.1:1/none',
  })

  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, offlineEnv)
  const app = await buildServer({ db, env: offlineEnv })

  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const token = (login.json() as { token: string }).token

  const res = await app.inject({
    method: 'GET',
    url: '/updates/check',
    headers: { authorization: `Bearer ${token}` },
  })

  assertEqual(res.statusCode, 200, 'an unreachable cloud is not a client error')
  assertEqual((res.json() as { updateAvailable: boolean }).updateAvailable, false)

  await app.close()
  db.close()
})
