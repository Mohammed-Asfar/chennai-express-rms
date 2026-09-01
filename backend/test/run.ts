import { report, settle, exitCode } from './helpers.js'

await import('./money.test.js')
await import('./migrate.test.js')
await import('./schema.test.js')
await import('./health.test.js')
await import('./auth.test.js')
await import('./updates.test.js')
await import('./menu.test.js')
await import('./tables.test.js')
await import('./business-date.test.js')
await import('./orders.test.js')

await settle()
report('backend')
process.exit(exitCode())
