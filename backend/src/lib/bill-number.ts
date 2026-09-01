/**
 * Bill numbering: when the sequence resets, and how the number is printed.
 *
 * The period a bill belongs to is stored on the row, because the uniqueness
 * constraint is per period. With monthly reset, bill 47 recurs on many dates
 * within the month, so the date alone cannot key the sequence.
 */

export const RESET_PERIODS = ['daily', 'monthly', 'yearly', 'financial_year', 'never'] as const
export type ResetPeriod = (typeof RESET_PERIODS)[number]

export function isResetPeriod(value: string): value is ResetPeriod {
  return (RESET_PERIODS as readonly string[]).includes(value)
}

/**
 * The period key a business date belongs to.
 *
 * Stored on the bill and used for the unique constraint, so it must be stable:
 * the same date always maps to the same key.
 *
 * | Period           | Key for 2026-09-15 |
 * |------------------|--------------------|
 * | `daily`          | `2026-09-15`       |
 * | `monthly`        | `2026-09`          |
 * | `yearly`         | `2026`             |
 * | `financial_year` | `2026-27`          |
 * | `never`          | `all`              |
 */
export function periodKey(businessDate: string, period: ResetPeriod): string {
  const { year, month } = parseDate(businessDate)

  switch (period) {
    case 'daily':
      return businessDate
    case 'monthly':
      return `${year}-${pad(month, 2)}`
    case 'yearly':
      return String(year)
    case 'financial_year':
      return financialYearKey(year, month)
    case 'never':
      return 'all'
  }
}

/**
 * Indian financial year: April to March.
 *
 * A bill on 31 March 2027 belongs to 2026-27; one on 1 April 2027 starts
 * 2027-28. Getting this boundary wrong would restart the sequence a year late.
 */
function financialYearKey(year: number, month: number): string {
  const startYear = month >= 4 ? year : year - 1
  return `${startYear}-${pad((startYear + 1) % 100, 2)}`
}

/**
 * Formats a bill number for printing.
 *
 * The template is composed by the admin from tokens, so a restaurant can match
 * whatever series its accountant expects.
 *
 * | Token      | Meaning                        | Example    |
 * |------------|--------------------------------|------------|
 * | `{PREFIX}` | The `bill_prefix` setting      | `CE`       |
 * | `{NO}`     | The number, zero-padded        | `0042`     |
 * | `{YYYY}`   | Four-digit year                | `2026`     |
 * | `{YY}`     | Two-digit year                 | `26`       |
 * | `{MM}`     | Two-digit month                | `09`       |
 * | `{DD}`     | Two-digit day                  | `15`       |
 * | `{FY}`     | Financial year                 | `2026-27`  |
 *
 * Unknown tokens are left as written rather than silently dropped — a typo
 * should be visible on the bill, not invisible.
 */
export function formatBillNumber(options: {
  billNo: number
  businessDate: string
  template: string
  prefix: string
  padWidth: number
}): string {
  const { year, month, day } = parseDate(options.businessDate)

  const tokens: Record<string, string> = {
    PREFIX: options.prefix,
    NO: pad(options.billNo, options.padWidth),
    YYYY: String(year),
    YY: pad(year % 100, 2),
    MM: pad(month, 2),
    DD: pad(day, 2),
    FY: financialYearKey(year, month),
  }

  return options.template.replace(/\{([A-Z]+)\}/g, (match, token: string) =>
    token in tokens ? tokens[token]! : match,
  )
}

/** Rejects a template that would produce indistinguishable bill numbers. */
export function validateTemplate(template: string): { ok: true } | { ok: false; reason: string } {
  if (template.trim() === '') return { ok: false, reason: 'The format cannot be empty' }
  if (!template.includes('{NO}')) {
    // Without the number, every bill in a period prints the same string.
    return { ok: false, reason: 'The format must include {NO}' }
  }
  return { ok: true }
}

function parseDate(businessDate: string): { year: number; month: number; day: number } {
  const [y, m, d] = businessDate.split('-')
  const year = Number(y)
  const month = Number(m)
  const day = Number(d)

  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) {
    throw new Error(`Invalid business date: ${businessDate}`)
  }
  return { year, month, day }
}

function pad(value: number, width: number): string {
  return String(value).padStart(width, '0')
}
