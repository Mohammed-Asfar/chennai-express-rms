/**
 * Licence administration, run by the vendor — never on a restaurant's PC.
 *
 *   npm run license:new    -- --branch BR1 --restaurant "Chennai Express"
 *   npm run license:list
 *   npm run license:revoke -- --key CX-XXXX-XXXX-XXXX
 *   npm run license:reset  -- --key CX-XXXX-XXXX-XXXX
 *
 * `reset` clears the machine binding so a key can be activated on a replacement
 * PC. It is the answer to "their hard drive died" and to "they bought a new till".
 */
import { loadEnv } from '../lib/env.js'
import type { Sql } from 'postgres'
import { mintKey, normaliseKey } from '../lib/license.js'

interface Args {
  command: string
  branch?: string
  restaurant?: string
  key?: string
  notes?: string
}

function parseArgs(argv: string[]): Args {
  const [command = 'list'] = argv
  const args: Args = { command }

  for (let i = 1; i < argv.length; i += 2) {
    const flag = argv[i]
    const value = argv[i + 1]
    if (!flag?.startsWith('--') || value === undefined) continue
    const name = flag.slice(2)
    if (name === 'branch') args.branch = value
    else if (name === 'restaurant') args.restaurant = value
    else if (name === 'key') args.key = value
    else if (name === 'notes') args.notes = value
  }

  return args
}

async function main(): Promise<void> {
  const env = loadEnv()
  if (!env.CLOUD_DATABASE_URL) {
    console.error('CLOUD_DATABASE_URL is not set. Licences live in the cloud only.')
    process.exit(1)
  }

  const args = parseArgs(process.argv.slice(2))
  const { default: postgres } = await import('postgres')
  const sql = postgres(env.CLOUD_DATABASE_URL, { max: 1, connect_timeout: 10 })

  try {
    switch (args.command) {
      case 'new':
        await create(sql, args)
        break
      case 'list':
        await list(sql)
        break
      case 'revoke':
        await setStatus(sql, args, 'revoked')
        break
      case 'restore':
        await setStatus(sql, args, 'active')
        break
      case 'reset':
        await resetMachine(sql, args)
        break
      default:
        console.error(`Unknown command: ${args.command}`)
        console.error('Use one of: new, list, revoke, restore, reset')
        process.exit(1)
    }
  } finally {
    await sql.end({ timeout: 5 })
  }
}

async function create(sql: Sql, args: Args): Promise<void> {
  if (!args.branch || !args.restaurant) {
    console.error('Usage: npm run license:new -- --branch BR1 --restaurant "Name"')
    process.exit(1)
  }

  const key = mintKey()

  await sql`
    INSERT INTO licenses (key, branch_code, restaurant, notes)
    VALUES (${key}, ${args.branch}, ${args.restaurant}, ${args.notes ?? null})
  `

  console.log('')
  console.log(`  ${key}`)
  console.log('')
  console.log(`  branch      ${args.branch}`)
  console.log(`  restaurant  ${args.restaurant}`)
  console.log(`  status      unclaimed`)
  console.log('')
  console.log('  Give this key to the restaurant. It binds to the first PC that')
  console.log('  activates it and will not work on a second.')
  console.log('')
}

async function list(sql: Sql): Promise<void> {
  const rows = await sql`
    SELECT key, branch_code, restaurant, status, activated_at, last_seen_at
      FROM licenses ORDER BY created_at
  `

  if (rows.length === 0) {
    console.log('No licences yet. Create one with: npm run license:new -- --branch BR1 --restaurant "Name"')
    return
  }

  console.log('')
  for (const row of rows) {
    const bound = row.activated_at ? 'bound' : 'not activated'
    const seen = row.last_seen_at ? new Date(row.last_seen_at).toISOString().slice(0, 16).replace('T', ' ') : 'never'
    console.log(`  ${row.key}  ${row.branch_code.padEnd(6)} ${row.status.padEnd(10)} ${bound.padEnd(14)} last seen ${seen}`)
    console.log(`  ${' '.repeat(18)} ${row.restaurant}`)
    console.log('')
  }
}

async function setStatus(sql: Sql, args: Args, status: string): Promise<void> {
  const key = args.key ? normaliseKey(args.key) : null
  if (!key) {
    console.error('Usage: --key CX-XXXX-XXXX-XXXX')
    process.exit(1)
  }

  const rows = await sql`
    UPDATE licenses SET status = ${status}, updated_at = now()
     WHERE key = ${key}
    RETURNING branch_code, restaurant
  `

  if (rows.length === 0) {
    console.error('No licence with that key.')
    process.exit(1)
  }

  console.log(`${key} (${rows[0]!.restaurant}) is now ${status}.`)
  if (status === 'revoked') {
    console.log('The branch keeps billing for up to 7 days, then stops.')
  }
}

async function resetMachine(sql: Sql, args: Args): Promise<void> {
  const key = args.key ? normaliseKey(args.key) : null
  if (!key) {
    console.error('Usage: --key CX-XXXX-XXXX-XXXX')
    process.exit(1)
  }

  const rows = await sql`
    UPDATE licenses
       SET fingerprint = NULL, status = 'unclaimed', activated_at = NULL, updated_at = now()
     WHERE key = ${key}
    RETURNING branch_code, restaurant
  `

  if (rows.length === 0) {
    console.error('No licence with that key.')
    process.exit(1)
  }

  console.log(`${key} (${rows[0]!.restaurant}) is unbound and can be activated on a new PC.`)
}

await main()
