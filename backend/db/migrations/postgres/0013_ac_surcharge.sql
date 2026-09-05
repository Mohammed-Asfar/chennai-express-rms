-- What an air-conditioned table costs extra, per item.
--
-- Matches the SQLite counterpart: `sections` and `menu_items` both sync, so a
-- column added on one side and not the other breaks the push.
--
-- Paise. Zero for a section that charges nothing extra; NULL on an item means
-- it follows its section, which is what distinguishes "not set" from "this one
-- is deliberately free".
ALTER TABLE sections ADD COLUMN surcharge INTEGER NOT NULL DEFAULT 0;

ALTER TABLE menu_items ADD COLUMN ac_surcharge INTEGER;
