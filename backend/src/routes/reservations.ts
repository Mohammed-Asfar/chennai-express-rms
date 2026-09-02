import { randomUUID } from 'node:crypto'
import type { FastifyInstance, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { optionalText, requiredText } from '../lib/validation.js'
import type { Db } from '../db/client.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { businessDateFor, currentBusinessDate, nextOrderNumber } from '../lib/business-date.js'
import { getSetting } from '../lib/settings.js'
import { refreshTableStatus } from './tables.js'

/**
 * Bookings.
 *
 * A booking holds tables ahead of a party arriving, and turns into an order when
 * they do. The one rule that shapes everything here is FR-V7: a reservation
 * informs, it never obstructs. Staff facing a customer at the door will work
 * around a system that refuses to seat them, and a system worked around stops
 * being trusted for the things it should refuse.
 */

/** How late a booking runs before the floor should chase it (FR-V11). */
export const OVERDUE_AFTER_MINUTES = 20

/** Either side of a booking that a second one on the same table counts as a clash. */
const OVERLAP_WINDOW_MINUTES = 90

const tableIdsField = z
  .array(z.string().uuid())
  .min(1, 'A booking needs at least one table')
  .max(20)
  // Two of the same table is one table, and the join table's composite key would
  // reject the duplicate insert anyway.
  .transform((ids) => [...new Set(ids)])

const createBody = z.object({
  customerName: requiredText(80),
  customerPhone: optionalText(20).optional(),
  partySize: z.number().int().min(1).max(200),
  reservedAt: z.string().datetime({ offset: true }),
  tableIds: tableIdsField,
  notes: optionalText(200).optional(),
})

const updateBody = z.object({
  customerName: requiredText(80).optional(),
  customerPhone: optionalText(20).optional(),
  partySize: z.number().int().min(1).max(200).optional(),
  reservedAt: z.string().datetime({ offset: true }).optional(),
  tableIds: tableIdsField.optional(),
  notes: optionalText(200).optional(),
})

const seatBody = z.object({
  /** Which table the party actually sat at, when the booking holds several. */
  tableId: z.string().uuid().optional(),
})

const closeBody = z.object({ reason: optionalText(200).optional() })

type ReservationStatus = 'booked' | 'seated' | 'no_show' | 'cancelled'

interface ReservationRow {
  id: string
  branch_id: string
  customer_name: string
  customer_phone: string | null
  party_size: number
  reserved_at: string
  business_date: string
  status: ReservationStatus
  order_id: string | null
  notes: string | null
  created_by: string
  created_at: string
  updated_at: string
}

interface BookedTable {
  id: string
  name: string
  seats: number
}

const toPublic = (row: ReservationRow, tables: BookedTable[], now: Date) => ({
  id: row.id,
  customerName: row.customer_name,
  customerPhone: row.customer_phone,
  partySize: row.party_size,
  reservedAt: row.reserved_at,
  businessDate: row.business_date,
  status: row.status,
  orderId: row.order_id,
  notes: row.notes,
  tables,
  seatCount: tables.reduce((sum, t) => sum + t.seats, 0),
  // FR-V11: computed here rather than by the client, so a screen left open
  // overnight cannot decide a booking is on time because its clock says so.
  isOverdue: isOverdue(row, now),
})

function isOverdue(row: ReservationRow, now: Date): boolean {
  if (row.status !== 'booked') return false
  const due = Date.parse(row.reserved_at)
  if (Number.isNaN(due)) return false
  return now.getTime() - due > OVERDUE_AFTER_MINUTES * 60_000
}

export async function reservationRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Bookings for a trading day, defaulting to today (FR-V4).
   *
   * Ordered by time rather than by when they were entered — the floor reads
   * this list to see who is due next, not who phoned first.
   */
  app.get<{ Querystring: { date?: string; status?: ReservationStatus } }>(
    '/reservations',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const date = request.query.date ?? currentBusinessDate(app.db, me.branchId)

      const conditions = ['branch_id = ?', 'business_date = ?', 'deleted_at IS NULL']
      const params: unknown[] = [me.branchId, date]

      if (request.query.status) {
        conditions.push('status = ?')
        params.push(request.query.status)
      }

      const rows = app.db
        .prepare(
          `SELECT * FROM reservations WHERE ${conditions.join(' AND ')} ORDER BY reserved_at, created_at`,
        )
        .all(...params) as ReservationRow[]

      const tables = loadBookedTables(app.db, rows.map((r) => r.id))
      const now = new Date()

      return {
        date,
        reservations: rows.map((row) => toPublic(row, tables.get(row.id) ?? [], now)),
        summary: {
          booked: rows.filter((r) => r.status === 'booked').length,
          seated: rows.filter((r) => r.status === 'seated').length,
          noShow: rows.filter((r) => r.status === 'no_show').length,
          cancelled: rows.filter((r) => r.status === 'cancelled').length,
          overdue: rows.filter((r) => isOverdue(r, now)).length,
          covers: rows
            .filter((r) => r.status === 'booked' || r.status === 'seated')
            .reduce((sum, r) => sum + r.party_size, 0),
        },
      }
    },
  )

  app.get<{ Params: { id: string } }>(
    '/reservations/:id',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const row = find(app, me.branchId, request.params.id)
      return {
        reservation: toPublic(row, loadBookedTables(app.db, [row.id]).get(row.id) ?? [], new Date()),
      }
    },
  )

  /** FR-V1, FR-V2: one booking, one or more tables. */
  app.post('/reservations', { preHandler: requireAuth }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)

    assertTablesExist(app, me.branchId, body.tableIds)

    const reservedAt = new Date(body.reservedAt)
    const businessDate = businessDateFor(
      reservedAt,
      getSetting(app.db, me.branchId, 'business_day_start'),
    )

    const id = randomUUID()
    const now = new Date().toISOString()

    app.db.transaction(() => {
      app.db
        .prepare(
          `INSERT INTO reservations (id, branch_id, customer_name, customer_phone, party_size,
                                     reserved_at, business_date, status, notes, created_by,
                                     created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'booked', ?, ?, ?, ?)`,
        )
        .run(
          id,
          me.branchId,
          body.customerName,
          body.customerPhone || null,
          body.partySize,
          reservedAt.toISOString(),
          businessDate,
          body.notes || null,
          me.sub,
          now,
          now,
        )

      linkTables(app.db, id, body.tableIds)
    })()

    // FR-V3: after the link rows exist, so the tables read as reserved.
    for (const tableId of body.tableIds) refreshTableStatus(app.db, tableId)

    reply.status(201)
    const created = find(app, me.branchId, id)
    return {
      reservation: toPublic(created, loadBookedTables(app.db, [id]).get(id) ?? [], new Date()),
      // FR-V10: a clash informs rather than refuses, exactly as FR-V7 does for
      // walk-ins. The booking is already saved by the time this is read.
      warnings: clashWarnings(app.db, me.branchId, id, body.tableIds, reservedAt),
    }
  })

  /** FR-V8: editable, including its table list, while it is still `booked`. */
  app.patch<{ Params: { id: string } }>(
    '/reservations/:id',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = updateBody.parse(request.body)
      const existing = find(app, me.branchId, request.params.id)

      if (existing.status !== 'booked') {
        throw new AppError(
          409,
          'RESERVATION_CLOSED',
          `This booking is already ${label(existing.status)} and can no longer be changed.`,
        )
      }

      if (body.tableIds) assertTablesExist(app, me.branchId, body.tableIds)

      const reservedAt = body.reservedAt ? new Date(body.reservedAt) : undefined
      const businessDate = reservedAt
        ? businessDateFor(reservedAt, getSetting(app.db, me.branchId, 'business_day_start'))
        : undefined

      // Tables dropped from the booking must be re-derived too, or one that is
      // no longer held stays showing as reserved.
      const previous = (loadBookedTables(app.db, [existing.id]).get(existing.id) ?? []).map(
        (t) => t.id,
      )

      app.db.transaction(() => {
        applyUpdate(app.db, existing.id, [
          ['customer_name', body.customerName],
          ['customer_phone', body.customerPhone === undefined ? undefined : body.customerPhone || null],
          ['party_size', body.partySize],
          ['reserved_at', reservedAt?.toISOString()],
          ['business_date', businessDate],
          ['notes', body.notes === undefined ? undefined : body.notes || null],
        ])

        if (body.tableIds) {
          app.db.prepare('DELETE FROM reservation_tables WHERE reservation_id = ?').run(existing.id)
          linkTables(app.db, existing.id, body.tableIds)
        }
      })()

      const affected = new Set([...previous, ...(body.tableIds ?? [])])
      for (const tableId of affected) refreshTableStatus(app.db, tableId)

      const updated = find(app, me.branchId, existing.id)
      const tableIds = (loadBookedTables(app.db, [updated.id]).get(updated.id) ?? []).map((t) => t.id)

      return {
        reservation: toPublic(
          updated,
          loadBookedTables(app.db, [updated.id]).get(updated.id) ?? [],
          new Date(),
        ),
        warnings: clashWarnings(
          app.db,
          me.branchId,
          updated.id,
          tableIds,
          new Date(updated.reserved_at),
        ),
      }
    },
  )

  /**
   * FR-V5: the party arrived. The booking becomes an order.
   *
   * The order is created here rather than by the client calling `/orders`
   * separately, so a crash between the two cannot leave a seated booking with
   * no order or an order no booking points at.
   */
  app.post<{ Params: { id: string } }>(
    '/reservations/:id/seat',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const body = seatBody.parse(request.body)
      const existing = find(app, me.branchId, request.params.id)

      if (existing.status === 'seated') {
        throw new AppError(409, 'ALREADY_SEATED', 'This booking has already been seated.')
      }
      if (existing.status !== 'booked') {
        throw new AppError(
          409,
          'RESERVATION_CLOSED',
          `This booking was marked ${label(existing.status)} and cannot be seated.`,
        )
      }

      const held = loadBookedTables(app.db, [existing.id]).get(existing.id) ?? []
      if (held.length === 0) {
        throw new AppError(
          409,
          'NO_TABLES',
          'This booking holds no tables — its tables were removed. Add one before seating.',
        )
      }

      // A booking across three tables still becomes one order, on one of them:
      // v1 has no table merge, and the party is one bill.
      const seatAt = body.tableId ?? held[0]!.id
      if (!held.some((t) => t.id === seatAt)) {
        throw new AppError(400, 'TABLE_NOT_BOOKED', 'That table is not part of this booking.')
      }

      const businessDate = currentBusinessDate(app.db, me.branchId)
      const orderId = randomUUID()
      const now = new Date().toISOString()

      app.db.transaction(() => {
        const orderNo = nextOrderNumber(app.db, me.branchId, businessDate)
        app.db
          .prepare(
            `INSERT INTO orders (id, branch_id, order_no, business_date, type, table_id, seat_label,
                                 status, customer_name, customer_phone, version, created_by,
                                 created_at, updated_at)
             VALUES (?, ?, ?, ?, 'dine_in', ?, NULL, 'open', ?, ?, 1, ?, ?, ?)`,
          )
          .run(
            orderId,
            me.branchId,
            orderNo,
            businessDate,
            seatAt,
            existing.customer_name,
            existing.customer_phone,
            me.sub,
            now,
            now,
          )

        app.db
          .prepare(
            `UPDATE reservations SET status = 'seated', order_id = ?, updated_at = ?, synced_at = NULL
             WHERE id = ?`,
          )
          .run(orderId, now, existing.id)
      })()

      // Every held table: the seated one becomes occupied, and the others drop
      // back to free now that the booking no longer holds them as `booked`.
      for (const table of held) refreshTableStatus(app.db, table.id)

      const updated = find(app, me.branchId, existing.id)
      return {
        reservation: toPublic(updated, held, new Date()),
        orderId,
      }
    },
  )

  /** FR-V6: no-show or cancelled. Either way the tables are released. */
  app.post<{ Params: { id: string } }>(
    '/reservations/:id/no-show',
    { preHandler: requireAuth },
    async (request) => close(app, request, 'no_show'),
  )

  app.post<{ Params: { id: string } }>(
    '/reservations/:id/cancel',
    { preHandler: requireAuth },
    async (request) => close(app, request, 'cancelled'),
  )

  /**
   * FR-V9: bookings are kept for reporting, never hard-deleted.
   *
   * Admin only, and only for a booking that never happened — a seated one is
   * part of the day's trading history and stays.
   */
  app.delete<{ Params: { id: string } }>(
    '/reservations/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const existing = find(app, me.branchId, request.params.id)

      if (existing.status === 'seated') {
        throw new AppError(
          409,
          'RESERVATION_SEATED',
          'This booking was seated and is part of the day\'s record. Cancel the order instead.',
        )
      }

      const held = (loadBookedTables(app.db, [existing.id]).get(existing.id) ?? []).map((t) => t.id)
      const now = new Date().toISOString()

      app.db.transaction(() => {
        app.db
          .prepare(
            'UPDATE reservations SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?',
          )
          .run(now, now, existing.id)
        app.db.prepare('DELETE FROM reservation_tables WHERE reservation_id = ?').run(existing.id)
      })()

      for (const tableId of held) refreshTableStatus(app.db, tableId)
      return { ok: true }
    },
  )
}

/** Marks a booking closed and frees whatever it was holding. */
async function close(
  app: FastifyInstance,
  request: FastifyRequest<{ Params: { id: string } }>,
  status: 'no_show' | 'cancelled',
) {
  const me = currentUser(request)
  const body = closeBody.parse(request.body ?? {})
  const existing = find(app, me.branchId, request.params.id)

  if (existing.status === 'seated') {
    throw new AppError(
      409,
      'ALREADY_SEATED',
      'This party has been seated. Cancel their order instead.',
    )
  }
  if (existing.status !== 'booked') {
    throw new AppError(
      409,
      'RESERVATION_CLOSED',
      `This booking is already marked ${label(existing.status)}.`,
    )
  }

  const held = loadBookedTables(app.db, [existing.id]).get(existing.id) ?? []
  const now = new Date().toISOString()

  // The reason goes onto the notes rather than a column of its own: the schema
  // has no cancel_reason here, and a note the floor can read is what is
  // actually useful when the same number books again next week.
  const note = body.reason
    ? [existing.notes, `${status === 'no_show' ? 'No-show' : 'Cancelled'}: ${body.reason}`]
        .filter(Boolean)
        .join(' — ')
        .slice(0, 200)
    : existing.notes

  app.db
    .prepare(
      'UPDATE reservations SET status = ?, notes = ?, updated_at = ?, synced_at = NULL WHERE id = ?',
    )
    .run(status, note, now, existing.id)

  // The link rows stay: FR-V9 keeps the booking whole for reporting, and
  // refreshTableStatus only counts tables held by a `booked` reservation.
  for (const table of held) refreshTableStatus(app.db, table.id)

  const updated = find(app, me.branchId, existing.id)
  return { reservation: toPublic(updated, held, new Date()) }
}

/**
 * Bookings that clash with this one (FR-V10).
 *
 * A warning, never a refusal. Two parties on one table an hour apart is normal
 * — the second sits down as the first leaves — so this reports the overlap and
 * lets the person holding the phone decide.
 */
function clashWarnings(
  db: Db,
  branchId: string,
  reservationId: string,
  tableIds: string[],
  reservedAt: Date,
): string[] {
  if (tableIds.length === 0) return []

  const windowMs = OVERLAP_WINDOW_MINUTES * 60_000
  const placeholders = tableIds.map(() => '?').join(', ')

  const rows = db
    .prepare(
      `SELECT r.customer_name, r.reserved_at, t.name AS table_name
       FROM reservations r
       JOIN reservation_tables rt ON rt.reservation_id = r.id
       JOIN tables t ON t.id = rt.table_id
       WHERE r.branch_id = ? AND r.id != ? AND r.status = 'booked' AND r.deleted_at IS NULL
         AND rt.table_id IN (${placeholders})
       ORDER BY r.reserved_at`,
    )
    .all(branchId, reservationId, ...tableIds) as {
      customer_name: string
      reserved_at: string
      table_name: string
    }[]

  const warnings: string[] = []
  for (const row of rows) {
    const other = Date.parse(row.reserved_at)
    if (Number.isNaN(other)) continue
    if (Math.abs(other - reservedAt.getTime()) > windowMs) continue

    const at = new Date(other).toLocaleTimeString('en-IN', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: true,
    })
    warnings.push(`${row.table_name} is also booked for ${row.customer_name} at ${at}.`)
  }
  return warnings
}

function loadBookedTables(db: Db, reservationIds: string[]): Map<string, BookedTable[]> {
  const grouped = new Map<string, BookedTable[]>()
  if (reservationIds.length === 0) return grouped

  const placeholders = reservationIds.map(() => '?').join(', ')
  const rows = db
    .prepare(
      `SELECT rt.reservation_id, t.id, t.name, t.seats
       FROM reservation_tables rt
       JOIN tables t ON t.id = rt.table_id
       WHERE rt.reservation_id IN (${placeholders}) AND t.deleted_at IS NULL
       ORDER BY t.sort_order, t.name`,
    )
    .all(...reservationIds) as {
      reservation_id: string
      id: string
      name: string
      seats: number
    }[]

  for (const row of rows) {
    const table: BookedTable = { id: row.id, name: row.name, seats: row.seats }
    const list = grouped.get(row.reservation_id)
    if (list) list.push(table)
    else grouped.set(row.reservation_id, [table])
  }
  return grouped
}

function linkTables(db: Db, reservationId: string, tableIds: string[]): void {
  const insert = db.prepare(
    'INSERT INTO reservation_tables (reservation_id, table_id) VALUES (?, ?)',
  )
  for (const tableId of tableIds) insert.run(reservationId, tableId)
}

function applyUpdate(db: Db, id: string, columns: [string, unknown][]): void {
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
  db.prepare(`UPDATE reservations SET ${sets.join(', ')} WHERE id = ?`).run(...values)
}

function find(app: FastifyInstance, branchId: string, id: string): ReservationRow {
  const row = app.db
    .prepare('SELECT * FROM reservations WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as ReservationRow | undefined
  if (!row) throw new AppError(404, 'RESERVATION_NOT_FOUND', 'Booking not found')
  return row
}

function assertTablesExist(app: FastifyInstance, branchId: string, tableIds: string[]): void {
  const placeholders = tableIds.map(() => '?').join(', ')
  const rows = app.db
    .prepare(
      `SELECT id FROM tables WHERE branch_id = ? AND deleted_at IS NULL AND id IN (${placeholders})`,
    )
    .all(branchId, ...tableIds) as { id: string }[]

  if (rows.length !== tableIds.length) {
    throw new AppError(404, 'TABLE_NOT_FOUND', 'One of those tables no longer exists')
  }
}

const label = (status: ReservationStatus): string =>
  status === 'no_show' ? 'a no-show' : status
