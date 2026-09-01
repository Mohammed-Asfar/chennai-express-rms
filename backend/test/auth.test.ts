import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { hashPassword, verifyPassword, signToken, verifyToken } from '../src/lib/auth.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({
  NODE_ENV: 'test',
  DB_PATH: ':memory:',
  SEED_ADMIN_PASSWORD: 'admin123',
})

async function setup(): Promise<{ app: FastifyInstance; db: Db }> {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const app = await buildServer({ db, env })
  return { app, db }
}

async function loginAs(
  app: FastifyInstance,
  username: string,
  password: string,
): Promise<string> {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username, password },
  })
  if (res.statusCode !== 200) throw new Error(`login failed: ${res.statusCode} ${res.body}`)
  return (res.json() as { token: string }).token
}

const bearer = (token: string) => ({ authorization: `Bearer ${token}` })

// --- password hashing ---

test('a password hash is not the password, and verifies', async () => {
  const hash = await hashPassword('secret123')
  if (hash === 'secret123') throw new Error('password was stored in plaintext')
  assertEqual(await verifyPassword('secret123', hash), true)
  assertEqual(await verifyPassword('wrong', hash), false)
})

test('the same password hashes differently each time', async () => {
  const a = await hashPassword('secret123')
  const b = await hashPassword('secret123')
  if (a === b) throw new Error('hashes are not salted')
})

// --- tokens ---

test('a token round-trips its claims', () => {
  const token = signToken(
    { sub: 'u1', branchId: 'b1', username: 'admin', role: 'admin' },
    'a-test-secret-that-is-long-enough-to-pass',
    60,
  )
  const payload = verifyToken(token, 'a-test-secret-that-is-long-enough-to-pass')
  assertEqual(payload.sub, 'u1')
  assertEqual(payload.role, 'admin')
})

test('a token signed with another secret is rejected', () => {
  const token = signToken(
    { sub: 'u1', branchId: 'b1', username: 'admin', role: 'admin' },
    'a-test-secret-that-is-long-enough-to-pass',
    60,
  )
  try {
    verifyToken(token, 'a-different-secret-that-is-also-long-enough')
    throw new Error('a forged token was accepted')
  } catch (error) {
    assertEqual((error as { code?: string }).code, 'INVALID_TOKEN')
  }
})

test('an expired token is reported as expired, not merely invalid', async () => {
  const token = signToken(
    { sub: 'u1', branchId: 'b1', username: 'admin', role: 'admin' },
    'a-test-secret-that-is-long-enough-to-pass',
    -1, // already expired
  )
  try {
    verifyToken(token, 'a-test-secret-that-is-long-enough-to-pass')
    throw new Error('an expired token was accepted')
  } catch (error) {
    assertEqual((error as { code?: string }).code, 'TOKEN_EXPIRED')
  }
})

// --- seeding ---

test('first run seeds a branch, an admin, a section and settings', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  const result = await seedIfEmpty(db, env)
  assertEqual(result.seeded, true)

  const branches = db.prepare('SELECT COUNT(*) AS n FROM branches').get() as { n: number }
  const admin = db.prepare("SELECT * FROM users WHERE role = 'admin'").get() as {
    must_change_password: number
    password_hash: string
  }
  const sections = db.prepare('SELECT COUNT(*) AS n FROM sections').get() as { n: number }
  const settings = db.prepare('SELECT COUNT(*) AS n FROM settings').get() as { n: number }

  assertEqual(branches.n, 1)
  assertEqual(sections.n, 1, 'a default section is needed before any table can exist')
  assertEqual(admin.must_change_password, 1, 'the seeded password must be changed at first login')
  if (admin.password_hash === env.SEED_ADMIN_PASSWORD) throw new Error('password stored in plaintext')
  if (settings.n < 6) throw new Error('default settings were not seeded')
  db.close()
})

test('seeding twice does not duplicate anything', async () => {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)
  const second = await seedIfEmpty(db, env)
  assertEqual(second.seeded, false)
  const branches = db.prepare('SELECT COUNT(*) AS n FROM branches').get() as { n: number }
  assertEqual(branches.n, 1)
  db.close()
})

// --- login ---

test('login succeeds with the seeded credentials', async () => {
  const { app, db } = await setup()
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  assertEqual(res.statusCode, 200)

  const body = res.json() as {
    token: string
    user: { username: string; role: string; mustChangePassword: boolean }
  }
  assertEqual(body.user.username, 'admin')
  assertEqual(body.user.role, 'admin')
  assertEqual(body.user.mustChangePassword, true)
  if (!body.token) throw new Error('no token returned')

  await app.close()
  db.close()
})

test('login never returns the password hash', async () => {
  const { app, db } = await setup()
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  if (res.body.includes('password_hash') || res.body.includes('passwordHash')) {
    throw new Error('the response leaked the password hash')
  }
  await app.close()
  db.close()
})

test('a wrong password and an unknown user give the same error', async () => {
  const { app, db } = await setup()

  const wrongPassword = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'nope' },
  })
  const unknownUser = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'ghost', password: 'nope' },
  })

  assertEqual(wrongPassword.statusCode, 401)
  assertEqual(unknownUser.statusCode, 401)
  // Distinguishing the two would tell an attacker which usernames exist.
  assertEqual(wrongPassword.json<{ error: { code: string } }>().error.code, 'INVALID_CREDENTIALS')
  assertEqual(unknownUser.json<{ error: { code: string } }>().error.code, 'INVALID_CREDENTIALS')

  await app.close()
  db.close()
})

test('login rejects a malformed body', async () => {
  const { app, db } = await setup()
  const res = await app.inject({ method: 'POST', url: '/auth/login', payload: { username: 'admin' } })
  assertEqual(res.statusCode, 400)
  await app.close()
  db.close()
})

// --- protected routes ---

test('a protected route refuses a request with no token', async () => {
  const { app, db } = await setup()
  const res = await app.inject({ method: 'GET', url: '/auth/me' })
  assertEqual(res.statusCode, 401)
  assertEqual(res.json<{ error: { code: string } }>().error.code, 'UNAUTHENTICATED')
  await app.close()
  db.close()
})

test('a protected route refuses a garbage token', async () => {
  const { app, db } = await setup()
  const res = await app.inject({
    method: 'GET',
    url: '/auth/me',
    headers: bearer('not-a-real-token'),
  })
  assertEqual(res.statusCode, 401)
  await app.close()
  db.close()
})

test('a valid token reaches a protected route', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const res = await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(token) })
  assertEqual(res.statusCode, 200)
  assertEqual(res.json<{ user: { username: string } }>().user.username, 'admin')
  await app.close()
  db.close()
})

// --- password change ---

test('changing the password clears the must-change flag', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')

  const res = await app.inject({
    method: 'POST',
    url: '/auth/change-password',
    headers: bearer(token),
    payload: { currentPassword: 'admin123', newPassword: 'newpass456' },
  })
  assertEqual(res.statusCode, 200)

  const me = await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(token) })
  assertEqual(me.json<{ user: { mustChangePassword: boolean } }>().user.mustChangePassword, false)

  // The new password works and the old one does not.
  await loginAs(app, 'admin', 'newpass456')
  const old = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  assertEqual(old.statusCode, 401)

  await app.close()
  db.close()
})

test('changing the password requires the current one', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const res = await app.inject({
    method: 'POST',
    url: '/auth/change-password',
    headers: bearer(token),
    payload: { currentPassword: 'wrong', newPassword: 'newpass456' },
  })
  assertEqual(res.statusCode, 400)
  assertEqual(res.json<{ error: { code: string } }>().error.code, 'INCORRECT_PASSWORD')
  await app.close()
  db.close()
})

test('a short new password is rejected', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const res = await app.inject({
    method: 'POST',
    url: '/auth/change-password',
    headers: bearer(token),
    payload: { currentPassword: 'admin123', newPassword: 'abc' },
  })
  assertEqual(res.statusCode, 400)
  await app.close()
  db.close()
})

// --- roles ---

test('a cashier cannot reach an admin endpoint', async () => {
  const { app, db } = await setup()
  const adminToken = await loginAs(app, 'admin', 'admin123')

  const created = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(adminToken),
    payload: { username: 'cashier1', password: 'cash123', fullName: 'Cashier One', role: 'cashier' },
  })
  assertEqual(created.statusCode, 201)

  const cashierToken = await loginAs(app, 'cashier1', 'cash123')

  // Role is enforced on the server, not by hiding a button in the UI.
  const listUsers = await app.inject({ method: 'GET', url: '/users', headers: bearer(cashierToken) })
  assertEqual(listUsers.statusCode, 403)
  assertEqual(listUsers.json<{ error: { code: string } }>().error.code, 'FORBIDDEN')

  const createUser = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(cashierToken),
    payload: { username: 'sneaky', password: 'sneak123', fullName: 'Sneaky', role: 'admin' },
  })
  assertEqual(createUser.statusCode, 403)

  await app.close()
  db.close()
})

test('a deactivated user is refused immediately, even with a live token', async () => {
  const { app, db } = await setup()
  const adminToken = await loginAs(app, 'admin', 'admin123')

  const created = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(adminToken),
    payload: { username: 'cashier2', password: 'cash123', fullName: 'Cashier Two', role: 'cashier' },
  })
  const cashierId = created.json<{ user: { id: string } }>().user.id
  const cashierToken = await loginAs(app, 'cashier2', 'cash123')

  // Works before deactivation.
  assertEqual(
    (await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(cashierToken) })).statusCode,
    200,
  )

  await app.inject({
    method: 'PATCH',
    url: `/users/${cashierId}`,
    headers: bearer(adminToken),
    payload: { isActive: false },
  })

  // The token is still cryptographically valid, so the guard must check the row.
  const after = await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(cashierToken) })
  assertEqual(after.statusCode, 403)
  assertEqual(after.json<{ error: { code: string } }>().error.code, 'ACCOUNT_DISABLED')

  await app.close()
  db.close()
})

test('a deactivated user cannot log in again', async () => {
  const { app, db } = await setup()
  const adminToken = await loginAs(app, 'admin', 'admin123')
  const created = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(adminToken),
    payload: { username: 'cashier3', password: 'cash123', fullName: 'Cashier Three', role: 'cashier' },
  })
  const id = created.json<{ user: { id: string } }>().user.id

  await app.inject({
    method: 'PATCH',
    url: `/users/${id}`,
    headers: bearer(adminToken),
    payload: { isActive: false },
  })

  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'cashier3', password: 'cash123' },
  })
  assertEqual(res.statusCode, 403)
  await app.close()
  db.close()
})

// --- user management ---

test('duplicate usernames are rejected', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const payload = { username: 'dupe', password: 'pass123', fullName: 'First', role: 'cashier' }

  assertEqual((await app.inject({ method: 'POST', url: '/users', headers: bearer(token), payload })).statusCode, 201)
  const second = await app.inject({ method: 'POST', url: '/users', headers: bearer(token), payload })
  assertEqual(second.statusCode, 409)
  assertEqual(second.json<{ error: { code: string } }>().error.code, 'USERNAME_TAKEN')

  await app.close()
  db.close()
})

test('an admin cannot remove their own admin access', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const me = await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(token) })
  const myId = me.json<{ user: { id: string } }>().user.id

  const demote = await app.inject({
    method: 'PATCH',
    url: `/users/${myId}`,
    headers: bearer(token),
    payload: { role: 'cashier' },
  })
  assertEqual(demote.statusCode, 400)
  assertEqual(demote.json<{ error: { code: string } }>().error.code, 'CANNOT_DEMOTE_SELF')

  await app.close()
  db.close()
})

test('the last active admin cannot be deactivated', async () => {
  // Otherwise the restaurant locks itself out with no way back in.
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const me = await app.inject({ method: 'GET', url: '/auth/me', headers: bearer(token) })
  const myId = me.json<{ user: { id: string } }>().user.id

  const res = await app.inject({
    method: 'PATCH',
    url: `/users/${myId}`,
    headers: bearer(token),
    payload: { isActive: false },
  })
  assertEqual(res.statusCode, 400)

  await app.close()
  db.close()
})

test('an admin resetting a password forces a change at next login', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const created = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(token),
    payload: { username: 'cashier4', password: 'cash123', fullName: 'Cashier Four', role: 'cashier' },
  })
  const id = created.json<{ user: { id: string } }>().user.id

  await app.inject({
    method: 'PATCH',
    url: `/users/${id}`,
    headers: bearer(token),
    payload: { password: 'reset789' },
  })

  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'cashier4', password: 'reset789' },
  })
  assertEqual(login.statusCode, 200)
  assertEqual(login.json<{ user: { mustChangePassword: boolean } }>().user.mustChangePassword, true)

  await app.close()
  db.close()
})

test('a new user is created with must-change-password set', async () => {
  const { app, db } = await setup()
  const token = await loginAs(app, 'admin', 'admin123')
  const created = await app.inject({
    method: 'POST',
    url: '/users',
    headers: bearer(token),
    payload: { username: 'cashier5', password: 'cash123', fullName: 'Cashier Five', role: 'cashier' },
  })
  assertEqual(created.json<{ user: { mustChangePassword: boolean } }>().user.mustChangePassword, true)
  await app.close()
  db.close()
})
