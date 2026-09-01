import { businessDateFor } from '../src/lib/business-date.js'
import { lineAmounts } from '../src/lib/order-math.js'
import { test, assertEqual, assertThrows } from './helpers.js'

/** Local-time date, so the cutoff means "5 AM here", not 5 AM UTC. */
const at = (y: number, m: number, d: number, h: number, min = 0) =>
  new Date(y, m - 1, d, h, min, 0)

// --- business date ---

test('an evening sale belongs to the same calendar day', () => {
  assertEqual(businessDateFor(at(2026, 9, 1, 20, 30), '05:00'), '2026-09-01')
})

test('a 1 AM sale belongs to the previous trading day', () => {
  // The whole point: one night's service must not split across two report days.
  assertEqual(businessDateFor(at(2026, 9, 2, 1, 0), '05:00'), '2026-09-01')
})

test('a sale exactly at the cutoff starts the new day', () => {
  assertEqual(businessDateFor(at(2026, 9, 2, 5, 0), '05:00'), '2026-09-02')
})

test('a sale one minute before the cutoff is still the previous day', () => {
  assertEqual(businessDateFor(at(2026, 9, 2, 4, 59), '05:00'), '2026-09-01')
})

test('the cutoff can include minutes', () => {
  assertEqual(businessDateFor(at(2026, 9, 2, 4, 29), '04:30'), '2026-09-01')
  assertEqual(businessDateFor(at(2026, 9, 2, 4, 30), '04:30'), '2026-09-02')
})

test('a midnight cutoff makes the business day the calendar day', () => {
  assertEqual(businessDateFor(at(2026, 9, 2, 0, 1), '00:00'), '2026-09-02')
})

test('crossing a month boundary rolls back correctly', () => {
  assertEqual(businessDateFor(at(2026, 10, 1, 2, 0), '05:00'), '2026-09-30')
})

test('crossing a year boundary rolls back correctly', () => {
  assertEqual(businessDateFor(at(2027, 1, 1, 3, 0), '05:00'), '2026-12-31')
})

test('a leap day is handled', () => {
  assertEqual(businessDateFor(at(2028, 3, 1, 2, 0), '05:00'), '2028-02-29')
})

// --- line amounts ---

test('exclusive tax adds on top of the line', () => {
  const result = lineAmounts({ unitPrice: 10_000, taxRate: 500, qty: 3 }, 'exclusive')
  assertEqual(result.base, 30_000)
  assertEqual(result.tax, 1_500)
  assertEqual(result.total, 31_500)
})

test('inclusive tax is extracted from the line', () => {
  const result = lineAmounts({ unitPrice: 10_000, taxRate: 500, qty: 1 }, 'inclusive')
  assertEqual(result.base, 9_524)
  assertEqual(result.tax, 476)
  assertEqual(result.total, 10_000, 'the customer pays exactly the menu price')
})

test('inclusive base plus tax always equals the printed price', () => {
  for (let price = 9_990; price <= 10_010; price++) {
    for (const rate of [0, 250, 500, 1_200, 1_800]) {
      for (const qty of [1, 3, 7]) {
        const result = lineAmounts({ unitPrice: price, taxRate: rate, qty }, 'inclusive')
        assertEqual(
          result.base + result.tax,
          result.total,
          `price=${price} rate=${rate} qty=${qty}`,
        )
      }
    }
  }
})

test('a zero-priced item produces no tax', () => {
  const result = lineAmounts({ unitPrice: 0, taxRate: 500, qty: 2 }, 'exclusive')
  assertEqual(result.base, 0)
  assertEqual(result.tax, 0)
  assertEqual(result.total, 0)
})

test('a zero tax rate leaves the whole amount as base', () => {
  const result = lineAmounts({ unitPrice: 10_000, taxRate: 0, qty: 1 }, 'inclusive')
  assertEqual(result.base, 10_000)
  assertEqual(result.tax, 0)
})

test('non-integer money is rejected', () => {
  // A float here is how rounding drift enters the system.
  assertThrows(() => lineAmounts({ unitPrice: 100.5, taxRate: 500, qty: 1 }, 'exclusive'))
  assertThrows(() => lineAmounts({ unitPrice: 100, taxRate: 5.5, qty: 1 }, 'exclusive'))
})

test('a zero or negative quantity is rejected', () => {
  assertThrows(() => lineAmounts({ unitPrice: 100, taxRate: 500, qty: 0 }, 'exclusive'))
  assertThrows(() => lineAmounts({ unitPrice: 100, taxRate: 500, qty: -1 }, 'exclusive'))
})
