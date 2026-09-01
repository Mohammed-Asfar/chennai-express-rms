import type { FastifyInstance } from 'fastify'
import { requireAuth } from '../lib/guards.js'
import {
  APP_BUILD_NUMBER,
  APP_VERSION,
  evaluateRelease,
  type ReleaseInfo,
  type UpdateCheckResult,
} from '../lib/version.js'

/**
 * The backend performs the update check, not the client — so the Neon connection
 * string never leaves the billing PC's server process.
 *
 * The check is best-effort. No internet, no cloud configured, or a slow response
 * all resolve to "no update available" rather than an error: an update check must
 * never stand between staff and a bill.
 */
export async function updateRoutes(app: FastifyInstance): Promise<void> {
  app.get('/version', async () => ({
    version: APP_VERSION,
    buildNumber: APP_BUILD_NUMBER,
  }))

  app.get('/updates/check', { preHandler: requireAuth }, async (request) => {
    const base: UpdateCheckResult = {
      currentVersion: APP_VERSION,
      currentBuild: APP_BUILD_NUMBER,
      updateAvailable: false,
      isForced: false,
      release: null,
    }

    if (!app.env.CLOUD_DATABASE_URL) {
      return { ...base, unavailableReason: 'Cloud updates are not configured' }
    }

    try {
      const release = await fetchLatestRelease(app)
      const verdict = evaluateRelease(APP_BUILD_NUMBER, release)

      return {
        ...base,
        updateAvailable: verdict.updateAvailable,
        isForced: verdict.isForced,
        release: verdict.updateAvailable && release ? stripInternal(release) : null,
      }
    } catch (error) {
      // Log it, but report "no update" — an offline restaurant must not see an
      // error banner on a screen it cannot act on.
      request.log.warn({ err: error }, 'update check failed')
      return { ...base, unavailableReason: 'Could not reach the update service' }
    }
  })
}

type CloudRelease = ReleaseInfo & { minSupportedBuild: number }

const stripInternal = ({ minSupportedBuild: _ignored, ...rest }: CloudRelease): ReleaseInfo => rest

/**
 * Reads the newest active release for the configured channel.
 *
 * Deliberately given a short timeout: a hanging cloud query must not delay the
 * startup check.
 */
async function fetchLatestRelease(app: FastifyInstance): Promise<CloudRelease | null> {
  const { default: postgres } = await import('postgres')
  const sql = postgres(app.env.CLOUD_DATABASE_URL!, {
    max: 1,
    idle_timeout: 5,
    connect_timeout: 5,
  })

  try {
    const rows = await sql<
      {
        version: string
        build_number: number
        download_url: string
        file_size: string
        sha256: string
        release_notes: string
        is_mandatory: boolean
        min_supported_build: number
        released_at: Date
      }[]
    >`
      SELECT version, build_number, download_url, file_size, sha256,
             release_notes, is_mandatory, min_supported_build, released_at
      FROM app_releases
      WHERE channel = ${app.env.UPDATE_CHANNEL} AND is_active
      ORDER BY build_number DESC
      LIMIT 1
    `

    const row = rows[0]
    if (!row) return null

    return {
      version: row.version,
      buildNumber: row.build_number,
      downloadUrl: row.download_url,
      fileSize: Number(row.file_size),
      sha256: row.sha256,
      releaseNotes: row.release_notes,
      isMandatory: row.is_mandatory,
      minSupportedBuild: row.min_supported_build,
      releasedAt: row.released_at.toISOString(),
    }
  } finally {
    await sql.end({ timeout: 1 })
  }
}
