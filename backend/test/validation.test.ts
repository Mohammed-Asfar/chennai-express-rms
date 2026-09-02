import { requiredText, optionalText } from '../src/lib/validation.js'
import { test, assertEqual } from './helpers.js'

test('a whitespace-only value is refused', () => {
  // z.string().min(1).trim() does not do this: the checks run in order, so
  // "   " satisfies min(1) and is only then trimmed to "". That is how a bill
  // gets voided with a blank reason.
  for (const value of ['', ' ', '   ', '\t', '\n  ']) {
    assertEqual(
      requiredText(64).safeParse(value).success,
      false,
      `accepted ${JSON.stringify(value)}`,
    )
  }
})

test('surrounding whitespace is trimmed off a real value', () => {
  const parsed = requiredText(64).parse('  Billed the wrong table  ')
  assertEqual(parsed, 'Billed the wrong table')
})

test('the length limit applies after trimming', () => {
  // Otherwise padding a value with spaces would push a legitimate entry over
  // the limit, or sneak an over-long one under it.
  const padded = `  ${'a'.repeat(64)}  `
  assertEqual(requiredText(64).safeParse(padded).success, true, 'fits once trimmed')
  assertEqual(requiredText(64).safeParse('a'.repeat(65)).success, false, 'genuinely too long')
})

test('an optional value may be empty but is still trimmed', () => {
  assertEqual(optionalText(64).parse('   '), '', 'whitespace collapses to empty')
  assertEqual(optionalText(64).parse('  note  '), 'note')
  assertEqual(optionalText(4).safeParse('toolong').success, false)
})
