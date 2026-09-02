import { randomUUID } from 'node:crypto'
import type { Db } from '../db/client.js'
import { send, PrintError, type Connection } from './transport.js'
import type { PaperWidth } from './escpos.js'

/**
 * The print queue.
 *
 * A print failure must never block an order or a bill: the record saves, the
 * job queues, and a kitchen printer on wifi is free to be offline. Everything
 * here is best-effort by design — the one thing it may not do is throw into a
 * billing path.
 */

export type JobType = 'bill' | 'kot' | 'kot_additional' | 'kot_cancel' | 'test'

/** Enough attempts to ride out a reboot, few enough to stop a doomed job. */
const MAX_ATTEMPTS = 5

export interface PrinterRow {
  id: string
  branch_id: string
  name: string
  connection: Connection
  address: string
  role: 'bill' | 'kot' | 'both'
  paper_width: PaperWidth
  is_active: number
}

/**
 * Finds the printer a job should go to.
 *
 * A printer set to `both` covers the single-printer restaurant without a
 * special case anywhere else.
 */
export function resolvePrinter(
  db: Db,
  branchId: string,
  role: 'bill' | 'kot',
): PrinterRow | undefined {
  return db
    .prepare(
      `SELECT * FROM printers
       WHERE branch_id = ? AND is_active = 1 AND deleted_at IS NULL
         AND (role = ? OR role = 'both')
       ORDER BY CASE role WHEN ? THEN 0 ELSE 1 END, created_at
       LIMIT 1`,
    )
    .get(branchId, role, role) as PrinterRow | undefined
}

/**
 * Queues a rendered ticket.
 *
 * The payload is stored already rendered so a retry reproduces the original
 * exactly, even if the order was edited after the first attempt failed.
 */
export function enqueue(
  db: Db,
  input: {
    branchId: string
    printerId: string
    type: JobType
    refId: string
    payload: Buffer
  },
): string {
  const id = randomUUID()
  const now = new Date().toISOString()

  db.prepare(
    `INSERT INTO print_jobs (id, branch_id, printer_id, type, ref_id, payload,
                             status, attempts, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)`,
  ).run(
    id,
    input.branchId,
    input.printerId,
    input.type,
    input.refId,
    input.payload.toString('base64'),
    now,
    now,
  )

  return id
}

interface JobRow {
  id: string
  printer_id: string
  type: JobType
  payload: string
  attempts: number
}

/**
 * Sends one job and records what happened.
 *
 * Returns whether it printed. Never throws — the caller is often a route that
 * has already committed a bill.
 */
export async function runJob(db: Db, jobId: string): Promise<boolean> {
  const job = db
    .prepare("SELECT * FROM print_jobs WHERE id = ? AND status = 'pending'")
    .get(jobId) as JobRow | undefined
  if (!job) return false

  const printer = db
    .prepare('SELECT * FROM printers WHERE id = ?')
    .get(job.printer_id) as PrinterRow | undefined

  const now = new Date().toISOString()

  if (!printer) {
    db.prepare(
      `UPDATE print_jobs SET status = 'failed', last_error = ?, updated_at = ?
       WHERE id = ?`,
    ).run('Printer no longer exists', now, job.id)
    return false
  }

  try {
    await send(printer.connection, printer.address, Buffer.from(job.payload, 'base64'))
    // Only settle a job that is still pending. Someone may have cancelled it
    // while this send was in flight, and overwriting that would revive a job
    // they have already dealt with by hand.
    db.prepare(
      `UPDATE print_jobs SET status = 'printed', attempts = attempts + 1,
                             printed_at = ?, updated_at = ?, last_error = NULL
       WHERE id = ? AND status = 'pending'`,
    ).run(now, now, job.id)
    return true
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const attempts = job.attempts + 1
    const permanent = error instanceof PrintError && !error.retryable
    // Give up after enough tries so a dead printer stops being retried forever,
    // but leave the row for someone to look at.
    const status = permanent || attempts >= MAX_ATTEMPTS ? 'failed' : 'pending'

    db.prepare(
      `UPDATE print_jobs SET status = ?, attempts = ?, last_error = ?, updated_at = ?
       WHERE id = ? AND status = 'pending'`,
    ).run(status, attempts, message, now, job.id)
    return false
  }
}

/**
 * Queues a job and tries it immediately, without making the caller wait.
 *
 * This is what billing paths call. The promise is deliberately not returned:
 * a bill is saved whether or not the paper comes out.
 */
export function enqueueAndSend(
  db: Db,
  input: {
    branchId: string
    printerId: string
    type: JobType
    refId: string
    payload: Buffer
  },
  onSettled?: (printed: boolean) => void,
): string {
  const jobId = enqueue(db, input)
  void runJob(db, jobId)
    .then((printed) => onSettled?.(printed))
    .catch(() => onSettled?.(false))
  return jobId
}

/**
 * Waits for a queued job to stop being pending, up to a limit.
 *
 * Polls rather than sleeping a fixed time. A socket printer answers in
 * milliseconds while a Windows spool takes seconds, so any single delay is
 * wrong for one of them: too short reports a working printer as failed, and
 * too long makes every print feel slow.
 *
 * Returns whatever the job looks like when it settles or the limit runs out —
 * still pending is a real answer, meaning "queued, not yet printed".
 */
export async function settleJob(
  db: Db,
  jobId: string,
  timeoutMs: number,
): Promise<{ status: string; last_error: string | null } | undefined> {
  const deadline = Date.now() + timeoutMs
  let job: { status: string; last_error: string | null } | undefined

  while (Date.now() < deadline) {
    job = db
      .prepare('SELECT status, last_error FROM print_jobs WHERE id = ?')
      .get(jobId) as { status: string; last_error: string | null } | undefined

    if (job === undefined || job.status !== 'pending') return job
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  return job
}

/** How long a print request waits before reporting back. */
export const SETTLE_TIMEOUT_MS = 4_000

/** Retries everything still pending. Called on a timer and at startup. */
export async function drainPending(db: Db, branchId?: string): Promise<number> {
  const rows = (
    branchId
      ? db
          .prepare(
            `SELECT id FROM print_jobs WHERE status = 'pending' AND branch_id = ?
             ORDER BY created_at LIMIT 50`,
          )
          .all(branchId)
      : db
          .prepare(
            "SELECT id FROM print_jobs WHERE status = 'pending' ORDER BY created_at LIMIT 50",
          )
          .all()
  ) as { id: string }[]

  let printed = 0
  for (const row of rows) {
    if (await runJob(db, row.id)) printed++
  }
  return printed
}
