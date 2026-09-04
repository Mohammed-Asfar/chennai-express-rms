/**
 * CSV, written for a spreadsheet that will be opened by an accountant.
 *
 * Money is written in rupees with two decimals — not paise. Everywhere else in
 * this system money is an integer and converting early is a bug, but a CSV is
 * the boundary: the file exists to be read by a person and summed by Excel, and
 * a column of `45000` invites someone to total it and report the wrong figure.
 * The conversion happens here and nowhere else.
 */

/**
 * One field, escaped.
 *
 * Excel and Sheets both treat a leading `=`, `+`, `-` or `@` as the start of a
 * formula, so a customer named `=cmd|...` in a bill export becomes a live
 * formula in someone's spreadsheet. Prefixing with a single quote is the
 * standard defence and displays as the plain text it should be.
 */
function field(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return ''

  const text = String(value)

  // A negative number is not a formula. rupees() produces "-0.50" for a refund
  // or a round-off, and prefixing those would make Excel treat the column as
  // text — the whole point of the export is that it sums.
  const isNumber = /^-?\d+(\.\d+)?$/.test(text)
  const risky = !isNumber && /^[=+\-@\t\r]/.test(text)
  const escaped = risky ? `'${text}` : text

  if (/[",\n\r]/.test(escaped)) return `"${escaped.replace(/"/g, '""')}"`
  return escaped
}

/** Integer paise as a decimal string. The single conversion point. */
export function rupees(paise: number): string {
  const sign = paise < 0 ? '-' : ''
  const abs = Math.abs(paise)
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`
}

/**
 * A CSV document.
 *
 * `\r\n` line endings and a UTF-8 BOM, both because Excel on Windows wants
 * them: without the BOM a rupee sign or a dish name in Tamil arrives as
 * mojibake, and Excel is the program these files are opened in.
 */
export function toCsv(headers: string[], rows: (string | number | null)[][]): string {
  const lines = [headers.map(field).join(',')]
  for (const row of rows) lines.push(row.map(field).join(','))
  return `﻿${lines.join('\r\n')}\r\n`
}
