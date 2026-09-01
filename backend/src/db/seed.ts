import { randomUUID } from 'node:crypto'
import type { Db } from './client.js'
import type { Env } from '../lib/env.js'
import { hashPassword } from '../lib/auth.js'

/**
 * Creates the branch, an admin account, a default section, and baseline settings
 * on first run. Idempotent — does nothing if a branch already exists.
 *
 * The seeded admin has `must_change_password` set: shipping a system whose default
 * password stays in place is how a restaurant PC ends up with a known login.
 */
export async function seedIfEmpty(db: Db, env: Env): Promise<{ seeded: boolean; branchId: string }> {
  const existing = db.prepare('SELECT id FROM branches LIMIT 1').get() as { id: string } | undefined
  if (existing) return { seeded: false, branchId: existing.id }

  const now = new Date().toISOString()
  const branchId = randomUUID()
  const userId = randomUUID()
  const sectionId = randomUUID()
  const passwordHash = await hashPassword(env.SEED_ADMIN_PASSWORD)

  db.transaction(() => {
    db.prepare(
      `INSERT INTO branches (id, name, print_logo, is_active, created_at, updated_at)
       VALUES (?, ?, 1, 1, ?, ?)`,
    ).run(branchId, env.SEED_BRANCH_NAME, now, now)

    db.prepare(
      `INSERT INTO users (id, branch_id, username, password_hash, full_name, role,
                          is_active, must_change_password, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'Administrator', 'admin', 1, 1, ?, ?)`,
    ).run(userId, branchId, env.SEED_ADMIN_USERNAME, passwordHash, now, now)

    // Tables must belong to a section, so one has to exist before any table can.
    db.prepare(
      `INSERT INTO sections (id, branch_id, name, sort_order, is_active, created_at, updated_at)
       VALUES (?, ?, 'Main', 0, 1, ?, ?)`,
    ).run(sectionId, branchId, now, now)

    const setting = db.prepare(
      `INSERT INTO settings (branch_id, key, value, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
    )
    const defaults: [string, string][] = [
      ['tax_mode', 'inclusive'],
      ['default_tax_rate', '500'], // 5% in basis points
      ['business_day_start', '05:00'],
      ['bill_prefix', ''],
      ['bill_footer', 'Thank you, visit again!'],
      ['round_off_enabled', '1'],
    ]
    for (const [key, value] of defaults) setting.run(branchId, key, value, now, now)
  })()

  return { seeded: true, branchId }
}
