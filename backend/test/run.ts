import { report, settle, exitCode } from './helpers.js'

await import('./money.test.js')
await import('./migrate.test.js')
await import('./schema.test.js')
await import('./health.test.js')

await settle()
report('backend')
process.exit(exitCode())
