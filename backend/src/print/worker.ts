import type { FastifyBaseLogger } from 'fastify'
import type { Db } from '../db/client.js'
import { drainPending, prunePrintJobs } from './queue.js'

/**
 * Retries print jobs that have not gone out yet.
 *
 * A kitchen printer on wifi will be offline sometimes, and a job that failed
 * its first attempt is left pending on purpose so it can be tried again. Until
 * something actually tries it, though, "pending" means "stuck forever": the
 * ticket never prints, and the queue panel offers no Retry because the job has
 * not given up yet.
 *
 * Runs at boot too, so a job caught by a restart is picked up rather than
 * waiting for the first tick.
 */
export interface PrintWorker {
  start(): void
  stop(): void
}

/** Long enough not to hammer a dead printer, short enough that a cook waiting
 * at the pass is not waiting on a whole minute. */
const INTERVAL_MS = 20_000

/** Old jobs are not urgent. Sweeping them on the print tick would run a DELETE
 *  three times a minute for a table that changes slowly. */
const PRUNE_EVERY_MS = 60 * 60 * 1000

export function createPrintWorker(db: Db, log: FastifyBaseLogger): PrintWorker {
  let timer: NodeJS.Timeout | undefined
  let pruneTimer: NodeJS.Timeout | undefined
  let running = false

  /**
   * Drops finished jobs past the retention window.
   *
   * `print_jobs` is never synced and nothing deleted from it, so it grew for
   * the life of an install — every bill and every KOT keeping its full ESC/POS
   * payload for ever.
   */
  const prune = (): void => {
    try {
      const removed = prunePrintJobs(db)
      if (removed > 0) log.info({ removed }, 'old print jobs pruned')
    } catch (error) {
      // Housekeeping. A failure here must never affect printing or a sale.
      log.error({ err: error }, 'print job prune failed')
    }
  }

  const tick = async (): Promise<void> => {
    // A slow spooler must not let two sweeps overlap and send the same ticket
    // twice.
    if (running) return
    running = true
    try {
      const printed = await drainPending(db)
      if (printed > 0) log.info({ printed }, 'print queue drained')
    } catch (error) {
      // Never throws onward: this is a background sweep, and a failure here
      // must not take the server down or block a sale.
      log.error({ err: error }, 'print queue sweep failed')
    } finally {
      running = false
    }
  }

  return {
    start(): void {
      if (timer) return
      void tick()
      timer = setInterval(() => void tick(), INTERVAL_MS)
      // Does not hold the process open on its own.
      timer.unref?.()

      // At boot as well as hourly: a till that is switched off each night would
      // otherwise never reach the first hourly sweep.
      prune()
      pruneTimer = setInterval(prune, PRUNE_EVERY_MS)
      pruneTimer.unref?.()
    },
    stop(): void {
      if (timer) clearInterval(timer)
      timer = undefined
      if (pruneTimer) clearInterval(pruneTimer)
      pruneTimer = undefined
    },
  }
}
