import { FREE_TIER_BYTES } from '../src/sync/storage.js'
import { test, assertEqual } from './helpers.js'

// --- the quota the screen measures against ---

test('the free tier limit is 0.5 GB as the host counts it', () => {
  // Neon counts a GB as 1000³, not 1024³. The limit was written as
  // 512 * 1024 * 1024, which is 512 MiB — 7% more headroom than the plan
  // actually gives, so the screen would have read "within limits" while the
  // project was already over.
  assertEqual(FREE_TIER_BYTES, 500_000_000, '0.5 GB in the host’s units')
})

test('the limit is not the binary 512 MiB it was', () => {
  // Named separately because the two are easy to confuse at a glance and the
  // difference only shows up at the point it matters.
  const binary512 = 512 * 1024 * 1024
  if (FREE_TIER_BYTES === binary512) {
    throw new Error('FREE_TIER_BYTES is 512 MiB again; the plan is 0.5 GB (500 MB)')
  }
})
