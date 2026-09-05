-- What an air-conditioned table costs extra, per item.
--
-- A restaurant charging more for AC seating adds a flat amount to each item
-- ordered there — ₹10 on a ₹75 soup makes it ₹85. Held on the section rather
-- than in settings because a branch may surcharge a Terrace differently, or not
-- at all, and one branch-wide figure could not say so.
--
-- Paise, like every other money column. Zero for Non-AC, which is why it
-- defaults to zero: existing sections keep charging exactly what they charge
-- today, and this migration changes no price anywhere until someone sets one.
ALTER TABLE sections ADD COLUMN surcharge INTEGER NOT NULL DEFAULT 0;

-- What this item does instead, when it should not follow its section.
--
-- NULL means "use the section's amount" — the ordinary case, and the reason
-- this is nullable rather than a plain zero default. Zero here is a decision:
-- tea stays ₹20 in the AC room. Without the null the two are indistinguishable,
-- and raising a section from ₹10 to ₹15 would silently skip every item.
ALTER TABLE menu_items ADD COLUMN ac_surcharge INTEGER;
