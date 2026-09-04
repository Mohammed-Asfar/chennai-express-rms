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

// --- the card ---------------------------------------------------------------
//
// Transcribed from the printed menu. Prices in rupees; converted to paise below
// at the single boundary, never scattered through the data.

const MENU = [
  {
    category: 'Soup - Veg',
    items: [
      ['Veg Clear Soup', 65],
      ['Sweet Corn Veg Soup', 85],
      ['Hot & Sour Veg Soup', 85],
      ['Veg Manchow Soup', 85],
      ['Veg Noodles Soup', 105],
      ['Mushroom Soup', 115],
      ['Cream of Mushroom Soup', 105],
      ['Cream of Veg Soup', 95],
    ],
  },
  {
    category: 'Soup - Non Veg',
    items: [
      ['Chicken Clear Soup', 75],
      ['Sweet Corn Chicken Soup', 95],
      ['Chicken Manchow Soup', 95],
      ['Chicken Noodles Soup', 120],
      ['Hot & Sour Chicken Soup', 95],
      ['Mutton Soup', 125],
      ['Cream of Chicken Soup', 115],
      ['Cream of Mutton Soup', 135],
    ],
  },
  {
    category: 'Non Veg Starters',
    items: [
      ['Prawn Szechwan Chilly', 265],
      ['Prawn Manchurian', 265],
      ['Prawn Pepper Fry', 270],
      ['Prawn 65', 260],
      ['Fish Chilly', 265],
      ['Fish Manchurian', 265],
      ['Fish Fry', 240],
      ['Fish Finger', 260],
      ['Crab Lollypop', 280],
      ['Kadamba Chilly', 260],
      ['Mutton Chilly', 260],
      ['Chicken Lollypop', 180],
      ['Lollypop Manchurian', 240],
      ['Lemon Chicken', 215],
      ['Ginger Chicken', 215],
      ['Garlic Chicken', 215],
      // "(Dry & Gravy)" on the card means both are available at one price, not
      // that a plate arrives with each. The kitchen still has to be told which.
      ['Chilly Chicken', [['Dry', 185], ['Gravy', 185]]],
      ['Chicken Manchurian', 185],
      // Two preparations at one price, so the kitchen ticket has to say which.
      ['Pepper Chicken', [['Dry', 195], ['Fry', 195]]],
      ['Chicken 65', 160],
      ['Egg Chilly', 140],
      ['Egg Manchurian', 140],
      ['Egg Bhujee', 60],
      ['Omlate', 50],
      ['Masala Omlate', 55],
      ['Cheese Omlate', 100],
    ],
  },
  {
    category: 'Veg Starters',
    items: [
      ['Paneer 65', 180],
      ['Paneer Chilly', 195],
      ['Paneer Manchurian', 195],
      ['Mushroom Chilly', 165],
      ['Mushroom Manchurian', 165],
      ['Gobi Chilly', [['Dry', 165], ['Gravy', 165]]],
      ['Gobi Manchurian', 165],
      ['Gobi 65', 165],
    ],
  },
  {
    category: 'Tandoori - Roti / Naan',
    items: [
      ['Tandoori Roti', 40],
      ['Butter Roti', 45],
      ['Naan', 40],
      ['Kulcha', 55],
      ['Tandoori Paratha', 55],
      ['Butter Naan', 45],
      ['Garlic Naan', 75],
      ['Kashmiri Naan', 75],
      ['Masala Kulcha', 75],
      ['Stuff Paratha', 75],
      ['Aloo Paratha', 75],
      ['Lachhaka Paratha', 75],
      ['Paneer Paratha', 85],
      ['Paneer Kulcha', 85],
      ['Cheese Naan', 95],
      ['Cheese Paratha', 95],
    ],
  },
  {
    category: 'Tandoori - Veg',
    items: [
      ['Aloo Tikka', 190],
      ['Gobi Tikka', 190],
      ['Paneer Tikka', 230],
      ['Paneer Malai Tikka', 260],
      ['Mushroom Tikka', 190],
    ],
  },
  {
    category: "Tandoori - Kabab's",
    items: [
      // One dish at three prices. As three items, staff had to find the right
      // "(Half)" among them; as portions they tap the dish and pick the size.
      ['Tandoori Chicken', [['Full', 440], ['Half', 240], ['Single', 120]]],
      ['Chicken Tikka', 190],
      ['Chicken Malai Tikka', 250],
      ['Chicken Haryali Kabab', 240],
      ['Lasuni Kabab', 250],
      ['Tandoori Fish', 250],
    ],
  },
  {
    category: 'Fried Rice & Noodles - Non Veg',
    items: [
      // The card prices rice and noodles together — "Mutton Fried Rice /
      // Noodles  250.00" — but they are two dishes. Sold as one line, nobody
      // can tell which the customer asked for, and the kitchen ticket does not
      // say. Split, at the shared price the card gives.
      ['Mutton Fried Rice', 250],
      ['Mutton Fried Noodles', 250],
      ['Mutton Szechwan Fried Rice', 250],
      ['Mutton Szechwan Fried Noodles', 250],
      ['Chicken Fried Rice', 160],
      ['Chicken Fried Noodles', 160],
      ['Chicken Szechwan Fried Rice', 160],
      ['Chicken Szechwan Fried Noodles', 160],
      ['Egg Fried Rice', 130],
      ['Egg Fried Noodles', 130],
      ['Egg Szechwan Fried Rice', 130],
      ['Egg Szechwan Fried Noodles', 130],
      ['Mixed Fried Rice', 250],
      ['Mixed Fried Noodles', 250],
      ['Mixed Szechwan Fried Rice', 250],
      ['Mixed Szechwan Fried Noodles', 250],
      ['Prawn Fried Rice', 250],
      ['Prawn Fried Noodles', 250],
      ['Prawn Szechwan Fried Rice', 250],
      ['Prawn Szechwan Fried Noodles', 250],
    ],
  },
  {
    category: 'Fried Rice & Noodles - Veg',
    items: [
      ['Veg Fried Rice', 120],
      ['Veg Fried Noodles', 120],
      ['Veg Szechwan Fried Rice', 120],
      ['Veg Szechwan Fried Noodles', 120],
      ['Paneer Fried Rice', 190],
      ['Paneer Fried Noodles', 190],
      ['Paneer Szechwan Fried Rice', 190],
      ['Paneer Szechwan Fried Noodles', 190],
      ['Mushroom Fried Rice', 180],
      ['Mushroom Fried Noodles', 180],
      ['Mushroom Szechwan Fried Rice', 180],
      ['Mushroom Szechwan Fried Noodles', 180],
      ['Gobi Fried Rice', 160],
      ['Gobi Fried Noodles', 160],
      ['Gobi Szechwan Fried Rice', 160],
      ['Gobi Szechwan Fried Noodles', 160],
      ['Mixed Veg Fried Rice', 200],
      ['Mixed Veg Fried Noodles', 200],
    ],
  },
  {
    category: 'Rice',
    items: [
      ['Steam Rice', 80],
      ['Jeera Rice', 140],
      ['Ghee Rice', 140],
      ['Peas Pulav', 170],
      ['Butter Rice', 180],
      ['Mushroom Pulav', 180],
      ['Paneer Pulav', 200],
      ['Veg Pulav', 170],
    ],
  },
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
      VALUES (?, ?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        name = excluded.name, price = excluded.price,
        sort_order = excluded.sort_order, is_available = 1,
        deleted_at = NULL, updated_at = excluded.updated_at
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
      console.log('The sync worker will push these to the cloud on its next cycle.')
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
