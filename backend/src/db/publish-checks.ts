/**
 * The checks that decide whether a published installer is safe to announce.
 *
 * Separated from `publish.ts` so they can be tested without a network or a
 * GitHub token. The script supplies the facts — what GitHub says it stored,
 * what came back down the wire — and these decide.
 *
 * **Why this exists.** 1.0.5 was published and verified as matching, yet GitHub
 * served a file 11 MB short of the installer. Every till downloaded it, found
 * the hash disagreed with `app_releases`, and refused to update. The guard on
 * the till did its job; the publisher had already said the upload was fine.
 *
 * The lesson is that hashing the download is not enough on its own. The size
 * GitHub records for the stored asset is a second, independent witness, and it
 * disagreed immediately — 43,542,605 against 54,964,421.
 */

export interface PublishedAsset {
  /** Bytes GitHub reports for the stored asset. */
  size: number
  /** `uploaded` once GitHub considers it complete. */
  state: string
}

export interface LocalFile {
  size: number
  sha256: string
}

export interface Downloaded {
  size: number
  sha256: string
}

export type CheckResult =
  | { ok: true }
  | { ok: false; retryable: boolean; reason: string }

/**
 * Whether the asset GitHub stored is the file that was built.
 *
 * Run before downloading anything: it is one API call, and it catches a
 * truncated upload without pulling 50 MB back down.
 *
 * A size mismatch is [retryable] — the upload is the thing that went wrong, and
 * doing it again is the fix. So is an asset still settling, which is a state
 * other than `uploaded`.
 */
export function checkStoredAsset(asset: PublishedAsset, local: LocalFile): CheckResult {
  if (asset.state !== 'uploaded') {
    return {
      ok: false,
      retryable: true,
      reason: `the asset is in state "${asset.state}", not "uploaded"`,
    }
  }

  if (asset.size !== local.size) {
    const short = local.size - asset.size
    return {
      ok: false,
      retryable: true,
      reason:
        `GitHub stored ${asset.size} bytes, the installer is ${local.size} — ` +
        `${short > 0 ? `${short} short` : `${-short} too many`}`,
    }
  }

  return { ok: true }
}

/**
 * Whether the bytes that actually came down the public URL are the installer.
 *
 * The size is checked before the hash, because a short read says plainly what
 * went wrong where two different hashes only say that something did.
 *
 * Not retryable: the upload already looked right, so a differing download is
 * either a corrupted store or something serving the wrong file, and repeating
 * the upload is unlikely to help. It needs a person.
 */
export function checkDownload(got: Downloaded, local: LocalFile): CheckResult {
  if (got.size !== local.size) {
    return {
      ok: false,
      retryable: false,
      reason: `the download is ${got.size} bytes, the installer is ${local.size}`,
    }
  }

  if (got.sha256 !== local.sha256) {
    return {
      ok: false,
      retryable: false,
      reason: `the download hashes to ${got.sha256}, the installer to ${local.sha256}`,
    }
  }

  return { ok: true }
}
