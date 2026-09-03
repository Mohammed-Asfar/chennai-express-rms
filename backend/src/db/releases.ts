/**
 * Release administration, run by the vendor.
 *
 *   npm run release:list
 *   npm run release:withdraw -- --build 3
 *   npm run release:restore  -- --build 3
 *
 * Withdrawing sets `is_active = false`, which is the rollback for a release that
 * turns out to be broken: branches stop being offered it immediately, and no new
 * build has to be published to undo the mistake.
 *
 * Rows are never deleted. A branch that already installed a withdrawn build is a
 * thing you need to be able to see.
 */
import type { Sql } from 'postgres'
import { loadEnv } from '../lib/env.js'

interface Args {
  command: string
  build?: number
  channel?: string
}

function parseArgs(argv: string[]): Args {
  const [command = 'list'] = argv
  const args: Args = { command }

  for (let i = 1; i < argv.length; i += 2) {
    const flag = argv[i]
    const value = argv[i + 1]
    if (!flag?.startsWith('--') || value === undefined) continue
    if (flag === '--build') args.build = Number(value)
    else if (flag === '--channel') args.channel = value
  }

  return args
}

async function main(): Promise<void> {
  const env = loadEnv()
  if (!env.CLOUD_DATABASE_URL) {
    console.error('CLOUD_DATABASE_URL is not set. Releases live in the cloud only.')
    process.exit(1)
  }

  const args = parseArgs(process.argv.slice(2))
  const { default: postgres } = await import('postgres')
  const sql = postgres(env.CLOUD_DATABASE_URL, { max: 1, connect_timeout: 10 })

  try {
    switch (args.command) {
      case 'list':
        await list(sql)
        break
      case 'withdraw':
        await setActive(sql, args, false)
        break
      case 'restore':
        await setActive(sql, args, true)
        break
      default:
        console.error(`Unknown command: ${args.command}`)
        console.error('Use one of: list, withdraw, restore')
        process.exit(1)
    }
  } finally {
    await sql.end({ timeout: 5 })
  }
}

async function list(sql: Sql): Promise<void> {
  const rows = await sql<
    {
      version: string
      build_number: number
      channel: string
      is_active: boolean
      is_mandatory: boolean
      released_at: Date
      file_size: string
    }[]
  >`
    SELECT version, build_number, channel, is_active, is_mandatory, released_at, file_size
      FROM app_releases ORDER BY channel, build_number DESC
  `

  if (rows.length === 0) {
    console.log('No releases published yet.')
    return
  }

  console.log('')
  for (const row of rows) {
    const state = row.is_active ? 'active' : 'withdrawn'
    const forced = row.is_mandatory ? ' mandatory' : ''
    const size = (Number(row.file_size) / (1024 * 1024)).toFixed(1)
    const when = row.released_at.toISOString().slice(0, 10)
    console.log(
      `  ${row.version.padEnd(10)} build ${String(row.build_number).padEnd(4)} ` +
        `${row.channel.padEnd(7)} ${state.padEnd(10)}${forced.padEnd(10)} ${size} MB   ${when}`,
    )
  }
  console.log('')
}

async function setActive(sql: Sql, args: Args, active: boolean): Promise<void> {
  if (args.build === undefined || Number.isNaN(args.build)) {
    console.error('Usage: --build <number> [--channel stable]')
    process.exit(1)
  }

  const channel = args.channel ?? 'stable'
  const rows = await sql<{ version: string }[]>`
    UPDATE app_releases SET is_active = ${active}, updated_at = now()
     WHERE build_number = ${args.build} AND channel = ${channel}
    RETURNING version
  `

  if (rows.length === 0) {
    console.error(`No ${channel} release with build ${args.build}.`)
    process.exit(1)
  }

  const version = rows[0]!.version
  if (active) {
    console.log(`${version} (build ${args.build}) is offered again.`)
  } else {
    console.log(`${version} (build ${args.build}) is withdrawn.`)
    console.log('Branches stop being offered it immediately.')
    console.log('Tills that already installed it are not rolled back — publish a fix.')
  }
}

await main()
