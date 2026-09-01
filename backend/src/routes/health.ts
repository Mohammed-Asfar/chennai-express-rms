import type { FastifyInstance } from 'fastify'

const startedAt = Date.now()

/**
 * The Flutter client holds no data, so a backend that is down means a dead UI.
 * This endpoint is what lets the client show an actionable error instead of a
 * blank screen, and what the Windows service watchdog polls.
 */
export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get('/health', async (_request, reply) => {
    try {
      const row = app.db.prepare('SELECT 1 AS ok').get() as { ok: number } | undefined
      if (row?.ok !== 1) throw new Error('database probe returned no row')

      const migrations = app.db.prepare('SELECT COUNT(*) AS n FROM _migrations').get() as { n: number }

      return {
        status: 'ok',
        uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
        database: { connected: true, migrationsApplied: migrations.n },
      }
    } catch (error: unknown) {
      reply.status(503)
      return {
        status: 'degraded',
        uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
        database: { connected: false, error: error instanceof Error ? error.message : String(error) },
      }
    }
  })
}
