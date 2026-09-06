# Releasing

How a new version reaches the restaurants.

Built locally, published from local. The connection string is baked into the
installer at build time, and this repository is public — so the credential
cannot live in a GitHub secret, and CI cannot produce a shippable build.

---

## What CI does and does not do

`.github/workflows/ci.yml` runs the backend and Flutter suites on every push.
Green CI is the gate for merging, not for shipping.

`.github/workflows/release.yml` builds an installer and attaches it to a GitHub
Release, on a `v*` tag **or on a push to `main` that changes the version**.

On `main` it first reads `APP_VERSION` and checks whether a release for it
already exists. If it does, nothing is built — a merge that fixes a doc or a
test should not mint a release. Bumping the version is what asks for one, which
makes releasing a deliberate act inside an ordinary merge rather than a separate
ritual.

**That artefact is deliberately offline-only**: it is built with
`-CloudDatabaseUrl ''`, so it has no cloud backup, no auto-update, and cannot be
activated — activation checks a licence that lives in the cloud. It exists to
prove `main` always packages cleanly on a machine that is not yours.

So there are two different releases with the same version number: the one CI
attaches to GitHub, which nobody can install, and the one you build locally and
publish with `publish:release`, which is the one tills download. The GitHub
Release body says which is which.

The installer a restaurant runs is the one built by step 2 below, on a machine
that has `backend\.env`.

Both workflows pin Flutter to the SDK the product is built with. `stable` floats,
and a runner that moved ahead of the local SDK once failed on a deprecation whose
replacement did not exist in the local version — so satisfying CI would have
broken the build that produces the installer. Raise the pin deliberately, in both
workflows, together with the local SDK.

---

## 0. Before you build

```bash
cd backend
npm run typecheck     # tsc --noEmit
npm test
cd ../desktop
flutter analyze
flutter test
```

**Run typecheck, not just the tests.** `npm test` does not run `tsc`, so a full
green suite says nothing about types — a push with 503 passing tests failed CI on
two type errors in the tests themselves.

### Migrate the cloud, before the tills get the new code

```bash
cd backend
npm run db:status:cloud    # what the cloud has
npm run db:migrate:cloud   # apply what it does not
```

**A migration written is not a migration run.** SQLite migrates itself at
startup, so a dev machine and a till both pick up a new column the moment they
boot the new build. Postgres does not — it is migrated deliberately, by this
command, and nothing reminds you.

Skip it and the tills upgrade, start pushing a column the cloud has never heard
of, and sync stops with `column "surcharge" of relation "sections" does not
exist`. Billing keeps working — sync failing never blocks a sale — but nothing
reaches the cloud until someone runs the migration.

This happened during 1.0.5. It cost only a confusing error because the branch was
not yet trading.

**Check which database you are pointed at first.** `backend/.env` holds one
`CLOUD_DATABASE_URL`, and test and production look identical from the terminal:

```bash
node -e "const m=require('fs').readFileSync('.env','utf8').match(/CLOUD_DATABASE_URL=(.*)/);const p=m[1].match(/@([^/]+)\//);console.log('host:',p[1])"
```

Migrations that only add columns are survivable if you get this wrong. One that
rewrites a table is not.

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

Check `.env` points where you intend before building. A `localhost` URL is now a
hard error rather than a warning — an installer built from one tells every till
to look for a database on its own PC, and activation fails because licences live
in the cloud.

Pass `-CloudDatabaseUrl ''` to build an offline-only till: billing works, cloud
backup and updates do not. Watch for the line the build prints:

```
    Cloud backup and updates configured.          <- shippable
WARNING:   No CLOUD_DATABASE_URL - offline-only    <- not shippable
```

Do not trust `-SkipFlutter` blindly. The staleness guard compares the newest
`.dart` file against `data\app.so` — the compiled Dart — and not against
`chennai_express_pos.exe`, which is a native loader that only changes when the
C++ runner or a plugin does. A Dart-only change leaves the exe untouched.

### What the installer does on the restaurant's PC

1. Copies the Flutter app and the bundled backend
2. Creates `C:\ProgramData\Chennai Express` with `users-modify`, so a cashier on
   a standard Windows account can write the database and its `-wal`/`-shm` files
3. Runs `configure.ps1` — generates a JWT secret unique to that installation and
   DPAPI-encrypts the configuration to that machine
4. That is all. No service is registered — the app starts the backend itself as a
   child process when it launches

Uninstalling removes `config.dat` but **not the database**. Bills
must survive an uninstall — that is also what an operator runs before a clean
reinstall, and GST requires six years of retention.

A reinstall on the same PC keeps the licence: the activation is cached in
`license_state` inside that database, and the machine fingerprint is derived
from the registry's `MachineGuid`, which an uninstall does not touch. Nobody has
to re-enter a key. Reimaging Windows does change `MachineGuid` — that needs the
fingerprint cleared in the cloud before the key will bind again.

---

## 3. Publish

```powershell
cd backend
npm run publish:release -- --file ..\dist\chennai-express-setup-1.1.0.exe --notes "Fixes the round-off on split payments"
```

One line. A `\` continuation is bash syntax and PowerShell will not join the
lines — it runs the first half, publishing with no notes.

What it does, in order:

1. Hashes the local file
2. Refuses if the build number is not newer than the published one
3. Creates the GitHub release for `v<version>` if needed, uploads the installer
4. **Asks GitHub what size it stored for the asset**, and re-uploads once if that
   disagrees with the file on disk
5. **Downloads the published file back**, checks its byte count, then its hash
6. Writes the `app_releases` row only if every check passes

Steps 4 and 5 are both required, and 4 exists because 5 alone was not enough —
see below. Nothing is written to the database until they pass: a row pointing at
a URL that does not serve the installer offers every branch an update it cannot
install.

### Why the size is checked as well as the hash

**1.0.5 was published, reported as verified, and shipped an installer GitHub was
serving 11 MB short.**

The publisher downloaded the file back and re-hashed it, exactly as step 5 says,
and reported `Matches.` Yet the asset GitHub had stored was 43,542,605 bytes of a
54,964,421-byte installer — and it was marked `uploaded`, so nothing looked
wrong. Every till downloaded it, found the hash disagreed with `app_releases`,
and refused to install. Which was correct: an installer runs with full privileges
on the billing PC, so an unverified binary must never execute.

The size GitHub records for the asset is a **second, independent witness**. It
disagreed immediately, and it costs one API call rather than a 50 MB download.
Two hashes tell you something is wrong; two byte counts tell you what.

A short upload is retried once automatically — re-uploading is exactly the fix,
and the release is already broken. A download that still disagrees after that is
not retried: something is serving the wrong bytes, and that needs a person.

`curl` runs with `--fail`. Without it a 404 is followed into an HTML body, curl
exits zero, and a few hundred bytes get hashed as though they were the installer.

The decisions live in `src/db/publish-checks.ts`, tested without a network or a
token — including the real truncation, asserted down to the 11,421,816 bytes.

**Do not weaken these to make a publish succeed.** A failing check means the
release is broken, not that the check is.

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

### Confirm a till would get the real file

The publisher checks this, but it is worth seeing once with your own eyes,
because it is the exact request a restaurant's PC makes:

```bash
curl -sL --fail -o /tmp/check.exe "<download_url from release:list>"
sha256sum /tmp/check.exe        # must equal app_releases.sha256
stat -c %s /tmp/check.exe       # must equal app_releases.file_size
```

Both, not just the hash. That is the lesson of 1.0.5.

**If a till reports "The downloaded file failed its security check", believe
it.** The app hashes what it downloaded and refuses to run a binary that does not
match — that message means the file on the host is wrong, not that the till is.
Check the asset before touching anything on the restaurant's PC.

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
