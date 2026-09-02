import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { requiredText } from '../lib/validation.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { getSetting } from '../lib/settings.js'

/** The variant name given to an item that has no portion sizes. */
const DEFAULT_VARIANT_NAME = 'Standard'

const variantInput = z.object({
  name: requiredText(32),
  /** Paise. The client converts rupees at the boundary. */
  price: z.number().int().min(0),
  isAvailable: z.boolean().optional(),
})

const createBody = z.object({
  categoryId: z.string().uuid(),
  name: requiredText(96),
  description: z.string().max(256).trim().optional(),
  /** Basis points. Omitted means inherit the branch default. */
  taxRate: z.number().int().min(0).max(10_000).optional(),
  isAvailable: z.boolean().optional(),
  /** Omitted or empty creates a single `Standard` variant (FR-M5). */
  variants: z.array(variantInput).optional(),
  price: z.number().int().min(0).optional(),
})

const updateBody = z.object({
  categoryId: z.string().uuid().optional(),
  name: requiredText(96).optional(),
  description: z.string().max(256).trim().nullable().optional(),
  taxRate: z.number().int().min(0).max(10_000).optional(),
  isAvailable: z.boolean().optional(),
  sortOrder: z.number().int().min(0).optional(),
})

const updateVariantBody = z.object({
  name: requiredText(32).optional(),
  price: z.number().int().min(0).optional(),
  isAvailable: z.boolean().optional(),
  sortOrder: z.number().int().min(0).optional(),
})

interface ItemRow {
  id: string
  category_id: string
  name: string
  description: string | null
  tax_rate: number
  is_available: number
  sort_order: number
}

interface VariantRow {
  id: string
  menu_item_id: string
  name: string
  price: number
  sort_order: number
  is_available: number
}

const toPublicVariant = (row: VariantRow) => ({
  id: row.id,
  name: row.name,
  price: row.price,
  sortOrder: row.sort_order,
  isAvailable: row.is_available === 1,
})

const toPublicItem = (row: ItemRow, variants: VariantRow[]) => ({
  id: row.id,
  categoryId: row.category_id,
  name: row.name,
  description: row.description,
  taxRate: row.tax_rate,
  isAvailable: row.is_available === 1,
  sortOrder: row.sort_order,
  variants: variants.map(toPublicVariant),
})

export async function menuRoutes(app: FastifyInstance): Promise<void> {
  app.get<{ Querystring: { categoryId?: string; availableOnly?: string } }>(
    '/menu-items',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const { categoryId, availableOnly } = request.query

      const conditions = ['m.branch_id = ?', 'm.deleted_at IS NULL']
      const params: unknown[] = [me.branchId]

      if (categoryId) {
        conditions.push('m.category_id = ?')
        params.push(categoryId)
      }
      if (availableOnly === 'true') conditions.push('m.is_available = 1')

      const items = app.db
        .prepare(
          `SELECT m.* FROM menu_items m
           WHERE ${conditions.join(' AND ')}
           ORDER BY m.sort_order, m.name`,
        )
        .all(...params) as ItemRow[]

      const variants = loadVariants(app, items.map((i) => i.id))

      return {
        items: items.map((item) => toPublicItem(item, variants.get(item.id) ?? [])),
      }
    },
  )

  app.get<{ Params: { id: string } }>('/menu-items/:id', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const item = findItemOrThrow(app, me.branchId, request.params.id)
    return { item: toPublicItem(item, loadVariants(app, [item.id]).get(item.id) ?? []) }
  })

  app.post('/menu-items', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)

    assertCategoryExists(app, me.branchId, body.categoryId)
    assertItemNameAvailable(app, me.branchId, body.name)

    // FR-M5: an item always has at least one variant, so the rest of the system
    // has a single code path — order lines always reference a variant.
    const variants = resolveInitialVariants(body)
    assertUniqueVariantNames(variants.map((v) => v.name))

    // FR-M7: inherit the branch GST rate unless overridden.
    const taxRate = body.taxRate ?? getSetting(app.db, me.branchId, 'default_tax_rate')

    const id = randomUUID()
    const now = new Date().toISOString()
    const sortOrder = nextItemSortOrder(app, body.categoryId)

    app.db.transaction(() => {
      app.db
        .prepare(
          `INSERT INTO menu_items (id, branch_id, category_id, name, description, tax_rate,
                                   is_available, sort_order, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          id,
          me.branchId,
          body.categoryId,
          body.name,
          body.description ?? null,
          taxRate,
          body.isAvailable === false ? 0 : 1,
          sortOrder,
          now,
          now,
        )

      const insertVariant = app.db.prepare(
        `INSERT INTO menu_item_variants (id, menu_item_id, name, price, sort_order,
                                         is_available, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      variants.forEach((variant, index) => {
        insertVariant.run(
          randomUUID(),
          id,
          variant.name,
          variant.price,
          index,
          variant.isAvailable === false ? 0 : 1,
          now,
          now,
        )
      })
    })()

    const created = findItemOrThrow(app, me.branchId, id)
    reply.status(201)
    return { item: toPublicItem(created, loadVariants(app, [id]).get(id) ?? []) }
  })

  app.patch<{ Params: { id: string } }>(
    '/menu-items/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateBody.parse(request.body)
      const existing = findItemOrThrow(app, me.branchId, request.params.id)

      if (body.categoryId !== undefined) assertCategoryExists(app, me.branchId, body.categoryId)
      if (body.name !== undefined && body.name !== existing.name) {
        assertItemNameAvailable(app, me.branchId, body.name)
      }

      const sets: string[] = []
      const values: unknown[] = []
      const push = (column: string, value: unknown) => {
        sets.push(`${column} = ?`)
        values.push(value)
      }

      if (body.categoryId !== undefined) push('category_id', body.categoryId)
      if (body.name !== undefined) push('name', body.name)
      if (body.description !== undefined) push('description', body.description)
      if (body.taxRate !== undefined) push('tax_rate', body.taxRate)
      if (body.isAvailable !== undefined) push('is_available', body.isAvailable ? 1 : 0)
      if (body.sortOrder !== undefined) push('sort_order', body.sortOrder)

      if (sets.length > 0) {
        sets.push('updated_at = ?', 'synced_at = NULL')
        values.push(new Date().toISOString(), request.params.id)
        app.db.prepare(`UPDATE menu_items SET ${sets.join(', ')} WHERE id = ?`).run(...values)
      }

      // FR-M12: editing the menu never touches order lines, which hold their own
      // snapshot of name, price and tax rate.
      const updated = findItemOrThrow(app, me.branchId, request.params.id)
      return { item: toPublicItem(updated, loadVariants(app, [updated.id]).get(updated.id) ?? []) }
    },
  )

  app.delete<{ Params: { id: string } }>(
    '/menu-items/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const item = findItemOrThrow(app, me.branchId, request.params.id)
      const now = new Date().toISOString()

      // FR-M11: soft delete. Order lines reference a variant id, and history must
      // stay resolvable.
      app.db.transaction(() => {
        app.db
          .prepare('UPDATE menu_items SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?')
          .run(now, now, item.id)
        app.db
          .prepare(
            `UPDATE menu_item_variants SET deleted_at = ?, updated_at = ?, synced_at = NULL
             WHERE menu_item_id = ? AND deleted_at IS NULL`,
          )
          .run(now, now, item.id)
      })()

      return { ok: true }
    },
  )

  // --- variants ---

  app.post<{ Params: { id: string } }>(
    '/menu-items/:id/variants',
    { preHandler: requireRole('admin') },
    async (request, reply) => {
      const me = currentUser(request)
      const item = findItemOrThrow(app, me.branchId, request.params.id)
      const body = variantInput.parse(request.body)

      const existing = loadVariants(app, [item.id]).get(item.id) ?? []
      if (existing.some((v) => v.name.toLowerCase() === body.name.toLowerCase())) {
        throw new AppError(409, 'VARIANT_EXISTS', 'That portion already exists on this item')
      }

      const now = new Date().toISOString()
      const id = randomUUID()
      app.db
        .prepare(
          `INSERT INTO menu_item_variants (id, menu_item_id, name, price, sort_order,
                                           is_available, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(id, item.id, body.name, body.price, existing.length, body.isAvailable === false ? 0 : 1, now, now)

      reply.status(201)
      return { item: toPublicItem(item, loadVariants(app, [item.id]).get(item.id) ?? []) }
    },
  )

  app.patch<{ Params: { id: string; variantId: string } }>(
    '/menu-items/:id/variants/:variantId',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const item = findItemOrThrow(app, me.branchId, request.params.id)
      const body = updateVariantBody.parse(request.body)

      const variants = loadVariants(app, [item.id]).get(item.id) ?? []
      const variant = variants.find((v) => v.id === request.params.variantId)
      if (!variant) throw new AppError(404, 'VARIANT_NOT_FOUND', 'Portion not found')

      if (body.name !== undefined) {
        const clash = variants.some(
          (v) => v.id !== variant.id && v.name.toLowerCase() === body.name!.toLowerCase(),
        )
        if (clash) throw new AppError(409, 'VARIANT_EXISTS', 'That portion already exists on this item')
      }

      const sets: string[] = []
      const values: unknown[] = []
      const push = (column: string, value: unknown) => {
        sets.push(`${column} = ?`)
        values.push(value)
      }

      if (body.name !== undefined) push('name', body.name)
      if (body.price !== undefined) push('price', body.price)
      if (body.isAvailable !== undefined) push('is_available', body.isAvailable ? 1 : 0)
      if (body.sortOrder !== undefined) push('sort_order', body.sortOrder)

      if (sets.length > 0) {
        sets.push('updated_at = ?', 'synced_at = NULL')
        values.push(new Date().toISOString(), variant.id)
        app.db.prepare(`UPDATE menu_item_variants SET ${sets.join(', ')} WHERE id = ?`).run(...values)
      }

      // Repricing never rewrites an existing order — order lines snapshot the price.
      return { item: toPublicItem(item, loadVariants(app, [item.id]).get(item.id) ?? []) }
    },
  )

  app.delete<{ Params: { id: string; variantId: string } }>(
    '/menu-items/:id/variants/:variantId',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const item = findItemOrThrow(app, me.branchId, request.params.id)

      const variants = loadVariants(app, [item.id]).get(item.id) ?? []
      const variant = variants.find((v) => v.id === request.params.variantId)
      if (!variant) throw new AppError(404, 'VARIANT_NOT_FOUND', 'Portion not found')

      // FR-M6: an item with no variants could not be ordered at all, and every
      // order line references one.
      if (variants.length <= 1) {
        throw new AppError(
          409,
          'LAST_VARIANT',
          'An item must keep at least one portion. Delete the item instead.',
        )
      }

      const now = new Date().toISOString()
      app.db
        .prepare(
          'UPDATE menu_item_variants SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?',
        )
        .run(now, now, variant.id)

      return { item: toPublicItem(item, loadVariants(app, [item.id]).get(item.id) ?? []) }
    },
  )
}

/** Loads variants for several items in one query rather than N. */
function loadVariants(app: FastifyInstance, itemIds: string[]): Map<string, VariantRow[]> {
  const grouped = new Map<string, VariantRow[]>()
  if (itemIds.length === 0) return grouped

  const placeholders = itemIds.map(() => '?').join(', ')
  const rows = app.db
    .prepare(
      `SELECT * FROM menu_item_variants
       WHERE menu_item_id IN (${placeholders}) AND deleted_at IS NULL
       ORDER BY sort_order, name`,
    )
    .all(...itemIds) as VariantRow[]

  for (const row of rows) {
    const list = grouped.get(row.menu_item_id)
    if (list) list.push(row)
    else grouped.set(row.menu_item_id, [row])
  }
  return grouped
}

function resolveInitialVariants(
  body: z.infer<typeof createBody>,
): z.infer<typeof variantInput>[] {
  if (body.variants && body.variants.length > 0) return body.variants
  return [{ name: DEFAULT_VARIANT_NAME, price: body.price ?? 0 }]
}

function assertUniqueVariantNames(names: string[]): void {
  const seen = new Set<string>()
  for (const name of names) {
    const key = name.toLowerCase()
    if (seen.has(key)) {
      throw new AppError(400, 'DUPLICATE_VARIANT', `Portion "${name}" is listed twice`)
    }
    seen.add(key)
  }
}

function findItemOrThrow(app: FastifyInstance, branchId: string, id: string): ItemRow {
  const row = app.db
    .prepare('SELECT * FROM menu_items WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as ItemRow | undefined
  if (!row) throw new AppError(404, 'ITEM_NOT_FOUND', 'Menu item not found')
  return row
}

function assertCategoryExists(app: FastifyInstance, branchId: string, categoryId: string): void {
  const row = app.db
    .prepare('SELECT id FROM categories WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(categoryId, branchId)
  if (!row) throw new AppError(404, 'CATEGORY_NOT_FOUND', 'Category not found')
}

function assertItemNameAvailable(app: FastifyInstance, branchId: string, name: string): void {
  const clash = app.db
    .prepare(
      'SELECT id FROM menu_items WHERE branch_id = ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL',
    )
    .get(branchId, name)
  if (clash) throw new AppError(409, 'ITEM_EXISTS', 'A menu item with that name already exists')
}

function nextItemSortOrder(app: FastifyInstance, categoryId: string): number {
  const row = app.db
    .prepare(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM menu_items WHERE category_id = ? AND deleted_at IS NULL',
    )
    .get(categoryId) as { next: number }
  return row.next
}
