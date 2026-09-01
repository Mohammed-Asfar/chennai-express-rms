/**
 * The running application version.
 *
 * `buildNumber` is what update comparison uses — a monotonic integer cannot be
 * ambiguous, whereas comparing semantic version strings correctly is fiddly and
 * easy to get subtly wrong. `version` is for humans.
 *
 * Bump both on every release. The installer and this constant must agree.
 */
export const APP_VERSION = '1.0.0'
export const APP_BUILD_NUMBER = 1

export interface ReleaseInfo {
  version: string
  buildNumber: number
  downloadUrl: string
  fileSize: number
  sha256: string
  releaseNotes: string
  isMandatory: boolean
  releasedAt: string
}

export interface UpdateCheckResult {
  currentVersion: string
  currentBuild: number
  updateAvailable: boolean
  /** True when this build is below the release's `min_supported_build`. */
  isForced: boolean
  release: ReleaseInfo | null
  /** Set when the check could not run — the client treats this as "no update". */
  unavailableReason?: string
}

/**
 * Decides whether `release` is an update for `currentBuild`.
 *
 * Forced when the release is flagged mandatory, or when the running build is below
 * the minimum it supports — the case that matters after a billing-math fix, where
 * an old build would keep producing wrong bills.
 */
export function evaluateRelease(
  currentBuild: number,
  release: (ReleaseInfo & { minSupportedBuild: number }) | null,
): { updateAvailable: boolean; isForced: boolean } {
  if (!release || release.buildNumber <= currentBuild) {
    return { updateAvailable: false, isForced: false }
  }
  return {
    updateAvailable: true,
    isForced: release.isMandatory || currentBuild < release.minSupportedBuild,
  }
}
