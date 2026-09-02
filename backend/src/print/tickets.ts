import { EscPosBuilder, type PaperWidth } from './escpos.js'
import { formatMoney } from '../lib/money.js'
import { rasterCommand, type LogoRaster } from './logo.js'

/**
 * Ticket layouts.
 *
 * A KOT and a bill are different documents for different readers. The kitchen
 * needs the dish and the quantity, large, with no prices at all — a cook
 * glancing at a ticket over a hot pass should not have to find the name among
 * numbers. The customer needs the money to be unambiguous.
 */

export interface TicketLine {
  name: string
  variantName: string
  qty: number
  notes?: string | null
  /** Paise. Absent on a KOT, which never shows money. */
  lineTotal?: number
  unitPrice?: number
}

export interface KotData {
  orderNo: number
  type: 'dine_in' | 'takeaway'
  tableName?: string | null
  seatLabel?: string | null
  printedAt: Date
  lines: TicketLine[]
  /** Reprints and additions must be obvious, or the kitchen cooks twice. */
  kind: 'new' | 'additional' | 'cancel'
}

export interface BillData {
  billNumber: string
  branchName: string
  /** A line under the name — "Authentic Chennai Cuisine", "Since 1998". */
  branchTagline?: string | null
  branchAddress?: string | null
  branchPhone?: string | null
  gstin?: string | null
  orderNo: number
  type: 'dine_in' | 'takeaway'
  tableName?: string | null
  printedAt: Date
  lines: TicketLine[]
  subtotal: number
  discountAmount: number
  cgst: number
  sgst: number
  roundOff: number
  total: number
  taxMode: 'inclusive' | 'exclusive'
  payments: { mode: string; amount: number }[]
  footer?: string | null
  isReprint?: boolean
  /** Pre-rasterised at upload. Absent when none is set or it is switched off. */
  logo?: LogoRaster | null
}

const timeOf = (date: Date) =>
  date.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: true })

const dateOf = (date: Date) =>
  date.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' })

/**
 * The kitchen ticket.
 *
 * Deliberately sparse and large. No prices, no tax, no branding — everything
 * that is not a dish or a quantity is noise to someone cooking.
 */
export function renderKot(data: KotData, paper: PaperWidth = '80mm'): Buffer {
  const b = new EscPosBuilder(paper)

  b.align('center').size(true).bold(true)
  if (data.kind === 'cancel') {
    b.line('** CANCELLED **')
  } else if (data.kind === 'additional') {
    b.line('** ADDED ITEMS **')
  } else {
    b.line('KOT')
  }
  b.size(false).bold(false)

  b.align('center')
  const where = data.type === 'takeaway'
    ? 'TAKEAWAY'
    : [data.tableName, data.seatLabel].filter(Boolean).join(' / ')
  b.size(true, false).bold(true).line(where || 'DINE-IN').size(false).bold(false)

  b.align('left').rule()
  b.columns(`Order #${data.orderNo}`, timeOf(data.printedAt))
  b.rule()

  // Quantity first and doubled: it is the number that gets misread, and cooking
  // two of something instead of twelve is the expensive mistake.
  for (const line of data.lines) {
    b.size(true, false).bold(true)
    b.line(`${line.qty}  ${line.name}`)
    b.size(false).bold(false)

    if (line.variantName && line.variantName !== 'Standard') {
      b.line(`    (${line.variantName})`)
    }
    if (line.notes) {
      // Indented via the parameter, not by padding the string: wrapped() splits
      // on whitespace and would drop leading spaces, and a note that runs onto a
      // second line needs that line indented too.
      b.bold(true).wrapped(`* ${line.notes}`, 4).bold(false)
    }
    b.line()
  }

  b.rule()
  b.align('center').line(dateOf(data.printedAt))
  return b.cut().build()
}

/**
 * The customer's bill.
 *
 * Every number the customer might check has to be here and has to add up: the
 * line prices, the tax split, and the total they are being asked to pay.
 */
export function renderBill(data: BillData, paper: PaperWidth = '80mm'): Buffer {
  const b = new EscPosBuilder(paper)

  // The logo goes above the name, not instead of it: a thermal logo can print
  // faintly on worn paper, and the bill must still say who issued it.
  if (data.logo) {
    b.align('center').raw(...rasterCommand(data.logo)).line()
  }

  // With no logo the name is the only thing identifying the bill at a glance,
  // so it takes the space the logo would have used. With one, it stays at
  // double height — competing with the image would just look crowded.
  const nameHeight = data.logo ? 2 : 3
  const nameWidth = 2

  b.align('center').scale(nameHeight, nameWidth).bold(true)
  b.wrappedAtScale(data.branchName, nameWidth)
  b.scale(1, 1).bold(false)

  // A tagline under the name, in normal type: the name is what must stand out,
  // and a second large line would fight it rather than support it.
  if (data.branchTagline) b.wrapped(data.branchTagline)

  if (data.branchAddress) b.wrapped(data.branchAddress)
  // Under the address, where a customer looks for it to call back about an
  // order — not beside the GSTIN, which is a tax reference, not a contact.
  if (data.branchPhone) b.line(`Ph: ${data.branchPhone}`)
  if (data.gstin) b.line(`GSTIN: ${data.gstin}`)
  b.line()

  if (data.isReprint) {
    // A duplicate must never be mistakable for the original.
    b.bold(true).line('** DUPLICATE **').bold(false)
  }

  b.align('left').rule()
  b.columns(`Bill No: ${data.billNumber}`, dateOf(data.printedAt))
  const where = data.type === 'takeaway' ? 'Takeaway' : (data.tableName ?? 'Dine-in')
  b.columns(`${where}  Order #${data.orderNo}`, timeOf(data.printedAt))
  b.rule()

  // Header for the item columns.
  b.line(padQty('Qty') + 'Item'.padEnd(b.width - 16) + 'Amount'.padStart(10))
  b.rule()

  for (const line of data.lines) {
    const name = line.variantName && line.variantName !== 'Standard'
      ? `${line.name} (${line.variantName})`
      : line.name
    const amount = formatMoney(line.lineTotal ?? 0)

    const room = b.width - 6 - 10
    const shown = name.length > room ? name.slice(0, room - 1) + '.' : name
    b.line(padQty(String(line.qty)) + shown.padEnd(room) + amount.padStart(10))

    // The unit price justifies the line amount when the quantity is not 1.
    if (line.qty > 1 && line.unitPrice !== undefined) {
      b.line(`      @ ${formatMoney(line.unitPrice)}`)
    }
  }

  b.rule()

  const money = (n: number) => formatMoney(n)
  b.columns('Subtotal', money(data.subtotal))
  if (data.discountAmount > 0) b.columns('Discount', `-${money(data.discountAmount)}`)

  // Split shown separately because GST invoices require both halves visible.
  if (data.cgst > 0 || data.sgst > 0) {
    b.columns('CGST', money(data.cgst))
    b.columns('SGST', money(data.sgst))
  }
  if (data.roundOff !== 0) {
    b.columns('Round off', `${data.roundOff > 0 ? '+' : ''}${money(data.roundOff)}`)
  }

  b.rule('=')
  // Double height only, never double width: doubling the width halves the
  // usable columns, and the amount is pushed off the edge of the paper. The
  // total is the one line on the bill that must always be readable.
  b.size(true, false).bold(true).columns('TOTAL', money(data.total)).size(false).bold(false)
  b.rule('=')

  if (data.taxMode === 'inclusive') {
    b.align('center').line('(Price includes GST)').align('left')
  }

  if (data.payments.length > 0) {
    b.line()
    for (const payment of data.payments) {
      b.columns(titleCase(payment.mode), money(payment.amount))
    }
  }

  // FR-P8: what is still owed, stated plainly. A customer handed a bill with
  // payments listed but no balance cannot tell whether they are settled, and
  // neither can whoever finds it in the drawer later.
  const paid = data.payments.reduce((sum, payment) => sum + payment.amount, 0)
  const due = data.total - paid

  b.line()
  if (due <= 0 && paid > 0) {
    b.align('center').bold(true).line('*** PAID ***').bold(false).align('left')
  } else if (paid > 0) {
    b.bold(true).columns('BALANCE DUE', money(due)).bold(false)
  } else {
    b.align('center').bold(true).line('*** UNPAID ***').bold(false).align('left')
  }

  b.line()
  b.align('center')
  // The branch's own footer replaces the default rather than stacking with it —
  // a receipt thanking the customer twice looks like a bug, because it is one.
  b.wrapped(data.footer && data.footer.trim().length > 0 ? data.footer : 'Thank you!')

  return b.cut().build()
}

/** A test page, for checking a printer is reachable and the paper is right. */
export function renderTest(printerName: string, paper: PaperWidth): Buffer {
  const b = new EscPosBuilder(paper)
  b.align('center').size(true).bold(true).line('TEST PRINT').size(false).bold(false)
  b.line(printerName).line()
  b.align('left').rule()
  b.columns('Paper', paper)
  b.columns('Columns', String(b.width))
  b.columns('Time', timeOf(new Date()))
  b.rule()
  // A full-width ruler shows immediately if the paper width is set wrong.
  b.line('123456789012345678901234567890123456789012345678'.slice(0, b.width))
  b.line()
  // Wrapped, not a fixed line: this caption is longer than 58mm paper is wide,
  // and a test page that wraps is exactly what it is meant to rule out.
  b.align('center').wrapped('If the ruler fits on one line, the width is right.')
  return b.cut().build()
}

const padQty = (value: string) => value.padEnd(6)

/** Payment mode as a customer would expect to read it. */
const titleCase = (value: string) => {
  // UPI is an initialism, not a word — "Upi" on a receipt looks like a typo.
  if (value.toLowerCase() === 'upi') return 'UPI'
  return value.charAt(0).toUpperCase() + value.slice(1).replace(/_/g, ' ')
}
