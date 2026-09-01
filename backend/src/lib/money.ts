/**
 * Money is integer paise. Rates are integer basis points (5% = 500).
 *
 * Nothing in this file returns a float. Floats reintroduce the rounding drift
 * that integer money exists to prevent — see CLAUDE.md section 2.
 */

/** Round half away from zero, on integers only. */
function divRound(numerator: number, denominator: number): number {
  if (denominator === 0) throw new Error('divRound: division by zero')
  const sign = numerator < 0 !== denominator < 0 ? -1 : 1
  const n = Math.abs(numerator)
  const d = Math.abs(denominator)
  return sign * Math.floor((n * 2 + d) / (2 * d))
}

/** Rupees (as typed by a user) to paise. `450.50` -> `45050`. */
export function toPaise(rupees: number | string): number {
  const value = typeof rupees === 'string' ? Number(rupees) : rupees
  if (!Number.isFinite(value)) throw new Error(`toPaise: not a number: ${rupees}`)
  return Math.round(value * 100)
}

/** Paise to a display string. `45050` -> `"450.50"`. Never used for arithmetic. */
export function formatMoney(paise: number): string {
  assertInt(paise, 'formatMoney')
  const sign = paise < 0 ? '-' : ''
  const abs = Math.abs(paise)
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`
}

/** Percent to basis points. `5` -> `500`, `2.5` -> `250`. */
export function toBasisPoints(percent: number | string): number {
  const value = typeof percent === 'string' ? Number(percent) : percent
  if (!Number.isFinite(value)) throw new Error(`toBasisPoints: not a number: ${percent}`)
  return Math.round(value * 100)
}

/** Basis points to a display string. `500` -> `"5"`, `250` -> `"2.5"`. */
export function formatRate(basisPoints: number): string {
  assertInt(basisPoints, 'formatRate')
  const whole = Math.floor(basisPoints / 100)
  const frac = basisPoints % 100
  if (frac === 0) return String(whole)
  return `${whole}.${String(frac).padStart(2, '0').replace(/0+$/, '')}`
}

/**
 * Tax on an amount at a basis-point rate.
 * Divides by 10000, not 100 — basis points carry two extra digits.
 */
export function taxOn(amountPaise: number, rateBasisPoints: number): number {
  assertInt(amountPaise, 'taxOn amount')
  assertInt(rateBasisPoints, 'taxOn rate')
  if (rateBasisPoints < 0) throw new Error('taxOn: negative rate')
  return divRound(amountPaise * rateBasisPoints, 10_000)
}

/**
 * Extract the tax already contained in a tax-inclusive amount.
 * Returns base and tax such that `base + tax === grossPaise` exactly.
 */
export function extractInclusiveTax(
  grossPaise: number,
  rateBasisPoints: number,
): { base: number; tax: number } {
  assertInt(grossPaise, 'extractInclusiveTax gross')
  assertInt(rateBasisPoints, 'extractInclusiveTax rate')
  if (rateBasisPoints < 0) throw new Error('extractInclusiveTax: negative rate')
  const base = divRound(grossPaise * 10_000, 10_000 + rateBasisPoints)
  return { base, tax: grossPaise - base }
}

/**
 * Split a tax amount into CGST and SGST.
 * The second half is the remainder, never a second rounding — two independent
 * roundings of 2.5% can differ from one rounding of 5% by a paisa.
 */
export function splitGst(taxPaise: number): { cgst: number; sgst: number } {
  assertInt(taxPaise, 'splitGst')
  const cgst = Math.floor(taxPaise / 2)
  return { cgst, sgst: taxPaise - cgst }
}

/**
 * Distribute a total proportionally across weights.
 * The last non-zero share absorbs the remainder so the parts sum to `total` exactly.
 */
export function distribute(total: number, weights: readonly number[]): number[] {
  assertInt(total, 'distribute total')
  if (weights.length === 0) return []
  const sum = weights.reduce((a, b) => a + b, 0)
  if (sum === 0) return weights.map(() => 0)

  const shares = weights.map((w) => divRound(total * w, sum))
  const allocated = shares.reduce((a, b) => a + b, 0)
  let remainder = total - allocated

  // Give the remainder to the last line with a non-zero weight.
  for (let i = shares.length - 1; i >= 0 && remainder !== 0; i--) {
    if (weights[i] !== 0) {
      shares[i] = shares[i]! + remainder
      remainder = 0
    }
  }
  return shares
}

/** Round-off to the nearest rupee. Returns the signed adjustment, not the total. */
export function roundOffToRupee(totalPaise: number): number {
  assertInt(totalPaise, 'roundOffToRupee')
  return divRound(totalPaise, 100) * 100 - totalPaise
}

function assertInt(value: number, label: string): void {
  if (!Number.isInteger(value)) {
    throw new Error(`${label}: expected an integer (paise/basis points), got ${value}`)
  }
}
