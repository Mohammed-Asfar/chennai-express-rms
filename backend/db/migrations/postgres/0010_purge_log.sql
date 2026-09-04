-- The cloud counterpart of the SQLite migration of the same name.
--
-- Both dialects change together, or a push naming a table Postgres does not
-- have breaks sync for every branch at once.
--
-- Neither log syncs today — they are branch-local records of what happened on
-- that PC — but the tables exist here so a future decision to sync them is a
-- registry change rather than a migration against live data.

CREATE TABLE IF NOT EXISTS export_log (
  id            TEXT PRIMARY KEY,
  branch_id     TEXT NOT NULL REFERENCES branches(id),
  kind          TEXT NOT NULL CHECK (kind IN ('bills', 'bill_items', 'payments')),
  from_date     TEXT NOT NULL,
  to_date       TEXT NOT NULL,
  row_count     INTEGER NOT NULL DEFAULT 0,
  exported_by   TEXT NOT NULL REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_export_log_range
  ON export_log(branch_id, kind, from_date, to_date);

CREATE TABLE IF NOT EXISTS purge_log (
  id                TEXT PRIMARY KEY,
  branch_id         TEXT NOT NULL REFERENCES branches(id),
  from_date         TEXT NOT NULL,
  to_date           TEXT NOT NULL,
  bills_removed     INTEGER NOT NULL DEFAULT 0,
  orders_removed    INTEGER NOT NULL DEFAULT 0,
  payments_removed  INTEGER NOT NULL DEFAULT 0,
  was_exported      BOOLEAN NOT NULL DEFAULT FALSE,
  purged_by         TEXT NOT NULL REFERENCES users(id),
  created_at        TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_purge_log_branch ON purge_log(branch_id, created_at);
