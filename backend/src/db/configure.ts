/**
 * Writes the encrypted configuration for an installed service.
 *
 *   npm run configure -- --dir "C:\Program Files\Chennai Express\backend"
 *
 * Reads the current `.env` and environment, encrypts what the service needs to
 * this machine, and writes `config.dat` beside `server.mjs`. Run by the
 * installer, or by hand when changing a connection string on a live till.
 *
 * The JWT secret is generated here rather than shipped: every installation gets
 * its own, so a token minted on one restaurant's PC is meaningless on another.
 */
import { randomBytes } from 'node:crypto'
import { existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadEnv } from '../lib/env.js'
import { encrypt } from '../lib/secure-config.js'

interface Options {
  dir?: string
  jwtSecret?: string
}

function parseArgs(argv: string[]): Options {
  const options: Options = {}
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i]
    const value = argv[i + 1]
    if (!flag?.startsWith('--') || value === undefined) continue
    if (flag === '--dir') options.dir = value
    else if (flag === '--jwt-secret') options.jwtSecret = value
  }
  return options
}

function main(): void {
  const options = parseArgs(process.argv.slice(2))

  if (!options.dir) {
    console.error('Usage: npm run configure -- --dir "C:\\Program Files\\Chennai Express\\backend"')
    process.exit(1)
  }

  if (!existsSync(join(options.dir, 'server.mjs'))) {
    console.error(`Not an install directory — server.mjs is not in ${options.dir}`)
    process.exit(1)
  }

  const env = loadEnv()

  // A fresh secret per installation unless one is supplied. Reusing a secret
  // across restaurants would mean a token forged on one works on all of them.
  const jwtSecret = options.jwtSecret ?? randomBytes(48).toString('base64url')

  const lines = [
    '# Written by the installer. Encrypted to this machine — copying it elsewhere',
    '# will not work. Edit through: npm run configure',
    `JWT_SECRET=${jwtSecret}`,
    `UPDATE_CHANNEL=${env.UPDATE_CHANNEL}`,
    'NODE_ENV=production',
  ]

  if (env.CLOUD_DATABASE_URL) {
    lines.push(`CLOUD_DATABASE_URL=${env.CLOUD_DATABASE_URL}`)
  }

  const target = join(options.dir, 'config.dat')
  writeFileSync(target, encrypt(lines.join('\n')), { mode: 0o600 })

  console.log(`Wrote ${target}`)
  console.log('')
  console.log(`  cloud sync    ${env.CLOUD_DATABASE_URL ? 'configured' : 'not configured'}`)
  console.log(`  jwt secret    ${options.jwtSecret ? 'supplied' : 'generated for this machine'}`)
  console.log('')
  console.log('Encrypted to this PC. Lock the directory before handing the machine over:')
  console.log(`  powershell -File scripts\\service.ps1 harden -Path "${options.dir}"`)
}

main()
