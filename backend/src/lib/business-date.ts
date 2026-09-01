import type { Db } from '../db/client.js'
import { getSetting } from './settings.js'

/**
 * The trading day an event belongs to.
 *
 * A restaurant open past midnight must keep 1 AM sales on the previous trading
 * day — otherwise one night's service is split across two report days and the
 * cash drawer never matches the sales figure.
 *
 * Uses local time deliberately: the cutoff is "5 AM here", not 5 AM UTC.
 */
export function businessDateFor(at: Date, dayStart: string): string {
  const [hourText, minuteText] = dayStart.split(':')
  const cutoffHour = Number(hourText ?? '0')
  const cutoffMinute = Number(minuteText ?? '0')

  const minutesNow = at.getHours() * 60 + at.getMinutes()
  const minutesCutoff = cutoffHour * 60 + cutoffMinute

  const day = new Date(at)
  if (minutesNow < minutesCutoff) day.setDate(day.getDate() - 1)

  return toDateString(day)
}

/** The current business date for a branch, per its configured cutoff. */
export function currentBusinessDate(db: Db, branchId: string, now = new Date()): string {
  return businessDateFor(now, getSetting(db, branchId, 'business_day_start'))
}

function toDateString(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

/**
 * Allocates the next number in a per-branch, per-day sequence.
 *
 * Must run inside the same transaction as the insert it numbers. `better-sqlite3`
 * is synchronous and SQLite serialises writers, so this cannot interleave; the
 * UNIQUE constraint on (branch_id, business_date, no) is the backstop.
 */
export function nextDailyNumber(
  db: Db,
  table: 'orders' | 'bills',
  column: 'order_no' | 'bill_no',
  branchId: string,
  businessDate: string,
): number {
  const row = db
    .prepare(
      `SELECT COALESCE(MAX(${column}), 0) + 1 AS next FROM ${table}
       WHERE branch_id = ? AND business_date = ?`,
    )
    .get(branchId, businessDate) as { next: number }
  return row.next
}
