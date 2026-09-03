import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { openDatabase, type Db } from '../src/db/client.js'
import { migrate } from '../src/db/migrate.js'
import { seedIfEmpty } from '../src/db/seed.js'
import { buildServer } from '../src/server.js'
import { loadEnv } from '../src/lib/env.js'
import { prunePrintJobs, KEEP_FINISHED_DAYS } from '../src/print/queue.js'
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

test('settleJob keeps polling instead of reading the status once', async () => {
  // A USB printer goes through the Windows spooler and takes seconds. Reading
  // the status once after a fixed 400ms wait reported it as failed, so a bill
  // that printed fine showed "The bill did not print" and sent someone looking
  // for a fault that was not there.
  //
  // Counts polls rather than watching the clock: the suite runs tests
  // concurrently, so wall-clock timing here is whatever the event loop allows.
  const { settleJob } = await import('../src/print/queue.js')
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  let reads = 0
  const realPrepare = ctx.db.prepare.bind(ctx.db)
  const spy = new Proxy(ctx.db, {
    get(target, property, receiver) {
      if (property !== 'prepare') return Reflect.get(target, property, receiver)
      return (sql: string) => {
        // Settles on the second look. One read alone would have returned
        // pending, which is exactly what the old fixed-wait code did.
        if (sql.includes('SELECT status, last_error') && ++reads === 2) {
          realPrepare("UPDATE print_jobs SET status = 'printed' WHERE id = ?").run(id)
        }
        return realPrepare(sql)
      }
    },
  })

  const job = await settleJob(spy, id, 4_000)
  assertEqual(job?.status, 'printed', `after ${reads} polls, status was ${job?.status}`)
  assertEqual(reads >= 2, true, `polled ${reads} times, so it did not read once and stop`)

  await ctx.app.close()
})

test('settleJob gives up rather than hanging on a job that never settles', async () => {
  // Still pending is a real answer: "queued, not yet printed". The request must
  // not hold open waiting for a printer that will never respond.
  const { settleJob } = await import('../src/print/queue.js')
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'pending' })

  const job = await settleJob(ctx.db, id, 300)
  assertEqual(job?.status, 'pending', 'returned rather than hanging')

  await ctx.app.close()
})

test('settleJob returns a settled job without waiting out its timeout', async () => {
  // A 4s timeout must not mean every print takes 4s.
  const { settleJob } = await import('../src/print/queue.js')
  const ctx = await setup()
  const id = queueJob(ctx, { status: 'failed', lastError: 'offline' })

  const job = await settleJob(ctx.db, id, 60_000)

  assertEqual(job?.status, 'failed')
  assertEqual(job?.last_error, 'offline')

  await ctx.app.close()
})

test('the sweep leaves a cancelled job alone', async () => {
  // The worker calls drainPending on a timer. It must never revive something
  // someone deliberately stopped.
  const { drainPending } = await import('../src/print/queue.js')
  const ctx = await setup()
  const cancelled = queueJob(ctx, { status: 'cancelled' })
  const printed = queueJob(ctx, { status: 'printed' })

  await drainPending(ctx.db, ctx.branchId)

  assertEqual(statusOf(ctx, cancelled), 'cancelled')
  assertEqual(statusOf(ctx, printed), 'printed')

  await ctx.app.close()
})

// --- retention ---

/**
 * Inserts a job directly, with a chosen age and status.
 *
 * The API will not create a job dated last month, and the point of these cases
 * is what happens to one that is.
 */
function insertJob(
  db: Db,
  branchId: string,
  status: string,
  daysOld: number,
): string {
  const id = randomUUID()
  const at = new Date(Date.now() - daysOld * 24 * 60 * 60 * 1000).toISOString()
  db.prepare(
    `INSERT INTO print_jobs
       (id, branch_id, printer_id, type, ref_id, payload, status, attempts,
        printed_at, created_at, updated_at)
     VALUES (?, ?, NULL, 'bill', NULL, 'x', ?, 0, ?, ?, ?)`,
  ).run(id, branchId, status, status === 'printed' ? at : null, at, at)
  return id
}

test('printed jobs past the window are dropped', async () => {
  const { db, branchId, app } = await setup()
  const old = insertJob(db, branchId, 'printed', KEEP_FINISHED_DAYS + 1)
  const recent = insertJob(db, branchId, 'printed', 1)

  const removed = prunePrintJobs(db)

  assertEqual(removed, 1, 'one job removed')
  assertEqual(
    db.prepare('SELECT count(*) n FROM print_jobs WHERE id = ?').get(old).n,
    0,
    'the old job is gone',
  )
  assertEqual(
    db.prepare('SELECT count(*) n FROM print_jobs WHERE id = ?').get(recent).n,
    1,
    'the recent one is kept',
  )
  await app.close()
})

test('a pending job is never pruned, however old', async () => {
  // The ticket has not gone out. A printer offline over a long weekend, or a
  // branch that reopens after a fortnight, must still print what it owes —
  // deleting it here would lose an order the kitchen never saw.
  const { db, branchId, app } = await setup()
  const stuck = insertJob(db, branchId, 'pending', KEEP_FINISHED_DAYS * 10)

  prunePrintJobs(db)

  assertEqual(
    db.prepare('SELECT count(*) n FROM print_jobs WHERE id = ?').get(stuck).n,
    1,
    'still queued',
  )
  await app.close()
})

test('a failed job is never pruned, however old', async () => {
  // Failed is what the queue panel offers a Retry for. Pruning it would remove
  // the row and the button along with it, with nothing saying why.
  const { db, branchId, app } = await setup()
  const failed = insertJob(db, branchId, 'failed', KEEP_FINISHED_DAYS * 10)

  prunePrintJobs(db)

  assertEqual(
    db.prepare('SELECT count(*) n FROM print_jobs WHERE id = ?').get(failed).n,
    1,
    'still retryable',
  )
  await app.close()
})

test('pruning does not touch the bill the job printed', async () => {
  // print_jobs holds a byte stream, not a financial record. The sale lives in
  // bills, and GST retention applies to that — this must never be a route to
  // deleting one.
  const { db, branchId, app } = await setup()
  const before = db.prepare('SELECT count(*) n FROM bills').get().n
  insertJob(db, branchId, 'printed', KEEP_FINISHED_DAYS + 1)

  prunePrintJobs(db)

  assertEqual(db.prepare('SELECT count(*) n FROM bills').get().n, before, 'bills untouched')
  await app.close()
})
