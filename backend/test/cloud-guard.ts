import { loadEnv } from '../src/lib/env.js'

/**
 * The Postgres database the cloud tests are allowed to destroy.
 *
 * Cloud tests TRUNCATE every synced table between cases, so they need a database
 * of their own. `TEST_CLOUD_DATABASE_URL` must be set explicitly and must differ
 * from `CLOUD_DATABASE_URL`; without it every cloud test skips.
 *
 * This exists because the tests once ran against the development cloud — the same
 * database the running app was syncing to — and truncated it. Reading
 * `CLOUD_DATABASE_URL` here would be one keystroke away from doing that again, so
 * the variable is never consulted except to refuse a match.
 */
export function testCloudUrl(): string | undefined {
  const env = loadEnv()
  const test = process.env.TEST_CLOUD_DATABASE_URL?.trim()
  if (!test) return undefined

  // Same database under two names is the exact accident this guards against.
  if (env.CLOUD_DATABASE_URL && sameDatabase(test, env.CLOUD_DATABASE_URL)) {
    throw new Error(
      'TEST_CLOUD_DATABASE_URL points at the same database as CLOUD_DATABASE_URL. ' +
        'Cloud tests truncate every table — point them at a separate database.',
    )
  }

  return test
}

/** Compares host, port and database name, ignoring credentials and options. */
function sameDatabase(a: string, b: string): boolean {
  try {
    const one = new URL(a)
    const two = new URL(b)
    return (
      one.host === two.host && one.pathname.toLowerCase() === two.pathname.toLowerCase()
    )
  } catch {
    // Unparseable: fall back to comparing the strings, which errs towards refusing.
    return a === b
  }
}
