import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import type { Db } from '../db/client.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth } from '../lib/guards.js'
import { currentBusinessDate, nextDailyNumber } from '../lib/business-date.js'
import { getSetting } from '../lib/settings.js'
import { lineAmounts, orderSubtotal, orderTax, orderTotal, type TaxMode } from '../lib/order-math.js'
import { refreshTableStatus } from './tables.js'

const createBody = z
  .object({
    type: z.enum(['dine_in', 'takeaway']),
    tableId: z.string().uuid().optional(),
    seatLabel: z.string().max(16).trim().optional(),
    customerName: z.string().max(64).trim().optional(),
    customerPhone: z.string().max(20).trim().optional(),
  })
  .refine((body) => body.type === 'takeaway' || body.tableId !== undefined, {
    message: 'A dine-in order needs a table',
    path: ['tableId'],
  })

const addItemBody = z.object({
  variantId: z.string().uuid(),
  qty: z.number().int().min(1).max(999),
  notes: z.string().max(128).trim().optional(),
})

const updateItemBody = z.object({
  qty: z.number().int().min(1).max(999).optional(),
  notes: z.string().max(128).trim().nullable().optional(),
})

const updateOrderBody = z.object({
  seatLabel: z.string().max(16).trim().nullable().optional(),
  customerName: z.string().max(64).trim().nullable().optional(),
  customerPhone: z.string().max(20).trim().nullable().optional(),
  /** Optimistic concurrency — the version the client last read. */
  version: z.number().int().min(1).optional(),
})

const cancelBody = z.object({
  reason: z.string().min(1).max(200).trim(),
})

interface OrderRow {
  id: string
  branch_id: string
  order_no: number
  business_date: string
  type: 'dine_in' | 'takeaway'
  table_id: string | null
  seat_label: string | null
  status: 'open' | 'billed' | 'cancelled'
  customer_name: string | null
  customer_phone: string | null
  cancel_reason: string | null
  version: number
  created_by: string
  created_at: string
}

interface OrderItemRow {
  id: string
  order_id: string
  variant_id: string
  item_name: string
  variant_name: string
  unit_price: number
  tax_rate: number
  qty: number
  line_base: number
  line_tax: number
  line_total: number
  notes: string | null
  kot_printed_at: string | null
}

export async function orderRoutes(app: FastifyInstance): Promise<void> {
  app.get<{ Querystring: { status?: string; tableId?: string; businessDate?: string } }>(
    '/orders',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const conditions = ['branch_id = ?', 'deleted_at IS NULL']
      const params: unknown[] = [me.branchId]

      if (request.query.status) {
        conditions.push('status = ?')
        params.push(request.query.status)
      }
      if (request.query.tableId) {
        conditions.push('table_id = ?')
        params.push(request.query.tableId)
      }
      if (request.query.businessDate) {
        conditions.push('business_date = ?')
        params.push(request.query.businessDate)
      }

      const rows = app.db
        .prepare(
          `SELECT * FROM orders WHERE ${conditions.join(' AND ')} ORDER BY order_no DESC LIMIT 200`,
        )
        .all(...params) as OrderRow[]

      const items = loadItems(app.db, rows.map((r) => r.id))
      const taxMode = getSetting(app.db, me.branchId, 'tax_mode')

      return { orders: rows.map((row) => present(row, items.get(row.id) ?? [], taxMode)) }
    },
  )

  app.get<{ Params: { id: string } }>('/orders/:id', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const order = findOrder(app, me.branchId, request.params.id)
    const items = loadItems(app.db, [order.id]).get(order.id) ?? []
    return { order: present(order, items, getSetting(app.db, me.branchId, 'tax_mode')) }
  })

  app.post('/orders', { preHandler: requireAuth }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)

    if (body.type === 'dine_in') assertTableUsable(app, me.branchId, body.tableId!)

    const businessDate = currentBusinessDate(app.db, me.branchId)
    const id = randomUUID()
    const now = new Date().toISOString()

    // Numbering happens inside the transaction that inserts the row, so two
    // terminals cannot allocate the same order number.
    app.db.transaction(() => {
      const orderNo = nextDailyNumber(app.db, 'orders', 'order_no', me.branchId, businessDate)
      app.db
        .prepare(
          `INSERT INTO orders (id, branch_id, order_no, business_date, type, table_id, seat_label,
                               status, customer_name, customer_phone, version, created_by,
                               created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, 1, ?, ?, ?)`,
        )
        .run(
          id,
          me.branchId,
          orderNo,
          businessDate,
          body.type,
          body.tableId ?? null,
          body.seatLabel ?? null,
          body.customerName ?? null,
          body.customerPhone ?? null,
          me.sub,
          now,
          now,
        )

      if (body.tableId) refreshTableStatus(app.db, body.tableId)
    })()

    const created = findOrder(app, me.branchId, id)
    reply.status(201)
    return { order: present(created, [], getSetting(app.db, me.branchId, 'tax_mode')) }
  })

  app.patch<{ Params: { id: string } }>(
    '/orders/:id',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = updateOrderBody.parse(request.body)
      const order = findOpenOrder(app, me.branchId, request.params.id)
      assertVersion(order, body.version)

      const sets: string[] = []
      const values: unknown[] = []
      const push = (column: string, value: unknown) => {
        if (value === undefined) return
        sets.push(`${column} = ?`)
        values.push(value)
      }

      push('seat_label', body.seatLabel)
      push('customer_name', body.customerName)
      push('customer_phone', body.customerPhone)

      if (sets.length > 0) {
        sets.push('version = version + 1', 'updated_at = ?', 'synced_at = NULL')
        values.push(new Date().toISOString(), order.id)
        app.db.prepare(`UPDATE orders SET ${sets.join(', ')} WHERE id = ?`).run(...values)
      }

      return respond(app, me.branchId, order.id)
    },
  )

  app.post<{ Params: { id: string } }>(
    '/orders/:id/items',
    { preHandler: requireAuth },
    async (request, reply) => {
      const me = currentUser(request)
      const body = addItemBody.parse(request.body)
      const order = findOpenOrder(app, me.branchId, request.params.id)

      const variant = loadOrderableVariant(app, me.branchId, body.variantId)
      const taxMode = getSetting(app.db, me.branchId, 'tax_mode')

      app.db.transaction(() => {
        // Merge into an existing line only when the snapshot price matches. If the
        // item was repriced between the two adds, each keeps its own price.
        const existing = app.db
          .prepare(
            `SELECT * FROM order_items
             WHERE order_id = ? AND variant_id = ? AND unit_price = ? AND tax_rate = ?
               AND IFNULL(notes, '') = IFNULL(?, '') AND deleted_at IS NULL
             LIMIT 1`,
          )
          .get(order.id, variant.id, variant.price, variant.tax_rate, body.notes ?? null) as
          | OrderItemRow
          | undefined

        if (existing) {
          writeLine(app.db, existing.id, {
            qty: existing.qty + body.qty,
            unitPrice: existing.unit_price,
            taxRate: existing.tax_rate,
            taxMode,
          })
        } else {
          const amounts = lineAmounts(
            { unitPrice: variant.price, taxRate: variant.tax_rate, qty: body.qty },
            taxMode,
          )
          const now = new Date().toISOString()
          app.db
            .prepare(
              `INSERT INTO order_items (id, order_id, variant_id, item_name, variant_name,
                                        unit_price, tax_rate, qty, line_base, line_tax, line_total,
                                        notes, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            )
            .run(
              randomUUID(),
              order.id,
              variant.id,
              // Snapshots: renaming or repricing the dish must never alter this line.
              variant.item_name,
              variant.name,
              variant.price,
              variant.tax_rate,
              body.qty,
              amounts.base,
              amounts.tax,
              amounts.total,
              body.notes ?? null,
              now,
              now,
            )
        }

        bumpOrder(app.db, order.id)
      })()

      reply.status(201)
      return respond(app, me.branchId, order.id)
    },
  )

  app.patch<{ Params: { id: string; itemId: string } }>(
    '/orders/:id/items/:itemId',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = updateItemBody.parse(request.body)
      const order = findOpenOrder(app, me.branchId, request.params.id)
      const item = findItem(app, order.id, request.params.itemId)
      const taxMode = getSetting(app.db, me.branchId, 'tax_mode')

      app.db.transaction(() => {
        if (body.qty !== undefined) {
          writeLine(app.db, item.id, {
            qty: body.qty,
            unitPrice: item.unit_price,
            taxRate: item.tax_rate,
            taxMode,
          })
        }
        if (body.notes !== undefined) {
          app.db
            .prepare('UPDATE order_items SET notes = ?, updated_at = ?, synced_at = NULL WHERE id = ?')
            .run(body.notes, new Date().toISOString(), item.id)
        }
        bumpOrder(app.db, order.id)
      })()

      return respond(app, me.branchId, order.id)
    },
  )

  app.delete<{ Params: { id: string; itemId: string } }>(
    '/orders/:id/items/:itemId',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const order = findOpenOrder(app, me.branchId, request.params.id)
      const item = findItem(app, order.id, request.params.itemId)
      const now = new Date().toISOString()

      app.db.transaction(() => {
        app.db
          .prepare(
            'UPDATE order_items SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?',
          )
          .run(now, now, item.id)
        bumpOrder(app.db, order.id)
      })()

      const result = await respond(app, me.branchId, order.id)
      return {
        ...result,
        // FR-O13: the kitchen is already cooking this. The caller decides whether
        // to send a cancellation slip.
        kotAlreadyPrinted: item.kot_printed_at !== null,
      }
    },
  )

  app.post<{ Params: { id: string } }>(
    '/orders/:id/cancel',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = cancelBody.parse(request.body)
      const order = findOpenOrder(app, me.branchId, request.params.id)
      const now = new Date().toISOString()

      const anyKotPrinted = app.db
        .prepare(
          `SELECT COUNT(*) AS n FROM order_items
           WHERE order_id = ? AND kot_printed_at IS NOT NULL AND deleted_at IS NULL`,
        )
        .get(order.id) as { n: number }

      app.db.transaction(() => {
        app.db
          .prepare(
            `UPDATE orders SET status = 'cancelled', cancel_reason = ?, deleted_at = ?,
                               version = version + 1, updated_at = ?, synced_at = NULL
             WHERE id = ?`,
          )
          .run(body.reason, now, now, order.id)

        // Freeing the table must be derived: another party may still be seated.
        if (order.table_id) refreshTableStatus(app.db, order.table_id)
      })()

      return {
        ok: true,
        // FR-P19: the kitchen must be told, or they keep cooking.
        kotCancellationNeeded: anyKotPrinted.n > 0,
      }
    },
  )
}

/** Recomputes and writes a line's amounts. Never trusts client-supplied totals. */
function writeLine(
  db: Db,
  itemId: string,
  input: { qty: number; unitPrice: number; taxRate: number; taxMode: TaxMode },
): void {
  const amounts = lineAmounts(
    { unitPrice: input.unitPrice, taxRate: input.taxRate, qty: input.qty },
    input.taxMode,
  )
  db.prepare(
    `UPDATE order_items SET qty = ?, line_base = ?, line_tax = ?, line_total = ?,
                            updated_at = ?, synced_at = NULL
     WHERE id = ?`,
  ).run(input.qty, amounts.base, amounts.tax, amounts.total, new Date().toISOString(), itemId)
}

function bumpOrder(db: Db, orderId: string): void {
  db.prepare(
    'UPDATE orders SET version = version + 1, updated_at = ?, synced_at = NULL WHERE id = ?',
  ).run(new Date().toISOString(), orderId)
}

function loadItems(db: Db, orderIds: string[]): Map<string, OrderItemRow[]> {
  const grouped = new Map<string, OrderItemRow[]>()
  if (orderIds.length === 0) return grouped

  const placeholders = orderIds.map(() => '?').join(', ')
  const rows = db
    .prepare(
      `SELECT * FROM order_items WHERE order_id IN (${placeholders}) AND deleted_at IS NULL
       ORDER BY created_at`,
    )
    .all(...orderIds) as OrderItemRow[]

  for (const row of rows) {
    const list = grouped.get(row.order_id)
    if (list) list.push(row)
    else grouped.set(row.order_id, [row])
  }
  return grouped
}

function present(order: OrderRow, items: OrderItemRow[], taxMode: TaxMode) {
  const amounts = items.map((i) => ({ base: i.line_base, tax: i.line_tax, total: i.line_total }))

  return {
    id: order.id,
    orderNo: order.order_no,
    businessDate: order.business_date,
    type: order.type,
    tableId: order.table_id,
    seatLabel: order.seat_label,
    status: order.status,
    customerName: order.customer_name,
    customerPhone: order.customer_phone,
    cancelReason: order.cancel_reason,
    version: order.version,
    createdAt: order.created_at,
    taxMode,
    items: items.map((i) => ({
      id: i.id,
      variantId: i.variant_id,
      itemName: i.item_name,
      variantName: i.variant_name,
      unitPrice: i.unit_price,
      taxRate: i.tax_rate,
      qty: i.qty,
      lineBase: i.line_base,
      lineTax: i.line_tax,
      lineTotal: i.line_total,
      notes: i.notes,
      kotPrinted: i.kot_printed_at !== null,
    })),
    // A running preview only. The bill recomputes everything, including discounts.
    subtotal: orderSubtotal(amounts),
    tax: orderTax(amounts),
    total: orderTotal(amounts),
    itemCount: items.reduce((sum, i) => sum + i.qty, 0),
  }
}

async function respond(app: FastifyInstance, branchId: string, orderId: string) {
  const order = findOrder(app, branchId, orderId)
  const items = loadItems(app.db, [orderId]).get(orderId) ?? []
  return { order: present(order, items, getSetting(app.db, branchId, 'tax_mode')) }
}

function findOrder(app: FastifyInstance, branchId: string, id: string): OrderRow {
  const row = app.db
    .prepare('SELECT * FROM orders WHERE id = ? AND branch_id = ?')
    .get(id, branchId) as OrderRow | undefined
  if (!row) throw new AppError(404, 'ORDER_NOT_FOUND', 'Order not found')
  return row
}

function findOpenOrder(app: FastifyInstance, branchId: string, id: string): OrderRow {
  const order = findOrder(app, branchId, id)
  if (order.status !== 'open') {
    // FR-O14: a billed order is a financial record and must not change.
    throw new AppError(
      409,
      'ORDER_NOT_OPEN',
      order.status === 'billed'
        ? 'This order has been billed and can no longer be changed.'
        : 'This order was cancelled.',
    )
  }
  return order
}

function findItem(app: FastifyInstance, orderId: string, itemId: string): OrderItemRow {
  const row = app.db
    .prepare('SELECT * FROM order_items WHERE id = ? AND order_id = ? AND deleted_at IS NULL')
    .get(itemId, orderId) as OrderItemRow | undefined
  if (!row) throw new AppError(404, 'ORDER_ITEM_NOT_FOUND', 'That line is not on this order')
  return row
}

/** FR-O15: rejects a write based on a stale read rather than overwriting silently. */
function assertVersion(order: OrderRow, expected: number | undefined): void {
  if (expected !== undefined && expected !== order.version) {
    throw new AppError(
      409,
      'ORDER_MODIFIED',
      'Someone else changed this order. Reload it and try again.',
    )
  }
}

function assertTableUsable(app: FastifyInstance, branchId: string, tableId: string): void {
  const table = app.db
    .prepare(
      'SELECT id, is_active FROM tables WHERE id = ? AND branch_id = ? AND deleted_at IS NULL',
    )
    .get(tableId, branchId) as { id: string; is_active: number } | undefined

  if (!table) throw new AppError(404, 'TABLE_NOT_FOUND', 'Table not found')
  if (table.is_active !== 1) {
    throw new AppError(409, 'TABLE_INACTIVE', 'That table is not in service')
  }
  // A table already holding an order is fine — two parties may share it.
}

interface VariantJoin {
  id: string
  name: string
  price: number
  is_available: number
  item_name: string
  tax_rate: number
  item_available: number
}

function loadOrderableVariant(app: FastifyInstance, branchId: string, variantId: string): VariantJoin {
  const row = app.db
    .prepare(
      `SELECT v.id, v.name, v.price, v.is_available,
              m.name AS item_name, m.tax_rate, m.is_available AS item_available
       FROM menu_item_variants v
       JOIN menu_items m ON m.id = v.menu_item_id
       WHERE v.id = ? AND m.branch_id = ? AND v.deleted_at IS NULL AND m.deleted_at IS NULL`,
    )
    .get(variantId, branchId) as VariantJoin | undefined

  if (!row) throw new AppError(404, 'VARIANT_NOT_FOUND', 'That item is not on the menu')
  if (row.item_available !== 1) {
    throw new AppError(409, 'ITEM_UNAVAILABLE', `${row.item_name} is not available right now`)
  }
  if (row.is_available !== 1) {
    throw new AppError(
      409,
      'VARIANT_UNAVAILABLE',
      `${row.item_name} (${row.name}) is not available right now`,
    )
  }
  return row
}
