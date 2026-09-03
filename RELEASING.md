# Releasing

How a new version reaches the restaurants.

Built locally, published from local. GitHub's Windows runners are slow for
Flutter, and the release step is a handful of commands — CI would add a wait and
a secret to manage without removing any real work.

---

## 1. Bump the version

`backend/src/lib/version.ts`:

```ts
export const APP_VERSION = '1.1.0'
export const APP_BUILD_NUMBER = 2
```

**Both, every time.** `build_number` is what the update check compares — a
monotonic integer cannot be ambiguous the way a version string can. `publish`
refuses a build that is not above the one already published, because a release
nobody is offered looks exactly like a successful one until a restaurant asks why
they never got the fix.

---

## 2. Build

```powershell
.\installer\build.ps1
.\installer\build.ps1 -SkipFlutter    # reuse the last Flutter build
```

One command. It bundles the backend (which smoke-tests itself and fails if the
result will not start), builds the Flutter app, compiles the installer, and
prints the SHA-256:

```
  dist\chennai-express-setup-1.1.0.exe
  57.7 MB
  sha256  a4b9710244bed07068289b911583461a39b0b965ffe82c0b5be70816145c943e
```

**The connection string is baked in at build time.** It is read from
`backend\.env` and written into a *copy* of `configure.ps1` inside
`installer\staging\`, which is gitignored — the script in the repository keeps
its `@CLOUD_DATABASE_URL@` placeholder, so a connection string is never
committed.

Check `.env` points where you intend before building. A local `localhost:5432`
URL produces an installer that tells every till to look for a database on its own
machine.

Pass `-CloudDatabaseUrl ''` to build an offline-only till: billing works, cloud
backup and updates do not.

### What the installer does on the restaurant's PC

1. Copies the Flutter app and the bundled backend
2. Runs `configure.ps1` — generates a JWT secret unique to that installation and
   DPAPI-encrypts the configuration to that machine
3. That is all. No service is registered — the app starts the backend itself as a
   child process when it launches

Uninstalling removes `config.dat` but **not the database**. Bills
must survive an uninstall — that is also what an operator runs before a clean
reinstall, and GST requires six years of retention.

---

## 3. Publish

```bash
cd backend
npm run publish:release -- --file ..\dist\chennai-express-setup-1.1.0.exe \
  --notes "Fixes the round-off on split payments"
```

What it does, in order:

1. Hashes the local file
2. Refuses if the build number is not newer than the published one
3. Creates the GitHub release for `v<version>` if needed, uploads the installer
4. **Downloads the published file back and re-hashes it**
5. Writes the `app_releases` row only if the two hashes match

Step 4 is the one that matters. A hash taken from a different build than the one
uploaded means every till downloads the installer, fails verification, and
refuses to update — with no obvious cause, because both halves look right on
their own.

Nothing is written to the database until the upload is verified. A row pointing
at a URL that does not work would offer every branch an update it cannot install.

| Flag | |
|---|---|
| `--channel beta` | Publish to beta instead of stable |
| `--mandatory` | The update dialog cannot be dismissed |
| `--min-build N` | Builds below N are forced to update |
| `--url <href>` | Already hosted elsewhere; skip the upload |
| `--dry-run` | Print the hash and plan, write nothing |

Use `--dry-run` first if you are unsure. It prints the SHA-256 without touching
anything.

---

## 4. Check

```bash
npm run release:list
```

```
  1.1.0      build 2    stable  active               64.2 MB   2026-09-03
  1.0.0      build 1    stable  active               63.8 MB   2026-08-21
```

Branches are offered the new build the next time someone opens the app. The check
is startup-only by design — a till stays open all day, and a dialog appearing
mid-service interrupts someone who never asked for it.

---

## 5. If it turns out to be broken

```bash
npm run release:withdraw -- --build 2
```

Sets `is_active = false`. Branches stop being offered it immediately, and no new
build has to be published to undo the mistake. `release:restore` puts it back.

**Tills that already installed it are not rolled back.** Withdrawing stops the
spread; fixing it means publishing a higher build number.

Rows are never deleted — which restaurant installed which build is something you
need to be able to answer later.

---

## `--mandatory` and `--min-build`

Reserved for billing correctness, not features.

After a tax or rounding fix, an old build producing wrong bills must not keep
running for months because staff kept dismissing a dialog. `--min-build` forces
anything below it to update before billing continues.

For a new report or a nicer screen, let people update when they choose.

---

## Hosting

The installer goes to GitHub Releases on the public repo. Free, unlimited
bandwidth, and the URL is tied to the tag so it never moves.

`download_url` is just a string in the `app_releases` row, so a release can be
hosted anywhere — `--url` publishes a row for a file you uploaded yourself. The
Firebase bucket (`releaseChennaiExpress/`) works the same way; its 1 GB/day free
limit is roughly 14 installer downloads, which is fine for a handful of branches
but is shared with anything else in that project.

The installer being publicly downloadable is not a problem: it is useless without
a login, and useless without an activation key. That is how every desktop
application ships.
