/**
 * Bundles the backend for shipping.
 *
 * Produces `dist-bundle/` holding one JavaScript file, the two native modules
 * that cannot be bundled, the SQL migrations, and a private Node runtime. The
 * result runs on a PC with no Node installed and no source on disk.
 *
 *   node scripts/bundle.mjs
 *
 * **Why bundle at all.** `.env` sits in the source tree as readable text. Anyone
 * who can open it can point the backend at their own Postgres and mint themselves
 * a licence. The bundle takes its configuration from an encrypted file written by
 * the installer instead, and the install directory is ACL-locked so a non-admin
 * cannot replace it.
 *
 * **Why not a single .exe.** `better-sqlite3` and `sharp` are native addons —
 * compiled `.node` binaries that a JavaScript bundler cannot inline. Node's SEA
 * support can carry them, but the unpacking is fragile across Node versions and
 * a failure mode there is a till that will not start. A directory with a private
 * runtime is boring, and boring is what a billing PC needs.
 */
import { build } from 'esbuild'
import { closeSync, cpSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync, spawn } from 'node:child_process'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const out = join(root, 'dist-bundle')

/**
 * Native addons, copied rather than bundled.
 *
 * Marked external below so esbuild leaves the `require` in place; the paths are
 * rewritten at runtime by `native-path.cjs`.
 */
const NATIVE = ['better-sqlite3', 'sharp']

// `--smoke-only` runs the check against whatever is already in dist-bundle,
// without rebuilding. It is how the smoke test itself gets verified: break the
// bundle by hand, then confirm the check notices.
if (process.argv.includes('--smoke-only')) {
  if (!existsSync(join(out, 'server.mjs'))) {
    console.error('Nothing to test — run without --smoke-only first.')
    process.exit(1)
  }
  smokeTest(out)
  process.exit(0)
}

console.log('Bundling the backend')
console.log('')

rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })

// --- 1. the JavaScript ---

const result = await build({
  entryPoints: [join(root, 'src/index.ts')],
  bundle: true,
  platform: 'node',
  target: 'node20',
  // ESM, because the source uses top-level await — index.ts awaits the restore
  // and the seed before the server is built, and CJS cannot express that.
  format: 'esm',
  outfile: join(out, 'server.mjs'),
  // Native addons resolve through node_modules at runtime, not through the
  // bundle. Everything else is inlined.
  external: NATIVE,
  // esbuild's ESM output has no require(); the native addons need one.
  banner: {
    js: [
      "import { createRequire as __createRequire } from 'node:module'",
      'const require = __createRequire(import.meta.url)',
    ].join('\n'),
  },
  minify: false,
  sourcemap: false,
  // A stack trace from a restaurant's log is worth more than the few hundred
  // kilobytes minifying would save.
  legalComments: 'none',
  define: {
    'process.env.NODE_ENV': '"production"',
  },
  logLevel: 'warning',
})

if (result.errors.length > 0) {
  console.error('Bundle failed')
  process.exit(1)
}

const bundleSize = readFileSync(join(out, 'server.mjs')).length
console.log(`  server.mjs            ${kb(bundleSize)}`)

// --- 2. the native modules ---

mkdirSync(join(out, 'node_modules'), { recursive: true })

for (const name of NATIVE) {
  const from = join(root, 'node_modules', name)
  if (!existsSync(from)) {
    console.error(`  ${name} is not installed — run pnpm install first`)
    process.exit(1)
  }

  // pnpm symlinks node_modules; dereference so the bundle is self-contained.
  cpSync(from, join(out, 'node_modules', name), {
    recursive: true,
    dereference: true,
    filter: (src) => !src.includes(`${name}\\test`) && !src.includes(`${name}/test`),
  })
  console.log(`  node_modules/${name}`)
}

// sharp ships its platform binaries as separate @img packages.
copyScopedDeps(out)

// The native modules are external to the bundle, so their own runtime imports
// are too. sharp reaches for detect-libc and semver at load time; missing them
// is a till that will not start.
copyRuntimeDeps(out)

// --- 3. migrations ---

// Read from disk at boot by `migrate.ts`, so they must travel with the bundle.
cpSync(join(root, 'db'), join(out, 'db'), { recursive: true })
console.log('  db/migrations')

// --- 4. the launcher ---

writeFileSync(
  join(out, 'start.cmd'),
  [
    '@echo off',
    'rem Starts the billing service. Run by the Windows service wrapper.',
    'setlocal',
    'cd /d "%~dp0"',
    'node\\node.exe server.mjs',
    'endlocal',
    '',
  ].join('\r\n'),
)
console.log('  start.cmd')

// --- 5. a private Node runtime ---

const nodeExe = process.execPath
mkdirSync(join(out, 'node'), { recursive: true })
cpSync(nodeExe, join(out, 'node', 'node.exe'))

const nodeVersion = execFileSync(nodeExe, ['--version'], { encoding: 'utf8' }).trim()
console.log(`  node/node.exe         ${nodeVersion}`)

// --- 6. version stamp ---

const version = readFileSync(join(root, 'src/lib/version.ts'), 'utf8')
const appVersion = version.match(/APP_VERSION\s*=\s*'([^']+)'/)?.[1] ?? '0.0.0'
const buildNumber = version.match(/APP_BUILD_NUMBER\s*=\s*(\d+)/)?.[1] ?? '0'

writeFileSync(
  join(out, 'build.json'),
  JSON.stringify(
    {
      version: appVersion,
      buildNumber: Number(buildNumber),
      node: nodeVersion,
      builtAt: new Date().toISOString(),
    },
    null,
    2,
  ),
)

// --- 7. prove it starts ---

smokeTest(out)

console.log('')
console.log(`Bundled ${appVersion} (build ${buildNumber}) to dist-bundle/`)
console.log('')
console.log('The bundle carries no .env. Configuration is written by the installer')
console.log('to an encrypted config file — see scripts/README.md.')

/**
 * Starts the bundle and asks it a question.
 *
 * Not optional, and not a nicety. Every failure this script has produced so far
 * built without complaint and died on first run: a missing `detect-libc` that
 * only sharp imports, and a migrations path correct in the source tree and wrong
 * in the bundle. Neither is visible in the output of a successful build.
 *
 * The check runs against a throwaway database in a temp directory, so it proves
 * the native modules load and the migrations are found without touching anything
 * the developer cares about.
 */
function smokeTest(bundleDir) {
  const scratch = join(bundleDir, '.smoke')
  rmSync(scratch, { recursive: true, force: true })
  mkdirSync(scratch, { recursive: true })

  // Output goes to a file rather than a pipe: this function polls synchronously,
  // so the event loop never turns and stream handlers would never fire.
  const logPath = join(scratch, 'smoke.log')
  const log = openSync(logPath, 'w')

  const child = spawn(join(bundleDir, 'node', 'node.exe'), ['server.mjs'], {
    cwd: bundleDir,
    env: {
      ...process.env,
      // A port nothing else is likely to hold, and no cloud: the bundle must
      // start with no internet at all.
      PORT: '45999',
      HOST: '127.0.0.1',
      DB_PATH: join(scratch, 'smoke.db'),
      NODE_ENV: 'production',
      JWT_SECRET: 'smoke-test-secret-not-used-for-anything-real',
      CLOUD_DATABASE_URL: '',
    },
    stdio: ['ignore', log, log],
    detached: false,
  })

  const deadline = Date.now() + 30_000
  let healthy = false

  while (Date.now() < deadline) {
    try {
      const body = execFileSync(
        'curl',
        ['-s', '--max-time', '2', 'http://127.0.0.1:45999/health'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
      )
      if (body.includes('"status":"ok"')) {
        healthy = true
        break
      }
    } catch {
      // Not up yet, or already dead — the log says which.
    }
    // Sleeps without turning this event loop.
    execFileSync(process.execPath, ['-e', 'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 400)'])
  }

  // taskkill, not child.kill(): the polling loop above blocks the event loop, so
  // Node's own signal handling has not been servicing this child and kill() can
  // throw ESRCH on a process that is still very much running.
  try {
    execFileSync('taskkill', ['/F', '/T', '/PID', String(child.pid)], { stdio: 'ignore' })
  } catch {
    // Already gone, which is the case when the bundle crashed on startup.
  }
  closeSync(log)

  const output = existsSync(logPath) ? readFileSync(logPath, 'utf8') : '(no output captured)'
  rmSync(scratch, { recursive: true, force: true })

  if (!healthy) {
    console.error('')
    console.error('Smoke test failed — the bundle does not start.')
    console.error(output.split('\n').slice(0, 25).join('\n'))
    process.exit(1)
  }

  console.log('  smoke test            starts, migrates, answers /health')
}

function kb(bytes) {
  return `${(bytes / 1024).toFixed(0)} KB`
}

/**
 * Copies whatever the native modules import at runtime.
 *
 * The bundler inlines the dependency tree of everything it bundles, but the two
 * native modules are external — so their imports are external too, and nothing
 * has copied them. sharp imports `detect-libc` and `semver` while loading.
 *
 * Walked transitively from each native module's own `dependencies`, rather than
 * listed by hand: a sharp upgrade that adds a dependency would otherwise produce
 * a bundle that builds cleanly here and dies on the restaurant's PC.
 */
function copyRuntimeDeps(target) {
  const seen = new Set(NATIVE)
  const queue = [...NATIVE]
  const copied = []

  while (queue.length > 0) {
    const name = queue.shift()
    const dir = findPackage(name)
    if (!dir) continue

    let manifest
    try {
      manifest = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    } catch {
      continue
    }

    for (const dep of Object.keys(manifest.dependencies ?? {})) {
      if (seen.has(dep)) continue
      seen.add(dep)

      const from = findPackage(dep)
      // An unresolvable dependency is usually optional and platform-specific.
      // The smoke test is what proves the bundle actually starts.
      if (!from) continue

      cpSync(from, join(target, 'node_modules', dep), {
        recursive: true,
        dereference: true,
      })
      copied.push(dep)
      queue.push(dep)
    }
  }

  if (copied.length > 0) {
    console.log(`  node_modules/         ${copied.sort().join(', ')}`)
  }
}

/**
 * Finds an installed package directory by looking, not by resolving.
 *
 * `require.resolve` cannot reach these: the `@img/*` packages declare an
 * `exports` map with no main entry and no `./package.json`, so Node refuses both
 * lookups with ERR_PACKAGE_PATH_NOT_EXPORTED. The directory is perfectly present
 * — module resolution is simply the wrong tool for finding it.
 *
 * Checks the top level first (npm hoists), then beside sharp's real location
 * (pnpm links platform binaries as siblings inside `.pnpm/`).
 */
function findPackage(name) {
  // npm hoists to the top level.
  const candidates = [join(root, 'node_modules', name)]

  // pnpm links a package's own dependencies as siblings of its real location
  // inside `.pnpm/`, so each native module's real directory is another place a
  // dependency can be found.
  for (const owner of NATIVE) {
    const link = join(root, 'node_modules', owner)
    if (!existsSync(link)) continue
    candidates.push(join(dirname(realpathSync(link)), name))
  }

  // Last resort: scan the pnpm store. Directory names are `name@version` with
  // slashes escaped as `+`, so a scoped package appears as `@img+sharp-...`.
  const store = join(root, 'node_modules', '.pnpm')
  if (existsSync(store)) {
    const prefix = `${name.replace('/', '+')}@`
    for (const entry of readdirSync(store)) {
      if (entry.startsWith(prefix)) {
        candidates.push(join(store, entry, 'node_modules', name))
      }
    }
  }

  return candidates.find((path) => existsSync(join(path, 'package.json'))) ?? null
}

/**
 * Copies sharp's Windows binaries.
 *
 * sharp declares one optional dependency per platform under `@img/`, and loads
 * the matching one at runtime. Only the win32-x64 pair is shipped — the rest are
 * Linux and macOS builds worth tens of megabytes that a billing PC will never
 * load.
 *
 * pnpm does not put these in the top-level `node_modules`; they live inside
 * `.pnpm/`. Resolving through `require.resolve` finds them wherever the package
 * manager chose to put them, which npm and pnpm disagree about.
 *
 * Missing them means logo printing throws on the restaurant's PC rather than
 * failing here, so an absent binary is a hard error.
 */
function copyScopedDeps(target) {
  const needed = ['@img/sharp-win32-x64', '@img/sharp-libvips-win32-x64']
  let copied = 0

  for (const name of needed) {
    const from = findPackage(name)
    if (!from) {
      // libvips is folded into the sharp binary in some releases, so its absence
      // is normal. A missing sharp-win32-x64 is not.
      if (name === '@img/sharp-libvips-win32-x64') continue
      console.error(`  ${name} is not installed — logo printing would fail on the till`)
      process.exit(1)
    }

    cpSync(from, join(target, 'node_modules', name), {
      recursive: true,
      dereference: true,
    })
    copied += 1
  }

  console.log(`  node_modules/@img     ${copied} sharp win32-x64 package(s)`)
}
