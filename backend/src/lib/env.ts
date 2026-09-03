import { z } from 'zod'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadSecureConfig } from './secure-config.js'

/**
 * Loads `.env` into `process.env` without a dependency.
 *
 * Existing environment variables win, so a value set on the command line is
 * never silently overridden by the file.
 */
function loadDotEnv(path = '.env'): void {
  if (!existsSync(path)) return
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue
    const eq = trimmed.indexOf('=')
    if (eq === -1) continue
    const key = trimmed.slice(0, eq).trim()
    if (process.env[key] !== undefined) continue
    let value = trimmed.slice(eq + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    process.env[key] = value
  }
}

/**
 * Where the database lives when nothing overrides it.
 *
 * An installed copy sits under Program Files, which is read-only for anyone
 * who is not an administrator — creating `data/` beside the server fails with
 * EPERM and the backend dies before it listens. Per-machine application data
 * belongs in ProgramData on Windows, which is writable by design.
 *
 * A source checkout keeps `./data`, so a developer's database stays in the
 * working tree where it can be inspected and deleted freely.
 *
 * The distinction is the bundle: an installed build is a single `server.mjs`
 * at the install root, while the source runs as `src/lib/env.ts`.
 */
export function defaultDatabasePath(moduleUrl: string = import.meta.url): string {
  const bundled = fileURLToPath(moduleUrl).endsWith("server.mjs")
  if (!bundled) return './data/chennai-express.db'

  const base = process.env.PROGRAMDATA ?? 'C:\\ProgramData'
  return join(base, 'Chennai Express', 'chennai-express.db')
}

const schema = z.object({
  PORT: z.coerce.number().int().positive().default(4000),
  HOST: z.string().default('127.0.0.1'),
  DB_PATH: z.string().default(defaultDatabasePath()),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),

  JWT_SECRET: z.string().min(32).optional(),
  /** 12 hours — longer than a shift, so staff are not logged out mid-service. */
  JWT_EXPIRES_SECONDS: z.coerce.number().int().positive().default(12 * 60 * 60),

  /** Seeded on first run. The admin is forced to change it at first login. */
  SEED_ADMIN_USERNAME: z.string().default('admin'),
  SEED_ADMIN_PASSWORD: z.string().min(4).default('admin123'),
  SEED_BRANCH_NAME: z.string().default('Chennai Express'),

  /** Neon connection string. Absent means no cloud sync and no update checks. */
  CLOUD_DATABASE_URL: z.string().optional(),
  UPDATE_CHANNEL: z.enum(['stable', 'beta']).default('stable'),
})

export type Env = z.infer<typeof schema> & { JWT_SECRET: string }

export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  if (source === process.env) {
    // An installed service reads config.dat, encrypted to this machine. A
    // development checkout has no such file and falls through to .env.
    loadSecureConfig()
    loadDotEnv()
  }
  const parsed = schema.safeParse(source)
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n')
    throw new Error(`Invalid environment configuration:\n${issues}`)
  }

  const env = parsed.data

  // A hardcoded fallback secret in production would let anyone mint a valid token.
  if (env.NODE_ENV === 'production' && !env.JWT_SECRET) {
    throw new Error('JWT_SECRET is required in production (minimum 32 characters)')
  }

  return {
    ...env,
    JWT_SECRET: env.JWT_SECRET ?? 'dev-only-insecure-secret-do-not-use-in-production',
  }
}

// Bind to loopback by default. The billing PC's backend is not a network service;
// waiter tablets on the LAN would need an explicit HOST override plus auth.
