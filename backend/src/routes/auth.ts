import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { AppError } from '../lib/errors.js'
import { hashPassword, signToken, verifyPassword, type Role } from '../lib/auth.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'

const loginBody = z.object({
  username: z.string().min(1, 'Username is required'),
  password: z.string().min(1, 'Password is required'),
})

const changePasswordBody = z.object({
  currentPassword: z.string().min(1),
  newPassword: z.string().min(6, 'New password must be at least 6 characters'),
})

const createUserBody = z.object({
  username: z.string().min(3).max(32).regex(/^[a-zA-Z0-9._-]+$/, 'Use letters, numbers, . _ - only'),
  password: z.string().min(6),
  fullName: z.string().min(1).max(64),
  role: z.enum(['admin', 'cashier']),
})

const updateUserBody = z.object({
  fullName: z.string().min(1).max(64).optional(),
  role: z.enum(['admin', 'cashier']).optional(),
  isActive: z.boolean().optional(),
  password: z.string().min(6).optional(),
})

interface UserRow {
  id: string
  branch_id: string
  username: string
  password_hash: string
  full_name: string
  role: Role
  is_active: number
  must_change_password: number
}

const publicUser = (row: UserRow) => ({
  id: row.id,
  username: row.username,
  fullName: row.full_name,
  role: row.role,
  isActive: row.is_active === 1,
  mustChangePassword: row.must_change_password === 1,
})

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post('/auth/login', async (request) => {
    const { username, password } = loginBody.parse(request.body)

    const user = app.db
      .prepare('SELECT * FROM users WHERE username = ? AND deleted_at IS NULL')
      .get(username) as UserRow | undefined

    // One message for both a missing user and a wrong password — distinguishing
    // them tells an attacker which usernames exist.
    const invalid = new AppError(401, 'INVALID_CREDENTIALS', 'Incorrect username or password')

    if (!user) {
      // Hash anyway so the response time does not reveal whether the user exists.
      await verifyPassword(password, '$2b$10$invalidinvalidinvalidinvalidinvalidinvalidinvalidinva')
      throw invalid
    }

    if (!(await verifyPassword(password, user.password_hash))) throw invalid
    if (user.is_active !== 1) {
      throw new AppError(403, 'ACCOUNT_DISABLED', 'Account has been disabled')
    }

    const token = signToken(
      { sub: user.id, branchId: user.branch_id, username: user.username, role: user.role },
      app.env.JWT_SECRET,
      app.env.JWT_EXPIRES_SECONDS,
    )

    return { token, expiresIn: app.env.JWT_EXPIRES_SECONDS, user: publicUser(user) }
  })

  app.get('/auth/me', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const row = app.db
      .prepare('SELECT * FROM users WHERE id = ? AND deleted_at IS NULL')
      .get(me.sub) as UserRow | undefined
    if (!row) throw new AppError(401, 'USER_NOT_FOUND', 'Account no longer exists')
    return { user: publicUser(row) }
  })

  app.post('/auth/change-password', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const { currentPassword, newPassword } = changePasswordBody.parse(request.body)

    const row = app.db
      .prepare('SELECT * FROM users WHERE id = ? AND deleted_at IS NULL')
      .get(me.sub) as UserRow | undefined
    if (!row) throw new AppError(401, 'USER_NOT_FOUND', 'Account no longer exists')

    if (!(await verifyPassword(currentPassword, row.password_hash))) {
      throw new AppError(400, 'INCORRECT_PASSWORD', 'Current password is incorrect')
    }
    if (currentPassword === newPassword) {
      throw new AppError(400, 'PASSWORD_UNCHANGED', 'New password must differ from the current one')
    }

    const hash = await hashPassword(newPassword)
    app.db
      .prepare(
        `UPDATE users SET password_hash = ?, must_change_password = 0, updated_at = ?, synced_at = NULL
         WHERE id = ?`,
      )
      .run(hash, new Date().toISOString(), me.sub)

    return { ok: true }
  })

  // --- user management (admin only) ---

  app.get('/users', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const rows = app.db
      .prepare('SELECT * FROM users WHERE branch_id = ? AND deleted_at IS NULL ORDER BY username')
      .all(me.branchId) as UserRow[]
    return { users: rows.map(publicUser) }
  })

  app.post('/users', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createUserBody.parse(request.body)

    const clash = app.db
      .prepare('SELECT id FROM users WHERE branch_id = ? AND username = ? AND deleted_at IS NULL')
      .get(me.branchId, body.username)
    if (clash) throw new AppError(409, 'USERNAME_TAKEN', 'That username is already in use')

    const id = randomUUID()
    const now = new Date().toISOString()
    const hash = await hashPassword(body.password)

    app.db
      .prepare(
        `INSERT INTO users (id, branch_id, username, password_hash, full_name, role,
                            is_active, must_change_password, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?)`,
      )
      .run(id, me.branchId, body.username, hash, body.fullName, body.role, now, now)

    const created = app.db.prepare('SELECT * FROM users WHERE id = ?').get(id) as UserRow
    reply.status(201)
    return { user: publicUser(created) }
  })

  app.patch<{ Params: { id: string } }>(
    '/users/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateUserBody.parse(request.body)
      const targetId = request.params.id

      const target = app.db
        .prepare('SELECT * FROM users WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
        .get(targetId, me.branchId) as UserRow | undefined
      if (!target) throw new AppError(404, 'USER_NOT_FOUND', 'User not found')

      // Locking yourself out of the only admin account leaves the restaurant with
      // no way back in, so both self-demotion and self-deactivation are refused.
      const losingAdmin =
        target.id === me.sub && (body.role === 'cashier' || body.isActive === false)
      if (losingAdmin) {
        throw new AppError(400, 'CANNOT_DEMOTE_SELF', 'You cannot remove your own admin access')
      }

      if (body.role === 'cashier' || body.isActive === false) {
        const admins = app.db
          .prepare(
            `SELECT COUNT(*) AS n FROM users
             WHERE branch_id = ? AND role = 'admin' AND is_active = 1 AND deleted_at IS NULL`,
          )
          .get(me.branchId) as { n: number }
        if (target.role === 'admin' && target.is_active === 1 && admins.n <= 1) {
          throw new AppError(400, 'LAST_ADMIN', 'At least one active admin must remain')
        }
      }

      const now = new Date().toISOString()
      const sets: string[] = []
      const values: unknown[] = []

      if (body.fullName !== undefined) {
        sets.push('full_name = ?')
        values.push(body.fullName)
      }
      if (body.role !== undefined) {
        sets.push('role = ?')
        values.push(body.role)
      }
      if (body.isActive !== undefined) {
        sets.push('is_active = ?')
        values.push(body.isActive ? 1 : 0)
      }
      if (body.password !== undefined) {
        sets.push('password_hash = ?', 'must_change_password = 1')
        values.push(await hashPassword(body.password))
      }

      if (sets.length === 0) return { user: publicUser(target) }

      sets.push('updated_at = ?', 'synced_at = NULL')
      values.push(now, targetId)

      app.db.prepare(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`).run(...values)

      const updated = app.db.prepare('SELECT * FROM users WHERE id = ?').get(targetId) as UserRow
      return { user: publicUser(updated) }
    },
  )
}
