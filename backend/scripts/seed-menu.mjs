/**
 * Seeds the printed menu.
 *
 *   node scripts/seed-menu.mjs --dry-run          # print what would be written
 *   node scripts/seed-menu.mjs                    # write it to the cloud
 *   node scripts/seed-menu.mjs --local            # write it to this PC's till
 *   node scripts/seed-menu.mjs --local --db PATH  # a specific database file
 *
 * Sync only pushes upward, so a menu written to the cloud never reaches a till
 * that already has a database. --local writes to SQLite instead, and the sync
 * worker then carries it up the way menu data normally travels.
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
 * synced_at is left NULL. These rows were written straight to the cloud rather
 * than pushed from a till, and marking them as pushed would be a lie the sync
 * worker later has to reconcile.
 */

import { createHash } from 'node:crypto'

// loadEnv is imported lazily, inside the cloud path only. It is TypeScript, so a
// static import forces the whole script to run under tsx — and --local needs
// nothing from it. Importing it there keeps `node scripts/seed-menu.mjs --local`
// working with a plain runtime.

// --- the card ---------------------------------------------------------------
//
// Transcribed from the printed menu. Prices in rupees; converted to paise below
// at the single boundary, never scattered through the data.

const MENU = [
  {
    category: 'Dum Biriyani',
    items: [
      ['Chicken Biriyani', 140],
      ['Mutton Biriyani', 230],
      ['Prawn Biriyani', 210],
      ['Egg Biriyani', 110],
      ['Veg Biriyani', 120],
      ['Special Biriyani', 160],
    ],
  },
  {
    category: 'Indian Masala - Non Veg',
    items: [
      ['Chicken Jhalfareji', 195],
      ['Chicken Dopiyaza', 195],
      ['Chetinadu Chicken', 195],
      ['Pepper Chicken Masala', 195],
      ['Chicken Kolhapuri', 195],
      ['Kadai Chicken Masala', 195],
      ['Hydrabadi Chicken', 195],
      ['Chicken Masala', 185],
      ['Banjara Chicken', 205],
      ['Butter Chicken Masala', 225],
      ['Chicken Tikka Masala', 225],
      ['Mutton Masala', 245],
      ['Motten Pepper Fry', 265],
      ['Egg Masala', 125],
      ['Fish Curry', 245],
      ['Prawn Curry', 245],
    ],
  },
  {
    category: 'Indian Masala - Veg',
    items: [
      ['Veg Jhalfareji', 165],
      ['Kadai Paneer', 195],
      ['Paneer Butter Masala', 195],
      ['Paneer Do Piyaja', 195],
      ['Mutter Paneer Masala', 195],
      ['Aloo Jeera', 145],
      ['Aloo Gobi', 145],
      ['Aloo Mutter', 145],
      ['Gobi Masala', 145],
      ['Gobi Mutter', 145],
      ['Mixed Veg Curry', 155],
      ['Veg Kadai', 155],
      ['Green Peas Masala', 155],
      ['Chana Masala', 155],
      ['Daal Fry', 135],
      ['Daal Tadka', 155],
      ['Double Daal Tadka', 175],
      ['Bhindi Masala', 165],
      ['Mushroom Masala', 165],
      ['Green Salad', 110],
    ],
  },
  {
    category: 'Shawarma & Roll Items',
    items: [
      ['Regular Shawarma Roll', 130],
      ['Special Shawarma Roll', 150],
      ['Regular Shawarma Plate', 160],
      ['Special Shawarma Plate', 180],
      ['Mexican Shawarma', 140],
      ['Chicken Roll', 140],
      ['Mutton Roll', 170],
      ['Egg Roll', 110],
      ['Veg Roll', 200],
      ['Paneer Roll', 160],
      ['Mushroom Roll', 140],
      ['Chicken Tikka Roll', 160],
    ],
  },
  {
    category: 'Lassi & Fresh Juice',
    items: [
      ['Sweet Lassi', 65],
      ['Mango Lassi', 85],
      ['Strawberry Lassi', 95],
      ['Salt Lassi', 65],
      ['Plain Lassi', 55],
      // "Soft Drinks ........" is priced with dots on the card. Left out
      // deliberately rather than invented — an item that bills the wrong amount
      // is worse than one a cashier has to add.
    ],
  },
  {
    category: 'Bucket Biriyani',
    items: [
      ['Chicken Bucket Biriyani', 999],
      ['Mutton Bucket Biriyani', 1699],
    ],
  },
]

const TAX_RATE = 0

/** Rupees to paise, at the boundary. */
function toPaise(rupees) {
  return Math.round(rupees * 100)
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

    const category = db.prepare(`
      INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, sort_order = excluded.sort_order,
        is_active = 1, deleted_at = NULL, updated_at = excluded.updated_at
    `)

    const item = db.prepare(`
      INSERT INTO menu_items
        (id, branch_id, category_id, name, tax_rate, is_available, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, category_id = excluded.category_id,
        tax_rate = excluded.tax_rate, is_available = 1,
        sort_order = excluded.sort_order, deleted_at = NULL,
        updated_at = excluded.updated_at
    `)

    const variant = db.prepare(`
      INSERT INTO menu_item_variants
        (id, menu_item_id, name, price, sort_order, is_available, created_at, updated_at)
      VALUES (?, ?, ?, ?, 0, 1, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        price = excluded.price, is_available = 1,
        deleted_at = NULL, updated_at = excluded.updated_at
    `)

    let categories = 0
    let items = 0

    // One transaction: a menu half-written is worse than one not written, and
    // a cashier must never see a category whose items did not arrive.
    const write = db.transaction(() => {
      for (const [index, group] of MENU.entries()) {
        const categoryId = stableId(branch.id, `category:${group.category}`)
        category.run(categoryId, branch.id, group.category, index, now, now)
        categories++

        for (const [order, [name, rupees]] of group.items.entries()) {
          const itemId = stableId(branch.id, `item:${group.category}:${name}`)
          const variantId = stableId(branch.id, `variant:${group.category}:${name}`)
          item.run(itemId, branch.id, categoryId, name, TAX_RATE, order, now, now)
          variant.run(variantId, itemId, 'Regular', toPaise(rupees), now, now)
          items++
        }
      }
    })

    for (const group of MENU) {
      console.log(`${group.category}  (${group.items.length} items)`)
      for (const [name, rupees] of group.items) {
        console.log(`   ${name.padEnd(26)} ₹${String(rupees).padStart(5)}  =  ${toPaise(rupees)} paise`)
      }
      console.log('')
    }

    if (!dryRun) {
      write()
      console.log(`${categories} categories, ${items} items written`)
      console.log('The sync worker will push these to the cloud on its next cycle.')
    } else {
      console.log(`${MENU.length} categories, ${MENU.reduce((n, g) => n + g.items.length, 0)} items`)
      console.log('\nDry run — nothing written. Re-run without --dry-run to apply.')
    }
  } finally {
    db.close()
  }
}

async function seedCloud() {
const { loadEnv } = await import('../src/lib/env.js')
const env = loadEnv()
if (!env.CLOUD_DATABASE_URL) {
  console.error('CLOUD_DATABASE_URL is not set.')
  process.exit(1)
}

const { default: postgres } = await import('postgres')
const sql = postgres(env.CLOUD_DATABASE_URL, { max: 1, connect_timeout: 10 })

try {
  const branches = await sql`
    SELECT id, name FROM branches WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1
  `
  if (branches.length === 0) {
    console.error('No branch in the cloud. Install and activate a till first.')
    process.exit(1)
  }

  const branch = branches[0]
  const now = new Date()

  let categories = 0
  let items = 0

  console.log(`branch: ${branch.name} (${branch.id})`)
  console.log(dryRun ? 'DRY RUN — nothing will be written\n' : '')

  for (const [index, group] of MENU.entries()) {
    const categoryId = stableId(branch.id, `category:${group.category}`)
    console.log(`${group.category}  (${group.items.length} items)`)

    if (!dryRun) {
      await sql`
        INSERT INTO categories (id, branch_id, name, sort_order, is_active, created_at, updated_at)
        VALUES (${categoryId}, ${branch.id}, ${group.category}, ${index}, true, ${now}, ${now})
        ON CONFLICT (id) DO UPDATE SET
          name = excluded.name,
          sort_order = excluded.sort_order,
          is_active = true,
          deleted_at = NULL,
          updated_at = excluded.updated_at
      `
    }
    categories++

    for (const [order, [name, rupees]] of group.items.entries()) {
      const itemId = stableId(branch.id, `item:${group.category}:${name}`)
      const variantId = stableId(branch.id, `variant:${group.category}:${name}`)
      const price = toPaise(rupees)

      console.log(`   ${name.padEnd(26)} ₹${String(rupees).padStart(5)}  =  ${price} paise`)

      if (!dryRun) {
        await sql`
          INSERT INTO menu_items
            (id, branch_id, category_id, name, tax_rate, is_available, sort_order, created_at, updated_at)
          VALUES
            (${itemId}, ${branch.id}, ${categoryId}, ${name}, ${TAX_RATE}, true, ${order}, ${now}, ${now})
          ON CONFLICT (id) DO UPDATE SET
            name = excluded.name,
            category_id = excluded.category_id,
            tax_rate = excluded.tax_rate,
            is_available = true,
            sort_order = excluded.sort_order,
            deleted_at = NULL,
            updated_at = excluded.updated_at
        `

        // Every item needs one variant: price lives on the variant, never on
        // the item. A single unnamed variant is how a dish with no size options
        // is represented.
        await sql`
          INSERT INTO menu_item_variants
            (id, menu_item_id, name, price, sort_order, is_available, created_at, updated_at)
          VALUES
            (${variantId}, ${itemId}, ${'Regular'}, ${price}, 0, true, ${now}, ${now})
          ON CONFLICT (id) DO UPDATE SET
            price = excluded.price,
            is_available = true,
            deleted_at = NULL,
            updated_at = excluded.updated_at
        `
      }
      items++
    }
    console.log('')
  }

  console.log(`${categories} categories, ${items} items`)
  if (dryRun) console.log('\nDry run — nothing written. Re-run without --dry-run to apply.')
} finally {
  await sql.end({ timeout: 5 })
}
}
