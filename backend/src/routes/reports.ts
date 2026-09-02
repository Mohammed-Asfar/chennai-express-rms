import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { currentUser, requireRole } from '../lib/guards.js'
import { currentBusinessDate } from '../lib/business-date.js'

/**
 * Management reporting.
 *
 * Three endpoints rather than one per metric: `/reports/summary` carries the
 * headline figures and every breakdown a management screen shows side by side,
 * `/reports/items` is separated because it is unbounded in length (one row per
 * dish sold), and `/reports/outstanding` is separated because it is not a
 * period report at all — an unpaid bill from three weeks ago is still owed
 * today, so it ignores the range entirely.
 *
 * Two dates govern everything here and they are not interchangeable:
 *   - sales, discounts, orders, sections → `bills.business_date`
 *   - cash and every other collection    → `payments.business_date`
 * A Monday bill settled on Wednesday is Monday's sale and Wednesday's cash.
 *
 * Every aggregate is computed in SQL. A year of bills must never be pulled into
 * memory to be summed.
 */

/** `from`/`to` are inclusive business dates, not calendar timestamps. */
const rangeQuery = z.object({
  from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
})

/** Reportable sales. FR-R9: a voided bill is not a sale, nor is a deleted one. */
const LIVE_BILL = 'b.branch_id = ? AND b.deleted_at IS NULL AND b.voided_at IS NULL'

interface Range {
  from: string
  to: string
}

export async function reportRoutes(app: FastifyInstance): Promise<void> {
  /**
   * FR-R1, R2, R4, R5, R7, R8, R10, R11, R12 — the whole headline picture for a
   * business-date range.
   */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/reports/summary',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)
      const scope = [me.branchId, range.from, range.to]

      // FR-R1/R2: sales are what was billed, regardless of whether it has been
      // paid yet — an unpaid bill is still a sale that happened.
      const sales = app.db
        .prepare(
          `SELECT COUNT(*) AS bill_count,
                  COALESCE(SUM(b.total), 0) AS total_sales,
                  COALESCE(SUM(b.subtotal), 0) AS subtotal,
                  COALESCE(SUM(b.discount_amount), 0) AS discount_total,
                  COALESCE(SUM(b.cgst), 0) AS cgst,
                  COALESCE(SUM(b.sgst), 0) AS sgst,
                  COALESCE(SUM(b.round_off), 0) AS round_off,
                  COALESCE(SUM(b.amount_paid), 0) AS collected
           FROM bills b
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?`,
        )
        .get(...scope) as {
        bill_count: number
        total_sales: number
        subtotal: number
        discount_total: number
        cgst: number
        sgst: number
        round_off: number
        collected: number
      }

      // Integer paise, truncated. Averaging money can only ever be approximate,
      // so it is never used to reconcile — the exact figure is `totalSales`.
      const averageBillValue =
        sales.bill_count === 0 ? 0 : Math.trunc(sales.total_sales / sales.bill_count)

      // FR-R4/R5: collections come from `payments`, keyed on the payment's own
      // business date. A split bill contributes a row to each mode it used, so
      // it counts in both without being double-counted in either.
      // Reversed payments are excluded: money that was un-taken was never taken.
      const collections = app.db
        .prepare(
          `SELECT p.mode AS mode, COUNT(*) AS count, COALESCE(SUM(p.amount), 0) AS amount
           FROM payments p
           WHERE p.branch_id = ? AND p.deleted_at IS NULL AND p.reversed_at IS NULL
             AND p.business_date BETWEEN ? AND ?
           GROUP BY p.mode
           ORDER BY p.mode`,
        )
        .all(...scope) as { mode: string; count: number; amount: number }[]

      // FR-R7
      const byOrderType = app.db
        .prepare(
          `SELECT o.type AS type, COUNT(*) AS bill_count,
                  COALESCE(SUM(b.total), 0) AS total_sales
           FROM bills b JOIN orders o ON o.id = b.order_id
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?
           GROUP BY o.type
           ORDER BY o.type`,
        )
        .all(...scope) as { type: string; bill_count: number; total_sales: number }[]

      // FR-R8: takeaway has no table and therefore no section. Those bills are
      // reported under a null section rather than dropped, or the section rows
      // would not sum back to total sales.
      const bySection = app.db
        .prepare(
          `SELECT s.id AS section_id, s.name AS section_name,
                  COUNT(*) AS bill_count, COALESCE(SUM(b.total), 0) AS total_sales
           FROM bills b
                JOIN orders o ON o.id = b.order_id
                LEFT JOIN tables t ON t.id = o.table_id
                LEFT JOIN sections s ON s.id = t.section_id
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?
           GROUP BY s.id, s.name
           ORDER BY s.name IS NULL, s.name`,
        )
        .all(...scope) as {
        section_id: string | null
        section_name: string | null
        bill_count: number
        total_sales: number
      }[]

      // FR-R10: attributed to whoever applied it. A discount is a giveaway of
      // margin, and knowing which cashier gives them away is the point.
      const discounts = app.db
        .prepare(
          `SELECT u.id AS user_id, u.username AS username, u.full_name AS full_name,
                  COUNT(*) AS bill_count,
                  COALESCE(SUM(b.discount_amount), 0) AS discount_total
           FROM bills b JOIN users u ON u.id = b.created_by
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?
             AND b.discount_amount > 0
           GROUP BY u.id, u.username, u.full_name
           ORDER BY discount_total DESC`,
        )
        .all(...scope) as {
        user_id: string
        username: string
        full_name: string
        bill_count: number
        discount_total: number
      }[]

      // FR-R11: excluded from sales, but never silently dropped — a run of
      // cancellations is how theft or a broken workflow shows up.
      const voidedBills = app.db
        .prepare(
          `SELECT b.id AS id, b.bill_number AS bill_number, b.business_date AS business_date,
                  b.total AS total, b.void_reason AS void_reason, b.voided_at AS voided_at,
                  u.full_name AS voided_by_name
           FROM bills b LEFT JOIN users u ON u.id = b.voided_by
           WHERE b.branch_id = ? AND b.voided_at IS NOT NULL
             AND b.business_date BETWEEN ? AND ?
           ORDER BY b.business_date DESC, b.bill_no DESC`,
        )
        .all(...scope) as {
        id: string
        bill_number: string
        business_date: string
        total: number
        void_reason: string | null
        voided_at: string
        voided_by_name: string | null
      }[]

      const cancelledOrders = app.db
        .prepare(
          `SELECT o.id AS id, o.order_no AS order_no, o.business_date AS business_date,
                  o.type AS type, o.cancel_reason AS cancel_reason, o.updated_at AS cancelled_at,
                  COALESCE(SUM(i.line_total), 0) AS value
           FROM orders o
                LEFT JOIN order_items i ON i.order_id = o.id AND i.deleted_at IS NULL
           WHERE o.branch_id = ? AND o.status = 'cancelled'
             AND o.business_date BETWEEN ? AND ?
           GROUP BY o.id, o.order_no, o.business_date, o.type, o.cancel_reason, o.updated_at
           ORDER BY o.business_date DESC, o.order_no DESC`,
        )
        .all(...scope) as {
        id: string
        order_no: number
        business_date: string
        type: string
        cancel_reason: string | null
        cancelled_at: string
        value: number
      }[]

      const collected = collections.reduce((sum, row) => sum + row.amount, 0)

      return {
        // FR-R12: which trading days this covers, stated on every response.
        range,
        sales: {
          billCount: sales.bill_count,
          totalSales: sales.total_sales,
          averageBillValue,
          subtotal: sales.subtotal,
          discountTotal: sales.discount_total,
          cgst: sales.cgst,
          sgst: sales.sgst,
          roundOff: sales.round_off,
          /** Paid against bills *dated* in this range — not the same as `collections.total`. */
          collected: sales.collected,
          outstanding: sales.total_sales - sales.collected,
        },
        collections: {
          /** Taken in this range, whatever day the bill itself was dated. */
          total: collected,
          byMode: collections.map((row) => ({
            mode: row.mode,
            count: row.count,
            amount: row.amount,
          })),
        },
        byOrderType: byOrderType.map((row) => ({
          type: row.type,
          billCount: row.bill_count,
          totalSales: row.total_sales,
        })),
        bySection: bySection.map((row) => ({
          sectionId: row.section_id,
          /** Null for takeaway, which is served from no section. */
          sectionName: row.section_name,
          billCount: row.bill_count,
          totalSales: row.total_sales,
        })),
        discounts: {
          total: sales.discount_total,
          byUser: discounts.map((row) => ({
            userId: row.user_id,
            username: row.username,
            fullName: row.full_name,
            billCount: row.bill_count,
            discountTotal: row.discount_total,
          })),
        },
        voided: {
          billCount: voidedBills.length,
          total: voidedBills.reduce((sum, row) => sum + row.total, 0),
          bills: voidedBills.map((row) => ({
            id: row.id,
            billNumber: row.bill_number,
            businessDate: row.business_date,
            total: row.total,
            reason: row.void_reason,
            voidedAt: row.voided_at,
            voidedByName: row.voided_by_name,
          })),
        },
        cancelled: {
          orderCount: cancelledOrders.length,
          total: cancelledOrders.reduce((sum, row) => sum + row.value, 0),
          orders: cancelledOrders.map((row) => ({
            id: row.id,
            orderNo: row.order_no,
            businessDate: row.business_date,
            type: row.type,
            /** What the lines were worth when it was killed. */
            value: row.value,
            reason: row.cancel_reason,
            cancelledAt: row.cancelled_at,
          })),
        },
      }
    },
  )

  /**
   * FR-R3 — quantity and revenue per dish.
   *
   * Grouped on the snapshotted `item_name`/`variant_name` from `order_items`,
   * never on a join to `menu_items`. Renaming a dish today must not rewrite what
   * last month's report says was sold.
   */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/reports/items',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)

      const rows = app.db
        .prepare(
          `SELECT i.item_name AS item_name, i.variant_name AS variant_name,
                  SUM(i.qty) AS qty,
                  SUM(i.line_base) AS revenue,
                  SUM(i.line_tax) AS tax,
                  SUM(i.line_total) AS gross
           FROM order_items i
                JOIN bills b ON b.order_id = i.order_id
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?
             AND i.deleted_at IS NULL
           GROUP BY i.item_name, i.variant_name
           ORDER BY revenue DESC, i.item_name`,
        )
        .all(me.branchId, range.from, range.to) as {
        item_name: string
        variant_name: string
        qty: number
        revenue: number
        tax: number
        gross: number
      }[]

      return {
        range,
        items: rows.map((row) => ({
          itemName: row.item_name,
          variantName: row.variant_name,
          qty: row.qty,
          /** Pre-tax, before any bill-level discount. */
          revenue: row.revenue,
          tax: row.tax,
          gross: row.gross,
        })),
        totals: {
          qty: rows.reduce((sum, row) => sum + row.qty, 0),
          revenue: rows.reduce((sum, row) => sum + row.revenue, 0),
          gross: rows.reduce((sum, row) => sum + row.gross, 0),
        },
      }
    },
  )

  /**
   * A per-day series for the trend chart.
   *
   * Every day in the range gets a row, including the ones that took nothing.
   * A closed Monday omitted from the series would be drawn as a straight line
   * from Sunday to Tuesday, which reads as steady trade rather than a shut door.
   *
   * Sales and collections are keyed on their own business dates, exactly as in
   * `/reports/summary`, so `totalSales` here sums back to the summary's total
   * for the same range.
   */
  app.get<{ Querystring: { from?: string; to?: string } }>(
    '/reports/daily',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const range = resolveRange(app, me.branchId, request.query)

      const sales = app.db
        .prepare(
          `SELECT b.business_date AS business_date,
                  COUNT(*) AS bill_count,
                  COALESCE(SUM(b.total), 0) AS total_sales,
                  COALESCE(SUM(b.amount_paid), 0) AS collected
           FROM bills b
           WHERE ${LIVE_BILL} AND b.business_date BETWEEN ? AND ?
           GROUP BY b.business_date`,
        )
        .all(me.branchId, range.from, range.to) as {
        business_date: string
        bill_count: number
        total_sales: number
        collected: number
      }[]

      const byDate = new Map(sales.map((row) => [row.business_date, row]))

      return {
        range,
        days: eachDay(range).map((businessDate) => {
          const row = byDate.get(businessDate)
          return {
            businessDate,
            billCount: row?.bill_count ?? 0,
            totalSales: row?.total_sales ?? 0,
            collected: row?.collected ?? 0,
          }
        }),
      }
    },
  )

  /**
   * FR-R6 — what is still owed, with age.
   *
   * Deliberately not range-filtered: an unpaid bill from three weeks ago is
   * still owed today, and a report that hid it would be worse than useless.
   * Age is measured in whole days from the bill's business date.
   */
  app.get('/reports/outstanding', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const today = currentBusinessDate(app.db, me.branchId)

    const rows = app.db
      .prepare(
        `SELECT b.id AS id, b.bill_number AS bill_number, b.business_date AS business_date,
                b.total AS total, b.amount_paid AS amount_paid,
                b.payment_status AS payment_status,
                b.customer_name AS customer_name, b.customer_phone AS customer_phone,
                o.order_no AS order_no, o.type AS type
         FROM bills b LEFT JOIN orders o ON o.id = b.order_id
         WHERE ${LIVE_BILL} AND b.payment_status != 'paid'
         ORDER BY b.business_date, b.bill_no`,
      )
      .all(me.branchId) as {
      id: string
      bill_number: string
      business_date: string
      total: number
      amount_paid: number
      payment_status: string
      customer_name: string | null
      customer_phone: string | null
      order_no: number | null
      type: string | null
    }[]

    const bills = rows.map((row) => ({
      id: row.id,
      billNumber: row.bill_number,
      businessDate: row.business_date,
      orderNo: row.order_no,
      orderType: row.type,
      total: row.total,
      amountPaid: row.amount_paid,
      outstanding: row.total - row.amount_paid,
      paymentStatus: row.payment_status,
      customerName: row.customer_name,
      customerPhone: row.customer_phone,
      ageDays: daysBetween(row.business_date, today),
    }))

    return {
      asOf: today,
      billCount: bills.length,
      total: bills.reduce((sum, bill) => sum + bill.outstanding, 0),
      bills,
    }
  })
}

/**
 * The business days a report covers.
 *
 * With neither bound given it is today's trading day — the common case is "how
 * did we do today". An open-ended range is still a range: `from` alone means
 * "everything since Monday", `to` alone means "everything up to Sunday", and
 * the missing end is anchored to today.
 */
function resolveRange(
  app: FastifyInstance,
  branchId: string,
  query: { from?: string; to?: string },
): Range {
  const { from, to } = rangeQuery.parse(query)
  const today = currentBusinessDate(app.db, branchId)
  return { from: from ?? to ?? today, to: to ?? from ?? today }
}

/**
 * Every business date from `from` to `to` inclusive.
 *
 * Walked in UTC so a daylight-saving shift cannot drop or repeat a day. A range
 * whose end precedes its start yields nothing rather than looping forever.
 */
function eachDay(range: Range): string[] {
  const start = Date.parse(`${range.from}T00:00:00Z`)
  const end = Date.parse(`${range.to}T00:00:00Z`)
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return []

  const days: string[] = []
  for (let at = start; at <= end; at += 86_400_000) {
    days.push(new Date(at).toISOString().slice(0, 10))
  }
  return days
}

/** Whole days between two `YYYY-MM-DD` business dates. Never negative. */
function daysBetween(from: string, to: string): number {
  const start = Date.parse(`${from}T00:00:00Z`)
  const end = Date.parse(`${to}T00:00:00Z`)
  if (Number.isNaN(start) || Number.isNaN(end)) return 0
  return Math.max(0, Math.round((end - start) / 86_400_000))
}
