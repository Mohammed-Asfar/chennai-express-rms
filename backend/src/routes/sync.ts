import type { FastifyInstance } from 'fastify'
import { requireAuth, requireRole } from '../lib/guards.js'
import { retryQuarantined } from '../sync/push.js'

/**
 * Sync visibility. Silent failure is the worst outcome: the owner would believe
 * their cloud reports are complete when they are not.
 */
export async function syncRoutes(app: FastifyInstance): Promise<void> {
  app.get('/sync/status', { preHandler: requireAuth }, async () => app.sync.status())

  app.post('/sync/now', { preHandler: requireRole('admin') }, async () => {
    const result = await app.sync.syncNow()
    return { ok: true, result, status: app.sync.status() }
  })

  /** Clears quarantine so the next cycle retries those rows. */
  app.post('/sync/retry', { preHandler: requireRole('admin') }, async () => {
    const reset = retryQuarantined(app.db)
    const result = await app.sync.syncNow()
    return { ok: true, reset, result, status: app.sync.status() }
  })
}
