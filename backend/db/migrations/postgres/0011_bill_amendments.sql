-- The cloud counterpart of the SQLite migration of the same name.
--
-- Both dialects change together, or a push naming a table Postgres does not
-- have breaks sync for every branch at once.
--
-- This one does sync: a bill's history is worth as much as the bill, and an
-- amendment that only ever existed on the till is lost with the till.

CREATE TABLE IF NOT EXISTS bill_amendments (
  id            TEXT PRIMARY KEY,
  branch_id     TEXT NOT NULL REFERENCES branches(id),
  bill_id       TEXT NOT NULL REFERENCES bills(id),

  business_date DATE NOT NULL,

  kind          TEXT NOT NULL CHECK (kind IN ('items', 'discount', 'customer')),

  before_json   TEXT NOT NULL,
  after_json    TEXT NOT NULL,

  -- Integer paise, as everywhere. Null for a customer-detail edit.
  total_before  BIGINT,
  total_after   BIGINT,

  -- Booleans here, integers in SQLite: the push converts them, as it must for
  -- every other flag in this schema.
  was_printed   BOOLEAN NOT NULL DEFAULT false,
  was_paid      BOOLEAN NOT NULL DEFAULT false,

  reason        TEXT,

  amended_by    TEXT NOT NULL REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL,
  updated_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bill_amendments_bill
  ON bill_amendments(bill_id, created_at);
CREATE INDEX IF NOT EXISTS idx_bill_amendments_date
  ON bill_amendments(branch_id, business_date);
