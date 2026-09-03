import { defaultDatabasePath } from '../src/lib/env.js'
import { test, assertEqual } from './helpers.js'

/**
 * Where the database goes when nothing says otherwise.
 *
 * This exists because of a shipped bug: the default was `./data` beside the
 * server, and an installed copy lives under Program Files, which is read-only
 * for anyone who is not an administrator. Every install died with
 *
 *   EPERM: operation not permitted, mkdir 'C:\Program Files\...\backend\data'
 *
 * before the server ever listened. The bundle's smoke test could not catch it —
 * the bundle directory is writable while that runs, so the wrong default worked
 * there and failed everywhere that mattered.
 */

test('an installed build writes to ProgramData', () => {
  const path = defaultDatabasePath('file:///C:/Program%20Files/Chennai%20Express/backend/server.mjs')

  if (!path.toLowerCase().includes('programdata')) {
    throw new Error(`installed build would write to ${path} — that fails with EPERM`)
  }
})

test('an installed build does not write beside itself', () => {
  const path = defaultDatabasePath('file:///C:/Program%20Files/Chennai%20Express/backend/server.mjs')

  // The specific shape of the bug: a relative path resolves against the process
  // working directory, which for a spawned backend is its own install folder.
  if (path.startsWith('./') || path.startsWith('.\\')) {
    throw new Error(`installed build uses a relative path: ${path}`)
  }
})

test('a source checkout keeps its database in the working tree', () => {
  // A developer's database stays where it can be inspected and deleted, not
  // buried in ProgramData.
  const path = defaultDatabasePath('file:///D:/work/backend/src/lib/env.ts')
  assertEqual(path, './data/chennai-express.db', 'source checkout uses ./data')
})

test('the bundled path is absolute', () => {
  // The backend is spawned by the app with the install directory as its working
  // directory. Anything relative would resolve there, which is the read-only
  // location this whole function exists to avoid.
  const path = defaultDatabasePath('file:///C:/Program%20Files/Chennai%20Express/backend/server.mjs')

  if (!/^[A-Za-z]:[\\/]/.test(path)) {
    throw new Error(`expected an absolute Windows path, got ${path}`)
  }
})
