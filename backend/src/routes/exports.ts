import type { FastifyInstance, FastifyReply } from 'fastify'
import { z } from 'zod'
import { currentUser, requireRole } from '../lib/guards.js'
import { currentBusinessDate } from '../lib/business-date.js'
import { toCsv, rupees } from '../lib/csv.js'
import { recordExport } from '../db/purge.js'

/**
 * CSV exports of trading data.
 *
 * The record that leaves this system. A branch keeps six years of bills for GST,
 * and these files are how that record is handed to an accountant, kept off the
 * till, or checked before anything is cleared from the cloud.
 *
 * Everything is filtered by **business date**, not `created_at`: a restaurant
 * open past midnight keeps 1 AM sales on the previous trading day, and an export
 * that split a night's service across two files would not reconcile against the
 * reports screen.
 *
 * Voided bills are included and marked. They are not sales, but they are part of
 * the audit trail — an export that silently dropped them would leave a gap in
 * the bill numbers that nobody could explain.
 */

const rangeQuery = z.object({
  from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
})

interface Range {
  from: string
  to: string
}

export async function exportRoutes(app: FastifyInstance): Promise<void> {
  /** One row per bill: what an accountant asks for. */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/exports/bills.csv',
    { preHandler: requireRole('admin') },
    async (request, reply) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)

      const rows = app.db
        .prepare(
          `SELECT b.bill_number, b.bill_no, b.business_date, b.subtotal,
                  b.discount_amount, b.cgst, b.sgst, b.round_off, b.total,
                  b.amount_paid, b.payment_status, b.tax_mode,
                  b.customer_name, b.customer_phone,
                  b.voided_at, b.void_reason, b.settled_at, b.created_at,
                  o.order_no, o.type AS order_type, t.name AS table_name,
                  u.full_name AS billed_by
             FROM bills b
             JOIN orders o ON o.id = b.order_id
        LEFT JOIN tables t ON t.id = o.table_id
             JOIN users u ON u.id = b.created_by
            WHERE b.branch_id = ? AND b.deleted_at IS NULL
              AND b.business_date BETWEEN ? AND ?
         ORDER BY b.business_date, b.bill_no`,
        )
        .all(me.branchId, range.from, range.to) as BillRow[]

      const csv = toCsv(
        [
          'Bill number', 'Bill no', 'Business date', 'Order no', 'Order type',
          'Table', 'Subtotal', 'Discount', 'CGST', 'SGST', 'Round off', 'Total',
          'Paid', 'Payment status', 'Tax mode', 'Customer', 'Phone',
          'Voided', 'Void reason', 'Billed by', 'Settled at',
        ],
        rows.map((r) => [
          r.bill_number,
          r.bill_no,
          r.business_date,
          r.order_no,
          r.order_type,
          r.table_name,
          rupees(r.subtotal),
          rupees(r.discount_amount),
          rupees(r.cgst),
          rupees(r.sgst),
          rupees(r.round_off),
          rupees(r.total),
          rupees(r.amount_paid),
          r.payment_status,
          r.tax_mode,
          r.customer_name,
          r.customer_phone,
          r.voided_at ? 'yes' : 'no',
          r.void_reason,
          r.billed_by,
          r.settled_at,
        ]),
      )

      recordExport(app.db, me.branchId, 'bills', range, rows.length, me.sub)
      return send(reply, csv, `bills-${range.from}-to-${range.to}.csv`)
    },
  )

  /** One row per dish sold, so item-level analysis does not need the till. */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/exports/bill-items.csv',
    { preHandler: requireRole('admin') },
    async (request, reply) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)

      const rows = app.db
        .prepare(
          `SELECT b.bill_number, b.business_date, b.voided_at,
                  oi.item_name, oi.variant_name, oi.qty,
                  oi.unit_price, oi.tax_rate, oi.line_base, oi.line_tax,
                  oi.line_total, oi.notes
             FROM bills b
             JOIN orders o ON o.id = b.order_id
             JOIN order_items oi ON oi.order_id = o.id AND oi.deleted_at IS NULL
            WHERE b.branch_id = ? AND b.deleted_at IS NULL
              AND b.business_date BETWEEN ? AND ?
         ORDER BY b.business_date, b.bill_no, oi.created_at`,
        )
        .all(me.branchId, range.from, range.to) as ItemRow[]

      const csv = toCsv(
        [
          'Bill number', 'Business date', 'Item', 'Variant', 'Qty',
          'Unit price', 'Tax rate %', 'Line base', 'Line tax', 'Line total',
          'Notes', 'Voided',
        ],
        rows.map((r) => [
          r.bill_number,
          r.business_date,
          r.item_name,
          r.variant_name,
          r.qty,
          rupees(r.unit_price),
          // Basis points to a percentage: 500 is 5%, and a column headed "%"
          // holding 500 would be read as 500%.
          (r.tax_rate / 100).toFixed(2),
          rupees(r.line_base),
          rupees(r.line_tax),
          rupees(r.line_total),
          r.notes,
          r.voided_at ? 'yes' : 'no',
        ]),
      )

      recordExport(app.db, me.branchId, 'bill_items', range, rows.length, me.sub)
      return send(reply, csv, `bill-items-${range.from}-to-${range.to}.csv`)
    },
  )

  /**
   * One row per payment.
   *
   * Filtered on the payment's own business date, not the bill's. A Monday bill
   * settled on Wednesday belongs to Monday's sales and Wednesday's cash — they
   * are different questions and this file answers the second.
   */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/exports/payments.csv',
    { preHandler: requireRole('admin') },
    async (request, reply) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)

      const rows = app.db
        .prepare(
          `SELECT p.business_date, p.mode, p.amount, p.reference,
                  p.reversed_at, p.reverse_reason, p.created_at,
                  b.bill_number, b.business_date AS bill_date,
                  u.full_name AS taken_by
             FROM payments p
             JOIN bills b ON b.id = p.bill_id
             JOIN users u ON u.id = p.created_by
            WHERE p.branch_id = ?
              AND p.business_date BETWEEN ? AND ?
         ORDER BY p.business_date, p.created_at`,
        )
        .all(me.branchId, range.from, range.to) as PaymentRow[]

      const csv = toCsv(
        [
          'Payment date', 'Bill number', 'Bill date', 'Mode', 'Amount',
          'Reference', 'Taken by', 'Reversed', 'Reversal reason',
        ],
        rows.map((r) => [
          r.business_date,
          r.bill_number,
          r.bill_date,
          r.mode,
          rupees(r.amount),
          r.reference,
          r.taken_by,
          r.reversed_at ? 'yes' : 'no',
          r.reverse_reason,
        ]),
      )

      recordExport(app.db, me.branchId, 'payments', range, rows.length, me.sub)
      return send(reply, csv, `payments-${range.from}-to-${range.to}.csv`)
    },
  )
}

interface BillRow {
  bill_number: string
  bill_no: number
  business_date: string
  subtotal: number
  discount_amount: number
  cgst: number
  sgst: number
  round_off: number
  total: number
  amount_paid: number
  payment_status: string
  tax_mode: string
  customer_name: string | null
  customer_phone: string | null
  voided_at: string | null
  void_reason: string | null
  settled_at: string | null
  created_at: string
  order_no: number
  order_type: string
  table_name: string | null
  billed_by: string
}

interface ItemRow {
  bill_number: string
  business_date: string
  voided_at: string | null
  item_name: string
  variant_name: string
  qty: number
  unit_price: number
  tax_rate: number
  line_base: number
  line_tax: number
  line_total: number
  notes: string | null
}

interface PaymentRow {
  business_date: string
  mode: string
  amount: number
  reference: string | null
  reversed_at: string | null
  reverse_reason: string | null
  created_at: string
  bill_number: string
  bill_date: string
  taken_by: string
}

function resolveRange(
  app: FastifyInstance,
  branchId: string,
  query: { from?: string; to?: string },
): Range {
  const { from, to } = rangeQuery.parse(query)
  const today = currentBusinessDate(app.db, branchId)
  return { from: from ?? to ?? today, to: to ?? from ?? today }
}

/** Sends the file as a download rather than something the browser renders. */
function send(reply: FastifyReply, csv: string, filename: string): unknown {
  return reply
    .header('content-type', 'text/csv; charset=utf-8')
    .header('content-disposition', `attachment; filename="${filename}"`)
    .send(csv)
}
