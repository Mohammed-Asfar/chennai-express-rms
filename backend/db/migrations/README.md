# Migrations

Numbered, append-only, applied in order. A migration that has run against real data
is immutable — its checksum is verified at boot and a mismatch is a hard startup
error. Fix forward with a new migration.

## Two dialects

Most migrations exist in both `sqlite/` and `postgres/` under the same number. A
SQLite migration without its Postgres counterpart breaks sync on the first row that
uses a new column.

## Dialect-specific migrations

A few tables live in only one database. The number is still reserved in both, so
`0003` means the same change everywhere.

| Number | SQLite | Postgres | Why |
|---|---|---|---|
| `0002` | — | `app_releases` | Cloud-only: a branch cannot tell itself about a version it does not have |
| `0003` | no-op | drops `print_jobs` | `print_jobs` is branch-local. It was included in the Postgres `0001` by mistake; since `0001` was already applied, this fixes forward rather than editing history. |

`print_jobs` is the mirror case — branch-local, so it has no Postgres counterpart,
but it was created inside `0001` rather than its own migration.
