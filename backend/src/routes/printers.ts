import { randomUUID } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { enqueueAndSend, resolvePrinter, runJob, type PrinterRow } from '../print/queue.js'
import { renderTest } from '../print/tickets.js'
import { discoverAll, discoverNetwork, discoverUsb, type Discovered } from '../print/discover.js'
import { verifyToken } from '../lib/auth.js'

const createBody = z.object({
  name: z.string().min(1).max(48).trim(),
  connection: z.enum(['usb', 'network']),
  address: z.string().min(1).max(128).trim(),
  role: z.enum(['bill', 'kot', 'both']),
  paperWidth: z.enum(['58mm', '80mm']),
})

const updateBody = z.object({
  name: z.string().min(1).max(48).trim().optional(),
  connection: z.enum(['usb', 'network']).optional(),
  address: z.string().min(1).max(128).trim().optional(),
  role: z.enum(['bill', 'kot', 'both']).optional(),
  paperWidth: z.enum(['58mm', '80mm']).optional(),
  isActive: z.boolean().optional(),
})

const toPublic = (row: PrinterRow) => ({
  id: row.id,
  name: row.name,
  connection: row.connection,
  address: row.address,
  role: row.role,
  paperWidth: row.paper_width,
  isActive: row.is_active === 1,
})

export async function printerRoutes(app: FastifyInstance): Promise<void> {
  /** Whether printing is set up at all — the UI hides print buttons without it. */
  app.get('/printers/status', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    return {
      bill: resolvePrinter(app.db, me.branchId, 'bill') !== undefined,
      kot: resolvePrinter(app.db, me.branchId, 'kot') !== undefined,
    }
  })

  /**
   * Looks for printers on this machine and the local network.
   *
   * Slow by nature — a subnet sweep is 254 probes — so the client shows
   * progress rather than a frozen dialog. Anything already configured is
   * marked, so the same printer is not added twice.
   */
  app.get<{ Querystring: { scanNetwork?: string } }>(
    '/printers/discover',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const skipNetwork = request.query.scanNetwork === 'false'

      const found = skipNetwork ? await discoverUsb() : await discoverAll()

      const existing = app.db
        .prepare(
          'SELECT address FROM printers WHERE branch_id = ? AND deleted_at IS NULL',
        )
        .all(me.branchId) as { address: string }[]
      const configured = new Set(existing.map((row) => row.address.toLowerCase()))

      return {
        printers: found.map((printer) => ({
          ...printer,
          alreadyAdded: configured.has(printer.address.toLowerCase()),
        })),
      }
    },
  )

  /**
   * The same scan, streamed.
   *
   * A subnet sweep is 254 probes and takes several seconds. Over HTTP that is a
   * request that looks hung; here the client sees USB results immediately, then
   * a progress count, then each network printer as it answers.
   *
   * Messages are newline-free JSON objects with a `type`:
   *   found    — one printer, sent as soon as it is discovered
   *   progress — {scanned, total}
   *   done     — the sweep finished
   *   error    — something went wrong; the socket then closes
   */
  app.get('/printers/discover/stream', { websocket: true }, async (socket, request) => {
    // The websocket handshake carries no Authorization header, so the token
    // comes as a query parameter. It is still verified before anything runs.
    const token = (request.query as { token?: string }).token
    let branchId: string
    try {
      const claims = verifyToken(token ?? '', app.env.JWT_SECRET)
      if (claims.role !== 'admin') throw new Error('admin only')
      branchId = claims.branchId
    } catch {
      socket.send(JSON.stringify({ type: 'error', message: 'Not authorised' }))
      socket.close()
      return
    }

    let cancelled = false
    socket.on('close', () => {
      // Stops a sweep nobody is watching.
      cancelled = true
    })

    const configured = new Set(
      (
        app.db
          .prepare('SELECT address FROM printers WHERE branch_id = ? AND deleted_at IS NULL')
          .all(branchId) as { address: string }[]
      ).map((row) => row.address.toLowerCase()),
    )

    const send = (payload: unknown) => {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(payload))
    }

    const emit = (printer: Discovered) =>
      send({
        type: 'found',
        printer: { ...printer, alreadyAdded: configured.has(printer.address.toLowerCase()) },
      })

    try {
      // USB first: it takes under a second, and showing it immediately makes
      // the slow part feel like progress rather than a wait.
      for (const printer of await discoverUsb()) {
        if (cancelled) return
        emit(printer)
      }

      await discoverNetwork({
        isCancelled: () => cancelled,
        onProgress: ({ scanned, total, found }) => {
          if (found) emit(found)
          else send({ type: 'progress', scanned, total })
        },
      })

      if (!cancelled) {
        send({ type: 'done' })
        socket.close()
      }
    } catch (error) {
      app.log.error({ err: error }, 'printer discovery failed')
      send({ type: 'error', message: 'The scan could not finish' })
      socket.close()
    }
  })

  app.get('/printers', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const rows = app.db
      .prepare(
        `SELECT * FROM printers WHERE branch_id = ? AND deleted_at IS NULL
         ORDER BY created_at`,
      )
      .all(me.branchId) as PrinterRow[]
    return { printers: rows.map(toPublic) }
  })

  app.post('/printers', { preHandler: requireRole('admin') }, async (request, reply) => {
    const me = currentUser(request)
    const body = createBody.parse(request.body)

    const id = randomUUID()
    const now = new Date().toISOString()

    app.db
      .prepare(
        `INSERT INTO printers (id, branch_id, name, connection, address, role,
                               paper_width, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
      )
      .run(id, me.branchId, body.name, body.connection, body.address, body.role, body.paperWidth, now, now)

    reply.status(201)
    return { printer: toPublic(findOrThrow(app, me.branchId, id)) }
  })

  app.patch<{ Params: { id: string } }>(
    '/printers/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const body = updateBody.parse(request.body)
      findOrThrow(app, me.branchId, request.params.id)

      const sets: string[] = []
      const values: unknown[] = []
      const push = (column: string, value: unknown) => {
        sets.push(`${column} = ?`)
        values.push(value)
      }

      if (body.name !== undefined) push('name', body.name)
      if (body.connection !== undefined) push('connection', body.connection)
      if (body.address !== undefined) push('address', body.address)
      if (body.role !== undefined) push('role', body.role)
      if (body.paperWidth !== undefined) push('paper_width', body.paperWidth)
      if (body.isActive !== undefined) push('is_active', body.isActive ? 1 : 0)

      if (sets.length > 0) {
        sets.push('updated_at = ?', 'synced_at = NULL')
        values.push(new Date().toISOString(), request.params.id)
        app.db.prepare(`UPDATE printers SET ${sets.join(', ')} WHERE id = ?`).run(...values)
      }

      return { printer: toPublic(findOrThrow(app, me.branchId, request.params.id)) }
    },
  )

  app.delete<{ Params: { id: string } }>(
    '/printers/:id',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      findOrThrow(app, me.branchId, request.params.id)
      const now = new Date().toISOString()
      app.db
        .prepare(
          'UPDATE printers SET deleted_at = ?, updated_at = ?, synced_at = NULL WHERE id = ?',
        )
        .run(now, now, request.params.id)
      return { ok: true }
    },
  )

  /**
   * Prints a test page.
   *
   * Unlike every other print path this one waits for the result and reports it,
   * because the whole point is finding out whether the printer works.
   */
  app.post<{ Params: { id: string } }>(
    '/printers/:id/test',
    { preHandler: requireRole('admin') },
    async (request) => {
      const me = currentUser(request)
      const printer = findOrThrow(app, me.branchId, request.params.id)

      const jobId = enqueueAndSend(app.db, {
        branchId: me.branchId,
        printerId: printer.id,
        type: 'test',
        refId: printer.id,
        payload: renderTest(printer.name, printer.paper_width),
      })

      // Wait for the send to settle so the response can say what happened. A
      // USB queue goes through the Windows spooler, which takes noticeably
      // longer than a socket — too short a wait reports a working printer as
      // failed, and someone goes looking for a fault that is not there.
      const job = await settleJob(app, jobId, 4_000)

      return {
        ok: job?.status === 'printed',
        status: job?.status ?? 'unknown',
        error: job?.last_error ?? null,
      }
    },
  )

  // --- the job queue ---

  app.get<{ Querystring: { status?: string; active?: string } }>(
    '/print-jobs',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const status = request.query.status

      // The queue panel asks for `active`: everything still waiting or stuck.
      // Printed and cancelled jobs are settled — listing them would mean the
      // panel is never empty, and a real failure gets lost in the history.
      const activeOnly = request.query.active === 'true'

      const filter = status
        ? ' AND j.status = ?'
        : activeOnly
          ? " AND j.status IN ('pending', 'failed')"
          : ''

      const rows = app.db
        .prepare(
          `SELECT j.id, j.type, j.status, j.attempts, j.last_error, j.created_at,
                  j.printed_at, j.printer_id, p.name AS printer_name
           FROM print_jobs j
           LEFT JOIN printers p ON p.id = j.printer_id
           WHERE j.branch_id = ?${filter}
           ORDER BY j.created_at DESC
           LIMIT 100`,
        )
        .all(...(status ? [me.branchId, status] : [me.branchId])) as Record<string, unknown>[]

      return { jobs: rows.map(toPublicJob) }
    },
  )

  /** Retries a failed job — the printer was offline and is now back. */
  app.post<{ Params: { id: string } }>(
    '/print-jobs/:id/retry',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const job = findJobOrThrow(app, me.branchId, request.params.id)

      // Reprinting something that already came out would put a second ticket in
      // the kitchen, and a second copy of a bill in a customer's hand.
      if (job.status === 'printed') {
        throw new AppError(409, 'JOB_ALREADY_PRINTED', 'That job has already printed')
      }

      // Reset to pending so runJob will pick it up; attempts is left alone as a
      // record of how much trouble this ticket has been.
      app.db
        .prepare("UPDATE print_jobs SET status = 'pending', updated_at = ? WHERE id = ?")
        .run(new Date().toISOString(), job.id)

      const printed = await runJob(app.db, job.id)
      return { ok: printed }
    },
  )

  /**
   * Cancels a queued or failed job.
   *
   * The row is kept, not deleted: what was sent to a printer and what happened
   * to it is a record worth having when someone asks why a ticket never
   * reached the kitchen.
   */
  app.post<{ Params: { id: string } }>(
    '/print-jobs/:id/cancel',
    { preHandler: requireAuth },
    async (request) => {
      const me = currentUser(request)
      const job = findJobOrThrow(app, me.branchId, request.params.id)

      // Paper is already out of the printer. Cancelling would claim otherwise.
      if (job.status === 'printed') {
        throw new AppError(409, 'JOB_ALREADY_PRINTED', 'That job has already printed')
      }
      if (job.status === 'cancelled') return { ok: true }

      app.db
        .prepare("UPDATE print_jobs SET status = 'cancelled', updated_at = ? WHERE id = ?")
        .run(new Date().toISOString(), job.id)

      return { ok: true }
    },
  )
}

interface JobStatusRow {
  id: string
  status: string
}

function findJobOrThrow(app: FastifyInstance, branchId: string, id: string): JobStatusRow {
  const job = app.db
    .prepare('SELECT id, status FROM print_jobs WHERE id = ? AND branch_id = ?')
    .get(id, branchId) as JobStatusRow | undefined
  if (!job) throw new AppError(404, 'JOB_NOT_FOUND', 'Print job not found')
  return job
}

/** Job rows go out camelCase like everything else the client consumes. */
function toPublicJob(row: Record<string, unknown>) {
  return {
    id: row.id as string,
    type: row.type as string,
    status: row.status as string,
    attempts: row.attempts as number,
    lastError: (row.last_error as string | null) ?? null,
    createdAt: row.created_at as string,
    printedAt: (row.printed_at as string | null) ?? null,
    printerId: (row.printer_id as string | null) ?? null,
    printerName: (row.printer_name as string | null) ?? null,
  }
}

/**
 * Waits for a queued job to stop being pending, up to a limit.
 *
 * Polls rather than sleeping a fixed time: a socket printer answers in
 * milliseconds while a Windows spool takes seconds, and a single delay long
 * enough for the slow case would make the fast one feel broken.
 */
async function settleJob(
  app: FastifyInstance,
  jobId: string,
  timeoutMs: number,
): Promise<{ status: string; last_error: string | null } | undefined> {
  const deadline = Date.now() + timeoutMs
  let job: { status: string; last_error: string | null } | undefined

  while (Date.now() < deadline) {
    job = app.db
      .prepare('SELECT status, last_error FROM print_jobs WHERE id = ?')
      .get(jobId) as { status: string; last_error: string | null } | undefined

    if (job === undefined || job.status !== 'pending') return job
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  return job
}

function findOrThrow(app: FastifyInstance, branchId: string, id: string): PrinterRow {
  const row = app.db
    .prepare('SELECT * FROM printers WHERE id = ? AND branch_id = ? AND deleted_at IS NULL')
    .get(id, branchId) as PrinterRow | undefined
  if (!row) throw new AppError(404, 'PRINTER_NOT_FOUND', 'Printer not found')
  return row
}
