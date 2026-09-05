-- The cloud counterpart of the SQLite migration of the same name.
--
-- Both dialects change together, or a push carrying type = 'delivery' is
-- rejected by a constraint the till no longer has, and every order after it
-- queues behind the rejection.
--
-- Postgres can alter a constraint in place, so unlike SQLite there is no table
-- rebuild here.

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_type_check;
ALTER TABLE orders ADD CONSTRAINT orders_type_check
  CHECK (type IN ('dine_in', 'takeaway', 'delivery'));

-- Only a dine-in order needs a table; delivery joins takeaway in not having one.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_check;
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_table_required_check;
ALTER TABLE orders ADD CONSTRAINT orders_table_required_check
  CHECK (type != 'dine_in' OR table_id IS NOT NULL);
