import { z } from 'zod'
import type { Db } from '../db/client.js'
import { RESET_PERIODS } from './bill-number.js'

/**
 * Settings are key-value, so values arrive as strings and are parsed on read.
 * The trade-off for not needing a migration per setting is that validation has
 * to live here.
 */
const parsers = {
  /** Whether GST applies at all. Off for a restaurant below the threshold. */
  gst_enabled: z.enum(['0', '1']).transform((v) => v === '1'),
  tax_mode: z.enum(['inclusive', 'exclusive']),
  default_tax_rate: z.coerce.number().int().min(0),
  business_day_start: z.string().regex(/^\d{2}:\d{2}$/),
  bill_prefix: z.string(),
  bill_reset_period: z.enum(RESET_PERIODS),
  /** Composed from tokens: {PREFIX} {NO} {YYYY} {YY} {MM} {DD} {FY} */
  bill_number_format: z.string().min(1),
  bill_number_pad: z.coerce.number().int().min(1).max(10),
  bill_footer: z.string(),
  round_off_enabled: z.enum(['0', '1']).transform((v) => v === '1'),
} as const

export type SettingKey = keyof typeof parsers
export type SettingValue<K extends SettingKey> = z.infer<(typeof parsers)[K]>

const fallbacks: { [K in SettingKey]: SettingValue<K> } = {
  // On by default: a registered restaurant that forgot to set it must not
  // silently under-charge tax, which is the expensive direction to be wrong.
  gst_enabled: true,
  tax_mode: 'inclusive',
  default_tax_rate: 500, // 5% in basis points
  business_day_start: '05:00',
  bill_prefix: '',
  bill_reset_period: 'daily',
  bill_number_format: '{NO}',
  bill_number_pad: 4,
  bill_footer: '',
  round_off_enabled: true,
}

/**
 * Reads a setting, falling back to a sane default rather than throwing.
 *
 * A missing or corrupt setting must not stop billing — the restaurant would
 * rather bill at the default rate than not at all.
 */
export function getSetting<K extends SettingKey>(
  db: Db,
  branchId: string,
  key: K,
): SettingValue<K> {
  const row = db
    .prepare('SELECT value FROM settings WHERE branch_id = ? AND key = ?')
    .get(branchId, key) as { value: string } | undefined

  if (!row) return fallbacks[key]

  const parsed = parsers[key].safeParse(row.value)
  return parsed.success ? (parsed.data as SettingValue<K>) : fallbacks[key]
}

export function setSetting<K extends SettingKey>(
  db: Db,
  branchId: string,
  key: K,
  value: string,
): void {
  const now = new Date().toISOString()
  db.prepare(
    `INSERT INTO settings (branch_id, key, value, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (branch_id, key)
     DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at, synced_at = NULL`,
  ).run(branchId, key, value, now, now)
}
