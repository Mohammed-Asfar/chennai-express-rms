import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Reads the installed configuration, encrypted to this machine.
 *
 * The cloud connection string and the JWT secret cannot ship as plain text on a
 * restaurant's PC. Anyone who can read the connection string can point their own
 * copy at the licence database and mint themselves a key; anyone who can read
 * the JWT secret can forge an admin session.
 *
 * **What this does and does not protect against.** The config is encrypted with
 * Windows DPAPI at machine scope, so the file is useless if copied to another
 * PC — which is the realistic threat, alongside a curious member of staff
 * opening it in Notepad. It is *not* protection against an administrator on the
 * billing PC itself: the service has to decrypt it to work, so anyone who can
 * run code as the service account can read what the service reads. Nothing
 * short of a hardware module changes that, and the honest mitigation is the
 * directory ACL, which stops a non-administrator getting that far.
 *
 * Absent config is not an error. Development runs from `.env` and the
 * environment as before; only an installed service has an encrypted file.
 */

const CONFIG_FILENAME = 'config.dat'

/**
 * Keys the installer may write. Anything else in the file is ignored.
 *
 * Must list every key `configure.ts` writes. NODE_ENV was missing from here
 * while the installer wrote it, so every installed till silently ran as
 * `development` — the key was dropped without a word and the default applied.
 * A silently discarded configuration line is worse than a rejected one.
 */
export const ALLOWED_CONFIG_KEYS = new Set([
  'CLOUD_DATABASE_URL',
  'JWT_SECRET',
  'NODE_ENV',
  'UPDATE_CHANNEL',
  'PORT',
  'HOST',
  'DB_PATH',
  'LOG_LEVEL',
  'SEED_BRANCH_NAME',
  'SEED_ADMIN_USERNAME',
  'SEED_ADMIN_PASSWORD',
])

/**
 * Loads `config.dat` from beside the running server, if it is there.
 *
 * Values already in the environment win, so a service definition or an operator
 * debugging on the machine can override without editing the encrypted file.
 */
export function loadSecureConfig(directory?: string): { loaded: boolean; keys: number } {
  const path = join(directory ?? installDirectory(), CONFIG_FILENAME)
  if (!existsSync(path)) return { loaded: false, keys: 0 }

  let plaintext: string
  try {
    plaintext = decrypt(readFileSync(path, 'utf8').trim())
  } catch (error) {
    // A config that cannot be decrypted is almost always one copied from another
    // machine. Failing loudly beats silently falling back to a half-configured
    // server that starts and then behaves strangely.
    throw new Error(
      'The configuration file could not be read on this machine. ' +
        'It is encrypted to the PC it was installed on and cannot be moved. ' +
        `Reinstall to generate a new one. (${error instanceof Error ? error.message : error})`,
    )
  }

  let keys = 0
  for (const line of plaintext.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue

    const eq = trimmed.indexOf('=')
    if (eq === -1) continue

    const key = trimmed.slice(0, eq).trim()
    if (!ALLOWED_CONFIG_KEYS.has(key)) continue
    if (process.env[key] !== undefined) continue

    process.env[key] = trimmed.slice(eq + 1).trim()
    keys += 1
  }

  return { loaded: true, keys }
}

/**
 * Encrypts a string so only this machine can read it back.
 *
 * Used by the installer, not at runtime.
 */
export function encrypt(plaintext: string): string {
  return dpapi('Protect', plaintext)
}

export function decrypt(ciphertext: string): string {
  return dpapi('Unprotect', ciphertext)
}

/**
 * Calls DPAPI through PowerShell.
 *
 * `LocalMachine` scope rather than `CurrentUser`: the service runs as
 * LocalSystem while the installer runs as the administrator installing it, and
 * user scope would mean the service could not read what the installer wrote.
 *
 * The trade-off is that any account on this PC can decrypt it. That is what the
 * directory ACL is for — DPAPI stops the file travelling, the ACL stops the
 * cashier reading it.
 */
function dpapi(direction: 'Protect' | 'Unprotect', input: string): string {
  if (process.platform !== 'win32') {
    throw new Error('Encrypted configuration is only supported on Windows')
  }

  // `$payload`, not `$input`: PowerShell binds `$input` to the pipeline
  // enumerator, and assigning to it leaves the variable unusable — Protect
  // silently encrypts the wrong thing and Unprotect fails with "The parameter is
  // incorrect".
  const body =
    direction === 'Protect'
      ? `
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
        [Convert]::ToBase64String($enc)
      `
      : `
        $bytes = [Convert]::FromBase64String($payload)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')
        [Text.Encoding]::UTF8.GetString($dec)
      `

  // Passed on stdin, never as an argument: a command line is visible to every
  // process on the machine, which would defeat the point for the plaintext.
  const script = `
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Security
    $payload = [Console]::In.ReadToEnd().Trim()
    ${body}
  `

  // stderr is discarded: a rejected blob is an expected outcome, handled by the
  // caller with a message written for staff. PowerShell's exception dump would
  // otherwise print over it and tell them nothing they can act on.
  const output = execFileSync(
    'powershell',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    {
      input,
      encoding: 'utf8',
      windowsHide: true,
      timeout: 15_000,
      stdio: ['pipe', 'pipe', 'ignore'],
    },
  )

  return output.trim()
}

/** The directory holding the running server — where the installer puts config.dat. */
function installDirectory(): string {
  return dirname(fileURLToPath(import.meta.url))
}
