#!/usr/bin/env node
/**
 * Regenerates the certificate roots the desktop app ships for its installer
 * download.
 *
 * Dart on Windows validates TLS against the Windows certificate store, which on
 * a till is frequently missing issuers it was supposed to fetch from Windows
 * Update — 1.0.7 could not be downloaded on a branch for exactly that reason.
 * Carrying our own roots makes the download depend on the shipped app instead
 * of on the machine it landed on.
 *
 * The source is Node's built-in root set, which is Mozilla's CA list as vendored
 * by the Node release this runs on. That means the bundle is only as fresh as
 * your Node install: run this on a current LTS.
 *
 * Roots expire and are withdrawn, so re-run this periodically — a bundle that
 * has aged out cannot be fixed from the field, because the app that would
 * download its own replacement is the one that can no longer connect.
 *
 *   node scripts/refresh-ca-roots.mjs
 */
import { rootCertificates } from 'node:tls'
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const target = resolve(here, '../../desktop/assets/ca_roots.pem')

// The hosts the installer is actually fetched from. GitHub redirects the
// download to a different host with a different root, so both must verify —
// checking only the URL we publish would miss the hop that does the transfer.
const MUST_VERIFY = ['github.com', 'objects.githubusercontent.com']

const previous = existsSync(target)
  ? (readFileSync(target, 'utf8').match(/BEGIN CERTIFICATE/g) ?? []).length
  : 0

const body = rootCertificates.join('\n') + '\n'
writeFileSync(target, body)

console.log(`Wrote ${rootCertificates.length} roots to ${target}`)
if (previous) console.log(`Previously ${previous}.`)
console.log(`Node ${process.version}\n`)

// Writing the file proves nothing about whether it works. Connect with only
// these roots trusted and confirm the download hosts still verify.
const tls = await import('node:tls')
let failed = false

for (const host of MUST_VERIFY) {
  await new Promise((done) => {
    const socket = tls.connect(
      { host, port: 443, servername: host, ca: rootCertificates, rejectUnauthorized: true },
      () => {
        console.log(`  ok    ${host}`)
        socket.end()
        done()
      },
    )
    socket.on('error', (err) => {
      console.error(`  FAIL  ${host} — ${err.message}`)
      failed = true
      done()
    })
  })
}

if (failed) {
  console.error('\nA download host did not verify against this bundle. Not usable.')
  process.exit(1)
}
console.log('\nAll download hosts verify against the bundle.')
