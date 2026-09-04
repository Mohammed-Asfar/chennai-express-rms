import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { currentUser, requireRole } from '../lib/guards.js'
import { currentBusinessDate } from '../lib/business-date.js'
import { previewPurge, purgeLocal, purgeCloud } from '../db/purge.js'

/**
 * Clearing old trading data.
 *
 * Two endpoints on purpose: the screen asks what would go, shows it, and only
 * then sends a second request to do it. A single destructive call that reports
 * afterwards gives the operator nothing to confirm against.
 *
 * Admin only, and never reachable by accident — there is no DELETE on a
 * collection here that a stray request could hit.
 */

const rangeBody = z.object({
  from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
})

export async function purgeRoutes(app: FastifyInstance): Promise<void> {
  /** What would go, and whether it has been exported. Changes nothing. */
  app.post('/purge/preview', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const parsed = rangeBody.safeParse(request.body)
    if (!parsed.success) {
      return reply.status(400).send({
        error: { code: 'RANGE_REQUIRED', message: 'Choose the dates to clear.' },
      })
    }

    const range = parsed.data
    if (range.from > range.to) {
      return reply.status(400).send({
        error: { code: 'RANGE_BACKWARDS', message: 'The first date must come before the last.' },
      })
    }

    return { preview: previewPurge(app.db, me.branchId, range) }
  })

  /**
   * Does it.
   *
   * The local delete and the cloud delete are separate: the till is the record
   * that matters, and an unreachable cloud must not stop a branch reclaiming
   * its own disk. A cloud failure is reported, not thrown — the caller is told
   * what happened rather than left assuming nothing did.
   */
  app.post('/purge', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const parsed = rangeBody.safeParse(request.body)
    if (!parsed.success) {
      return reply.status(400).send({
        error: { code: 'RANGE_REQUIRED', message: 'Choose the dates to clear.' },
      })
    }

    const range = parsed.data
    if (range.from > range.to) {
      return reply.status(400).send({
        error: { code: 'RANGE_BACKWARDS', message: 'The first date must come before the last.' },
      })
    }

    // Today's trading is never clearable. A range ending today would delete
    // bills taken minutes ago, and no reading of "clear old data" includes the
    // service currently running.
    const today = currentBusinessDate(app.db, me.branchId)
    if (range.to >= today) {
      return reply.status(400).send({
        error: {
          code: 'RANGE_TOO_RECENT',
          message: "Today's sales cannot be cleared. Choose an end date before today.",
        },
      })
    }

    const preview = previewPurge(app.db, me.branchId, range)
    const result = purgeLocal(app.db, me.branchId, range, me.sub)

    request.log.warn(
      { range, ...result, exported: preview.exported, by: me.username },
      'trading data purged',
    )

    let cloudRemoved: number | null = null
    let cloudError: string | null = null

    if (app.env.CLOUD_DATABASE_URL) {
      try {
        const { default: postgres } = await import('postgres')
        const sql = postgres(app.env.CLOUD_DATABASE_URL, {
          max: 1,
          idle_timeout: 5,
          connect_timeout: 8,
        })
        try {
          cloudRemoved = await purgeCloud(sql, me.branchId, range)
        } finally {
          await sql.end({ timeout: 5 })
        }
      } catch (error) {
        // Reported, not thrown. The local rows are already gone and saying
        // "purge failed" would be false.
        cloudError = error instanceof Error ? error.message : String(error)
        request.log.warn({ err: error }, 'cloud purge failed; the till was cleared')
      }
    }

    return { ...result, cloudRemoved, cloudError, wasExported: preview.exported }
  })

  /** What has been cleared before, so a gap in the bills is explainable. */
  app.get('/purge/history', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const rows = app.db
      .prepare(
        `SELECT p.from_date, p.to_date, p.bills_removed, p.orders_removed,
                p.payments_removed, p.was_exported, p.created_at,
                u.full_name AS purged_by
           FROM purge_log p
           JOIN users u ON u.id = p.purged_by
          WHERE p.branch_id = ?
       ORDER BY p.created_at DESC
          LIMIT 50`,
      )
      .all(me.branchId)

    return { history: rows }
  })
}
