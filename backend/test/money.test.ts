import {
  toPaise, formatMoney, toBasisPoints, formatRate,
  taxOn, extractInclusiveTax, splitGst, distribute, roundOffToRupee,
} from '../src/lib/money.js'
import { test, assertEqual, assertThrows } from './helpers.js'

// --- conversion at the boundary ---
test('toPaise converts rupees', () => {
  assertEqual(toPaise(450.5), 45050)
  assertEqual(toPaise('19.99'), 1999)
  assertEqual(toPaise(0), 0)
})

test('toPaise avoids float drift', () => {
  // 19.99 * 100 is 1998.9999... in IEEE 754; Math.round rescues it.
  assertEqual(toPaise(19.99), 1999)
  assertEqual(toPaise(0.1 + 0.2), 30)
})

test('formatMoney renders paise', () => {
  assertEqual(formatMoney(45050), '450.50')
  assertEqual(formatMoney(5), '0.05')
  assertEqual(formatMoney(0), '0.00')
  assertEqual(formatMoney(-1250), '-12.50')
})

test('formatMoney rejects a non-integer', () => {
  assertThrows(() => formatMoney(12.5))
})

test('rates convert to and from basis points', () => {
  assertEqual(toBasisPoints(5), 500)
  assertEqual(toBasisPoints(2.5), 250)
  assertEqual(toBasisPoints(18), 1800)
  assertEqual(formatRate(500), '5')
  assertEqual(formatRate(250), '2.5')
  assertEqual(formatRate(1800), '18')
})

// --- exclusive tax ---
test('taxOn divides by 10000, not 100', () => {
  // Rs100 at 5% is Rs5, not Rs500. This is the 100x bug.
  assertEqual(taxOn(10_000, 500), 500)
  assertEqual(taxOn(10_000, 1800), 1800)
  assertEqual(taxOn(0, 500), 0)
})

test('taxOn rounds half up', () => {
  assertEqual(taxOn(150, 500), 8) // 7.5 -> 8
})

test('taxOn rejects non-integers', () => {
  assertThrows(() => taxOn(100.5, 500))
  assertThrows(() => taxOn(100, 5.5))
})

// --- inclusive tax ---
test('extractInclusiveTax pulls tax out of a gross price', () => {
  const { base, tax } = extractInclusiveTax(10_000, 500)
  assertEqual(base, 9524)
  assertEqual(tax, 476) // Rs4.76 on a Rs100 tax-inclusive price
})

test('inclusive base + tax always equals the printed price', () => {
  // The property that must never break: if the customer sees Rs100, the
  // components add to exactly Rs100.
  for (let gross = 9900; gross <= 10_100; gross++) {
    for (const rate of [0, 250, 500, 1200, 1800, 2800]) {
      const { base, tax } = extractInclusiveTax(gross, rate)
      assertEqual(base + tax, gross, `gross=${gross} rate=${rate}`)
    }
  }
})

test('zero rate leaves the whole amount as base', () => {
  const { base, tax } = extractInclusiveTax(10_000, 0)
  assertEqual(base, 10_000)
  assertEqual(tax, 0)
})

// --- GST split ---
test('splitGst halves an even amount', () => {
  const { cgst, sgst } = splitGst(1000)
  assertEqual(cgst, 500)
  assertEqual(sgst, 500)
})

test('splitGst gives the odd paisa to SGST, never rounds twice', () => {
  const { cgst, sgst } = splitGst(7)
  assertEqual(cgst, 3)
  assertEqual(sgst, 4)
  assertEqual(cgst + sgst, 7)
})

test('cgst + sgst always equals the tax', () => {
  for (let tax = 0; tax <= 500; tax++) {
    const { cgst, sgst } = splitGst(tax)
    assertEqual(cgst + sgst, tax, `tax=${tax}`)
    if (Math.abs(cgst - sgst) > 1) throw new Error(`halves differ by more than 1 paisa at tax=${tax}`)
  }
})

// --- discount distribution ---
test('distribute splits proportionally', () => {
  assertEqual(distribute(6000, [30_000, 20_000, 10_000]).join(','), '3000,2000,1000')
})

test('distributed shares always sum back to the total', () => {
  // A Rs100 discount over three equal lines must not become Rs99.99.
  const cases: [number, number[]][] = [
    [10_000, [10_000, 10_000, 10_000]],
    [1, [1, 1, 1]],
    [777, [123, 456, 789]],
    [10_000, [1, 1, 1, 1, 1, 1, 1]],
    [333, [100, 200, 300, 400]],
  ]
  for (const [total, weights] of cases) {
    const shares = distribute(total, weights)
    assertEqual(shares.reduce((a, b) => a + b, 0), total, `weights=${weights.join('/')}`)
  }
})

test('distribute handles zero weights and empty input', () => {
  assertEqual(distribute(100, [0, 0]).join(','), '0,0')
  assertEqual(distribute(100, []).length, 0)
})

// --- round off ---
test('roundOffToRupee returns a signed adjustment', () => {
  assertEqual(roundOffToRupee(45_049), -49)
  assertEqual(roundOffToRupee(45_051), 49)
  assertEqual(roundOffToRupee(45_100), 0)
  assertEqual(roundOffToRupee(45_050), 50) // half rounds up
})

test('total plus round off lands on a whole rupee', () => {
  for (let total = 45_000; total <= 45_200; total++) {
    const adjusted = total + roundOffToRupee(total)
    assertEqual(adjusted % 100, 0, `total=${total}`)
  }
})

// --- an end-to-end bill, the way section 6.5 specifies ---
test('full bill: exclusive, 10% discount, mixed GST rates', () => {
  const lines = [
    { unit: 10_000, qty: 3, rate: 500 },
    { unit: 20_000, qty: 1, rate: 1800 },
    { unit: 5_000, qty: 2, rate: 500 },
  ]
  const bases = lines.map((l) => l.unit * l.qty)
  const subtotal = bases.reduce((a, b) => a + b, 0)
  assertEqual(subtotal, 60_000)

  // 1. discount first
  const discount = taxOn(subtotal, 1000) // 10% expressed as basis points
  assertEqual(discount, 6_000)
  const shares = distribute(discount, bases)
  assertEqual(shares.reduce((a, b) => a + b, 0), discount)

  // 2. tax on the discounted base
  const nets = bases.map((b, i) => b - shares[i]!)
  const taxes = nets.map((n, i) => taxOn(n, lines[i]!.rate))

  // 3. split per rate group, not per line
  const byRate = new Map<number, number>()
  taxes.forEach((t, i) => byRate.set(lines[i]!.rate, (byRate.get(lines[i]!.rate) ?? 0) + t))

  let cgst = 0
  let sgst = 0
  for (const groupTax of byRate.values()) {
    const split = splitGst(groupTax)
    cgst += split.cgst
    sgst += split.sgst
  }

  assertEqual(cgst + sgst, taxes.reduce((a, b) => a + b, 0), 'split must preserve total tax')

  const total = nets.reduce((a, b) => a + b, 0) + cgst + sgst
  assertEqual(total, 59_040) // Rs590.40
})

test('grouping before splitting avoids the per-line drift', () => {
  // Three lines each taxed 7 paise. Splitting per line and summing gives
  // cgst=12 sgst=9 -- a 3 paisa gap. Grouping first gives 10 and 11.
  const lineTaxes = [7, 7, 7]
  const grouped = splitGst(lineTaxes.reduce((a, b) => a + b, 0))
  assertEqual(grouped.cgst, 10)
  assertEqual(grouped.sgst, 11)
  if (Math.abs(grouped.cgst - grouped.sgst) > 1) throw new Error('halves drifted')
})
