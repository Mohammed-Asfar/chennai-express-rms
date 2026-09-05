-- Delivery, as a third kind of order.
--
-- It behaves exactly like a takeaway: no table, nothing required beyond the
-- items. The only thing it adds is being able to tell the two apart — on the
-- bill, on the kitchen ticket, and in the sales report, where "how much of
-- today went out the door" is a question the owner actually asks.
--
-- A separate type rather than a note on the order: a note depends on everyone
-- spelling it the same way, and reports cannot group on it.
--
-- Two CHECK constraints have to widen, and SQLite cannot alter a constraint —
-- the table is rebuilt: new table, copy, drop, rename, indexes.
--
-- `PRAGMA defer_foreign_keys` rather than `foreign_keys = OFF`. The runner puts
-- every migration in its own transaction so a failure leaves no partial state,
-- and `foreign_keys` is a no-op inside a transaction — it silently did nothing,
-- and dropping a table that order_items and bills reference failed on the
-- foreign key. `defer_foreign_keys` is designed for exactly this: constraints
-- are checked at COMMIT instead of per statement, so the rebuild completes and
-- the references are still verified before anything is durable.
--
-- The copy carries every column, including the ones 0004 added, so a row's
-- sync state survives. Rebuilding with `synced_at` reset would re-push every
-- order a branch has ever taken.

PRAGMA defer_foreign_keys = ON;

CREATE TABLE orders_new (
  id             TEXT PRIMARY KEY,
  branch_id      TEXT NOT NULL REFERENCES branches(id),
  order_no       INTEGER NOT NULL,
  business_date  TEXT NOT NULL,
  type           TEXT NOT NULL CHECK (type IN ('dine_in', 'takeaway', 'delivery')),
  table_id       TEXT REFERENCES tables(id),
  seat_label     TEXT,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'billed', 'cancelled')),
  customer_name  TEXT,
  customer_phone TEXT,
  cancel_reason  TEXT,
  version        INTEGER NOT NULL DEFAULT 1,
  created_by     TEXT NOT NULL REFERENCES users(id),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  synced_at      TEXT,
  deleted_at     TEXT,
  sync_attempts  INTEGER NOT NULL DEFAULT 0,
  sync_error     TEXT,
  -- Only a dine-in order needs a table. Delivery joins takeaway in not having
  -- one; without this a delivery order could not be created at all.
  CHECK (type != 'dine_in' OR table_id IS NOT NULL)
);

INSERT INTO orders_new
  (id, branch_id, order_no, business_date, type, table_id, seat_label, status,
   customer_name, customer_phone, cancel_reason, version, created_by,
   created_at, updated_at, synced_at, deleted_at, sync_attempts, sync_error)
SELECT
   id, branch_id, order_no, business_date, type, table_id, seat_label, status,
   customer_name, customer_phone, cancel_reason, version, created_by,
   created_at, updated_at, synced_at, deleted_at, sync_attempts, sync_error
FROM orders;

DROP TABLE orders;
ALTER TABLE orders_new RENAME TO orders;

-- Recreated exactly as they were: dropping the table took them with it, and a
-- till that lost idx_orders_no could issue the same order number twice.
CREATE UNIQUE INDEX idx_orders_no ON orders(branch_id, business_date, order_no);
CREATE INDEX idx_orders_table_open ON orders(branch_id, table_id, status)
  WHERE status = 'open' AND deleted_at IS NULL;
CREATE INDEX idx_orders_date ON orders(branch_id, business_date);
CREATE INDEX idx_orders_sync ON orders(synced_at) WHERE synced_at IS NULL;
CREATE INDEX idx_orders_sync_pending ON orders(synced_at, sync_attempts) WHERE synced_at IS NULL;

-- Resets itself at COMMIT, but stated so the file reads as balanced.
PRAGMA defer_foreign_keys = OFF;
