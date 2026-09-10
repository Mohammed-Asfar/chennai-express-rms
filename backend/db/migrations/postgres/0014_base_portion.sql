-- Which portion is the plain one, so the bill can leave its name off.
--
-- Matches the SQLite counterpart: `menu_item_variants` syncs, and a column on
-- one side only breaks the push on the first row that carries it.
--
-- BOOLEAN here against INTEGER in SQLite, like `is_available` beside it. The
-- push converts; see BOOLEAN_COLUMNS in src/sync/push.ts, which this column is
-- added to in the same change.
ALTER TABLE menu_item_variants ADD COLUMN is_base BOOLEAN NOT NULL DEFAULT FALSE;

-- Same backfill as SQLite, so a branch and the cloud agree before the first
-- push carrying this column. An item with one portion has nothing to tell the
-- customer; multi-portion items are left alone deliberately.
UPDATE menu_item_variants
SET is_base = TRUE
WHERE deleted_at IS NULL
  AND menu_item_id IN (
    SELECT menu_item_id
    FROM menu_item_variants
    WHERE deleted_at IS NULL
    GROUP BY menu_item_id
    HAVING COUNT(*) = 1
  );

-- Snapshotted onto the order line, like item_name and unit_price beside it.
-- Whether the portion was worth naming is a fact about the bill as issued.
ALTER TABLE order_items ADD COLUMN variant_is_base BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE order_items
SET variant_is_base = TRUE
WHERE variant_id IN (SELECT id FROM menu_item_variants WHERE is_base = TRUE);
