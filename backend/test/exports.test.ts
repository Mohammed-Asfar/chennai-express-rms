import { toCsv, rupees } from '../src/lib/csv.js'
import { test, assertEqual } from './helpers.js'

// --- money crossing the boundary ---

test('paise become rupees with two decimals', () => {
  // The one place in the system where money stops being an integer. A column of
  // 45000 in a spreadsheet gets summed and reported as forty-five thousand
  // rupees, so the conversion has to happen before the file leaves.
  assertEqual(rupees(45_000), '450.00')
  assertEqual(rupees(19_500), '195.00')
  assertEqual(rupees(0), '0.00')
})

test('paise that are not whole rupees keep both digits', () => {
  // 7 paise is 0.07, not 0.7. Losing the leading zero would multiply a
  // reconciliation error by ten.
  assertEqual(rupees(7), '0.07')
  assertEqual(rupees(70), '0.70')
  assertEqual(rupees(1), '0.01')
  assertEqual(rupees(45_007), '450.07')
})

test('a negative amount keeps its sign', () => {
  // Round-off and reversals are both negative. `-0.50` must not come out as
  // `-1.-50` or `0.50`.
  assertEqual(rupees(-50), '-0.50')
  assertEqual(rupees(-45_000), '-450.00')
  assertEqual(rupees(-7), '-0.07')
})

test('the conversion never loses a paisa', () => {
  // Reading the column back must give the integer that went in. A float
  // anywhere in this path is how a day's takings end up a rupee out.
  for (const paise of [1, 7, 99, 100, 12_345, 99_999, 1_234_567]) {
    const text = rupees(paise)
    const back = Math.round(Number(text) * 100)
    assertEqual(back, paise, `${paise} survived the round trip`)
  }
})

// --- the file a spreadsheet opens ---

test('a field containing a comma is quoted', () => {
  const csv = toCsv(['Item'], [['Chilly Chicken, Dry']])
  if (!csv.includes('"Chilly Chicken, Dry"')) {
    throw new Error(`the comma broke the column: ${csv}`)
  }
})

test('a quote inside a field is doubled', () => {
  const csv = toCsv(['Notes'], [['Extra "hot"']])
  if (!csv.includes('"Extra ""hot"""')) throw new Error(`bad quoting: ${csv}`)
})

test('a field that looks like a formula is neutralised', () => {
  // A customer name is free text that reaches a spreadsheet. Excel and Sheets
  // both execute a leading = + - or @, so an export is a way to run something
  // on the accountant's machine unless the value is defused.
  const csv = toCsv(['Customer'], [['=1+1']])
  if (!csv.includes("'=1+1")) throw new Error(`formula not defused: ${csv}`)

  for (const dangerous of ['+A1', '-2+3', '@SUM(A1)']) {
    const out = toCsv(['X'], [[dangerous]])
    if (!out.includes(`'${dangerous}`)) throw new Error(`not defused: ${dangerous}`)
  }
})

test('a negative money value is not mistaken for a formula', () => {
  // rupees() produces "-0.50", which starts with a minus. Defusing it would
  // put an apostrophe in front of every refund and stop Excel summing the
  // column — the opposite of the point.
  const csv = toCsv(['Round off'], [[rupees(-50)]])
  if (csv.includes("'-0.50")) {
    throw new Error('a negative amount was quoted as text and will not sum')
  }
  if (!csv.includes('-0.50')) throw new Error(`the value is missing: ${csv}`)
})

test('the file carries a BOM and CRLF for Excel', () => {
  const csv = toCsv(['A'], [['1']])
  assertEqual(csv.charCodeAt(0), 0xfeff, 'a BOM, or Excel mangles a rupee sign')
  if (!csv.includes('\r\n')) throw new Error('Excel on Windows expects CRLF')
})

test('an empty value is an empty column, not the word null', () => {
  // A bill with no customer phone must leave the cell empty. "null" in a
  // spreadsheet column reads as a value someone then tries to explain.
  const csv = toCsv(['Phone', 'Total'], [[null, rupees(45_000)]])
  const dataLine = csv.replace('﻿', '').trim().split('\r\n')[1]
  assertEqual(dataLine, ',450.00', 'the phone column is blank, the total is not')
})
