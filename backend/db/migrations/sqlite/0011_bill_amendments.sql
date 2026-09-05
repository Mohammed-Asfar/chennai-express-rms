-- Every change made to a bill after it was created.
--
-- Bills are edited in place: the bill number stays, the totals are recalculated,
-- and the row is overwritten. That is a deliberate choice — staff correct a
-- mistake without the customer being handed a second piece of paper with a
-- different number on it.
--
-- What it costs is the one thing a financial record is for: the original
-- figures. A bill printed at 45000 and later saved at 38000 leaves no trace of
-- the first amount in `bills` itself, and if that bill was already given to a
-- customer, the paper and the record no longer agree.
--
-- This table is that trace. Every amendment records what the bill said before,
-- what it says now, who changed it and why, so the history is reconstructible
-- even though `bills` holds only the latest state. It is append-only, it is
-- never purged, and nothing in the billing path reads it — it exists solely to
-- answer "this total changed, what happened".

CREATE TABLE bill_amendments (
  id            TEXT PRIMARY KEY,
  branch_id     TEXT NOT NULL REFERENCES branches(id),
  bill_id       TEXT NOT NULL REFERENCES bills(id),

  -- The trading day the amendment was made, which is not necessarily the
  -- trading day of the bill: a Monday bill corrected on Wednesday belongs to
  -- Monday's sales and Wednesday's amendments.
  business_date TEXT NOT NULL,

  -- What kind of change. 'items' covers a quantity, an addition or a removal;
  -- they are one edit from the operator's point of view and recalculate the
  -- same way.
  kind          TEXT NOT NULL CHECK (kind IN ('items', 'discount', 'customer')),

  -- The whole bill row as it stood before and after, as JSON. Stored rather
  -- than diffed: a diff is only meaningful against a schema, and this has to
  -- stay readable years after the columns have moved on.
  before_json   TEXT NOT NULL,
  after_json    TEXT NOT NULL,

  -- Integer paise, both. Null for a customer-detail edit, which moves no money.
  total_before  INTEGER,
  total_after   INTEGER,

  -- Whether the bill had already been printed or paid when it was changed.
  -- The case that matters at reconciliation: a bill nobody had seen is a draft
  -- being corrected, one already handed over is a document that now disagrees
  -- with its paper.
  was_printed   INTEGER NOT NULL DEFAULT 0,
  was_paid      INTEGER NOT NULL DEFAULT 0,

  reason        TEXT,

  amended_by    TEXT NOT NULL REFERENCES users(id),
  created_at    TEXT NOT NULL,

  -- Never changes; the sync worker orders and backs off on it, so the column
  -- has to exist even though an amendment is written once and left alone.
  updated_at    TEXT NOT NULL,

  -- Synced like any other row, so the cloud copy carries the history too.
  synced_at     TEXT,
  sync_attempts INTEGER NOT NULL DEFAULT 0,
  sync_error    TEXT
);

CREATE INDEX idx_bill_amendments_bill ON bill_amendments(bill_id, created_at);
CREATE INDEX idx_bill_amendments_date ON bill_amendments(branch_id, business_date);
