# Packaging the backend

```bash
npm run bundle          # build and verify
npm run bundle:smoke    # re-verify what is already built
```

Produces `backend/dist-bundle/` — about 177 MB, gitignored.

---

## What comes out

```
dist-bundle/
  server.mjs            2.2 MB   the whole backend, one file
  node/node.exe         110 MB   private runtime; the PC needs no Node
  node_modules/                  the two native addons and their dependencies
  db/migrations/                 SQL, read at boot
  start.cmd                      what the service wrapper runs
  build.json                     version, build number, Node version, timestamp
```

**No `.env`.** That is the point of packaging: configuration comes from the
environment the service is started with, written by the installer.

---

## Why it is a directory and not one .exe

`better-sqlite3` and `sharp` are native addons — compiled `.node` binaries a
JavaScript bundler cannot inline. Node's SEA support can carry them, but the
unpacking is fragile across Node versions, and the failure mode is a till that
will not start on a morning you are not there.

A directory with a private runtime is boring. A billing PC should be boring.

---

## Why ESM

The source uses top-level `await` — `index.ts` awaits the cloud restore and the
seed before building the server. CommonJS cannot express that, so the bundle is
ESM with a `createRequire` banner so the native addons can still be `require`d.

---

## The smoke test

Runs automatically at the end of every build, and **the build fails if it does
not pass**.

It starts the bundle on port 45999 against a throwaway database, with no cloud
configured, and asks `/health` for an answer.

This is not ceremony. Every failure this script has produced built without
complaint and died on first run:

| Failure | Why the build did not notice |
|---|---|
| `detect-libc` missing | Only `sharp` imports it, and only at load time |
| Migrations not found | The path is right in `src/db/`, wrong in a flat bundle |

Neither is visible in the output of a successful build. Both are immediately
obvious the moment the thing is asked to start.

To confirm the check still works, break the bundle and re-run it:

```bash
rm -rf dist-bundle/node_modules/detect-libc
npm run bundle:smoke     # exits 1, prints the module resolution error
```

---

## Finding the native modules

`copyRuntimeDeps` walks each native module's `dependencies` transitively rather
than working from a hand-written list. A `sharp` upgrade that adds a dependency
would otherwise build cleanly here and die on the restaurant's PC.

`findPackage` looks in three places, because npm and pnpm disagree about layout:

1. `node_modules/<name>` — npm hoists
2. Beside a native module's **real** path — pnpm links dependencies as siblings
   inside `.pnpm/`, and `node_modules/sharp` is a symlink
3. The `.pnpm` store, scanned by `name@version` prefix

It deliberately does **not** use `require.resolve`. The `@img/*` packages declare
an `exports` map with no main entry and no `./package.json`, so Node refuses both
lookups with `ERR_PACKAGE_PATH_NOT_EXPORTED`. The directory is present; module
resolution is simply the wrong tool for finding it.

Only the `win32-x64` sharp binary ships. The Linux and macOS builds are tens of
megabytes a billing PC will never load.

---

## Installing on a billing PC

Three steps, all run elevated, in this order.

```powershell
# 1. Encrypt the configuration to this machine
npm run configure -- --dir "C:\Program Files\Chennai Express\backend"

# 2. Install the service, lock the directory, and start it
powershell -File scripts\service.ps1 install -Path "C:\Program Files\Chennai Express\backend"

# 3. Confirm
powershell -File scripts\service.ps1 status
```

`install` hardens the directory and waits for `/health` before returning, so a
broken install fails while you are still standing at the till.

Other actions: `uninstall`, `restart`, `harden`, `status`.

---

## Configuration

`config.dat` sits beside `server.mjs`, encrypted with Windows DPAPI at machine
scope. `npm run configure` reads the current `.env`, encrypts what the service
needs, and writes it.

**The JWT secret is generated per installation.** A token forged on one
restaurant's PC is meaningless on another.

Loading order, first match wins:

1. The process environment — an operator or the service definition
2. `config.dat` — an installed service
3. `.env` — development only

**What this protects against:** the file copied to another machine (DPAPI
refuses), and a member of staff opening it in Notepad.

**What it does not:** an administrator on the billing PC. The service must
decrypt it to work, so anyone who can run code as the service account can read
what the service reads. Nothing short of a hardware module changes that — the
directory ACL is what stops a non-administrator getting that far.

A config that cannot be decrypted throws with a message naming the cause, rather
than starting half-configured and behaving strangely later.

Only keys on an allow list are read. A rewritten `config.dat` cannot set
`NODE_OPTIONS` or `PATH` and get code loaded into the service.

---

## The service

`sc.exe`, not a third-party wrapper. Windows already restarts a failed service;
a wrapper would be one more binary to trust, patch, and download at build time.

| | |
|---|---|
| Name | `ChennaiExpressRMS` |
| Account | `LocalSystem` |
| Startup | Automatic |
| On failure | Restart after 5s, 10s, then every 30s; count resets daily |

**Why LocalSystem.** The service binds only to `127.0.0.1` and touches nothing
outside its own directory and the print spooler, but it must start before anyone
logs in and survive the cashier signing out. A per-user account cannot do either,
and a low-privilege service account cannot reach a printer installed for another
user — which is the first thing a restaurant does.

---

## Directory ACLs

`harden` runs as part of `install`, and can be run alone.

Inheritance is disabled first — `Program Files` grants Users read access, and an
inherited allow rule cannot be removed, only overridden. `Users`, `Everyone`,
`Authenticated Users` and `INTERACTIVE` are then removed, leaving
`Administrators` and `SYSTEM`.

**This is the step that makes everything above it mean something.** Without it a
cashier can read `config.dat`, replace `server.mjs`, or point the backend at
their own database, and the licence check is decoration.

---

## Still to build

| | |
|---|---|
| Inno Setup installer | One `.exe`, plus its SHA-256 for the `app_releases` row |
| Release publishing | GitHub Actions on a `v*` tag → upload → insert the release row |
