import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { getSetting, setSetting, type SettingKey } from '../lib/settings.js'
import { formatBillNumber, RESET_PERIODS } from '../lib/bill-number.js'

/**
 * Branch settings and details.
 *
 * Everything here changes how bills are calculated, numbered or printed, so it
 * is admin-only and every value is validated before it is stored — a corrupt
 * tax rate would be discovered at reconciliation, not at the till.
 */

const updateSettingsBody = z.object({
  taxMode: z.enum(['inclusive', 'exclusive']).optional(),
  /** Basis points. 5% is 500. */
  defaultTaxRate: z.number().int().min(0).max(10_000).optional(),
  /** `HH:mm`. When a trading day rolls over. */
  businessDayStart: z.string().regex(/^\d{2}:\d{2}$/).optional(),
  billPrefix: z.string().max(16).optional(),
  billResetPeriod: z.enum(RESET_PERIODS).optional(),
  billNumberFormat: z.string().min(1).max(64).optional(),
  billNumberPad: z.number().int().min(1).max(10).optional(),
  billFooter: z.string().max(200).optional(),
  roundOffEnabled: z.boolean().optional(),
})

const updateBranchBody = z.object({
  name: z.string().min(1).max(64).trim().optional(),
  address: z.string().max(200).trim().nullable().optional(),
  phone: z.string().max(20).trim().nullable().optional(),
  gstin: z.string().max(15).trim().nullable().optional(),
})

interface BranchRow {
  id: string
  name: string
  address: string | null
  phone: string | null
  gstin: string | null
}

export async function settingsRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Every setting, in the shapes the client uses.
   *
   * Readable by any signed-in user because the till needs the tax mode and the
   * business day start to show correct figures; only writing is restricted.
   */
  app.get('/settings', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    return { settings: readAll(app, me.branchId) }
  })

  app.patch('/settings', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const body = updateSettingsBody.parse(request.body)

    const write = (key: SettingKey, value: string) =>
      setSetting(app.db, me.branchId, key, value)

    // Changing the tax mode does not touch bills already issued — each one
    // snapshots the mode it was calculated under.
    if (body.taxMode !== undefined) write('tax_mode', body.taxMode)
    if (body.defaultTaxRate !== undefined) {
      write('default_tax_rate', String(body.defaultTaxRate))
    }
    if (body.businessDayStart !== undefined) {
      assertValidTime(body.businessDayStart)
      write('business_day_start', body.businessDayStart)
    }
    if (body.billPrefix !== undefined) write('bill_prefix', body.billPrefix)
    if (body.billResetPeriod !== undefined) {
      write('bill_reset_period', body.billResetPeriod)
    }
    if (body.billNumberFormat !== undefined) {
      assertUsableFormat(body.billNumberFormat)
      write('bill_number_format', body.billNumberFormat)
    }
    if (body.billNumberPad !== undefined) {
      write('bill_number_pad', String(body.billNumberPad))
    }
    if (body.billFooter !== undefined) write('bill_footer', body.billFooter)
    if (body.roundOffEnabled !== undefined) {
      write('round_off_enabled', body.roundOffEnabled ? '1' : '0')
    }

    return { settings: readAll(app, me.branchId) }
  })

  /**
   * What a bill number would look like under a given format.
   *
   * Lets the settings screen show the result before it is saved — a format
   * string is not something anyone should have to guess at.
   */
  app.post('/settings/bill-number-preview', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const body = z
      .object({
        format: z.string().min(1).max(64),
        prefix: z.string().max(16).default(''),
        pad: z.number().int().min(1).max(10).default(4),
      })
      .parse(request.body)

    return {
      preview: formatBillNumber({
        billNo: 42,
        businessDate: new Date().toISOString().slice(0, 10),
        template: body.format,
        prefix: body.prefix,
        padWidth: body.pad,
      }),
      branchId: me.branchId,
    }
  })

  // --- branch details, which appear on the printed bill ---

  app.get('/branch', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const row = app.db
      .prepare('SELECT id, name, address, phone, gstin FROM branches WHERE id = ?')
      .get(me.branchId) as BranchRow | undefined
    if (!row) throw new AppError(404, 'BRANCH_NOT_FOUND', 'Branch not found')
    return { branch: row }
  })

  app.patch('/branch', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const body = updateBranchBody.parse(request.body)

    const sets: string[] = []
    const values: unknown[] = []
    const push = (column: string, value: unknown) => {
      sets.push(`${column} = ?`)
      values.push(value)
    }

    if (body.name !== undefined) push('name', body.name)
    if (body.address !== undefined) push('address', body.address)
    if (body.phone !== undefined) push('phone', body.phone)
    if (body.gstin !== undefined) {
      // Stored uppercase: a GSTIN is case-insensitive but printed uppercase on
      // every invoice, and mixed case on a tax document looks like an error.
      const gstin = body.gstin === null ? null : body.gstin.toUpperCase()
      if (gstin) assertValidGstin(gstin)
      push('gstin', gstin)
    }

    if (sets.length > 0) {
      sets.push('updated_at = ?', 'synced_at = NULL')
      values.push(new Date().toISOString(), me.branchId)
      app.db.prepare(`UPDATE branches SET ${sets.join(', ')} WHERE id = ?`).run(...values)
    }

    const row = app.db
      .prepare('SELECT id, name, address, phone, gstin FROM branches WHERE id = ?')
      .get(me.branchId) as BranchRow
    return { branch: row }
  })
}

/** Every setting in one shape, so read and write return the same thing. */
function readAll(app: FastifyInstance, branchId: string) {
  const read = <K extends SettingKey>(key: K) => getSetting(app.db, branchId, key)

  return {
    taxMode: read('tax_mode'),
    defaultTaxRate: read('default_tax_rate'),
    businessDayStart: read('business_day_start'),
    billPrefix: read('bill_prefix'),
    billResetPeriod: read('bill_reset_period'),
    billNumberFormat: read('bill_number_format'),
    billNumberPad: read('bill_number_pad'),
    billFooter: read('bill_footer'),
    roundOffEnabled: read('round_off_enabled'),
  }
}

function assertValidTime(value: string): void {
  const [hours, minutes] = value.split(':').map(Number)
  if (
    hours === undefined ||
    minutes === undefined ||
    hours < 0 ||
    hours > 23 ||
    minutes < 0 ||
    minutes > 59
  ) {
    throw new AppError(400, 'INVALID_TIME', 'Use a 24-hour time like 05:00')
  }
}

/**
 * A bill number format has to produce a different number for each bill.
 *
 * Without `{NO}` every bill in a period would print the same string, and two
 * bills sharing a number is not something anyone would notice until an audit.
 */
function assertUsableFormat(format: string): void {
  if (!format.includes('{NO}')) {
    throw new AppError(
      400,
      'FORMAT_MISSING_NUMBER',
      'The format must include {NO}, or every bill would have the same number.',
    )
  }
}

/** 15 characters: 2 state digits, a 10-character PAN, then 3 more. */
function assertValidGstin(value: string): void {
  if (!/^\d{2}[A-Z]{5}\d{4}[A-Z]\d[A-Z\d][A-Z\d]$/.test(value)) {
    throw new AppError(
      400,
      'INVALID_GSTIN',
      'That does not look like a GSTIN. It should be 15 characters, like 33ABCDE1234F1Z5.',
    )
  }
}
