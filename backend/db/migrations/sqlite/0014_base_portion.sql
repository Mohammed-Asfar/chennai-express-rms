-- Which portion is the plain one, so the bill can leave its name off.
--
-- An item with a single portion still needs a variant row, and that row gets a
-- placeholder name — every one of the 177 single-portion items on this menu is
-- called "Regular". Printing "Chicken Biryani (Regular)" tells the customer
-- nothing and costs a line on a 58mm roll.
--
-- Marked per portion rather than inferred from the name, because the word is
-- arbitrary: "Regular", "Base", "Normal" and "Standard" all mean the same
-- thing, and no list of them can be complete. It is also not inferred from the
-- portion count, because an item with three portions may still have a plain
-- one — Tandoori Chicken is Full, Half and Single, and "Full" is the default a
-- customer means when they say the dish name.
--
-- Defaults to 0 and is deliberately NOT backfilled by portion count here. The
-- backfill is a separate statement below so its reasoning is visible, and so
-- that multi-portion items are left alone: Dry and Gravy cost the same and
-- neither is a default, so hiding either would print two different dishes
-- under one name.
ALTER TABLE menu_item_variants ADD COLUMN is_base INTEGER NOT NULL DEFAULT 0
  CHECK (is_base IN (0, 1));

-- An item with exactly one portion has nothing to distinguish, so that portion
-- is its base whatever it is named. This is the whole of the common case: it
-- marks all 177 single-portion items and touches no multi-portion item.
--
-- Soft-deleted rows are excluded from the count so an item that once had two
-- portions and now has one is treated as the single-portion item it now is.
UPDATE menu_item_variants
SET is_base = 1
WHERE deleted_at IS NULL
  AND menu_item_id IN (
    SELECT menu_item_id
    FROM menu_item_variants
    WHERE deleted_at IS NULL
    GROUP BY menu_item_id
    HAVING COUNT(*) = 1
  );

-- Snapshotted onto the order line, like item_name and unit_price beside it.
--
-- Whether the portion name was worth printing is a fact about the bill as it
-- was issued. Reading it back from menu_item_variants at reprint time would
-- mean marking a base next month silently changes what last month's bills say
-- — the same reason price and name are copied rather than joined.
ALTER TABLE order_items ADD COLUMN variant_is_base INTEGER NOT NULL DEFAULT 0
  CHECK (variant_is_base IN (0, 1));

-- Existing lines: every one of the 54 already billed is "Regular", on an item
-- that has only ever had that single portion. Backfilled from the variant it
-- points at so reprints of old bills match what a fresh bill would now show.
UPDATE order_items
SET variant_is_base = 1
WHERE variant_id IN (SELECT id FROM menu_item_variants WHERE is_base = 1);
