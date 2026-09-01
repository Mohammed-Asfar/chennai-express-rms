import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'

const createBody = z.object({
  name: z.string().min(1).max(64).trim(),
  sortOrder: z.number().int().min(0).optional(),
})

const updateBody = z.object({
  name: z.string().min(1).max(64).trim().optional(),
  sortOrder: z.number().int().min(0).optional(),
  isActive: z.boolean().optional(),
})

const reorderBody = z.object({
  ids: z.array(z.string().uuid()).min(1),
})

interface CategoryRow {
  id: string
  name: string
  sort_order: number
  is_active: number
}

const toPublic = (row: CategoryRow & { item_count?: number }) => ({
  id: row.id,
  name: row.name,
  sortOrder: row.sort_order,
  isActive: row.is_active === 1,
  ...(row.item_count !== undefined ? { itemCount: row.item_count } : {}),
})

export async function categoryRoutes(app: FastifyInstance): Promise<void> {
  // Cashiers read the menu to take orders; only admins change it.
  app.get('/categories', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const rows = app.db
      .prepare(
        `SELECT c.*, COUNT(m.id) AS item_count
         FROM categories c
         LEFT JOIN menu_items m ON m.category_id = c.id AND m.deleted_at IS NULL
         WHERE c.branch_id = ? AND c.deleted_at IS NULL
         GROUP BY c.id
         ORDER BY c.sort_order, c.name`,
      )
      .all(me.branchId) as (CategoryRow & { item_count: number })[]

    return { categories: rows.map(toPublic) }
  })

  app.post('/categories', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)

    assertNameAvailable(app, me.branchId, body.name)

    const id = randomUUID()
    const now = new Date().toISOString()
    const sortOrder = body.sortOrder ?? nextSortOrder(app, me.branchId)

    app.db
      .prepare(
        `INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)`,
      )
      .run(id, me.branchId, body.name, sortOrder, now, now)

    reply.status(201)
    return { category: toPublic(findOrThrow(app, me.branchId, id)) }
  })

  app.patch<{ Params: { id: string } }>(
    '/categories/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateBody.parse(request.body)
      const existing = findOrThrow(app, me.branchId, request.params.id)

      if (body.name !== undefined && body.name !== existing.name) {
        assertNameAvailable(app, me.branchId, body.name)
      }

      const sets: string[] = []
      const values: unknown[] = []

      if (body.name !== undefined) {
        sets.push('name = ?')
        values.push(body.name)
      }
      if (body.sortOrder !== undefined) {
        sets.push('sort_order = ?')
        values.push(body.sortOrder)
      }
      if (body.isActive !== undefined) {
        sets.push('is_active = ?')
        values.push(body.isActive ? 1 : 0)
      }

      if (sets.length > 0) {
        sets.push('updated_at = ?', 'synced_at = NULL')
        values.push(new Date().toISOString(), request.params.id)
        app.db.prepare(`UPDATE categories SET ${sets.join(', ')} WHERE id = ?`).run(...values)
      }

      return { category: toPublic(findOrThrow(app, me.branchId, request.params.id)) }
    },
  )

  app.delete<{ Params: { id: string } }>(
    '/categories/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      findOrThrow(app, me.branchId, request.params.id)

      // FR-M10: blocked rather than cascading. Deleting a category should never
      // silently remove dishes with it.
      const items = app.db
        .prepare(
          'SELECT COUNT(*) AS n FROM menu_items WHERE category_id = ? AND deleted_at IS NULL',
        )
        .get(request.params.id) as { n: number }

      if (items.n > 0) {
        throw new AppError(
          409,
          'CATEGORY_NOT_EMPTY',
          `This category still has ${items.n} item${items.n === 1 ? '' : 's'}. Move or remove them first.`,
        )
      }

      app.db
        .prepare('UPDATE categories SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?')
        .run(new Date().toISOString(), new Date().toISOString(), request.params.id)

      return { ok: true }
    },
  )

  /** Bulk reorder — the UI sends the full list after a drag. */
  app.post('/categories/reorder', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const { ids } = reorderBody.parse(request.body)
    const now = new Date().toISOString()

    const update = app.db.prepare(
      `UPDATE categories SET sort_order = ?, updated_at = ?, synced_at = NULL
       WHERE id = ? AND branch_id = ? AND deleted_at IS NULL`,
    )

    // One transaction so a partial reorder cannot leave a scrambled menu.
    app.db.transaction(() => {
      ids.forEach((id, index) => update.run(index, now, id, me.branchId))
    })()

    return { ok: true }
  })
}

function findOrThrow(app: FastifyInstance, branchId: string, id: string): CategoryRow {
  const row = app.db
    .prepare('SELECT * FROM categories WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as CategoryRow | undefined
  if (!row) throw new AppError(404, 'CATEGORY_NOT_FOUND', 'Category not found')
  return row
}

function assertNameAvailable(app: FastifyInstance, branchId: string, name: string): void {
  const clash = app.db
    .prepare(
      'SELECT id FROM categories WHERE branch_id = ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL',
    )
    .get(branchId, name)
  if (clash) throw new AppError(409, 'CATEGORY_EXISTS', 'A category with that name already exists')
}

function nextSortOrder(app: FastifyInstance, branchId: string): number {
  const row = app.db
    .prepare(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM categories WHERE branch_id = ? AND deleted_at IS NULL',
    )
    .get(branchId) as { next: number }
  return row.next
}
