import { checkStoredAsset, checkDownload } from '../src/db/publish-checks.js'
import { test, assertEqual } from './helpers.js'

/** The 1.0.5 installer, as built. */
const local = {
  size: 54_964_421,
  sha256: '6c3040ffde3b50a620fb9a05736e74bdc6c501d5f9876f3047e3b3e5df81c341',
}

// --- what GitHub says it stored ---

test('a complete upload passes', () => {
  const result = checkStoredAsset({ size: local.size, state: 'uploaded' }, local)
  assertEqual(result.ok, true)
})

test('the truncated 1.0.5 upload is caught', () => {
  // The real numbers. GitHub stored 43,542,605 bytes of a 54,964,421-byte
  // installer, marked it uploaded, and served it to every till.
  const result = checkStoredAsset({ size: 43_542_605, state: 'uploaded' }, local)

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.retryable, true, 'a bad upload is worth repeating')
  assertEqual(result.reason.includes('11421816 short'), true, result.reason)
})

test('a single missing byte is caught', () => {
  // Nothing here is a tolerance. A file that is one byte short will not run.
  const result = checkStoredAsset({ size: local.size - 1, state: 'uploaded' }, local)
  assertEqual(result.ok, false)
})

test('an asset still settling is not accepted', () => {
  // `starter` and `open` both mean GitHub has not finished with it, and its
  // size cannot be trusted yet.
  const result = checkStoredAsset({ size: local.size, state: 'starter' }, local)

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.retryable, true)
})

test('an oversized asset is caught too', () => {
  // Less likely than a truncation, but it is not the installer either.
  const result = checkStoredAsset({ size: local.size + 4_096, state: 'uploaded' }, local)

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.reason.includes('4096 too many'), true, result.reason)
})

// --- what actually came down the wire ---

test('a matching download passes', () => {
  const result = checkDownload({ size: local.size, sha256: local.sha256 }, local)
  assertEqual(result.ok, true)
})

test('a short download is reported as short, not as a hash mismatch', () => {
  // Two hashes tell you something is wrong. A byte count tells you what.
  const result = checkDownload(
    { size: 43_542_605, sha256: 'd16d53ae0b9a63de0e832583d686fe33de35eeb7741e5eb2cfeb96861c3efa5d' },
    local,
  )

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.reason.includes('43542605 bytes'), true, result.reason)
})

test('a right-sized file with the wrong contents is caught', () => {
  // The case only the hash can catch: same length, different build.
  const result = checkDownload({ size: local.size, sha256: 'a'.repeat(64) }, local)

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.reason.includes('hashes to'), true, result.reason)
})

test('a bad download is not retried automatically', () => {
  // The upload already looked right, so repeating it is unlikely to help.
  // Something is serving the wrong bytes, and that needs a person.
  const result = checkDownload({ size: local.size, sha256: 'b'.repeat(64) }, local)

  assertEqual(result.ok, false)
  if (result.ok) return
  assertEqual(result.retryable, false)
})

test('an error page served instead of the file is caught', () => {
  // curl without --fail follows a 404 into an HTML body and exits zero. That
  // body is a few hundred bytes, so the size check ends it.
  const result = checkDownload({ size: 1_234, sha256: 'c'.repeat(64) }, local)
  assertEqual(result.ok, false)
})
