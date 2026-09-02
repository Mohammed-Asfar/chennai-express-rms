import { loadEnv } from './lib/env.js'
import { openDatabase } from './db/client.js'
import { migrate } from './db/migrate.js'
import { seedIfEmpty } from './db/seed.js'
import { restoreIfEmpty } from './db/restore.js'
import { buildServer } from './server.js'

const env = loadEnv()

// Before the database is opened, and before seeding. Restore builds a staging file
// and swaps it into place complete, so an interrupted attempt leaves nothing
// half-written for this process to open. Seeding first would mint a new branch id
// and make the branch already in the cloud unreachable.
const restore = await restoreIfEmpty(env)

const db = openDatabase(env.DB_PATH)

// Migrations run at boot. A checksum mismatch throws here and stops startup —
// running against a schema that does not match the code is worse than not starting.
const applied = migrate(db)

const { seeded } = await seedIfEmpty(db, env)

const app = await buildServer({ db, env })

if (restore.restored) {
  app.log.warn(
    {
      branch: restore.branchName,
      bills: restore.billCount,
      rows: restore.result?.restored,
      errors: restore.result?.errors,
    },
    'restored the local database from the cloud',
  )
} else if (restore.attempted) {
  app.log.info({ reason: restore.reason }, 'no cloud restore performed')
}

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

// Retries tickets that have not gone out. Without it a job left pending by an
// offline printer stays pending forever: nothing tries it again, and the queue
// panel offers no Retry because it has not given up yet.
app.printQueue.start()

const shutdown = async (signal: string): Promise<void> => {
  app.log.info({ signal }, 'shutting down')
  app.sync.stop()
  app.printQueue.stop()
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
