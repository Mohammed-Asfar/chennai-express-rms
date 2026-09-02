import type { FastifyInstance } from 'fastify'
import { requireAuth, requireRole } from '../lib/guards.js'
import { resyncMasterData, retryQuarantined } from '../sync/push.js'

/**
 * Sync visibility. Silent failure is the worst outcome: the owner would believe
 * their cloud reports are complete when they are not.
 */
export async function syncRoutes(app: FastifyInstance): Promise<void> {
  app.get('/sync/status', { preHandler: requireAuth }, async () => app.sync.status())

  /**
   * How much cloud room is used, and how long it will last.
   *
   * Separate from `/sync/status` because it costs a round trip to the cloud,
   * and the status is polled. Null storage means "could not measure", which the
   * UI shows as unknown rather than as a problem.
   */
  app.get('/sync/storage', { preHandler: requireAuth }, async () => ({
    storage: await app.sync.storage(),
  }))

  app.post('/sync/now', { preHandler: requireRole('admin') }, async () => {
    const result = await app.sync.syncNow()
    return { ok: true, result, status: app.sync.status() }
  })

  /**
   * Clears quarantine so the next cycle retries those rows.
   *
   * Master data is re-pushed first. The usual reason a bill is rejected is not
   * the bill — it is a branch or user the cloud does not have, and retrying the
   * children alone would fail again on the same foreign key.
   */
  app.post('/sync/retry', { preHandler: requireRole('admin') }, async () => {
    const repaired = resyncMasterData(app.db)
    const reset = retryQuarantined(app.db)

    // Twice: the first pass lands the parents, the second the children that
    // were rejected because those parents were missing.
    await app.sync.syncNow()
    retryQuarantined(app.db)
    const result = await app.sync.syncNow()

    return { ok: true, repaired, reset, result, status: app.sync.status() }
  })
}
