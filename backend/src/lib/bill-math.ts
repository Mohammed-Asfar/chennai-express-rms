import { distribute, extractInclusiveTax, roundOffToRupee, splitGst, taxOn } from './money.js'
import type { TaxMode } from './order-math.js'

export type DiscountType = 'none' | 'fixed' | 'percent'

export interface BillLineInput {
  /** Snapshot price from the order line, in paise. */
  unitPrice: number
  /** Snapshot rate, in basis points. 5% = 500. */
  taxRate: number
  qty: number
}

export interface BillLineResult {
  /** Gross before discount — the menu amount for this line. */
  gross: number
  /** This line's share of a bill-level discount. */
  discount: number
  /** Taxable base after discount. */
  base: number
  tax: number
  /** What this line contributes to the total. */
  total: number
  taxRate: number
}

export interface TaxGroup {
  rate: number
  base: number
  tax: number
  cgst: number
  sgst: number
}

export interface BillInput {
  lines: BillLineInput[]
  taxMode: TaxMode
  discountType: DiscountType
  /** Paise when fixed, basis points when percent. */
  discountValue: number
  roundOff: boolean
}

export interface BillResult {
  lines: BillLineResult[]
  /** Sum of taxable bases, after discount. */
  subtotal: number
  discountAmount: number
  cgst: number
  sgst: number
  /** Signed adjustment to reach a whole rupee. */
  roundOff: number
  total: number
  /** Per-rate breakdown, for the GST-compliant printout. */
  taxBreakdown: TaxGroup[]
}

export class BillError extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
    this.name = 'BillError'
  }
}

/**
 * Computes a bill.
 *
 * Order of operations is fixed and must not be rearranged:
 *
 *   1. line gross from unit price x qty
 *   2. apply the discount, distributed proportionally
 *   3. compute tax on the DISCOUNTED amount
 *   4. split each rate group into CGST and SGST
 *   5. round off the total once, if enabled
 *
 * Taxing before the discount charges GST on money the customer never pays.
 * See CLAUDE.md section 2.
 */
export function computeBill(input: BillInput): BillResult {
  if (input.lines.length === 0) {
    throw new BillError('EMPTY_ORDER', 'An order with no items cannot be billed')
  }

  for (const line of input.lines) {
    if (!Number.isInteger(line.unitPrice) || !Number.isInteger(line.taxRate)) {
      throw new BillError('NON_INTEGER', 'Prices and rates must be integers')
    }
    if (!Number.isInteger(line.qty) || line.qty <= 0) {
      throw new BillError('INVALID_QTY', 'Quantity must be a positive integer')
    }
  }

  // 1. Line gross, before any discount.
  const gross = input.lines.map((line) => line.unitPrice * line.qty)
  const grossTotal = gross.reduce((sum, value) => sum + value, 0)

  // 2. Discount, resolved then distributed.
  const discountAmount = resolveDiscount(input, grossTotal)
  // Proportional shares; the last non-zero line absorbs the remainder so the
  // parts sum back to the discount exactly.
  const shares = distribute(discountAmount, gross)

  // 3. Tax, on the discounted amount.
  const lines: BillLineResult[] = input.lines.map((line, index) => {
    const lineGross = gross[index]!
    const discount = shares[index]!
    const net = lineGross - discount

    if (input.taxMode === 'exclusive') {
      const tax = taxOn(net, line.taxRate)
      return { gross: lineGross, discount, base: net, tax, total: net + tax, taxRate: line.taxRate }
    }

    // Inclusive: the price already contains the tax. `tax` is the remainder, so
    // base + tax always equals what the customer actually pays.
    const { base, tax } = extractInclusiveTax(net, line.taxRate)
    return { gross: lineGross, discount, base, tax, total: net, taxRate: line.taxRate }
  })

  // 4. Split per rate group, not per line. Halving each line and summing drifts:
  // three lines taxed 7 paise give 12 and 9 instead of 10 and 11.
  const taxBreakdown = groupByRate(lines)
  const cgst = taxBreakdown.reduce((sum, group) => sum + group.cgst, 0)
  const sgst = taxBreakdown.reduce((sum, group) => sum + group.sgst, 0)

  const subtotal = lines.reduce((sum, line) => sum + line.base, 0)
  const beforeRounding =
    input.taxMode === 'exclusive' ? subtotal + cgst + sgst : lines.reduce((s, l) => s + l.total, 0)

  // 5. Round once, at the total.
  const roundOff = input.roundOff ? roundOffToRupee(beforeRounding) : 0

  return {
    lines,
    subtotal,
    discountAmount,
    cgst,
    sgst,
    roundOff,
    total: beforeRounding + roundOff,
    taxBreakdown,
  }
}

function resolveDiscount(input: BillInput, grossTotal: number): number {
  if (input.discountType === 'none') return 0

  if (!Number.isInteger(input.discountValue) || input.discountValue < 0) {
    throw new BillError('INVALID_DISCOUNT', 'Discount must be a non-negative integer')
  }

  const amount =
    input.discountType === 'percent'
      ? taxOn(grossTotal, input.discountValue) // basis points, same /10000 maths
      : input.discountValue

  // A discount larger than the bill would produce a negative total.
  if (amount > grossTotal) {
    throw new BillError('DISCOUNT_TOO_LARGE', 'The discount cannot exceed the bill amount')
  }
  return amount
}

/**
 * Groups tax by rate and splits each group.
 *
 * GST requires the rate-wise breakdown on the printout when a bill carries more
 * than one rate.
 */
function groupByRate(lines: BillLineResult[]): TaxGroup[] {
  const groups = new Map<number, { base: number; tax: number }>()

  for (const line of lines) {
    const existing = groups.get(line.taxRate)
    if (existing) {
      existing.base += line.base
      existing.tax += line.tax
    } else {
      groups.set(line.taxRate, { base: line.base, tax: line.tax })
    }
  }

  return [...groups.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([rate, totals]) => {
      const { cgst, sgst } = splitGst(totals.tax)
      return { rate, base: totals.base, tax: totals.tax, cgst, sgst }
    })
}
