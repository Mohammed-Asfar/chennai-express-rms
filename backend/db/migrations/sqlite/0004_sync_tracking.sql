-- Sync bookkeeping: attempt count and last error on every synced table.
--
-- A row that fails repeatedly is quarantined (sync_attempts >= 5) so one bad row
-- cannot block the queue behind it, and surfaces in the UI rather than failing
-- silently. See SCHEMA.md section 5.2.

ALTER TABLE branches ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE branches ADD COLUMN sync_error TEXT;
ALTER TABLE users ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN sync_error TEXT;
ALTER TABLE sections ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sections ADD COLUMN sync_error TEXT;
ALTER TABLE tables ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tables ADD COLUMN sync_error TEXT;
ALTER TABLE categories ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE categories ADD COLUMN sync_error TEXT;
ALTER TABLE menu_items ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE menu_items ADD COLUMN sync_error TEXT;
ALTER TABLE menu_item_variants ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE menu_item_variants ADD COLUMN sync_error TEXT;
ALTER TABLE reservations ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reservations ADD COLUMN sync_error TEXT;
ALTER TABLE orders ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE orders ADD COLUMN sync_error TEXT;
ALTER TABLE order_items ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE order_items ADD COLUMN sync_error TEXT;
ALTER TABLE bills ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE bills ADD COLUMN sync_error TEXT;
ALTER TABLE payments ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE payments ADD COLUMN sync_error TEXT;

-- reservation_tables and settings have composite keys and no id column; they are
-- pushed with their parent rather than tracked individually.

-- Finds the next batch to push, and the quarantined rows to surface.
CREATE INDEX idx_orders_sync_pending ON orders(synced_at, sync_attempts) WHERE synced_at IS NULL;
CREATE INDEX idx_bills_sync_pending ON bills(synced_at, sync_attempts) WHERE synced_at IS NULL;
CREATE INDEX idx_payments_sync_pending ON payments(synced_at, sync_attempts) WHERE synced_at IS NULL;
CREATE INDEX idx_order_items_sync_pending ON order_items(synced_at, sync_attempts) WHERE synced_at IS NULL;
