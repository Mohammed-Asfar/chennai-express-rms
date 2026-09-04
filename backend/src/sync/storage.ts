import type { Sql } from 'postgres'
import type { Db } from '../db/client.js'

/**
 * How much room the cloud copy is using, and how long it will last.
 *
 * The question behind this is commercial, not technical: a restaurant on a free
 * plan wants to know whether they are about to be asked for money. Answering it
 * with a raw byte count is no answer at all, so this projects the growth from
 * what the branch has actually billed.
 */
export interface CloudStorage {
  /** Logical size of the cloud database. What Neon bills a root branch on. */
  usedBytes: number

  /** The plan's ceiling. Neon's free plan is 0.5 GB per project. */
  limitBytes: number

  /** Bytes one bill costs, measured from this branch rather than assumed. */
  bytesPerBill: number

  /** Bills a day, averaged over the trading days on record. */
  billsPerDay: number

  /** Trading days the average is drawn from. Below ~7 it is not worth trusting. */
  daysMeasured: number

  /**
   * Years of headroom at the current rate, or null when there is not enough
   * history to say. Never a false precision — a week of trading cannot predict
   * a decade.
   */
  yearsRemaining: number | null

  /** The biggest tables, so an oversized logo is visible rather than a mystery. */
  largest: { table: string; bytes: number }[]
}

/**
 * Neon's free plan: 0.5 GB per project.
 *
 * Neon counts a GB as 1000³, not 1024³, so the limit is 500 MB — reporting it
 * as 512 MiB overstated the allowance by 2% and would have shown "within
 * limits" slightly past the point of being over it.
 */
export const FREE_TIER_BYTES = 500 * 1000 * 1000

/**
 * Measures the cloud database and projects its growth.
 *
 * Runs against the cloud, so it is a request the user asks for rather than
 * something polled — the status endpoint stays local and cheap.
 */
export async function readCloudStorage(
  db: Db,
  sql: Sql,
  limitBytes = FREE_TIER_BYTES,
): Promise<CloudStorage> {
  // Every database in the project, not just this one.
  //
  // The limit is per project, so measuring current_database() alone reported
  // less than Neon bills for — a project also carrying the default `postgres`
  // database read 9 MB here against 17 MB on the dashboard. A quota screen that
  // understates usage warns too late, which is the one thing it must not do.
  const size = (await sql`
    SELECT COALESCE(SUM(pg_database_size(datname)), 0) AS bytes
      FROM pg_database
     WHERE datistemplate = false
  `) as unknown as {
    bytes: string | number
  }[]
  const usedBytes = Number(size[0]?.bytes ?? 0)

  const largestRows = (await sql`
    SELECT c.relname AS table_name, pg_total_relation_size(c.oid) AS bytes
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    ORDER BY pg_total_relation_size(c.oid) DESC
    LIMIT 5`) as unknown as { table_name: string; bytes: string | number }[]

  const rate = billingRate(db)
  const bytesPerBill = await measureBytesPerBill(sql)

  // Only projected once there is enough trading to average over. A restaurant
  // three days old would otherwise be told its free tier lasts four months
  // because it happened to be busy on opening night.
  const perYear = bytesPerBill * rate.billsPerDay * 365
  const yearsRemaining =
    rate.daysMeasured >= 7 && perYear > 0
      ? Math.max(0, (limitBytes - usedBytes) / perYear)
      : null

  return {
    usedBytes,
    limitBytes,
    bytesPerBill,
    billsPerDay: rate.billsPerDay,
    daysMeasured: rate.daysMeasured,
    yearsRemaining,
    largest: largestRows.map((r) => ({ table: r.table_name, bytes: Number(r.bytes) })),
  }
}

/**
 * Bills per trading day, from the branch's own history.
 *
 * Counts distinct business dates rather than the calendar span: a restaurant
 * closed on Mondays should not have its average dragged down by days it never
 * opened.
 */
function billingRate(db: Db): { billsPerDay: number; daysMeasured: number } {
  const row = db
    .prepare(
      `SELECT COUNT(*) AS bills, COUNT(DISTINCT business_date) AS days
       FROM bills WHERE deleted_at IS NULL`,
    )
    .get() as { bills: number; days: number }

  if (row.days === 0) return { billsPerDay: 0, daysMeasured: 0 }
  return { billsPerDay: row.bills / row.days, daysMeasured: row.days }
}

/**
 * What one bill costs in the cloud, measured rather than guessed.
 *
 * Average row widths, not table sizes: a table holding thirty rows is mostly
 * empty pages, and dividing its size by its row count overstates the cost by
 * an order of magnitude.
 */
async function measureBytesPerBill(sql: Sql): Promise<number> {
  const width = async (table: string): Promise<number> => {
    const rows = (await sql.unsafe(
      `SELECT COALESCE(AVG(pg_column_size(x.*)), 0) AS w FROM ${table} x`,
    )) as unknown as { w: string | number }[]
    return Number(rows[0]?.w ?? 0)
  }

  const ratio = async (child: string, parent: string): Promise<number> => {
    const rows = (await sql.unsafe(
      `SELECT (SELECT COUNT(*) FROM ${child})::float
              / NULLIF((SELECT COUNT(*) FROM ${parent}), 0) AS n`,
    )) as unknown as { n: string | number | null }[]
    return Number(rows[0]?.n ?? 0)
  }

  const [bill, order, item, payment] = await Promise.all([
    width('bills'),
    width('orders'),
    width('order_items'),
    width('payments'),
  ])
  const [itemsPerOrder, paymentsPerBill] = await Promise.all([
    ratio('order_items', 'orders'),
    ratio('payments', 'bills'),
  ])

  // Nothing billed yet: a considered default rather than zero, which would
  // divide into an infinite runway.
  if (bill === 0) return 3000

  const rows = 2 + itemsPerOrder + paymentsPerBill
  const raw = bill + order + item * itemsPerOrder + payment * paymentsPerBill + TUPLE_HEADER * rows

  // Indexes and page slack. Measured at roughly 2.5x on a populated database;
  // erring high is the safe direction for a "how long have I got" figure.
  return Math.round(raw * 2.5)
}

/** Postgres per-row overhead, before any column data. */
const TUPLE_HEADER = 24
