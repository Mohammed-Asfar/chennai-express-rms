import { z } from 'zod'
import { existsSync, readFileSync } from 'node:fs'

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

const schema = z.object({
  PORT: z.coerce.number().int().positive().default(4000),
  HOST: z.string().default('127.0.0.1'),
  DB_PATH: z.string().default('./data/chennai-express.db'),
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
  if (source === process.env) loadDotEnv()
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
