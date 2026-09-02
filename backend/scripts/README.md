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

## Still to build

| | |
|---|---|
| Windows service wrapper | WinSW pointing at `start.cmd`; auto-start, restart on crash |
| Config encryption | The installer writes the connection string; the service reads it |
| Directory ACLs | The service account reads, the cashier cannot. **This is what makes the licence check meaningful** |
| Inno Setup installer | One `.exe`, plus its SHA-256 for the `app_releases` row |

Until the ACL work lands, a technical user on the billing PC can still point the
backend at their own database. See `LICENSING.md` §8.
