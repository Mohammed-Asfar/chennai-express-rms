-- A print job can be cancelled.
--
-- Without this a failed KOT stays in the queue forever: it has exhausted its
-- retries, the kitchen has already been told by hand, and there is no way to
-- clear it. The list only ever grows, so a genuine new failure is buried among
-- ones already dealt with.
--
-- SQLite cannot widen a CHECK constraint in place, so the table is rebuilt.
-- Rows are copied rather than recreated: a pending job here is a ticket nobody
-- has printed yet, and dropping it would silently lose a kitchen order.

CREATE TABLE print_jobs_new (
  id         TEXT PRIMARY KEY,
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  printer_id TEXT REFERENCES printers(id),
  type       TEXT NOT NULL CHECK (type IN ('bill', 'kot', 'kot_additional', 'kot_cancel', 'test')),
  ref_id     TEXT,
  payload    TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'printed', 'failed', 'cancelled')),
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  printed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT INTO print_jobs_new
  (id, branch_id, printer_id, type, ref_id, payload, status, attempts,
   last_error, printed_at, created_at, updated_at)
SELECT
  id, branch_id, printer_id, type, ref_id, payload, status, attempts,
  last_error, printed_at, created_at, updated_at
FROM print_jobs;

DROP TABLE print_jobs;
ALTER TABLE print_jobs_new RENAME TO print_jobs;

-- Dropped with the old table, so it is recreated here. Cancelled jobs are
-- excluded alongside printed ones: both are settled and neither is retried.
CREATE INDEX idx_print_jobs_pending ON print_jobs(status)
  WHERE status NOT IN ('printed', 'cancelled');
