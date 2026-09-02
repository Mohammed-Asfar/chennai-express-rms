import type { FastifyInstance } from 'fastify'
import { requireAuth, requireRole } from '../lib/guards.js'
import { verifyToken } from '../lib/auth.js'
import { resyncMasterData, retryQuarantined } from '../sync/push.js'

/**
 * Sync visibility. Silent failure is the worst outcome: the owner would believe
 * their cloud reports are complete when they are not.
 */
export async function syncRoutes(app: FastifyInstance): Promise<void> {
  app.get('/sync/status', { preHandler: requireAuth }, async () => app.sync.status())

  /**
   * The status, pushed as it changes.
   *
   * Polling made an outage take up to forty-five seconds to appear: the worker
   * noticed on its own schedule, then the screen asked on its own. This closes
   * the second half of that — a cycle starting, failing or succeeding reaches
   * an open screen immediately.
   *
   * The REST endpoint above stays. It is the fallback when the socket cannot
   * be established, and a screen that cannot connect must still work.
   */
  app.get('/sync/stream', { websocket: true }, async (socket, request) => {
    // The handshake carries no Authorization header, so the token comes as a
    // query parameter. It is verified before anything is sent.
    const token = (request.query as { token?: string }).token
    try {
      verifyToken(token ?? '', app.env.JWT_SECRET)
    } catch {
      socket.send(JSON.stringify({ type: 'error', message: 'Not authorised' }))
      socket.close()
      return
    }

    const send = (payload: unknown) => {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(payload))
    }

    // Immediately, so the screen has something to draw without waiting for the
    // first change.
    send({ type: 'status', status: app.sync.status() })

    const unwatch = app.sync.watch((status) => send({ type: 'status', status }))

    // A dropped TCP connection can go unnoticed for minutes on Windows. Without
    // this the screen would sit on a stale reading believing it was live —
    // exactly the silent staleness the socket is meant to remove.
    const ping = setInterval(() => {
      if (socket.readyState === socket.OPEN) socket.ping()
    }, 30_000)

    socket.on('close', () => {
      unwatch()
      clearInterval(ping)
    })
    socket.on('error', () => {
      unwatch()
      clearInterval(ping)
    })
  })

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
