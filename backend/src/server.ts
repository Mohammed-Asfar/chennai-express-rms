import Fastify, {
  type FastifyError,
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
  type FastifyServerOptions,
} from 'fastify'
import cors from '@fastify/cors'
import { ZodError } from 'zod'
import type { Db } from './db/client.js'
import type { Env } from './lib/env.js'
import { AppError } from './lib/errors.js'
import { healthRoutes } from './routes/health.js'
import { authRoutes } from './routes/auth.js'
import { updateRoutes } from './routes/updates.js'
import { categoryRoutes } from './routes/categories.js'
import { menuRoutes } from './routes/menu.js'
import { tableRoutes } from './routes/tables.js'
import { orderRoutes } from './routes/orders.js'
import { billRoutes } from './routes/bills.js'
import { syncRoutes } from './routes/sync.js'
import { SyncWorker } from './sync/worker.js'

export interface BuildOptions {
  db: Db
  env: Env
  /** Injectable so tests can supply a stub. */
  sync?: SyncWorker
}

type LoggerConfig = NonNullable<FastifyServerOptions['logger']>

function loggerConfig(env: Env): LoggerConfig {
  if (env.NODE_ENV === 'test') return false
  if (env.NODE_ENV === 'development') {
    return {
      level: env.LOG_LEVEL,
      transport: {
        target: 'pino-pretty',
        options: { translateTime: 'HH:MM:ss', ignore: 'pid,hostname' },
      },
    }
  }
  return { level: env.LOG_LEVEL }
}

export async function buildServer({ db, env, sync }: BuildOptions): Promise<FastifyInstance> {
  const app = Fastify({
    logger: loggerConfig(env),
    // Bills and orders are small; a low cap limits the blast radius of a bad request.
    bodyLimit: 2 * 1024 * 1024,
  })

  app.decorate('db', db)
  app.decorate('env', env)
  app.decorate('sync', sync ?? new SyncWorker(db, env, app.log))

  await app.register(cors, { origin: true })

  // Nudge sync after any successful mutation.
  //
  // A hook rather than a call in each route: a new endpoint would otherwise have
  // to remember, and forgetting means its writes sit unsynced until the next
  // heartbeat. The worker debounces, so a burst of edits is still one push.
  app.addHook('onResponse', async (request, reply) => {
    if (request.method === 'GET' || request.method === 'HEAD') return
    if (reply.statusCode >= 400) return
    // Sync's own endpoints must not retrigger it.
    if (request.url.startsWith('/sync/')) return
    app.sync.signal()
  })

  app.setErrorHandler((error: FastifyError, request: FastifyRequest, reply: FastifyReply) => {
    if (error instanceof AppError) {
      return reply.status(error.statusCode).send({
        error: { code: error.code, message: error.message, details: error.details },
      })
    }

    if (error instanceof ZodError) {
      return reply.status(400).send({
        error: {
          code: 'VALIDATION_FAILED',
          message: 'Request validation failed',
          details: error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
        },
      })
    }

    if (error.validation) {
      return reply.status(400).send({
        error: { code: 'VALIDATION_FAILED', message: error.message },
      })
    }

    // Never leak an internal message to the client, but always log it — a swallowed
    // exception in a billing path is how a wrong total ships unnoticed.
    request.log.error({ err: error }, 'unhandled error')
    return reply.status(500).send({
      error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' },
    })
  })

  app.setNotFoundHandler((request, reply) => {
    reply.status(404).send({
      error: { code: 'NOT_FOUND', message: `Route ${request.method} ${request.url} not found` },
    })
  })

  await app.register(healthRoutes)
  await app.register(authRoutes)
  await app.register(updateRoutes)
  await app.register(categoryRoutes)
  await app.register(menuRoutes)
  await app.register(tableRoutes)
  await app.register(orderRoutes)
  await app.register(billRoutes)
  await app.register(syncRoutes)

  return app
}

declare module 'fastify' {
  interface FastifyInstance {
    db: Db
    env: Env
    sync: SyncWorker
  }
}
