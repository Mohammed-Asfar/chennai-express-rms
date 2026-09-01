# Chennai Express RMS — Backend

Node.js + Fastify + SQLite. Owns all data, business logic, printing, and cloud sync.
The Flutter client is a pure UI layer with no database.

See `../PRD.md` for requirements, `../SCHEMA.md` for the database, and `../CLAUDE.md`
for the rules this code must follow.

## Setup

```bash
npm install
npm run db:migrate
npm run dev
```

The server listens on `127.0.0.1:4000` by default — loopback only, since the billing
PC's backend is not a network service.

## Commands

| Command | Purpose |
|---|---|
| `npm run dev` | Start with auto-reload |
| `npm test` | Run the test suite |
| `npm run typecheck` | Type check without emitting |
| `npm run build` | Compile to `dist/` |
| `npm start` | Run the compiled build |
| `npm run db:migrate` | Apply pending migrations |
| `npm run db:status` | Show applied and pending migrations |

## Configuration

All optional — the defaults suit a single billing PC.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `4000` | |
| `HOST` | `127.0.0.1` | Loopback. Change only if waiter tablets need LAN access. |
| `DB_PATH` | `./data/chennai-express.db` | |
| `LOG_LEVEL` | `info` | |
| `NODE_ENV` | `development` | `production` disables pretty logging |

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
