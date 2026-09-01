import {
  formatBillNumber,
  isResetPeriod,
  periodKey,
  validateTemplate,
} from '../src/lib/bill-number.js'
import { test, assertEqual } from './helpers.js'

// --- period keys ---

test('daily reset keys on the date', () => {
  assertEqual(periodKey('2026-09-15', 'daily'), '2026-09-15')
  assertEqual(periodKey('2026-09-16', 'daily'), '2026-09-16')
})

test('monthly reset keys on the month', () => {
  assertEqual(periodKey('2026-09-01', 'monthly'), '2026-09')
  assertEqual(periodKey('2026-09-30', 'monthly'), '2026-09')
  assertEqual(periodKey('2026-10-01', 'monthly'), '2026-10')
})

test('yearly reset keys on the calendar year', () => {
  assertEqual(periodKey('2026-01-01', 'yearly'), '2026')
  assertEqual(periodKey('2026-12-31', 'yearly'), '2026')
  assertEqual(periodKey('2027-01-01', 'yearly'), '2027')
})

test('financial year runs April to March', () => {
  // Getting this boundary wrong restarts the sequence a year late.
  assertEqual(periodKey('2026-04-01', 'financial_year'), '2026-27', 'first day of FY')
  assertEqual(periodKey('2026-12-31', 'financial_year'), '2026-27')
  assertEqual(periodKey('2027-03-31', 'financial_year'), '2026-27', 'last day of FY')
  assertEqual(periodKey('2027-04-01', 'financial_year'), '2027-28', 'next FY starts')
})

test('financial year handles a January date correctly', () => {
  // January belongs to the FY that started the previous April.
  assertEqual(periodKey('2027-01-15', 'financial_year'), '2026-27')
})

test('financial year rolls the two-digit suffix across a century', () => {
  assertEqual(periodKey('2099-05-01', 'financial_year'), '2099-00')
})

test('never reset uses a single key', () => {
  assertEqual(periodKey('2026-09-15', 'never'), 'all')
  assertEqual(periodKey('2030-01-01', 'never'), 'all', 'the same key years later')
})

test('reset periods are recognised', () => {
  assertEqual(isResetPeriod('daily'), true)
  assertEqual(isResetPeriod('financial_year'), true)
  assertEqual(isResetPeriod('weekly'), false)
})

// --- formatting ---

const format = (template: string, billNo = 42, businessDate = '2026-09-15') =>
  formatBillNumber({ billNo, businessDate, template, prefix: 'CE', padWidth: 4 })

test('a plain number is padded', () => {
  assertEqual(format('{NO}'), '0042')
})

test('prefix and number combine', () => {
  assertEqual(format('{PREFIX}-{NO}'), 'CE-0042')
})

test('year tokens render both widths', () => {
  assertEqual(format('{YYYY}/{NO}'), '2026/0042')
  assertEqual(format('{YY}/{NO}'), '26/0042')
})

test('month and day tokens are zero-padded', () => {
  assertEqual(format('{DD}{MM}-{NO}', 42, '2026-09-05'), '0509-0042')
})

test('the financial year token renders', () => {
  assertEqual(format('{PREFIX}/{FY}/{NO}'), 'CE/2026-27/0042')
  assertEqual(format('{FY}/{NO}', 42, '2027-03-31'), '2026-27/0042')
})

test('a template can mix any tokens with free text', () => {
  assertEqual(format('INV-{YY}{MM}-{NO}'), 'INV-2609-0042')
})

test('an unknown token is left visible rather than silently dropped', () => {
  // A typo should show on the bill, not vanish.
  assertEqual(format('{PREFIX}-{NOPE}-{NO}'), 'CE-{NOPE}-0042')
})

test('padding widens but never truncates', () => {
  assertEqual(
    formatBillNumber({
      billNo: 123_456,
      businessDate: '2026-09-15',
      template: '{NO}',
      prefix: '',
      padWidth: 4,
    }),
    '123456',
    'a number longer than the pad width is not cut',
  )
})

test('an empty prefix leaves no stray separator handling to the template', () => {
  assertEqual(
    formatBillNumber({
      billNo: 7,
      businessDate: '2026-09-15',
      template: '{PREFIX}{NO}',
      prefix: '',
      padWidth: 3,
    }),
    '007',
  )
})

// --- template validation ---

test('a template without the number is rejected', () => {
  // Every bill in the period would print the same string.
  const result = validateTemplate('{PREFIX}-{YYYY}')
  assertEqual(result.ok, false)
})

test('an empty template is rejected', () => {
  assertEqual(validateTemplate('').ok, false)
  assertEqual(validateTemplate('   ').ok, false)
})

test('a valid template is accepted', () => {
  assertEqual(validateTemplate('{NO}').ok, true)
  assertEqual(validateTemplate('{PREFIX}/{FY}/{NO}').ok, true)
})
