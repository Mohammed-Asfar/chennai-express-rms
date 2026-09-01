# Chennai Express RMS — Backend

Node.js + Fastify + SQLite. Owns all data, business logic, printing, and cloud sync.
The Flutter client is a pure UI layer with no database.

See `../PRD.md` for requirements, `../SCHEMA.md` for the database, and `../CLAUDE.md`
for the rules this code must follow.

## Setup

This project uses **pnpm**.

```bash
pnpm install
pnpm approve-builds better-sqlite3 esbuild   # see below
pnpm db:migrate
pnpm run dev
```

`better-sqlite3` is a native module: without its build script there is no compiled
binding and it cannot load at all. pnpm blocks install scripts by default, so the
approval step is required on a fresh clone. `pnpm-workspace.yaml` lists the allowed
packages, but pnpm 11.18 does not always honour it without the explicit command.

Default login is `admin` / `admin123`, and the first login forces a password change.

The server listens on `127.0.0.1:4000` by default — loopback only, since the billing
PC's backend is not a network service.

## Commands

| Command | Purpose |
|---|---|
| `pnpm run dev` | Start with auto-reload |
| `pnpm test` | Run the test suite |
| `pnpm run typecheck` | Type check without emitting |
| `pnpm run build` | Compile to `dist/` |
| `pnpm start` | Run the compiled build |
| `pnpm db:migrate` | Apply pending migrations to local SQLite |
| `pnpm db:status` | Show applied and pending local migrations |
| `pnpm db:migrate:cloud` | Apply pending migrations to Postgres / Neon |
| `pnpm db:status:cloud` | Show applied and pending cloud migrations |

## Configuration

All optional — the defaults suit a single billing PC.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `4000` | |
| `HOST` | `127.0.0.1` | Loopback. Change only if waiter tablets need LAN access. |
| `DB_PATH` | `./data/chennai-express.db` | |
| `LOG_LEVEL` | `info` | |
| `NODE_ENV` | `development` | `production` disables pretty logging |
| `JWT_SECRET` | dev fallback | **Required in production**, min 32 chars |
| `JWT_EXPIRES_SECONDS` | `43200` | 12 hours — longer than a shift |
| `SEED_ADMIN_USERNAME` | `admin` | Only used when seeding an empty database |
| `SEED_ADMIN_PASSWORD` | `admin123` | Forced to change at first login |
| `CLOUD_DATABASE_URL` | — | Postgres / Neon connection string. Absent means no sync and no update checks. |
| `UPDATE_CHANNEL` | `stable` | `stable` or `beta` |

## Layout

```
src/
  db/
    client.ts      SQLite connection and pragmas
    migrate.ts     migration runner with checksum verification
  lib/
    env.ts         validated configuration
    money.ts       paise and basis-point arithmetic
    errors.ts      typed HTTP errors
  routes/
    health.ts      liveness probe
  server.ts        Fastify app construction
  index.ts         entry point
db/migrations/
  sqlite/          applied locally
  postgres/        applied to Neon — same number, same change
test/
```

## API

| Endpoint | Role | Purpose |
|---|---|---|
| `GET /health` | — | Liveness probe |
| `GET /version` | — | Running version and build number |
| `POST /auth/login` | — | Sign in |
| `GET /auth/me` | any | Current user |
| `POST /auth/change-password` | any | Change own password |
| `GET /users` | admin | List users |
| `POST /users` | admin | Create user |
| `PATCH /users/:id` | admin | Update, deactivate, reset password |
| `GET /updates/check` | any | Is a newer release available |
| `GET /categories` | any | Menu categories with item counts |
| `POST /categories` | admin | Create |
| `PATCH /categories/:id` | admin | Rename, reorder, activate |
| `DELETE /categories/:id` | admin | Blocked while it holds items |
| `POST /categories/reorder` | admin | Bulk sort order after a drag |
| `GET /menu-items` | any | Items with variants; `?categoryId=` `?availableOnly=true` |
| `POST /menu-items` | admin | Create, with variants or a single price |
| `PATCH /menu-items/:id` | admin | Edit |
| `DELETE /menu-items/:id` | admin | Soft delete |
| `POST /menu-items/:id/variants` | admin | Add a portion |
| `PATCH /menu-items/:id/variants/:vid` | admin | Rename, reprice, mark sold out |
| `DELETE /menu-items/:id/variants/:vid` | admin | Blocked on the last one |
| `GET /sections` | any | Floor areas with table counts |
| `POST /sections` | admin | Create |
| `PATCH /sections/:id` | admin | Rename, reorder, activate |
| `DELETE /sections/:id` | admin | Blocked while it holds tables, or if it is the last |
| `POST /sections/reorder` | admin | Bulk sort order |
| `GET /tables` | any | Tables with seated parties; `?sectionId=` |
| `GET /tables/:id` | any | One table |
| `POST /tables` | admin | Create |
| `PATCH /tables/:id` | admin | Rename, resize, move section |
| `DELETE /tables/:id` | admin | Blocked while an order is open |
| `POST /tables/reorder` | admin | Bulk sort order |
| `GET /floor` | any | Sections with their tables and seated parties |
| `GET /orders` | any | `?status=` `?tableId=` `?businessDate=` |
| `GET /orders/:id` | any | One order with its lines and totals |
| `POST /orders` | any | Start a dine-in or takeaway order |
| `PATCH /orders/:id` | any | Seat label, customer details |
| `POST /orders/:id/items` | any | Add a line |
| `PATCH /orders/:id/items/:itemId` | any | Change quantity or notes |
| `DELETE /orders/:id/items/:itemId` | any | Remove a line |
| `POST /orders/:id/cancel` | any | Cancel with a reason |
| `POST /bills/preview` | any | Total without persisting |
| `GET /bills` | any | `?businessDate=` `?status=` `?unpaid=true` |
| `GET /bills/:id` | any | One bill with its payments |
| `POST /bills` | any | Generate from an open order |
| `POST /bills/:id/payments` | any | Take a payment (split supported) |
| `POST /bills/:id/payments/:pid/reverse` | any | Reverse a wrong payment |
| `POST /bills/:id/void` | admin | Void with a reason; reopens the order |
| `POST /bills/:id/reprint` | any | Marks the printout as a duplicate |
| `GET /sync/status` | any | Pending count, quarantined count, last success |
| `POST /sync/now` | admin | Force a cycle |
| `POST /sync/retry` | admin | Clear quarantine and retry |

## Billing

Order of operations is fixed and must not be rearranged:

```
line gross -> discount -> tax -> CGST/SGST split -> round off
```

Taxing before the discount charges GST on money the customer never pays.

**Tax is grouped per rate, then split.** Halving each line and summing drifts —
three lines taxed 7 paise give 12 and 9 instead of 10 and 11. GST also requires the
rate-wise breakdown on the printout, which `tax_breakdown` carries.

**Payments are separate rows**, so a bill can be split across cash, card and UPI, or
left partly paid. `amount_paid` and `payment_status` are derived from live payments
inside the same transaction — never set directly. A wrong payment is **reversed**,
never deleted; both rows stay for audit.

**A payment carries its own business date.** A Monday bill settled Wednesday has its
sale on Monday and its cash on Wednesday; conflating them makes the drawer disagree
with the sales figure.

**Voiding** requires an admin and a reason, reopens the order for correction, and
leaves the bill number consumed — a gap in the sequence looks worse to an auditor
than a number marked void. A bill with live payments cannot be voided until they are
reversed.

**An unpaid bill does not hold its table.** The balance follows the bill.

## Sync

Push-only: the branch is the source of truth, the cloud a read replica. Nothing
flows back down, so there is no conflict resolution.

**Triggered** by a response hook after any successful mutation (debounced ~2s so a
burst of edits is one push), a 5-minute idle heartbeat, and a drain at startup.

**Never blocks billing.** No internet, no cloud configured, or a slow response all
resolve to a failed cycle recorded in status — the till never waits on it.

**Idempotent upserts** keyed on the row id. If the connection dies after Postgres
commits but before SQLite records `synced_at`, the next cycle overwrites rather than
failing on a duplicate.

**Failure handling:** attempts 1–5 back off (30s, 1m, 2m, 4m, 8m); after 5 the row is
quarantined so it cannot block the queue, and surfaces in `/sync/status` with a Retry
action. The attempt count and last error are stored on the row.

`print_jobs` never syncs — print state is meaningless in the cloud.

### Testing sync

The cloud integration tests are skipped unless `CLOUD_DATABASE_URL` is set:

```bash
CLOUD_DATABASE_URL=postgresql://... pnpm test
```

They truncate the cloud database, so point them at a scratch one, never production.

## Orders

**Lines are snapshots.** `item_name`, `variant_name`, `unit_price` and `tax_rate` are
copied onto the line when it is added. Repricing or renaming a dish afterwards never
alters an order already placed — reading them live from the menu would silently
rewrite printed bills.

Adding the same variant twice merges into one line, **but only when the snapshot
price matches**. If the item was repriced between the two adds, they stay separate,
because merging would force one price onto both.

**A billed order cannot be modified.** It is a financial record. Cancelling requires
a reason and soft-deletes, never hard-deletes.

**Concurrency.** Pass the `version` you last read on a `PATCH`; a stale value returns
`409 ORDER_MODIFIED` rather than silently overwriting another terminal's edit.

**Kitchen signals.** Cancelling an order returns `kotCancellationNeeded`, and removing
a line returns `kotAlreadyPrinted`, so the caller knows whether the kitchen is already
cooking it.

## Business day

A restaurant open past midnight keeps 1 AM sales on the previous trading day. The
cutoff is the `business_day_start` setting, in local time. Reports use
`business_date`, never `created_at` — otherwise one night's service splits across two
report days and the cash drawer never matches the sales figure.

Order and bill numbers are sequential **per branch per business day**, allocated
inside the same transaction as the insert.

## Table status

`status` is **derived state**, never set by a client — the `PATCH` body has no
`status` field. It is recomputed by `refreshTableStatus()` whenever an order opens
or closes:

| Status | Meaning |
|---|---|
| `occupied` | At least one open order |
| `reserved` | A `booked` reservation holds it, and no open order |
| `free` | Neither |

A table can hold **several open orders at once** — two parties sharing it. So it
becomes occupied on the *first* order and frees only when the *last* one closes.
Setting `status = 'free'` directly when a bill settles would free a table with
another party still seated at it.

## Menu structure

Cashiers read the menu — they need it to take orders — but only admins change it.

## Menu structure

Price lives on the **variant**, not the item. An item created with a single `price`
gets one variant named `Standard`, so order lines always reference a variant and
there is one code path rather than two.

```
menu_items                menu_item_variants
Chicken Biryani     ->    Half      Rs180
                          Full      Rs320
Masala Tea          ->    Standard  Rs20
```

Menu edits never touch existing orders: order lines snapshot the item name,
variant name, price and tax rate when the line is added.

## Money

Money is **integer paise**, rates are **integer basis points** (5% = `500`). Nothing
in a billing path uses a float. `src/lib/money.ts` is the only place arithmetic
helpers live; use `toPaise` / `formatMoney` at the API boundary and integers
everywhere inside.

Tax divides by `10000`, not `100` — basis points carry two extra digits.

## Migrations

Append-only. A migration that has run against real data is immutable — its checksum
is verified at boot and a mismatch is a hard startup error. Fix forward with a new
migration.

Every SQLite migration needs its Postgres counterpart under the same number, or sync
will fail on the first row using a new column.

## Releases

The running version is `APP_VERSION` and `APP_BUILD_NUMBER` in `src/lib/version.ts`.
**Bump both on every release**, and keep them in step with the installer.

Clients compare `build_number`, never the version string — a monotonic integer
cannot be ambiguous.

To publish, insert a row into `app_releases` in Neon:

| Field | Note |
|---|---|
| `build_number` | Must be higher than the previous release |
| `sha256` | Checksum of the installer. Verified before it is executed — a mismatch aborts. |
| `is_mandatory` | The update dialog cannot be dismissed |
| `min_supported_build` | Builds below this are forced. Use after a billing-math fix. |
| `is_active` | Set to false to withdraw a release without publishing another |

The update check is best-effort: no internet, no cloud configured, or a slow
response all resolve to "no update available". It never blocks billing.
