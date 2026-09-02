import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { requiredText } from '../lib/validation.js'
import type { Db } from '../db/client.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'

const createSectionBody = z.object({
  name: requiredText(48),
  sortOrder: z.number().int().min(0).optional(),
})

const updateSectionBody = z.object({
  name: requiredText(48).optional(),
  sortOrder: z.number().int().min(0).optional(),
  isActive: z.boolean().optional(),
})

const createTableBody = z.object({
  sectionId: z.string().uuid(),
  name: requiredText(32),
  seats: z.number().int().min(1).max(64).optional(),
  sortOrder: z.number().int().min(0).optional(),
})

const updateTableBody = z.object({
  sectionId: z.string().uuid().optional(),
  name: requiredText(32).optional(),
  seats: z.number().int().min(1).max(64).optional(),
  sortOrder: z.number().int().min(0).optional(),
  isActive: z.boolean().optional(),
})

const reorderBody = z.object({ ids: z.array(z.string().uuid()).min(1) })

interface SectionRow {
  id: string
  name: string
  sort_order: number
  is_active: number
}

interface TableRow {
  id: string
  section_id: string
  name: string
  seats: number
  status: 'free' | 'occupied' | 'reserved'
  sort_order: number
  is_active: number
}

/** An order occupying a table, shown as a chip on the floor screen. */
interface SeatedParty {
  orderId: string
  orderNo: number
  seatLabel: string | null
  /**
   * Lines on the order.
   *
   * Zero means nobody has ordered anything yet — a mis-tap, or a screen left
   * by a crash. The floor offers to free such a table, because otherwise it
   * shows as seated forever with nothing explaining why.
   */
  itemCount: number
}

const toPublicSection = (row: SectionRow, tableCount?: number) => ({
  id: row.id,
  name: row.name,
  sortOrder: row.sort_order,
  isActive: row.is_active === 1,
  ...(tableCount !== undefined ? { tableCount } : {}),
})

const toPublicTable = (row: TableRow, parties: SeatedParty[]) => ({
  id: row.id,
  sectionId: row.section_id,
  name: row.name,
  seats: row.seats,
  status: row.status,
  sortOrder: row.sort_order,
  isActive: row.is_active === 1,
  // A table may hold several open orders — two parties sharing it.
  parties,
  partyCount: parties.length,
})

export async function tableRoutes(app: FastifyInstance): Promise<void> {
  // --- sections ---

  app.get('/sections', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const rows = app.db
      .prepare(
        `SELECT s.*, COUNT(t.id) AS table_count
         FROM sections s
         LEFT JOIN tables t ON t.section_id = s.id AND t.deleted_at IS NULL
         WHERE s.branch_id = ? AND s.deleted_at IS NULL
         GROUP BY s.id
         ORDER BY s.sort_order, s.name`,
      )
      .all(me.branchId) as (SectionRow & { table_count: number })[]

    return { sections: rows.map((r) => toPublicSection(r, r.table_count)) }
  })

  app.post('/sections', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createSectionBody.parse(request.body)
    assertSectionNameFree(app, me.branchId, body.name)

    const id = randomUUID()
    const now = new Date().toISOString()
    app.db
      .prepare(
        `INSERT INTO sections (id, branch_id, name, sort_order, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)`,
      )
      .run(id, me.branchId, body.name, body.sortOrder ?? nextSectionOrder(app, me.branchId), now, now)

    reply.status(201)
    return { section: toPublicSection(findSection(app, me.branchId, id)) }
  })

  app.patch<{ Params: { id: string } }>(
    '/sections/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateSectionBody.parse(request.body)
      const existing = findSection(app, me.branchId, request.params.id)

      if (body.name !== undefined && body.name !== existing.name) {
        assertSectionNameFree(app, me.branchId, body.name)
      }

      applyUpdate(app.db, 'sections', request.params.id, [
        ['name', body.name],
        ['sort_order', body.sortOrder],
        ['is_active', body.isActive === undefined ? undefined : body.isActive ? 1 : 0],
      ])

      return { section: toPublicSection(findSection(app, me.branchId, request.params.id)) }
    },
  )

  app.delete<{ Params: { id: string } }>(
    '/sections/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      findSection(app, me.branchId, request.params.id)

      // Deleting a section must never silently take its tables with it.
      const tables = app.db
        .prepare('SELECT COUNT(*) AS n FROM tables WHERE section_id = ? AND deleted_at IS NULL')
        .get(request.params.id) as { n: number }

      if (tables.n > 0) {
        throw new AppError(
          409,
          'SECTION_NOT_EMPTY',
          `This section still has ${tables.n} table${tables.n === 1 ? '' : 's'}. Move or remove them first.`,
        )
      }

      const remaining = app.db
        .prepare('SELECT COUNT(*) AS n FROM sections WHERE branch_id = ? AND deleted_at IS NULL')
        .get(me.branchId) as { n: number }
      if (remaining.n <= 1) {
        throw new AppError(
          409,
          'LAST_SECTION',
          'At least one section must remain — every table belongs to one.',
        )
      }

      softDelete(app.db, 'sections', request.params.id)
      return { ok: true }
    },
  )

  app.post('/sections/reorder', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const { ids } = reorderBody.parse(request.body)
    reorder(app.db, 'sections', ids, me.branchId)
    return { ok: true }
  })

  // --- tables ---

  app.get<{ Querystring: { sectionId?: string } }>(
    '/tables',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const conditions = ['t.branch_id = ?', 't.deleted_at IS NULL']
      const params: unknown[] = [me.branchId]

      if (request.query.sectionId) {
        conditions.push('t.section_id = ?')
        params.push(request.query.sectionId)
      }

      const rows = app.db
        .prepare(
          `SELECT t.* FROM tables t
           WHERE ${conditions.join(' AND ')}
           ORDER BY t.sort_order, t.name`,
        )
        .all(...params) as TableRow[]

      const parties = loadOpenParties(app.db, rows.map((r) => r.id))
      return { tables: rows.map((r) => toPublicTable(r, parties.get(r.id) ?? [])) }
    },
  )

  app.get<{ Params: { id: string } }>('/tables/:id', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const row = findTable(app, me.branchId, request.params.id)
    const parties = loadOpenParties(app.db, [row.id])
    return { table: toPublicTable(row, parties.get(row.id) ?? []) }
  })

  app.post('/tables', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createTableBody.parse(request.body)

    findSection(app, me.branchId, body.sectionId)
    assertTableNameFree(app, me.branchId, body.name)

    const id = randomUUID()
    const now = new Date().toISOString()
    app.db
      .prepare(
        `INSERT INTO tables (id, branch_id, section_id, name, seats, status, sort_order,
                             is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'free', ?, 1, ?, ?)`,
      )
      .run(
        id,
        me.branchId,
        body.sectionId,
        body.name,
        body.seats ?? 4,
        body.sortOrder ?? nextTableOrder(app, body.sectionId),
        now,
        now,
      )

    reply.status(201)
    return { table: toPublicTable(findTable(app, me.branchId, id), []) }
  })

  app.patch<{ Params: { id: string } }>(
    '/tables/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateTableBody.parse(request.body)
      const existing = findTable(app, me.branchId, request.params.id)

      if (body.sectionId !== undefined) findSection(app, me.branchId, body.sectionId)
      if (body.name !== undefined && body.name !== existing.name) {
        assertTableNameFree(app, me.branchId, body.name)
      }

      // `status` is deliberately absent from the update body: it is derived from
      // open orders and maintained by the backend, never set by a client.
      applyUpdate(app.db, 'tables', request.params.id, [
        ['section_id', body.sectionId],
        ['name', body.name],
        ['seats', body.seats],
        ['sort_order', body.sortOrder],
        ['is_active', body.isActive === undefined ? undefined : body.isActive ? 1 : 0],
      ])

      const updated = findTable(app, me.branchId, request.params.id)
      const parties = loadOpenParties(app.db, [updated.id])
      return { table: toPublicTable(updated, parties.get(updated.id) ?? []) }
    },
  )

  app.delete<{ Params: { id: string } }>(
    '/tables/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const table = findTable(app, me.branchId, request.params.id)

      // FR-T5: any open order blocks deletion — the party is still seated.
      const open = app.db
        .prepare(
          `SELECT COUNT(*) AS n FROM orders
           WHERE table_id = ? AND status = 'open' AND deleted_at IS NULL`,
        )
        .get(table.id) as { n: number }

      if (open.n > 0) {
        throw new AppError(
          409,
          'TABLE_IN_USE',
          'This table has an open order. Settle or cancel it first.',
        )
      }

      // FR-V12: the tables a live booking loses, named in the response so the
      // floor can be told which bookings now need another table found for them.
      const bookings = app.db
        .prepare(
          `SELECT r.customer_name, r.reserved_at
           FROM reservations r
           JOIN reservation_tables rt ON rt.reservation_id = r.id
           WHERE rt.table_id = ? AND r.status = 'booked' AND r.deleted_at IS NULL
           ORDER BY r.reserved_at`,
        )
        .all(table.id) as { customer_name: string; reserved_at: string }[]

      // A booking holding this table loses it, rather than pointing at a table
      // that no longer exists.
      app.db.transaction(() => {
        app.db.prepare('DELETE FROM reservation_tables WHERE table_id = ?').run(table.id)
        softDelete(app.db, 'tables', table.id)
      })()

      return {
        ok: true,
        warnings: bookings.map(
          (b) =>
            `${b.customer_name}'s booking at ${new Date(b.reserved_at).toLocaleTimeString('en-IN', {
              hour: '2-digit',
              minute: '2-digit',
              hour12: true,
            })} no longer has this table.`,
        ),
      }
    },
  )

  app.post('/tables/reorder', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const { ids } = reorderBody.parse(request.body)
    reorder(app.db, 'tables', ids, me.branchId)
    return { ok: true }
  })

  /** The floor screen: sections with their tables and who is seated. */
  app.get('/floor', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)

    const sections = app.db
      .prepare(
        `SELECT * FROM sections WHERE branch_id = ? AND deleted_at IS NULL AND is_active = 1
         ORDER BY sort_order, name`,
      )
      .all(me.branchId) as SectionRow[]

    const tables = app.db
      .prepare(
        `SELECT * FROM tables WHERE branch_id = ? AND deleted_at IS NULL AND is_active = 1
         ORDER BY sort_order, name`,
      )
      .all(me.branchId) as TableRow[]

    const parties = loadOpenParties(app.db, tables.map((t) => t.id))

    return {
      sections: sections.map((section) => ({
        ...toPublicSection(section),
        tables: tables
          .filter((t) => t.section_id === section.id)
          .map((t) => toPublicTable(t, parties.get(t.id) ?? [])),
      })),
    }
  })
}

/**
 * Recomputes a table's status from its open orders.
 *
 * Exported because billing and order cancellation both have to call it. Setting
 * `status = 'free'` directly when a bill settles would free a table that still
 * has another party seated at it.
 */
export function refreshTableStatus(db: Db, tableId: string): void {
  db.prepare(
    `UPDATE tables SET status = CASE
       WHEN EXISTS (
         SELECT 1 FROM orders
         WHERE table_id = ? AND status = 'open' AND deleted_at IS NULL
       ) THEN 'occupied'
       WHEN EXISTS (
         SELECT 1 FROM reservation_tables rt
         JOIN reservations r ON r.id = rt.reservation_id
         WHERE rt.table_id = ? AND r.status = 'booked' AND r.deleted_at IS NULL
       ) THEN 'reserved'
       ELSE 'free' END,
     updated_at = ?, synced_at = NULL
     WHERE id = ?`,
  ).run(tableId, tableId, new Date().toISOString(), tableId)
}

function loadOpenParties(db: Db, tableIds: string[]): Map<string, SeatedParty[]> {
  const grouped = new Map<string, SeatedParty[]>()
  if (tableIds.length === 0) return grouped

  const placeholders = tableIds.map(() => '?').join(', ')
  const rows = db
    .prepare(
      `SELECT o.id, o.table_id, o.order_no, o.seat_label,
              (SELECT COUNT(*) FROM order_items i
               WHERE i.order_id = o.id AND i.deleted_at IS NULL) AS item_count
       FROM orders o
       WHERE o.table_id IN (${placeholders}) AND o.status = 'open' AND o.deleted_at IS NULL
       ORDER BY o.order_no`,
    )
    .all(...tableIds) as {
      id: string
      table_id: string
      order_no: number
      seat_label: string | null
      item_count: number
    }[]

  for (const row of rows) {
    const party: SeatedParty = {
      orderId: row.id,
      orderNo: row.order_no,
      seatLabel: row.seat_label,
      itemCount: row.item_count,
    }
    const list = grouped.get(row.table_id)
    if (list) list.push(party)
    else grouped.set(row.table_id, [party])
  }
  return grouped
}

function applyUpdate(
  db: Db,
  table: 'sections' | 'tables',
  id: string,
  columns: [string, unknown][],
): void {
  const sets: string[] = []
  const values: unknown[] = []

  for (const [column, value] of columns) {
    if (value === undefined) continue
    sets.push(`${column} = ?`)
    values.push(value)
  }
  if (sets.length === 0) return

  sets.push('updated_at = ?', 'synced_at = NULL')
  values.push(new Date().toISOString(), id)
  db.prepare(`UPDATE ${table} SET ${sets.join(', ')} WHERE id = ?`).run(...values)
}

function softDelete(db: Db, table: 'sections' | 'tables', id: string): void {
  const now = new Date().toISOString()
  db.prepare(`UPDATE ${table} SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?`).run(
    now,
    now,
    id,
  )
}

function reorder(db: Db, table: 'sections' | 'tables', ids: string[], branchId: string): void {
  const now = new Date().toISOString()
  const update = db.prepare(
    `UPDATE ${table} SET sort_order = ?, updated_at = ?, synced_at = NULL
     WHERE id = ? AND branch_id = ? AND deleted_at IS NULL`,
  )
  // One transaction: a partial reorder would leave a scrambled floor plan.
  db.transaction(() => {
    ids.forEach((id, index) => update.run(index, now, id, branchId))
  })()
}

function findSection(app: FastifyInstance, branchId: string, id: string): SectionRow {
  const row = app.db
    .prepare('SELECT * FROM sections WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as SectionRow | undefined
  if (!row) throw new AppError(404, 'SECTION_NOT_FOUND', 'Section not found')
  return row
}

function findTable(app: FastifyInstance, branchId: string, id: string): TableRow {
  const row = app.db
    .prepare('SELECT * FROM tables WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as TableRow | undefined
  if (!row) throw new AppError(404, 'TABLE_NOT_FOUND', 'Table not found')
  return row
}

function assertSectionNameFree(app: FastifyInstance, branchId: string, name: string): void {
  const clash = app.db
    .prepare(
      'SELECT id FROM sections WHERE branch_id = ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL',
    )
    .get(branchId, name)
  if (clash) throw new AppError(409, 'SECTION_EXISTS', 'A section with that name already exists')
}

function assertTableNameFree(app: FastifyInstance, branchId: string, name: string): void {
  const clash = app.db
    .prepare(
      'SELECT id FROM tables WHERE branch_id = ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL',
    )
    .get(branchId, name)
  if (clash) throw new AppError(409, 'TABLE_EXISTS', 'A table with that name already exists')
}

function nextSectionOrder(app: FastifyInstance, branchId: string): number {
  const row = app.db
    .prepare(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM sections WHERE branch_id = ? AND deleted_at IS NULL',
    )
    .get(branchId) as { next: number }
  return row.next
}

function nextTableOrder(app: FastifyInstance, sectionId: string): number {
  const row = app.db
    .prepare(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM tables WHERE section_id = ? AND deleted_at IS NULL',
    )
    .get(sectionId) as { next: number }
  return row.next
}
