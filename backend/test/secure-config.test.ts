import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { encrypt, decrypt, loadSecureConfig } from '../src/lib/secure-config.js'
import { test, assertEqual } from './helpers.js'

/**
 * DPAPI is Windows-only. Elsewhere these skip rather than fail — the product
 * ships on Windows and the CI box may not be.
 */
const onWindows = process.platform === 'win32'

if (!onWindows) {
  test('secure config tests skipped (not Windows)', () => {})
} else {
  test('a secret survives the round trip', () => {
    const secret = 'CLOUD_DATABASE_URL=postgres://u:p@ep.neon.tech/db?sslmode=require'
    assertEqual(decrypt(encrypt(secret)), secret, 'decrypts to what was encrypted')
  })

  test('the ciphertext does not contain the plaintext', () => {
    // The whole point: a cashier opening config.dat in Notepad must not find a
    // connection string in it.
    const cipher = encrypt('CLOUD_DATABASE_URL=postgres://user:hunter2@ep.neon.tech/db')
    if (cipher.includes('neon.tech')) throw new Error('host leaked into the ciphertext')
    if (cipher.includes('hunter2')) throw new Error('password leaked into the ciphertext')
  })

  test('the ciphertext is transportable text', () => {
    // Written to and read from a file as UTF-8, so it has to survive that.
    const cipher = encrypt('A=1')
    if (!/^[A-Za-z0-9+/=]+$/.test(cipher)) throw new Error(`not base64: ${cipher.slice(0, 40)}`)
  })

  test('multi-line configuration round trips intact', () => {
    const config = ['JWT_SECRET=abc', 'CLOUD_DATABASE_URL=postgres://x', 'NODE_ENV=production'].join('\n')
    assertEqual(decrypt(encrypt(config)), config, 'newlines preserved')
  })

  test('config is loaded into the environment', () => {
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    const key = 'SEED_BRANCH_NAME'
    const previous = process.env[key]
    delete process.env[key]

    try {
      writeFileSync(join(dir, 'config.dat'), encrypt(`${key}=From Config`))
      const result = loadSecureConfig(dir)

      assertEqual(result.loaded, true, 'the file was found')
      assertEqual(process.env[key], 'From Config', 'the value reached the environment')
    } finally {
      if (previous === undefined) delete process.env[key]
      else process.env[key] = previous
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('the environment wins over the config file', () => {
    // An operator debugging a till, or a service definition, must be able to
    // override without decrypting and rewriting the file.
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    const key = 'SEED_BRANCH_NAME'
    const previous = process.env[key]
    process.env[key] = 'From Environment'

    try {
      writeFileSync(join(dir, 'config.dat'), encrypt(`${key}=From Config`))
      loadSecureConfig(dir)
      assertEqual(process.env[key], 'From Environment', 'the environment was not overwritten')
    } finally {
      if (previous === undefined) delete process.env[key]
      else process.env[key] = previous
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('keys outside the allow list are ignored', () => {
    // config.dat is written by the installer, but it sits on a machine someone
    // else controls. A rewritten file must not be able to set PATH or
    // NODE_OPTIONS and get code loaded into the service.
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    const previous = process.env.NODE_OPTIONS
    delete process.env.NODE_OPTIONS

    try {
      writeFileSync(join(dir, 'config.dat'), encrypt('NODE_OPTIONS=--require ./evil.js'))
      loadSecureConfig(dir)
      assertEqual(process.env.NODE_OPTIONS, undefined, 'NODE_OPTIONS was not set')
    } finally {
      if (previous !== undefined) process.env.NODE_OPTIONS = previous
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('a missing config file is not an error', () => {
    // Development has no config.dat and must still start.
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    try {
      assertEqual(loadSecureConfig(dir).loaded, false, 'reports not loaded')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('a config from another machine fails loudly', () => {
    // Corrupt ciphertext stands in for one copied from a different PC: DPAPI
    // rejects both the same way. Silently starting half-configured would be
    // worse than refusing.
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    try {
      writeFileSync(join(dir, 'config.dat'), 'bm90LXJlYWxseS1lbmNyeXB0ZWQtYXQtYWxs')

      let threw = false
      try {
        loadSecureConfig(dir)
      } catch (error) {
        threw = true
        const message = error instanceof Error ? error.message : String(error)
        if (!message.includes('encrypted to the PC')) {
          throw new Error(`unhelpful message for staff: ${message}`)
        }
      }
      assertEqual(threw, true, 'refuses rather than continuing')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('comments and blank lines are skipped', () => {
    const dir = mkdtempSync(join(tmpdir(), 'cfg-'))
    const key = 'SEED_ADMIN_USERNAME'
    const previous = process.env[key]
    delete process.env[key]

    try {
      writeFileSync(
        join(dir, 'config.dat'),
        encrypt(['# written by the installer', '', `${key}=cashier`, ''].join('\n')),
      )
      assertEqual(loadSecureConfig(dir).keys, 1, 'one key, not three')
      assertEqual(process.env[key], 'cashier', 'the real key was read')
    } finally {
      if (previous === undefined) delete process.env[key]
      else process.env[key] = previous
      rmSync(dir, { recursive: true, force: true })
    }
  })
}
