import { randomUUID } from 'node:crypto'
import type { Sql } from 'postgres'
import type { Db } from './client.js'

/**
 * Removes trading data older than a cutoff, from the till and the cloud.
 *
 * **This is the one place that hard-deletes bills.** Everywhere else in the
 * system orders and bills are soft-deleted and kept, because Indian GST wants
 * six years of them. Purging is the deliberate exception: it exists so a branch
 * can reclaim space once it holds the records somewhere else, and every call is
 * written to `purge_log` — including whether an export covering the range
 * existed at the time.
 *
 * What it never touches: branches, users, settings, categories, menu items and
 * their variants, sections, tables. Those are configuration, not trading data,
 * and a till that lost them would stop working rather than merely forget.
 */

export interface PurgeRange {
  from: string
  to: string
}

export interface PurgePreview {
  bills: number
  orders: number
  payments: number
  orderItems: number
  /** True when every kind has an export covering the whole range. */
  exported: boolean
  /** Which exports are missing, for a warning that names them. */
  missingExports: string[]
}

export interface PurgeResult {
  bills: number
  orders: number
  payments: number
  orderItems: number
  cloudRemoved: number | null
}

const KINDS = ['bills', 'bill_items', 'payments'] as const

/**
 * What a purge would remove, and whether it has been exported.
 *
 * Read-only. The screen calls this to build its warning, so the numbers the
 * operator confirms are the numbers that will actually go.
 */
export function previewPurge(db: Db, branchId: string, range: PurgeRange): PurgePreview {
  const count = (sql: string): number =>
    (db.prepare(sql).get(branchId, range.from, range.to) as { n: number }).n

  const bills = count(
    `SELECT count(*) n FROM bills
      WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
  )
  const orders = count(
    `SELECT count(*) n FROM orders
      WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
  )
  const payments = count(
    `SELECT count(*) n FROM payments
      WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
  )
  const orderItems = (
    db
      .prepare(
        `SELECT count(*) n FROM order_items oi
           JOIN orders o ON o.id = oi.order_id
          WHERE o.branch_id = ? AND o.business_date BETWEEN ? AND ?`,
      )
      .get(branchId, range.from, range.to) as { n: number }
  ).n

  // An export counts only if one run covered the whole range. Two exports that
  // happen to abut are not the same as one that spans it, and reasoning about
  // overlapping ranges here would be a way to talk ourselves into a gap.
  const missingExports = KINDS.filter((kind) => {
    const row = db
      .prepare(
        `SELECT count(*) n FROM export_log
          WHERE branch_id = ? AND kind = ? AND from_date <= ? AND to_date >= ?`,
      )
      .get(branchId, kind, range.from, range.to) as { n: number }
    return row.n === 0
  })

  return {
    bills,
    orders,
    payments,
    orderItems,
    exported: missingExports.length === 0,
    missingExports: [...missingExports],
  }
}

/**
 * Deletes the range locally, in one transaction.
 *
 * Children before parents: payments reference bills, bills and order_items
 * reference orders. Reversing that order fails on a foreign key partway through
 * and leaves a half-purged range, which is worse than either outcome.
 */
export function purgeLocal(
  db: Db,
  branchId: string,
  range: PurgeRange,
  userId: string,
  now = new Date(),
): PurgeResult {
  const preview = previewPurge(db, branchId, range)
  const at = now.toISOString()

  const run = db.transaction(() => {
    db.prepare(
      `DELETE FROM payments
        WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
    ).run(branchId, range.from, range.to)

    db.prepare(
      `DELETE FROM order_items
        WHERE order_id IN (
          SELECT id FROM orders
           WHERE branch_id = ? AND business_date BETWEEN ? AND ?
        )`,
    ).run(branchId, range.from, range.to)

    db.prepare(
      `DELETE FROM bills
        WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
    ).run(branchId, range.from, range.to)

    db.prepare(
      `DELETE FROM orders
        WHERE branch_id = ? AND business_date BETWEEN ? AND ?`,
    ).run(branchId, range.from, range.to)

    // The record of the gap. Written in the same transaction as the deletion,
    // so a purge cannot happen without one.
    db.prepare(
      `INSERT INTO purge_log
         (id, branch_id, from_date, to_date, bills_removed, orders_removed,
          payments_removed, was_exported, purged_by, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      randomUUID(),
      branchId,
      range.from,
      range.to,
      preview.bills,
      preview.orders,
      preview.payments,
      preview.exported ? 1 : 0,
      userId,
      at,
    )
  })

  run()

  return {
    bills: preview.bills,
    orders: preview.orders,
    payments: preview.payments,
    orderItems: preview.orderItems,
    cloudRemoved: null,
  }
}

/**
 * Deletes the same range from the cloud.
 *
 * Separate from the local purge and allowed to fail on its own: the till is the
 * record that matters, and a cloud that is unreachable must not stop a branch
 * reclaiming its own disk. A failure here leaves the cloud holding rows the till
 * no longer has, which is harmless — sync only pushes upward, so they are never
 * copied back.
 */
export async function purgeCloud(
  sql: Sql,
  branchId: string,
  range: PurgeRange,
): Promise<number> {
  let removed = 0

  await sql.begin(async (tx) => {
    const payments = await tx`
      DELETE FROM payments
       WHERE branch_id = ${branchId} AND business_date BETWEEN ${range.from} AND ${range.to}`
    const items = await tx`
      DELETE FROM order_items
       WHERE order_id IN (
         SELECT id FROM orders
          WHERE branch_id = ${branchId} AND business_date BETWEEN ${range.from} AND ${range.to}
       )`
    const bills = await tx`
      DELETE FROM bills
       WHERE branch_id = ${branchId} AND business_date BETWEEN ${range.from} AND ${range.to}`
    const orders = await tx`
      DELETE FROM orders
       WHERE branch_id = ${branchId} AND business_date BETWEEN ${range.from} AND ${range.to}`

    removed =
      (payments.count ?? 0) + (items.count ?? 0) + (bills.count ?? 0) + (orders.count ?? 0)
  })

  return removed
}

/** Records that an export ran, so a later purge can say whether one exists. */
export function recordExport(
  db: Db,
  branchId: string,
  kind: (typeof KINDS)[number],
  range: PurgeRange,
  rowCount: number,
  userId: string,
  now = new Date(),
): void {
  db.prepare(
    `INSERT INTO export_log
       (id, branch_id, kind, from_date, to_date, row_count, exported_by, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(randomUUID(), branchId, kind, range.from, range.to, rowCount, userId, now.toISOString())
}
