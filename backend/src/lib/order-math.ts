import { extractInclusiveTax, taxOn } from './money.js'

export type TaxMode = 'inclusive' | 'exclusive'

export interface LineInput {
  /** Snapshot price, in paise. */
  unitPrice: number
  /** Snapshot rate, in basis points. 5% = 500. */
  taxRate: number
  qty: number
}

export interface LineAmounts {
  /** Taxable base. */
  base: number
  tax: number
  /** What the customer pays for this line. */
  total: number
}

/**
 * Amounts for a single order line, before any bill-level discount.
 *
 * Rounds once, at the line — never on a running total. All arithmetic is integer
 * paise; see CLAUDE.md section 2.
 */
export function lineAmounts(line: LineInput, taxMode: TaxMode): LineAmounts {
  if (!Number.isInteger(line.unitPrice) || !Number.isInteger(line.taxRate)) {
    throw new Error('lineAmounts: price and rate must be integers (paise / basis points)')
  }
  if (!Number.isInteger(line.qty) || line.qty <= 0) {
    throw new Error('lineAmounts: quantity must be a positive integer')
  }

  if (taxMode === 'exclusive') {
    const base = line.unitPrice * line.qty
    const tax = taxOn(base, line.taxRate)
    return { base, tax, total: base + tax }
  }

  // Inclusive: the menu price already contains the tax, so extract it backwards.
  // `tax` is the remainder, which guarantees base + tax equals the printed price.
  const gross = line.unitPrice * line.qty
  const { base, tax } = extractInclusiveTax(gross, line.taxRate)
  return { base, tax, total: gross }
}

/** Sum of what the customer pays across lines, before a bill-level discount. */
export function orderTotal(lines: LineAmounts[]): number {
  return lines.reduce((sum, line) => sum + line.total, 0)
}

/** Sum of taxable bases. */
export function orderSubtotal(lines: LineAmounts[]): number {
  return lines.reduce((sum, line) => sum + line.base, 0)
}

/** Sum of tax across lines. */
export function orderTax(lines: LineAmounts[]): number {
  return lines.reduce((sum, line) => sum + line.tax, 0)
}
