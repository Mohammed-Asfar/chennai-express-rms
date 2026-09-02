import { z } from 'zod'

/**
 * Shared Zod pieces for request bodies.
 */

/**
 * A required string that cannot be only whitespace.
 *
 * `z.string().min(1).trim()` does not do this: the checks run in order, so
 * `"   "` satisfies `min(1)` and is only then trimmed to `""`. That is how a
 * bill gets voided with a blank reason, or a menu item saved with no name —
 * the field looks filled to the validator and is empty in the database.
 *
 * Trimming first makes the length check mean what it reads as.
 */
export function requiredText(max: number): z.ZodString {
  return z.string().trim().min(1).max(max)
}

/**
 * An optional string, trimmed before it is measured.
 *
 * Only the length rule differs from `requiredText` — an absent value is still
 * absent, and a whitespace-only one becomes `''` rather than being rejected,
 * since the caller decides whether empty means "clear it".
 */
export function optionalText(max: number): z.ZodString {
  return z.string().trim().max(max)
}
