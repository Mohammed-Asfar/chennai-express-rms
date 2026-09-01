import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import type { Db } from '../db/client.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { currentBusinessDate, nextBillNumber } from '../lib/business-date.js'
import { formatBillNumber, periodKey } from '../lib/bill-number.js'
import { getSetting } from '../lib/settings.js'
import { BillError, computeBill, type BillResult } from '../lib/bill-math.js'
import { refreshTableStatus } from './tables.js'
import { enqueueAndSend, resolvePrinter } from '../print/queue.js'
import { renderBill } from '../print/tickets.js'

const createBody = z.object({
  orderId: z.string().uuid(),
  discountType: z.enum(['none', 'fixed', 'percent']).optional(),
  /** Paise when fixed, basis points when percent. */
  discountValue: z.number().int().min(0).optional(),
  customerName: z.string().max(64).trim().optional(),
  customerPhone: z.string().max(20).trim().optional(),
})

const paymentBody = z.object({
  mode: z.enum(['cash', 'card', 'upi']),
  amount: z.number().int().min(1),
  reference: z.string().max(64).trim().optional(),
})

const voidBody = z.object({ reason: z.string().min(1).max(200).trim() })
const reverseBody = z.object({ reason: z.string().min(1).max(200).trim() })

interface BillRow {
  id: string
  branch_id: string
  order_id: string
  bill_no: number
  bill_period: string
  bill_number: string
  business_date: string
  subtotal: number
  discount_type: string
  discount_value: number
  discount_amount: number
  cgst: number
  sgst: number
  round_off: number
  total: number
  amount_paid: number
  payment_status: 'unpaid' | 'partial' | 'paid'
  tax_mode: string
  tax_breakdown: string
  settled_at: string | null
  customer_name: string | null
  customer_phone: string | null
  void_reason: string | null
  voided_at: string | null
  reprint_count: number
  created_at: string
}

interface PaymentRow {
  id: string
  bill_id: string
  mode: string
  amount: number
  reference: string | null
  paid_at: string
  business_date: string
  reversed_at: string | null
  reverse_reason: string | null
}

export async function billRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Bills for a business date or a range of them.
   *
   * Filtered on `business_date`, never `created_at`: a restaurant open past
   * midnight keeps 1 AM sales on the previous trading day, and a day's takings
   * must match what the till counted.
   *
   * `from`/`to` are inclusive. With neither, today is used — the common case is
   * "what has been billed today".
   */
  app.get<{
    Querystring: {
      businessDate?: string
      from?: string
      to?: string
      status?: string
      unpaid?: string
      all?: string
    }
  }>('/bills', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const conditions = ['branch_id = ?', 'deleted_at IS NULL']
    const params: unknown[] = [me.branchId]

    const { businessDate, from, to } = request.query

    if (businessDate) {
      conditions.push('business_date = ?')
      params.push(businessDate)
    } else if (from || to) {
      // An open-ended range is still a range: "everything since Monday".
      if (from) {
        conditions.push('business_date >= ?')
        params.push(from)
      }
      if (to) {
        conditions.push('business_date <= ?')
        params.push(to)
      }
    } else if (request.query.all !== 'true') {
      conditions.push('business_date = ?')
      params.push(currentBusinessDate(app.db, me.branchId))
    }

    if (request.query.status) {
      conditions.push('payment_status = ?')
      params.push(request.query.status)
    }
    if (request.query.unpaid === 'true') conditions.push("payment_status != 'paid'")

    const where = conditions.join(' AND ')

    const rows = app.db
      .prepare(
        `SELECT * FROM bills WHERE ${where} ORDER BY business_date DESC, bill_no DESC LIMIT 500`,
      )
      .all(...params) as BillRow[]

    // Summed in SQL over the whole match, not over the returned page: a day
    // with more than 500 bills must still report its real takings.
    const totals = app.db
      .prepare(
        `SELECT COUNT(*) AS count,
                COALESCE(SUM(total), 0) AS total,
                COALESCE(SUM(amount_paid), 0) AS collected
         FROM bills WHERE ${where}`,
      )
      .get(...params) as { count: number; total: number; collected: number }

    const payments = loadPayments(app.db, rows.map((r) => r.id))

    return {
      bills: rows.map((row) => present(row, payments.get(row.id) ?? [])),
      summary: {
        count: totals.count,
        total: totals.total,
        collected: totals.collected,
        outstanding: totals.total - totals.collected,
      },
    }
  })

  /**
   * One bill, with everything needed to show or re-check it.
   *
   * Line items come from `order_items`, which snapshotted the name, price and
   * tax rate when each was added. Reading the menu instead would mean a dish
   * renamed or repriced today silently rewrites a bill from last month.
   */
  app.get<{ Params: { id: string } }>('/bills/:id', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const bill = findBill(app, me.branchId, request.params.id)

    const items = app.db
      .prepare(
        `SELECT item_name, variant_name, qty, unit_price, tax_rate,
                line_base, line_tax, line_total
         FROM order_items
         WHERE order_id = ? AND deleted_at IS NULL
         ORDER BY created_at`,
      )
      .all(bill.order_id) as {
      item_name: string
      variant_name: string
      qty: number
      unit_price: number
      tax_rate: number
      line_base: number
      line_tax: number
      line_total: number
    }[]

    const order = app.db
      .prepare('SELECT order_no, type, table_id FROM orders WHERE id = ?')
      .get(bill.order_id) as
      | { order_no: number; type: 'dine_in' | 'takeaway'; table_id: string | null }
      | undefined

    const table = order?.table_id
      ? (app.db.prepare('SELECT name FROM tables WHERE id = ?').get(order.table_id) as
          | { name: string }
          | undefined)
      : undefined

    return {
      bill: {
        ...present(bill, loadPayments(app.db, [bill.id]).get(bill.id) ?? []),
        orderNo: order?.order_no ?? null,
        orderType: order?.type ?? null,
        tableName: table?.name ?? null,
        items: items.map((item) => ({
          itemName: item.item_name,
          variantName: item.variant_name,
          qty: item.qty,
          unitPrice: item.unit_price,
          taxRate: item.tax_rate,
          lineBase: item.line_base,
          lineTax: item.line_tax,
          lineTotal: item.line_total,
        })),
      },
    }
  })

  /** Preview without persisting — lets the till show a total before committing. */
  app.post('/bills/preview', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)
    const order = findBillableOrder(app, me.branchId, body.orderId)
    const computed = calculate(app, me.branchId, order.id, body)
    return { preview: shape(computed) }
  })

  app.post('/bills', { preHandler: requireAuth }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)
    const order = findBillableOrder(app, me.branchId, body.orderId)

    const existing = app.db
      .prepare('SELECT id FROM bills WHERE order_id = ? AND deleted_at IS NULL')
      .get(order.id) as { id: string } | undefined
    if (existing) {
      throw new AppError(409, 'ALREADY_BILLED', 'This order has already been billed')
    }

    const computed = calculate(app, me.branchId, order.id, body)
    const taxMode = getSetting(app.db, me.branchId, 'tax_mode')
    const businessDate = currentBusinessDate(app.db, me.branchId)
    const id = randomUUID()
    const now = new Date().toISOString()

    // Which sequence this bill belongs to. Keyed on the period, not the date:
    // with monthly reset, bill 47 recurs on many dates within the month.
    const resetPeriod = getSetting(app.db, me.branchId, 'bill_reset_period')
    const billPeriod = periodKey(businessDate, resetPeriod)

    app.db.transaction(() => {
      // Numbered inside the insert transaction, so two terminals cannot collide.
      const billNo = nextBillNumber(app.db, me.branchId, billPeriod)

      // The formatted string is stored, not derived on read: a reprint must show
      // what the original showed, even if the format is changed later.
      const billNumber = formatBillNumber({
        billNo,
        businessDate,
        template: getSetting(app.db, me.branchId, 'bill_number_format'),
        prefix: getSetting(app.db, me.branchId, 'bill_prefix'),
        padWidth: getSetting(app.db, me.branchId, 'bill_number_pad'),
      })

      app.db
        .prepare(
          `INSERT INTO bills (id, branch_id, order_id, bill_no, bill_period, bill_number,
                              business_date, subtotal,
                              discount_type, discount_value, discount_amount, cgst, sgst,
                              round_off, total, amount_paid, payment_status, tax_mode,
                              tax_breakdown, customer_name, customer_phone, reprint_count,
                              created_by, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'unpaid', ?, ?, ?, ?, 0, ?, ?, ?)`,
        )
        .run(
          id,
          me.branchId,
          order.id,
          billNo,
          billPeriod,
          billNumber,
          businessDate,
          computed.subtotal,
          body.discountType ?? 'none',
          body.discountValue ?? 0,
          computed.discountAmount,
          computed.cgst,
          computed.sgst,
          computed.roundOff,
          computed.total,
          taxMode,
          JSON.stringify(computed.taxBreakdown),
          body.customerName ?? order.customer_name,
          body.customerPhone ?? order.customer_phone,
          me.sub,
          now,
          now,
        )

      // Billing closes the order. The table frees only if no other party is
      // still seated — an unpaid bill must not hold it either.
      app.db
        .prepare(
          `UPDATE orders SET status = 'billed', version = version + 1, updated_at = ?,
                             synced_at = NULL
           WHERE id = ?`,
        )
        .run(now, order.id)

      if (order.table_id) refreshTableStatus(app.db, order.table_id)
    })()

    reply.status(201)
    return { bill: present(findBill(app, me.branchId, id), []) }
  })

  /**
   * Prints (or reprints) a bill.
   *
   * A reprint is marked DUPLICATE on the paper: two identical bills in a till
   * drawer at closing time is how a cashier ends up counting a sale twice.
   */
  app.post<{ Params: { id: string } }>(
    '/bills/:id/print',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const bill = findBill(app, me.branchId, request.params.id)

      const printer = resolvePrinter(app.db, me.branchId, 'bill')
      if (!printer) {
        throw new AppError(
          400,
          'NO_BILL_PRINTER',
          'No billing printer is set up. Add one in printer settings.',
        )
      }

      const alreadyPrinted = app.db
        .prepare(
          `SELECT COUNT(*) AS n FROM print_jobs
           WHERE ref_id = ? AND type = 'bill' AND status = 'printed'`,
        )
        .get(bill.id) as { n: number }

      const items = app.db
        .prepare(
          'SELECT * FROM order_items WHERE order_id = ? AND deleted_at IS NULL ORDER BY created_at',
        )
        .all(bill.order_id) as {
        item_name: string
        variant_name: string
        qty: number
        unit_price: number
        line_total: number
      }[]

      const order = app.db
        .prepare('SELECT order_no, type, table_id FROM orders WHERE id = ?')
        .get(bill.order_id) as
        | { order_no: number; type: 'dine_in' | 'takeaway'; table_id: string | null }
        | undefined

      const table = order?.table_id
        ? (app.db.prepare('SELECT name FROM tables WHERE id = ?').get(order.table_id) as
            | { name: string }
            | undefined)
        : undefined

      const branch = app.db
        .prepare('SELECT name, address, gstin FROM branches WHERE id = ?')
        .get(me.branchId) as
        | { name: string; address: string | null; gstin: string | null }
        | undefined

      const payments = app.db
        .prepare(
          // Reversed payments are excluded: the receipt should show what the
          // customer actually paid, not a corrected entry and its correction.
          `SELECT mode, amount FROM payments
           WHERE bill_id = ? AND deleted_at IS NULL AND reversed_at IS NULL
           ORDER BY created_at`,
        )
        .all(bill.id) as { mode: string; amount: number }[]

      const payload = renderBill(
        {
          billNumber: bill.bill_number,
          branchName: branch?.name ?? 'Restaurant',
          branchAddress: branch?.address ?? null,
          gstin: branch?.gstin ?? null,
          orderNo: order?.order_no ?? 0,
          type: order?.type ?? 'dine_in',
          tableName: table?.name ?? null,
          printedAt: new Date(),
          lines: items.map((item) => ({
            name: item.item_name,
            variantName: item.variant_name,
            qty: item.qty,
            unitPrice: item.unit_price,
            lineTotal: item.line_total,
          })),
          subtotal: bill.subtotal,
          discountAmount: bill.discount_amount,
          cgst: bill.cgst,
          sgst: bill.sgst,
          roundOff: bill.round_off,
          total: bill.total,
          taxMode: bill.tax_mode === 'exclusive' ? 'exclusive' : 'inclusive',
          payments,
          footer: getSetting(app.db, me.branchId, 'bill_footer'),
          isReprint: alreadyPrinted.n > 0,
        },
        printer.paper_width,
      )

      const jobId = enqueueAndSend(app.db, {
        branchId: me.branchId,
        printerId: printer.id,
        type: 'bill',
        refId: bill.id,
        payload,
      })

      await new Promise((resolve) => setTimeout(resolve, 400))
      const job = app.db
        .prepare('SELECT status, last_error FROM print_jobs WHERE id = ?')
        .get(jobId) as { status: string; last_error: string | null } | undefined

      return {
        ok: job?.status === 'printed',
        isReprint: alreadyPrinted.n > 0,
        error: job?.status === 'printed' ? null : job?.last_error ?? null,
      }
    },
  )

  // --- payments ---

  app.post<{ Params: { id: string } }>(
    '/bills/:id/payments',
    { preHandler: requireAuth },
    async (request, reply) => {
      const me = currentUser(request)
      const body = paymentBody.parse(request.body)
      const bill = findBill(app, me.branchId, request.params.id)

      if (bill.voided_at !== null) {
        throw new AppError(409, 'BILL_VOIDED', 'This bill has been voided')
      }

      const outstanding = bill.total - bill.amount_paid
      if (body.amount > outstanding) {
        // Change is handled at the drawer, not recorded as an overpayment.
        throw new AppError(
          400,
          'OVERPAYMENT',
          `That is more than the ${outstanding} paise still due on this bill`,
        )
      }

      const now = new Date().toISOString()
      app.db.transaction(() => {
        app.db
          .prepare(
            `INSERT INTO payments (id, branch_id, bill_id, mode, amount, reference, paid_at,
                                   business_date, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .run(
            randomUUID(),
            me.branchId,
            bill.id,
            body.mode,
            body.amount,
            body.reference ?? null,
            now,
            // The payment's own business date: a Monday bill settled Wednesday
            // has its sale on Monday and its cash on Wednesday.
            currentBusinessDate(app.db, me.branchId),
            me.sub,
            now,
            now,
          )
        recalculatePayment(app.db, bill.id, now)
      })()

      reply.status(201)
      return respond(app, me.branchId, bill.id)
    },
  )

  app.post<{ Params: { id: string; paymentId: string } }>(
    '/bills/:id/payments/:paymentId/reverse',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = reverseBody.parse(request.body)
      const bill = findBill(app, me.branchId, request.params.id)

      const payment = app.db
        .prepare('SELECT * FROM payments WHERE id = ? AND bill_id = ?')
        .get(request.params.paymentId, bill.id) as PaymentRow | undefined
      if (!payment) throw new AppError(404, 'PAYMENT_NOT_FOUND', 'Payment not found')
      if (payment.reversed_at !== null) {
        throw new AppError(409, 'ALREADY_REVERSED', 'That payment has already been reversed')
      }

      const now = new Date().toISOString()
      app.db.transaction(() => {
        // Reversed, never deleted: a cashier who recorded cash when it was card
        // leaves both rows for audit.
        app.db
          .prepare(
            `UPDATE payments SET reversed_at = ?, reversed_by = ?, reverse_reason = ?,
                                 updated_at = ?, synced_at = NULL
             WHERE id = ?`,
          )
          .run(now, me.sub, body.reason, now, payment.id)
        recalculatePayment(app.db, bill.id, now)
      })()

      return respond(app, me.branchId, bill.id)
    },
  )

  // --- void and reprint ---

  app.post<{ Params: { id: string } }>(
    '/bills/:id/void',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = voidBody.parse(request.body)
      const bill = findBill(app, me.branchId, request.params.id)

      if (bill.voided_at !== null) {
        throw new AppError(409, 'ALREADY_VOIDED', 'This bill is already voided')
      }

      const live = app.db
        .prepare(
          'SELECT COUNT(*) AS n FROM payments WHERE bill_id = ? AND reversed_at IS NULL',
        )
        .get(bill.id) as { n: number }
      if (live.n > 0) {
        // Money must not sit recorded against a sale that no longer exists.
        throw new AppError(
          409,
          'BILL_HAS_PAYMENTS',
          'Reverse this bill’s payments before voiding it',
        )
      }

      const now = new Date().toISOString()
      app.db.transaction(() => {
        app.db
          .prepare(
            `UPDATE bills SET void_reason = ?, voided_at = ?, voided_by = ?, deleted_at = ?,
                              updated_at = ?, synced_at = NULL
             WHERE id = ?`,
          )
          .run(body.reason, now, me.sub, now, now, bill.id)

        // The order reopens so it can be corrected and re-billed. The bill
        // number stays consumed: a gap in the sequence looks worse to an
        // auditor than a number marked void.
        app.db
          .prepare(
            `UPDATE orders SET status = 'open', version = version + 1, updated_at = ?,
                               synced_at = NULL
             WHERE id = ?`,
          )
          .run(now, bill.order_id)

        const order = app.db
          .prepare('SELECT table_id FROM orders WHERE id = ?')
          .get(bill.order_id) as { table_id: string | null }
        if (order?.table_id) refreshTableStatus(app.db, order.table_id)
      })()

      return { ok: true }
    },
  )

  app.post<{ Params: { id: string } }>(
    '/bills/:id/reprint',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const bill = findBill(app, me.branchId, request.params.id)

      app.db
        .prepare(
          `UPDATE bills SET reprint_count = reprint_count + 1, updated_at = ?, synced_at = NULL
           WHERE id = ?`,
        )
        .run(new Date().toISOString(), bill.id)

      const updated = findBill(app, me.branchId, bill.id)
      return {
        bill: present(updated, loadPayments(app.db, [bill.id]).get(bill.id) ?? []),
        // A reprint that looks identical to the original is a way to present
        // one sale as two.
        isDuplicate: true,
      }
    },
  )
}

/**
 * Recomputes `amount_paid` and `payment_status` from live payment rows.
 *
 * Derived, never set directly — and always inside the same transaction as the
 * payment write that caused it.
 */
function recalculatePayment(db: Db, billId: string, now: string): void {
  const sum = db
    .prepare(
      'SELECT COALESCE(SUM(amount), 0) AS paid FROM payments WHERE bill_id = ? AND reversed_at IS NULL',
    )
    .get(billId) as { paid: number }

  const bill = db.prepare('SELECT total FROM bills WHERE id = ?').get(billId) as { total: number }

  const status = sum.paid >= bill.total ? 'paid' : sum.paid > 0 ? 'partial' : 'unpaid'

  db.prepare(
    `UPDATE bills SET amount_paid = ?, payment_status = ?, settled_at = ?, updated_at = ?,
                      synced_at = NULL
     WHERE id = ?`,
  ).run(sum.paid, status, status === 'paid' ? now : null, now, billId)
}

function calculate(
  app: FastifyInstance,
  branchId: string,
  orderId: string,
  body: z.infer<typeof createBody>,
): BillResult {
  const lines = app.db
    .prepare(
      `SELECT unit_price, tax_rate, qty FROM order_items
       WHERE order_id = ? AND deleted_at IS NULL`,
    )
    .all(orderId) as { unit_price: number; tax_rate: number; qty: number }[]

  try {
    return computeBill({
      // Snapshots from the order line, never read live from the menu.
      lines: lines.map((l) => ({ unitPrice: l.unit_price, taxRate: l.tax_rate, qty: l.qty })),
      taxMode: getSetting(app.db, branchId, 'tax_mode'),
      discountType: body.discountType ?? 'none',
      discountValue: body.discountValue ?? 0,
      roundOff: getSetting(app.db, branchId, 'round_off_enabled'),
    })
  } catch (error) {
    if (error instanceof BillError) throw new AppError(400, error.code, error.message)
    throw error
  }
}

const shape = (result: BillResult) => ({
  subtotal: result.subtotal,
  discountAmount: result.discountAmount,
  cgst: result.cgst,
  sgst: result.sgst,
  roundOff: result.roundOff,
  total: result.total,
  taxBreakdown: result.taxBreakdown,
  lines: result.lines,
})

function present(bill: BillRow, payments: PaymentRow[]) {
  return {
    id: bill.id,
    orderId: bill.order_id,
    billNo: bill.bill_no,
    /** The formatted string as printed. */
    billNumber: bill.bill_number,
    billPeriod: bill.bill_period,
    businessDate: bill.business_date,
    subtotal: bill.subtotal,
    discountType: bill.discount_type,
    discountValue: bill.discount_value,
    discountAmount: bill.discount_amount,
    cgst: bill.cgst,
    sgst: bill.sgst,
    roundOff: bill.round_off,
    total: bill.total,
    amountPaid: bill.amount_paid,
    outstanding: bill.total - bill.amount_paid,
    paymentStatus: bill.payment_status,
    taxMode: bill.tax_mode,
    taxBreakdown: JSON.parse(bill.tax_breakdown) as unknown,
    settledAt: bill.settled_at,
    customerName: bill.customer_name,
    customerPhone: bill.customer_phone,
    voidReason: bill.void_reason,
    voidedAt: bill.voided_at,
    reprintCount: bill.reprint_count,
    createdAt: bill.created_at,
    payments: payments.map((p) => ({
      id: p.id,
      mode: p.mode,
      amount: p.amount,
      reference: p.reference,
      paidAt: p.paid_at,
      businessDate: p.business_date,
      reversedAt: p.reversed_at,
      reverseReason: p.reverse_reason,
    })),
  }
}

function loadPayments(db: Db, billIds: string[]): Map<string, PaymentRow[]> {
  const grouped = new Map<string, PaymentRow[]>()
  if (billIds.length === 0) return grouped

  const placeholders = billIds.map(() => '?').join(', ')
  const rows = db
    .prepare(`SELECT * FROM payments WHERE bill_id IN (${placeholders}) ORDER BY paid_at`)
    .all(...billIds) as PaymentRow[]

  for (const row of rows) {
    const list = grouped.get(row.bill_id)
    if (list) list.push(row)
    else grouped.set(row.bill_id, [row])
  }
  return grouped
}

async function respond(app: FastifyInstance, branchId: string, billId: string) {
  const bill = findBill(app, branchId, billId)
  return { bill: present(bill, loadPayments(app.db, [billId]).get(billId) ?? []) }
}

function findBill(app: FastifyInstance, branchId: string, id: string): BillRow {
  const row = app.db
    .prepare('SELECT * FROM bills WHERE id = ? AND branch_id = ?')
    .get(id, branchId) as BillRow | undefined
  if (!row) throw new AppError(404, 'BILL_NOT_FOUND', 'Bill not found')
  return row
}

interface OrderRow {
  id: string
  status: string
  table_id: string | null
  customer_name: string | null
  customer_phone: string | null
}

function findBillableOrder(app: FastifyInstance, branchId: string, id: string): OrderRow {
  const order = app.db
    .prepare('SELECT * FROM orders WHERE id = ? AND branch_id = ?')
    .get(id, branchId) as OrderRow | undefined

  if (!order) throw new AppError(404, 'ORDER_NOT_FOUND', 'Order not found')
  if (order.status === 'cancelled') {
    throw new AppError(409, 'ORDER_CANCELLED', 'This order was cancelled')
  }
  if (order.status === 'billed') {
    throw new AppError(409, 'ALREADY_BILLED', 'This order has already been billed')
  }

  const items = app.db
    .prepare('SELECT COUNT(*) AS n FROM order_items WHERE order_id = ? AND deleted_at IS NULL')
    .get(id) as { n: number }
  if (items.n === 0) {
    throw new AppError(400, 'EMPTY_ORDER', 'An order with no items cannot be billed')
  }

  return order
}
