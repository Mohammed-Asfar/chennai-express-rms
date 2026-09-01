import { computeBill, type BillInput } from '../src/lib/bill-math.js'
import { test, assertEqual, assertThrows } from './helpers.js'

const bill = (overrides: Partial<BillInput>): BillInput => ({
  lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }],
  taxMode: 'exclusive',
  discountType: 'none',
  discountValue: 0,
  roundOff: false,
  ...overrides,
})

// --- exclusive tax ---

test('exclusive: tax is added on top', () => {
  const result = computeBill(bill({ lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }] }))
  assertEqual(result.subtotal, 10_000)
  assertEqual(result.cgst, 250)
  assertEqual(result.sgst, 250)
  assertEqual(result.total, 10_500, 'Rs100 + 5% = Rs105')
})

test('exclusive: divides by 10000, not 100', () => {
  // The 100x bug: Rs100 at 5% is Rs5 of tax, not Rs500.
  const result = computeBill(bill({ lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }] }))
  assertEqual(result.cgst + result.sgst, 500, 'Rs5.00 in paise')
})

test('exclusive: several lines and quantities', () => {
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 32_000, taxRate: 500, qty: 2 },
        { unitPrice: 2_000, taxRate: 500, qty: 3 },
      ],
    }),
  )
  assertEqual(result.subtotal, 70_000)
  assertEqual(result.cgst + result.sgst, 3_500)
  assertEqual(result.total, 73_500)
})

// --- inclusive tax ---

test('inclusive: tax is extracted from the price', () => {
  const result = computeBill(
    bill({ taxMode: 'inclusive', lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }] }),
  )
  assertEqual(result.subtotal, 9_524)
  assertEqual(result.cgst + result.sgst, 476)
  assertEqual(result.total, 10_000, 'the customer pays the menu price')
})

test('inclusive: the parts always sum to what is charged', () => {
  // The property that must never break: if the customer sees Rs100, the
  // components add to exactly Rs100.
  for (let price = 9_950; price <= 10_050; price++) {
    for (const rate of [0, 250, 500, 1_200, 1_800]) {
      for (const qty of [1, 3]) {
        const result = computeBill(
          bill({ taxMode: 'inclusive', lines: [{ unitPrice: price, taxRate: rate, qty }] }),
        )
        assertEqual(
          result.subtotal + result.cgst + result.sgst,
          result.total,
          `price=${price} rate=${rate} qty=${qty}`,
        )
      }
    }
  }
})

// --- discount before tax ---

test('tax is computed after the discount, never before', () => {
  // Taxing the pre-discount amount charges GST on money nobody pays.
  const result = computeBill(
    bill({
      lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }],
      discountType: 'fixed',
      discountValue: 1_000,
    }),
  )
  assertEqual(result.discountAmount, 1_000)
  assertEqual(result.subtotal, 9_000, 'taxable base is the discounted amount')
  assertEqual(result.cgst + result.sgst, 450, '5% of Rs90, not Rs100')
  assertEqual(result.total, 9_450)
})

test('a percentage discount uses basis points', () => {
  const result = computeBill(
    bill({
      lines: [{ unitPrice: 60_000, taxRate: 500, qty: 1 }],
      discountType: 'percent',
      discountValue: 1_000, // 10%
    }),
  )
  assertEqual(result.discountAmount, 6_000)
  assertEqual(result.subtotal, 54_000)
})

test('a distributed discount sums back exactly', () => {
  // A Rs100 discount over three equal lines must not become Rs99.99.
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 10_000, taxRate: 500, qty: 1 },
        { unitPrice: 10_000, taxRate: 500, qty: 1 },
        { unitPrice: 10_000, taxRate: 500, qty: 1 },
      ],
      discountType: 'fixed',
      discountValue: 10_000,
    }),
  )
  const distributed = result.lines.reduce((sum, line) => sum + line.discount, 0)
  assertEqual(distributed, result.discountAmount)
})

test('an awkward discount split still sums back exactly', () => {
  for (const discount of [1, 7, 333, 999, 12_345]) {
    const result = computeBill(
      bill({
        lines: [
          { unitPrice: 12_300, taxRate: 500, qty: 1 },
          { unitPrice: 45_600, taxRate: 500, qty: 1 },
          { unitPrice: 78_900, taxRate: 500, qty: 1 },
        ],
        discountType: 'fixed',
        discountValue: discount,
      }),
    )
    const distributed = result.lines.reduce((sum, line) => sum + line.discount, 0)
    assertEqual(distributed, discount, `discount=${discount}`)
  }
})

test('a discount larger than the bill is rejected', () => {
  assertThrows(() =>
    computeBill(
      bill({
        lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }],
        discountType: 'fixed',
        discountValue: 20_000,
      }),
    ),
  )
})

test('a 100% discount is allowed and produces a zero total', () => {
  const result = computeBill(
    bill({
      lines: [{ unitPrice: 10_000, taxRate: 500, qty: 1 }],
      discountType: 'percent',
      discountValue: 10_000, // 100%
    }),
  )
  assertEqual(result.subtotal, 0)
  assertEqual(result.total, 0)
})

// --- CGST / SGST split ---

test('cgst plus sgst always equals the tax', () => {
  for (let price = 1; price <= 400; price++) {
    const result = computeBill(bill({ lines: [{ unitPrice: price, taxRate: 500, qty: 1 }] }))
    const groupTax = result.taxBreakdown.reduce((sum, g) => sum + g.tax, 0)
    assertEqual(result.cgst + result.sgst, groupTax, `price=${price}`)
    if (Math.abs(result.cgst - result.sgst) > 1) {
      throw new Error(`halves differ by more than a paisa at price=${price}`)
    }
  }
})

test('grouping before splitting avoids per-line drift', () => {
  // Three lines each taxed 7 paise. Splitting per line and summing gives
  // cgst=12 sgst=9 - a 3 paisa gap. Grouping first gives 10 and 11.
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 140, taxRate: 500, qty: 1 },
        { unitPrice: 140, taxRate: 500, qty: 1 },
        { unitPrice: 140, taxRate: 500, qty: 1 },
      ],
    }),
  )
  const totalTax = result.cgst + result.sgst
  assertEqual(result.cgst, Math.floor(totalTax / 2))
  assertEqual(result.sgst, totalTax - result.cgst)
  if (Math.abs(result.cgst - result.sgst) > 1) throw new Error('halves drifted')
})

// --- mixed rates ---

test('a bill can carry several tax rates, grouped for the printout', () => {
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 60_000, taxRate: 500, qty: 1 },
        { unitPrice: 20_000, taxRate: 1_800, qty: 1 },
        { unitPrice: 10_000, taxRate: 500, qty: 1 },
      ],
    }),
  )

  assertEqual(result.taxBreakdown.length, 2, 'one group per rate')
  const five = result.taxBreakdown.find((g) => g.rate === 500)!
  const eighteen = result.taxBreakdown.find((g) => g.rate === 1_800)!

  assertEqual(five.base, 70_000)
  assertEqual(five.tax, 3_500)
  assertEqual(eighteen.base, 20_000)
  assertEqual(eighteen.tax, 3_600)
  assertEqual(result.cgst + result.sgst, 7_100)
})

test('the rate breakdown sums to the bill totals', () => {
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 33_333, taxRate: 500, qty: 3 },
        { unitPrice: 12_345, taxRate: 1_200, qty: 2 },
        { unitPrice: 9_999, taxRate: 1_800, qty: 7 },
      ],
      discountType: 'percent',
      discountValue: 750,
    }),
  )
  assertEqual(
    result.taxBreakdown.reduce((sum, g) => sum + g.base, 0),
    result.subtotal,
  )
  assertEqual(
    result.taxBreakdown.reduce((sum, g) => sum + g.cgst, 0),
    result.cgst,
  )
  assertEqual(
    result.taxBreakdown.reduce((sum, g) => sum + g.sgst, 0),
    result.sgst,
  )
})

// --- round off ---

test('round off adjusts to the nearest rupee', () => {
  const result = computeBill(
    bill({ lines: [{ unitPrice: 10_049, taxRate: 0, qty: 1 }], roundOff: true }),
  )
  assertEqual(result.roundOff, -49)
  assertEqual(result.total, 10_000)
  assertEqual(result.total % 100, 0)
})

test('round off can be positive', () => {
  const result = computeBill(
    bill({ lines: [{ unitPrice: 10_051, taxRate: 0, qty: 1 }], roundOff: true }),
  )
  assertEqual(result.roundOff, 49)
  assertEqual(result.total, 10_100)
})

test('round off leaves a whole rupee alone', () => {
  const result = computeBill(
    bill({ lines: [{ unitPrice: 10_000, taxRate: 0, qty: 1 }], roundOff: true }),
  )
  assertEqual(result.roundOff, 0)
})

test('a rounded total always lands on a whole rupee', () => {
  for (let price = 45_000; price <= 45_200; price++) {
    const result = computeBill(
      bill({ lines: [{ unitPrice: price, taxRate: 500, qty: 1 }], roundOff: true }),
    )
    assertEqual(result.total % 100, 0, `price=${price}`)
  }
})

test('round off is not applied when disabled', () => {
  const result = computeBill(
    bill({ lines: [{ unitPrice: 10_049, taxRate: 0, qty: 1 }], roundOff: false }),
  )
  assertEqual(result.roundOff, 0)
  assertEqual(result.total, 10_049)
})

// --- edge cases ---

test('an order with no items cannot be billed', () => {
  assertThrows(() => computeBill(bill({ lines: [] })))
})

test('a zero-priced item is allowed and taxed nothing', () => {
  const result = computeBill(
    bill({
      lines: [
        { unitPrice: 0, taxRate: 500, qty: 1 },
        { unitPrice: 10_000, taxRate: 500, qty: 1 },
      ],
    }),
  )
  assertEqual(result.subtotal, 10_000)
  assertEqual(result.cgst + result.sgst, 500)
})

test('a zero tax rate produces no tax', () => {
  const result = computeBill(bill({ lines: [{ unitPrice: 10_000, taxRate: 0, qty: 1 }] }))
  assertEqual(result.cgst, 0)
  assertEqual(result.sgst, 0)
  assertEqual(result.total, 10_000)
})

test('non-integer money is rejected', () => {
  assertThrows(() => computeBill(bill({ lines: [{ unitPrice: 100.5, taxRate: 500, qty: 1 }] })))
  assertThrows(() => computeBill(bill({ lines: [{ unitPrice: 100, taxRate: 5.5, qty: 1 }] })))
})

test('a zero or negative quantity is rejected', () => {
  assertThrows(() => computeBill(bill({ lines: [{ unitPrice: 100, taxRate: 500, qty: 0 }] })))
  assertThrows(() => computeBill(bill({ lines: [{ unitPrice: 100, taxRate: 500, qty: -2 }] })))
})

// --- a realistic bill, end to end ---

test('a full bill: mixed rates, 10% discount, inclusive, rounded', () => {
  const result = computeBill({
    lines: [
      { unitPrice: 32_000, taxRate: 500, qty: 2 }, // biryani
      { unitPrice: 2_000, taxRate: 500, qty: 3 }, // tea
      { unitPrice: 4_000, taxRate: 1_800, qty: 1 }, // bottled water
    ],
    taxMode: 'inclusive',
    discountType: 'percent',
    discountValue: 1_000,
    roundOff: true,
  })

  const gross = 64_000 + 6_000 + 4_000
  assertEqual(result.discountAmount, 7_400, '10% of Rs740')

  // Inclusive: the total is what is charged after discount, then rounded.
  assertEqual(result.total % 100, 0, 'rounded to a whole rupee')
  assertEqual(result.subtotal + result.cgst + result.sgst + result.roundOff, result.total)

  const distributed = result.lines.reduce((sum, line) => sum + line.discount, 0)
  assertEqual(distributed, result.discountAmount)
  assertEqual(result.lines.reduce((sum, line) => sum + line.gross, 0), gross)
})
