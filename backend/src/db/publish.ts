/**
 * Publishes a built installer as a release.
 *
 *   npm run publish:release -- --file ..\dist\chennai-express-setup-1.1.0.exe --notes "Fixes ..."
 *
 * Takes the installer you built locally, uploads it to the release host, and
 * writes the `app_releases` row branches read on startup. Run by the vendor.
 *
 * **The hash is computed from the file that is uploaded, in that order.** A
 * checksum taken from a different build than the one published means every till
 * downloads the installer, fails verification, and refuses to update — with no
 * obvious cause, because both halves look correct in isolation.
 *
 * Nothing is written to the database until the upload has succeeded and the
 * uploaded copy has been read back and re-hashed. A row pointing at a URL that
 * does not exist would offer every branch an update it cannot install.
 */
import { createHash, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { basename } from 'node:path'
import type { Sql } from 'postgres'
import { loadEnv } from '../lib/env.js'
import { APP_BUILD_NUMBER, APP_VERSION } from '../lib/version.js'
import {
  checkDownload,
  checkStoredAsset,
  type Downloaded,
  type LocalFile,
  type PublishedAsset,
} from './publish-checks.js'

interface Options {
  file?: string
  notes?: string
  channel: 'stable' | 'beta'
  mandatory: boolean
  minBuild?: number
  url?: string
  /** Skip the upload; the file is already hosted at --url. */
  skipUpload: boolean
  dryRun: boolean
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    channel: 'stable',
    mandatory: argv.includes('--mandatory'),
    skipUpload: argv.includes('--skip-upload'),
    dryRun: argv.includes('--dry-run'),
  }

  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i]
    const value = argv[i + 1]
    if (!flag?.startsWith('--') || value === undefined || value.startsWith('--')) continue

    if (flag === '--file') options.file = value
    else if (flag === '--notes') options.notes = value
    else if (flag === '--url') options.url = value
    else if (flag === '--min-build') options.minBuild = Number(value)
    else if (flag === '--channel') {
      if (value !== 'stable' && value !== 'beta') {
        console.error(`--channel must be stable or beta, got ${value}`)
        process.exit(1)
      }
      options.channel = value
    }
  }

  return options
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2))
  const env = loadEnv()

  if (!env.CLOUD_DATABASE_URL) {
    console.error('CLOUD_DATABASE_URL is not set. Releases live in the cloud only.')
    process.exit(1)
  }

  if (!options.file) {
    console.error('Usage: npm run publish:release -- --file <installer.exe> [--notes "..."]')
    console.error('')
    console.error('  --channel stable|beta   default stable')
    console.error('  --mandatory             the update dialog cannot be dismissed')
    console.error('  --min-build N           builds below N are forced to update')
    console.error('  --url <href>            skip the upload; already hosted here')
    console.error('  --skip-upload           publish a row for an already-uploaded file')
    console.error('  --dry-run               print what would happen, write nothing')
    process.exit(1)
  }

  if (!existsSync(options.file)) {
    console.error(`No such file: ${options.file}`)
    process.exit(1)
  }

  const name = basename(options.file)
  const bytes = readFileSync(options.file)
  const size = statSync(options.file).size
  const sha256 = createHash('sha256').update(bytes).digest('hex')

  console.log('')
  console.log(`  ${name}`)
  console.log(`  version       ${APP_VERSION} (build ${APP_BUILD_NUMBER})`)
  console.log(`  channel       ${options.channel}`)
  console.log(`  size          ${(size / (1024 * 1024)).toFixed(1)} MB`)
  console.log(`  sha256        ${sha256}`)
  console.log('')

  // The version constants are what a running branch reports about itself. A
  // release whose build number is not above the previous one is never offered,
  // because comparison is on build_number — so it would upload and then sit
  // there doing nothing.
  const { default: postgres } = await import('postgres')
  const sql = postgres(env.CLOUD_DATABASE_URL, { max: 1, connect_timeout: 10 })

  try {
    await assertBuildIsNewer(sql, options.channel)

    let url = options.url
    if (!options.skipUpload && !url) {
      if (options.dryRun) {
        console.log('  Would upload, then write the release row. Nothing done (--dry-run).')
        return
      }
      url = uploadToGitHub(options.file!, name)
    }

    if (!url) {
      console.error('No download URL. Pass --url, or let the upload produce one.')
      process.exit(1)
    }

    // Verified twice, because 1.0.5 passed a hash check and still shipped an
    // installer GitHub was serving 11 MB short.
    //
    // First: what GitHub says it stored. That number disagreed immediately, and
    // it costs one API call rather than a 50 MB download. A truncated upload is
    // worth simply doing again, so it is — once.
    //
    // Then: the bytes that actually come down the public URL, which is the same
    // request a till makes. Only after both agree is a release row written.
    const local: LocalFile = { size: statSync(options.file!).size, sha256 }
    const tag = `v${APP_VERSION}`

    if (!options.skipUpload) {
      console.log('  Checking what GitHub stored...')
      let asset = storedAsset(tag, name)
      let stored = asset
        ? checkStoredAsset(asset, local)
        : ({ ok: false, retryable: true, reason: 'no such asset on the release' } as const)

      if (!stored.ok && stored.retryable) {
        console.log(`    ${stored.reason}`)
        console.log('    Re-uploading once...')
        execFileSync('gh', ['release', 'upload', tag, options.file!, '--clobber'], {
          stdio: 'inherit',
        })
        asset = storedAsset(tag, name)
        stored = asset
          ? checkStoredAsset(asset, local)
          : ({ ok: false, retryable: false, reason: 'no such asset after re-uploading' } as const)
      }

      if (!stored.ok) {
        console.error('')
        console.error('  The upload did not survive: ' + stored.reason)
        console.error('  No release row was written.')
        process.exit(1)
      }
      console.log(`    ${local.size} bytes, as built.`)
    }

    console.log('  Downloading it back...')
    const got = downloadPublished(url)
    const download = checkDownload(got, local)
    if (!download.ok) {
      console.error('')
      console.error('  What the URL serves is not the installer: ' + download.reason)
      console.error('  No release row was written.')
      console.error(`  Withdraw nothing — nothing was published. Fix the asset at ${url}`)
      process.exit(1)
    }
    console.log('  Matches, byte for byte.')

    if (options.dryRun) {
      console.log('')
      console.log('  Would write the release row. Nothing done (--dry-run).')
      return
    }

    const now = new Date().toISOString()
    await sql`
      INSERT INTO app_releases (
        id, version, build_number, channel, download_url, file_size, sha256,
        release_notes, is_mandatory, min_supported_build, released_at,
        is_active, created_at, updated_at
      ) VALUES (
        ${randomUUID()}, ${APP_VERSION}, ${APP_BUILD_NUMBER}, ${options.channel},
        ${url}, ${size}, ${sha256}, ${options.notes ?? ''}, ${options.mandatory},
        ${options.minBuild ?? 0}, ${now}, TRUE, ${now}, ${now}
      )
    `

    console.log('')
    console.log(`  Published ${APP_VERSION} (build ${APP_BUILD_NUMBER}) to ${options.channel}.`)
    console.log(`  ${url}`)
    console.log('')
    console.log('  Branches will be offered it the next time they open the app.')
    console.log('  To withdraw it:  npm run release:withdraw -- --build ' + APP_BUILD_NUMBER)
  } finally {
    await sql.end({ timeout: 5 })
  }
}

/**
 * Refuses to publish a build that is not newer than the current one.
 *
 * Update comparison is on `build_number`, so republishing the same number is a
 * release nobody is ever offered. Caught here rather than discovered when a
 * restaurant reports they never got the fix.
 */
async function assertBuildIsNewer(sql: Sql, channel: string): Promise<void> {
  const rows = await sql<{ build_number: number; version: string }[]>`
    SELECT build_number, version FROM app_releases
     WHERE channel = ${channel} AND is_active
     ORDER BY build_number DESC LIMIT 1
  `

  const current = rows[0]
  if (!current) return

  if (APP_BUILD_NUMBER <= current.build_number) {
    console.error(
      `  Build ${APP_BUILD_NUMBER} is not newer than the published ${current.version} ` +
        `(build ${current.build_number}).`,
    )
    console.error('  Bump APP_VERSION and APP_BUILD_NUMBER in src/lib/version.ts first.')
    process.exit(1)
  }
}

/**
 * Uploads to a GitHub release, creating the tag's release if needed.
 *
 * Uses the `gh` CLI so the credentials are whatever the operator is already
 * signed in with — no token needs to live in this repository or on this disk.
 */
function uploadToGitHub(file: string, name: string): string {
  const tag = `v${APP_VERSION}`

  let exists = true
  try {
    execFileSync('gh', ['release', 'view', tag], { stdio: 'ignore' })
  } catch {
    exists = false
  }

  const notes =
    `Chennai Express ${APP_VERSION} (build ${APP_BUILD_NUMBER}).\n\n` +
    'Run the installer as an administrator on the till. Existing bills, ' +
    'settings and activation are kept.'

  if (exists) {
    console.log(`  Release ${tag} exists; attaching the installer.`)

    // Replace the notes as well as the file.
    //
    // CI publishes a release for the same tag whose body says the installer
    // cannot be activated — true of the one CI built, and false of this one,
    // which is about to overwrite it. Leaving that text in place would tell
    // everyone the shippable installer is unusable.
    //
    // Deliberately outside the existence check above: a failure here must not
    // fall through to `release create` for a tag that already exists.
    execFileSync(
      'gh',
      ['release', 'edit', tag, '--title', `Chennai Express ${APP_VERSION}`, '--notes', notes],
      { stdio: 'ignore' },
    )
  } else {
    console.log(`  Creating release ${tag}.`)
    execFileSync(
      'gh',
      ['release', 'create', tag, '--title', `Chennai Express ${APP_VERSION}`, '--notes', notes],
      { stdio: 'inherit' },
    )
  }

  // --clobber: re-uploading after a failed publish must replace the asset rather
  // than fail, or a half-finished release can never be completed.
  execFileSync('gh', ['release', 'upload', tag, file, '--clobber'], { stdio: 'inherit' })

  const repo = execFileSync('gh', ['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'], {
    encoding: 'utf8',
  }).trim()

  return `https://github.com/${repo}/releases/download/${tag}/${name}`
}

/**
 * What GitHub says it stored for the release asset.
 *
 * One API call, and it is the check that would have caught 1.0.5 instantly:
 * GitHub reported 43,542,605 bytes for a 54,964,421-byte installer and still
 * marked it `uploaded`. Asking costs nothing next to downloading 50 MB.
 */
function storedAsset(tag: string, name: string): PublishedAsset | null {
  const json = execFileSync(
    'gh',
    ['release', 'view', tag, '--json', 'assets'],
    { encoding: 'utf8' },
  )

  const assets = (JSON.parse(json) as { assets: { name: string; size: number; state: string }[] })
    .assets
  const found = assets.find((a) => a.name === name)
  return found ? { size: found.size, state: found.state } : null
}

/**
 * Downloads the published file and returns its size and SHA-256.
 *
 * `--fail` so an HTTP error is an error: without it curl follows a 404 into an
 * HTML body, exits zero, and hands back a few hundred bytes to be hashed as
 * though they were the installer.
 */
function downloadPublished(url: string): Downloaded {
  const body = execFileSync('curl', ['-sL', '--fail', '--max-time', '600', url], {
    encoding: 'buffer',
    maxBuffer: 512 * 1024 * 1024,
  })

  return {
    size: body.byteLength,
    sha256: createHash('sha256').update(body).digest('hex'),
  }
}

await main()
