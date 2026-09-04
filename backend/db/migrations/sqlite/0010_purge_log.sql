-- What has been exported, and what has been purged.
--
-- Two questions this answers, both of which someone will ask months later:
--
--   "did we have a copy before we cleared it"   -> export_log
--   "why is there nothing before April"          -> purge_log
--
-- A purge destroys trading records. Indian GST requires six years of retention,
-- and the rest of this system is built so orders and bills are never hard
-- deleted (PRD §5). Purging is the deliberate exception, and it must leave a
-- record of itself — a gap in the bills with no explanation is indistinguishable
-- from data loss.
--
-- Neither table is ever purged.

CREATE TABLE export_log (
  id            TEXT PRIMARY KEY,
  branch_id     TEXT NOT NULL REFERENCES branches(id),

  -- Which export, and the business dates it covered.
  kind          TEXT NOT NULL CHECK (kind IN ('bills', 'bill_items', 'payments')),
  from_date     TEXT NOT NULL,
  to_date       TEXT NOT NULL,

  -- So the warning before a purge can say how much was in the file. A zero-row
  -- export of a busy month means the range was wrong.
  row_count     INTEGER NOT NULL DEFAULT 0,

  exported_by   TEXT NOT NULL REFERENCES users(id),
  created_at    TEXT NOT NULL
);

CREATE INDEX idx_export_log_range ON export_log(branch_id, kind, from_date, to_date);

CREATE TABLE purge_log (
  id            TEXT PRIMARY KEY,
  branch_id     TEXT NOT NULL REFERENCES branches(id),

  from_date     TEXT NOT NULL,
  to_date       TEXT NOT NULL,

  -- What went, so the gap is explainable without the rows themselves.
  bills_removed      INTEGER NOT NULL DEFAULT 0,
  orders_removed     INTEGER NOT NULL DEFAULT 0,
  payments_removed   INTEGER NOT NULL DEFAULT 0,

  -- Whether an export covering the whole range existed when this ran. Recorded
  -- rather than enforced: the operator was warned and chose.
  was_exported  INTEGER NOT NULL DEFAULT 0 CHECK (was_exported IN (0, 1)),

  purged_by     TEXT NOT NULL REFERENCES users(id),
  created_at    TEXT NOT NULL
);

CREATE INDEX idx_purge_log_branch ON purge_log(branch_id, created_at);
