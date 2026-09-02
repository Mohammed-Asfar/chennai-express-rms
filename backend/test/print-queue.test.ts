import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { test, assertEqual } from './helpers.js'

const env = loadEnv({ NODE_ENV: 'test', DB_PATH: ':memory:', SEED_ADMIN_PASSWORD: 'admin123' })

interface Ctx {
  app: FastifyInstance
  db: Db
  admin: Record<string, string>
  branchId: string
}

async function setup(): Promise<Ctx> {
  const db = openDatabase(':memory:')
  migrate(db)
  await seedIfEmpty(db, env)

  const app = await buildServer({ db, env })
  const res = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'admin', password: 'admin123' },
  })
  const { token } = res.json() as { token: string }

  // The seeded branch is the one the admin belongs to, and the one every
  // request will be scoped to.
  const { branch_id: branchId } = db
    .prepare("SELECT branch_id FROM users WHERE username = 'admin'")
    .get() as { branch_id: string }

  return {
    app,
    db,
    admin: { authorization: `Bearer ${token}` },
    branchId,
  }
}

/** Puts a job straight into the queue, without needing a real printer. */
function queueJob(
  ctx: Ctx,
  overrides: { status?: string; type?: string; attempts?: number; lastError?: string } = {},
): string {
  const id = randomUUID()
  const now = new Date().toISOString()
  ctx.db
    .prepare(
      `INSERT INTO print_jobs (id, branch_id, printer_id, type, ref_id, payload,
                               status, attempts, last_error, created_at, updated_at)
       VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      id,
      ctx.branchId,
      overrides.type ?? 'kot',
      randomUUID(),
      Buffer.from('ticket').toString('base64'),
      overrides.status ?? 'pending',
      overrides.attempts ?? 0,
      overrides.lastError ?? null,
      now,
      now,
    )
  return id
}

function statusOf(ctx: Ctx, id: string): string {
  const row = ctx.db.prepare('SELECT status FROM print_jobs WHERE id = ?').get(id) as
    | { status: string }
    | undefined
  return row?.status ?? 'missing'
}

test('the queue lists only what still needs attention', async () => {
  const ctx = await setup()

  const pending = queueJob(ctx, { status: 'pending' })
  const failed = queueJob(ctx, { status: 'failed' })
  queueJob(ctx, { status: 'printed' })
  queueJob(ctx, { status: 'cancelled' })

  const res = await ctx.app.inject({
    method: 'GET',
    url: '/print-jobs?active=true',
    headers: ctx.admin,
  })
  const { jobs } = res.json() as { jobs: { id: string }[] }

  const ids = jobs.map((j) => j.id).sort()
  assertEqual(
    JSON.stringify(ids),
    JSON.stringify([pending, failed].sort()),
    'settled jobs are left out',
  )

  await ctx.app.close()
})

test('a queued job can be cancelled', async () => {
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  assertEqual(res.statusCode, 200)
  assertEqual(statusOf(ctx, id), 'cancelled')

  await ctx.app.close()
})

test('a job that gave up can be cancelled too', async () => {
  // Otherwise a failed ticket the kitchen was told about by hand stays in the
  // list forever, and the panel only ever grows.
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'failed', attempts: 5, lastError: 'offline' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  assertEqual(res.statusCode, 200)
  assertEqual(statusOf(ctx, id), 'cancelled')

  await ctx.app.close()
})

test('a cancelled job leaves the queue but stays on the record', async () => {
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  const res = await ctx.app.inject({
    method: 'GET',
    url: '/print-jobs?active=true',
    headers: ctx.admin,
  })
  const { jobs } = res.json() as { jobs: { id: string }[] }
  assertEqual(jobs.some((j) => j.id === id), false, 'gone from the queue')

  const row = ctx.db.prepare('SELECT id FROM print_jobs WHERE id = ?').get(id)
  assertEqual(row !== undefined, true, 'the row is kept for the record')

  await ctx.app.close()
})

test('something already printed cannot be cancelled', async () => {
  // The paper is out of the printer. Saying it was cancelled would be a lie
  // recorded against a ticket the kitchen is already cooking.
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'printed' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  assertEqual(res.statusCode, 409)
  assertEqual(statusOf(ctx, id), 'printed')

  await ctx.app.close()
})

test('something already printed cannot be retried', async () => {
  // A second copy of a bill in a customer's hand, or a duplicate ticket in the
  // kitchen, means the dish gets cooked twice.
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'printed' })

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/retry`,
    headers: ctx.admin,
  })

  assertEqual(res.statusCode, 409)
  assertEqual(statusOf(ctx, id), 'printed')

  await ctx.app.close()
})

test('cancelling twice is not an error', async () => {
  // Two clicks on a slow connection must not produce a failure the user has to
  // interpret.
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'failed' })

  const first = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })
  const second = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  assertEqual(first.statusCode, 200)
  assertEqual(second.statusCode, 200)
  assertEqual(statusOf(ctx, id), 'cancelled')

  await ctx.app.close()
})

test('a cancelled job is not picked up by the retry sweep', async () => {
  // drainPending must not revive something someone deliberately stopped.
  const { drainPending } = await import('../src/print/queue.js')
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })
  await drainPending(ctx.db, ctx.branchId)

  assertEqual(statusOf(ctx, id), 'cancelled')

  await ctx.app.close()
})

test('another branch cannot touch this branch’s jobs', async () => {
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  // Move it to a real second branch the logged-in user is not part of.
  const otherBranch = randomUUID()
  const now = new Date().toISOString()
  ctx.db
    .prepare('INSERT INTO branches (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)')
    .run(otherBranch, 'Second branch', now, now)
  ctx.db.prepare('UPDATE print_jobs SET branch_id = ? WHERE id = ?').run(otherBranch, id)

  const res = await ctx.app.inject({
    method: 'POST',
    url: `/print-jobs/${id}/cancel`,
    headers: ctx.admin,
  })

  assertEqual(res.statusCode, 404)
  assertEqual(statusOf(ctx, id), 'pending')

  await ctx.app.close()
})

test('a job carries what the panel needs to describe it', async () => {
  const ctx = await setup()
  queueJob(ctx, { status: 'failed', type: 'kot', attempts: 5, lastError: 'Printer offline' })

  const res = await ctx.app.inject({
    method: 'GET',
    url: '/print-jobs?active=true',
    headers: ctx.admin,
  })
  const { jobs } = res.json() as {
    jobs: { type: string; attempts: number; lastError: string | null; createdAt: string }[]
  }
  const job = jobs[0]!

  assertEqual(job.type, 'kot')
  assertEqual(job.attempts, 5)
  assertEqual(job.lastError, 'Printer offline', 'camelCase, like every other payload')
  assertEqual(typeof job.createdAt, 'string')

  await ctx.app.close()
})
