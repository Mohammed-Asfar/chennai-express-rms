import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { requiredText } from '../lib/validation.js'
import { AppError } from '../lib/errors.js'
import { currentUser, requireAuth, requireRole } from '../lib/guards.js'
import { getSetting, setSetting, type SettingKey } from '../lib/settings.js'
import { formatBillNumber, RESET_PERIODS } from '../lib/bill-number.js'
import { resolvePrinter } from '../print/queue.js'
import { rasterise, rasterToPng } from '../print/logo.js'
import { renderBill } from '../print/tickets.js'
import { decodeTicket } from '../print/preview.js'
import { CHARS_PER_LINE } from '../print/escpos.js'
import { currentBusinessDate } from '../lib/business-date.js'

/**
 * Branch settings and details.
 *
 * Everything here changes how bills are calculated, numbered or printed, so it
 * is admin-only and every value is validated before it is stored — a corrupt
 * tax rate would be discovered at reconciliation, not at the till.
 */

const updateSettingsBody = z.object({
  /** Whether GST applies at all. Off for a restaurant below the threshold. */
  gstEnabled: z.boolean().optional(),
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
  name: requiredText(64).optional(),
  /** A line under the name on the bill. Empty clears it. */
  tagline: z.string().max(64).trim().nullable().optional(),
  address: z.string().max(200).trim().nullable().optional(),
  phone: z.string().max(20).trim().nullable().optional(),
  gstin: z.string().max(15).trim().nullable().optional(),
  /** Whether to print the logo, without deleting it (FR-P15). */
  printLogo: z.boolean().optional(),
})

interface BranchRow {
  id: string
  name: string
  tagline: string | null
  address: string | null
  phone: string | null
  gstin: string | null
  logo_bitmap: string | null
  print_logo: number
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

    // Neither switching GST off nor changing the mode touches bills already
    // issued: each one snapshots the mode and rates it was calculated under.
    if (body.gstEnabled !== undefined) {
      write('gst_enabled', body.gstEnabled ? '1' : '0')
    }
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

  /**
   * A sample bill, as it would print under the current settings.
   *
   * Rendered through the same code the printer uses and then decoded back to
   * text, so what is shown cannot drift from what comes out. Lets someone check
   * a footer, a bill number format or a logo without spending a roll of paper.
   */
  app.get('/settings/bill-preview', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)

    const branch = app.db
      .prepare(
        `SELECT name, tagline, address, phone, gstin, logo_bitmap, logo_width,
                logo_height, print_logo
         FROM branches WHERE id = ?`,
      )
      .get(me.branchId) as
      | {
          name: string
          tagline: string | null
          address: string | null
          phone: string | null
          gstin: string | null
          logo_bitmap: string | null
          logo_width: number | null
          logo_height: number | null
          print_logo: number
        }
      | undefined

    const printer = resolvePrinter(app.db, me.branchId, 'bill')
    const paper = printer?.paper_width ?? '80mm'

    const businessDate = currentBusinessDate(app.db, me.branchId)
    const taxMode = getSetting(app.db, me.branchId, 'tax_mode')
    const gstEnabled = getSetting(app.db, me.branchId, 'gst_enabled')

    // A representative order rather than real data: two lines, one with a
    // quantity above one, so the layout is exercised properly.
    const billNumber = formatBillNumber({
      billNo: 42,
      businessDate,
      template: getSetting(app.db, me.branchId, 'bill_number_format'),
      prefix: getSetting(app.db, me.branchId, 'bill_prefix'),
      padWidth: getSetting(app.db, me.branchId, 'bill_number_pad'),
    })

    const logo =
      branch?.print_logo === 1 &&
      branch.logo_bitmap &&
      branch.logo_width &&
      branch.logo_height
        ? {
            data: branch.logo_bitmap,
            width: branch.logo_width,
            height: branch.logo_height,
          }
        : null

    const rendered = renderBill(
      {
        billNumber,
        branchName: branch?.name ?? 'Restaurant',
        branchTagline: branch?.tagline ?? null,
        branchAddress: branch?.address ?? null,
        branchPhone: branch?.phone ?? null,
        gstin: branch?.gstin ?? null,
        orderNo: 7,
        type: 'dine_in',
        tableName: 'A4',
        printedAt: new Date(),
        lines: [
          {
            name: 'Mutton Biryani',
            variantName: 'Full',
            qty: 2,
            unitPrice: 38_000,
            lineTotal: 76_000,
          },
          {
            name: 'Filter Coffee',
            variantName: 'Standard',
            qty: 1,
            unitPrice: 3_000,
            lineTotal: 3_000,
          },
        ],
        // With GST off the sample carries none, so the preview shows what
        // will actually print rather than tax that no longer applies.
        subtotal: gstEnabled ? 75_238 : 79_000,
        discountAmount: 0,
        cgst: gstEnabled ? 1_881 : 0,
        sgst: gstEnabled ? 1_881 : 0,
        roundOff: 0,
        total: 79_000,
        taxMode,
        payments: [{ mode: 'cash', amount: 79_000 }],
        footer: getSetting(app.db, me.branchId, 'bill_footer'),
        logo,
      },
      paper,
    )

    // The raster as a picture, so the preview can show what actually prints
    // rather than a placeholder. Small enough to inline as a data URL.
    const logoImage = logo
      ? 'data:image/png;base64,' + (await rasterToPng(logo)).toString('base64')
      : null

    return {
      preview: decodeTicket(rendered, CHARS_PER_LINE[paper]),
      paper,
      logoImage,
    }
  })

  // --- branch details, which appear on the printed bill ---

  app.get('/branch', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const row = app.db
      .prepare(`SELECT id, name, tagline, address, phone, gstin, logo_bitmap, print_logo
         FROM branches WHERE id = ?`)
      .get(me.branchId) as BranchRow | undefined
    if (!row) throw new AppError(404, 'BRANCH_NOT_FOUND', 'Branch not found')
    return { branch: toPublicBranch(row) }
  })

  /**
   * Uploads a logo and rasterises it for the till's paper width.
   *
   * Converted once here rather than per bill: rasterising on every print would
   * cost more than the print target allows. The original is kept so it can be
   * re-rasterised if the paper width changes.
   */
  app.post('/branch/logo', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const body = z
      .object({
        /** Base64, with or without a data-URL prefix. */
        image: z.string().min(1).max(4_000_000),
      })
      .parse(request.body)

    const base64 = body.image.replace(/^data:image\/\w+;base64,/, '')
    let buffer: Buffer
    try {
      buffer = Buffer.from(base64, 'base64')
    } catch {
      throw new AppError(400, 'INVALID_IMAGE', 'That file could not be read')
    }

    // Sized to whatever the bill printer uses; falls back to 80mm when none is
    // configured yet, which is by far the common paper.
    const printer = resolvePrinter(app.db, me.branchId, 'bill')
    const paper = printer?.paper_width ?? '80mm'

    let raster
    try {
      raster = await rasterise(buffer, paper)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new AppError(400, 'INVALID_IMAGE', `Could not use that image: ${message}`)
    }

    const now = new Date().toISOString()
    app.db
      .prepare(
        `UPDATE branches SET logo = ?, logo_bitmap = ?, logo_width = ?, logo_height = ?,
                             updated_at = ?, synced_at = NULL
         WHERE id = ?`,
      )
      .run(base64, raster.data, raster.width, raster.height, now, me.branchId)

    return {
      logo: { width: raster.width, height: raster.height, paper },
    }
  })

  /**
   * The stored logo as a PNG, for showing on screen.
   *
   * Its own endpoint rather than a field on `GET /branch`: the raster is
   * kilobytes of base64, and every screen that reads the branch would carry it
   * whether or not it draws it.
   *
   * Drawn from the dithered raster, not the upload — the original is not kept,
   * and this is what actually burns onto the paper.
   */
  app.get('/branch/logo', { preHandler: requireAuth }, async (request) => {
    const me = currentUser(request)
    const branch = app.db
      .prepare('SELECT logo_bitmap, logo_width, logo_height FROM branches WHERE id = ?')
      .get(me.branchId) as
      | { logo_bitmap: string | null; logo_width: number | null; logo_height: number | null }
      | undefined

    if (!branch?.logo_bitmap || !branch.logo_width || !branch.logo_height) {
      return { logoImage: null, width: null, height: null }
    }

    const png = await rasterToPng({
      data: branch.logo_bitmap,
      width: branch.logo_width,
      height: branch.logo_height,
    })

    return {
      logoImage: 'data:image/png;base64,' + png.toString('base64'),
      width: branch.logo_width,
      height: branch.logo_height,
    }
  })

  app.delete('/branch/logo', { preHandler: requireRole('admin') }, async (request) => {
    const me = currentUser(request)
    const now = new Date().toISOString()
    app.db
      .prepare(
        `UPDATE branches SET logo = NULL, logo_bitmap = NULL, logo_width = NULL,
                             logo_height = NULL, updated_at = ?, synced_at = NULL
         WHERE id = ?`,
      )
      .run(now, me.branchId)
    return { ok: true }
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
    if (body.tagline !== undefined) {
      // An emptied field means "no tagline", not an empty line printed on every
      // bill, so it is stored as null rather than ''.
      push('tagline', body.tagline === null || body.tagline === '' ? null : body.tagline)
    }
    if (body.address !== undefined) push('address', body.address)
    if (body.phone !== undefined) push('phone', body.phone)
    if (body.printLogo !== undefined) push('print_logo', body.printLogo ? 1 : 0)
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
      .prepare(`SELECT id, name, tagline, address, phone, gstin, logo_bitmap, print_logo
         FROM branches WHERE id = ?`)
      .get(me.branchId) as BranchRow
    return { branch: toPublicBranch(row) }
  })
}

/** Every setting in one shape, so read and write return the same thing. */
/**
 * The branch as the client needs it.
 *
 * The raster itself is never sent: it is kilobytes of base64 the UI has no use
 * for, and only whether one exists matters on screen.
 */
function toPublicBranch(row: BranchRow) {
  return {
    id: row.id,
    name: row.name,
    tagline: row.tagline,
    address: row.address,
    phone: row.phone,
    gstin: row.gstin,
    hasLogo: row.logo_bitmap !== null,
    printLogo: row.print_logo === 1,
  }
}

function readAll(app: FastifyInstance, branchId: string) {
  const read = <K extends SettingKey>(key: K) => getSetting(app.db, branchId, key)

  return {
    taxMode: read('tax_mode'),
    gstEnabled: read('gst_enabled'),
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
