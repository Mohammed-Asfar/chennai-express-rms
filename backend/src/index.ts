import { loadEnv } from './lib/env.js'
import { openDatabase } from './db/client.js'
import { migrate } from './db/migrate.js'
import { seedIfEmpty } from './db/seed.js'
import { buildServer } from './server.js'

const env = loadEnv()
const db = openDatabase(env.DB_PATH)

// Migrations run at boot. A checksum mismatch throws here and stops startup —
// running against a schema that does not match the code is worse than not starting.
const applied = migrate(db)

const { seeded } = await seedIfEmpty(db, env)

const app = await buildServer({ db, env })

if (seeded) {
  app.log.warn(
    { username: env.SEED_ADMIN_USERNAME },
    'seeded initial admin account - the password must be changed at first login',
  )
}

if (applied.length > 0) {
  app.log.info({ migrations: applied }, 'applied pending migrations')
}

app.sync.start()

const shutdown = async (signal: string): Promise<void> => {
  app.log.info({ signal }, 'shutting down')
  app.sync.stop()
  await app.close()
  db.close()
  process.exit(0)
}

process.on('SIGINT', () => void shutdown('SIGINT'))
process.on('SIGTERM', () => void shutdown('SIGTERM'))

try {
  await app.listen({ port: env.PORT, host: env.HOST })
} catch (error) {
  app.log.error({ err: error }, 'failed to start')
  process.exit(1)
}
