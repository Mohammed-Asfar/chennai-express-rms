/**
 * Seeds the printed menu.
 *
 *   node scripts/seed-menu.mjs --local --dry-run  # print what would be written
 *   node scripts/seed-menu.mjs --local            # write it to this PC's till
 *   node scripts/seed-menu.mjs --local --db PATH  # a specific database file
 *
 * Always the till, never the cloud: sync only pushes upward, so rows written
 * straight to Postgres never reach a till that already has a database. Writing
 * to SQLite and letting the sync worker carry it up is how menu data travels.
 *
 * Safe to re-run. Items the card no longer lists are retired — soft-deleted, so
 * the order lines and printed bills that reference them are untouched.
 *
 * Prices are integer paise, exactly as the rest of the system stores money:
 * the card's ₹140.00 is 14000. Nothing here is a float at any point.
 *
 * tax_rate is 0 on every item, as configured for this branch. The order lines
 * snapshot it when an item is added to an order, so changing it later affects
 * new orders only and never rewrites a printed bill.
 *
 * Idempotent. Rows carry deterministic UUIDs derived from the branch and the
 * item name, so running this twice updates rather than duplicating — a menu
 * seeded twice would otherwise show every dish twice on the till.
 *
 * synced_at is left NULL so the sync worker treats every row as pending and
 * pushes it on its next cycle.
 */

import { createHash } from 'node:crypto'

// loadEnv is imported lazily, inside the cloud path only. It is TypeScript, so a
// static import forces the whole script to run under tsx — and --local needs
// nothing from it. Importing it there keeps `node scripts/seed-menu.mjs --local`
// working with a plain runtime.

// The card itself lives in menu-data.mjs: this file is the mechanism, that one
// is the content. Re-pricing a menu should not mean reading past 200 lines of
// transaction handling to find the number.
import { MENU } from './menu-data.mjs'

const TAX_RATE = 0

/** Rupees to paise, at the boundary. */
function toPaise(rupees) {
  return Math.round(rupees * 100)
}

/**
 * The portions an entry offers, as `[name, rupees]` pairs.
 *
 * A bare number means one portion, named "Regular" — most of the card. An array
 * means the dish is sold in sizes: Tandoori Chicken is one dish at three
 * prices, not three dishes, and listing it as three left staff scanning for
 * "(Half)" instead of picking a portion under the name they know.
 */
function portionsOf(priced) {
  return typeof priced === 'number' ? [['Regular', priced]] : priced
}

/**
 * A stable UUID for a seeded row.
 *
 * Derived from the branch and a label so a re-run addresses the same rows.
 * Formatted as a v4-shaped UUID because the column holds one everywhere else.
 */
function stableId(branchId, label) {
  const h = createHash('sha256').update(`${branchId}:${label}`).digest('hex')
  return [
    h.slice(0, 8),
    h.slice(8, 12),
    `4${h.slice(13, 16)}`,
    ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16) + h.slice(17, 20),
    h.slice(20, 32),
  ].join('-')
}

const dryRun = process.argv.includes('--dry-run')
const local = process.argv.includes('--local')

const dbFlag = process.argv.indexOf('--db')
const dbPath =
  dbFlag !== -1
    ? process.argv[dbFlag + 1]
    : 'C:/ProgramData/Chennai Express/chennai-express.db'

if (local) {
  await seedLocal()
} else {
  await seedCloud()
}

/**
 * Writes to the till's SQLite.
 *
 * synced_at is left NULL so the sync worker treats every row as pending and
 * pushes it on its next cycle — which is how the cloud copy stays in step
 * without a second write from here.
 */
async function seedLocal() {
  const { default: Database } = await import('better-sqlite3')
  const db = new Database(dbPath)

  try {
    const branch = db
      .prepare('SELECT id, name FROM branches WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1')
      .get()

    if (!branch) {
      console.error(`No branch in ${dbPath}. Install and activate the till first.`)
      process.exit(1)
    }

    const now = new Date().toISOString()
    console.log(`database: ${dbPath}`)
    console.log(`branch:   ${branch.name} (${branch.id})`)
    console.log(dryRun ? 'DRY RUN — nothing will be written\n' : '')

    // Every upsert below clears synced_at on update, not only on insert.
    //
    // Without it a re-priced row kept the stamp from its first push, so
    // selectPending skipped it for ever: the till showed the new price, the
    // cloud kept the old one, and nothing anywhere reported a problem. A
    // re-price is exactly what this script is for, so that was the common case
    // rather than an edge.
    const category = db.prepare(`
      INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, sort_order = excluded.sort_order,
        is_active = 1, deleted_at = NULL, updated_at = excluded.updated_at,
        synced_at = NULL
    `)

    const item = db.prepare(`
      INSERT INTO menu_items
        (id, branch_id, category_id, name, tax_rate, is_available, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, category_id = excluded.category_id,
        tax_rate = excluded.tax_rate, is_available = 1,
        sort_order = excluded.sort_order, deleted_at = NULL,
        updated_at = excluded.updated_at,
        synced_at = NULL
    `)

    const variant = db.prepare(`
      INSERT INTO menu_item_variants
        (id, menu_item_id, name, price, sort_order, is_available, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, price = excluded.price,
        sort_order = excluded.sort_order, is_available = 1,
        deleted_at = NULL, updated_at = excluded.updated_at,
        synced_at = NULL
    `)

    let categories = 0
    let items = 0

    // Soft-deleted, never removed: an item that has been ordered is referenced
    // by order lines and by the bills printed from them. Retiring it takes it
    // off the till without touching what it was sold for.
    const retire = db.prepare(
      `UPDATE menu_items
          SET deleted_at = ?, updated_at = ?, synced_at = NULL
        WHERE branch_id = ? AND deleted_at IS NULL AND id NOT IN (SELECT value FROM json_each(?))`,
    )

    // One transaction: a menu half-written is worse than one not written, and
    // a cashier must never see a category whose items did not arrive.
    const write = db.transaction(() => {
      const wanted = []

      for (const [index, group] of MENU.entries()) {
        const categoryId = stableId(branch.id, `category:${group.category}`)
        category.run(categoryId, branch.id, group.category, index, now, now)
        categories++

        for (const [order, [name, priced]] of group.items.entries()) {
          const itemId = stableId(branch.id, `item:${group.category}:${name}`)
          item.run(itemId, branch.id, categoryId, name, TAX_RATE, order, now, now)

          const portions = portionsOf(priced)

          for (const [vOrder, [vName, rupees]] of portions.entries()) {
            // A lone "Regular" keeps the key it was first seeded under.
            // Appending the portion name unconditionally gave every existing
            // item a second Regular row under a new id, which collides with
            // the old one on (menu_item_id, name) and fails the whole run.
            const variantId =
              portions.length === 1
                ? stableId(branch.id, `variant:${group.category}:${name}`)
                : stableId(branch.id, `variant:${group.category}:${name}:${vName}`)
            variant.run(variantId, itemId, vName, toPaise(rupees), vOrder, now, now)
          }

          items++
          wanted.push(itemId)
        }
      }

      // Anything the card no longer lists. Splitting "Mutton Fried Rice /
      // Noodles" into two dishes leaves the combined item behind otherwise,
      // and the till would offer all three.
      const { changes } = retire.run(now, now, branch.id, JSON.stringify(wanted))
      if (changes > 0) console.log(`retired ${changes} items no longer on the menu`)
    })

    for (const group of MENU) {
      console.log(`${group.category}  (${group.items.length} items)`)
      for (const [name, priced] of group.items) {
        const portions = portionsOf(priced)
        const shown = portions
          .map(([vName, rupees]) => (portions.length === 1 ? `₹${rupees}` : `${vName} ₹${rupees}`))
          .join('   ')
        console.log(`   ${name.padEnd(30)} ${shown}`)
      }
      console.log('')
    }

    if (!dryRun) {
      write()
      console.log(`${categories} categories, ${items} items written`)
      // Written straight to SQLite, so nothing in the running backend knows.
      // The API's onResponse hook is what normally signals the sync worker, and
      // this wrote underneath it — the rows wait for the next heartbeat, up to a
      // minute away. Saying so beats leaving someone watching a count that has
      // not moved and wondering what broke.
      console.log('Written to this PC. The sync worker pushes them within a minute.')
    } else {
      console.log(`${MENU.length} categories, ${MENU.reduce((n, g) => n + g.items.length, 0)} items`)
      console.log('\nDry run — nothing written. Re-run without --dry-run to apply.')
    }
  } finally {
    db.close()
  }
}

/**
 * Refuses, and says where to go instead.
 *
 * Writing straight to the cloud bypasses the till, which then never sees the
 * menu — sync only pushes upward, so rows written here stay there. It also
 * meant a second copy of the write path, and the two drifted the moment
 * portions were added to one and not the other.
 */
async function seedCloud() {
  console.error(
    'Seeding the cloud directly is not supported.\n' +
      '\n' +
      '  Menu data belongs on the till first; the sync worker pushes it up.\n' +
      '  Run:  node scripts/seed-menu.mjs --local\n',
  )
  process.exit(1)
}
