-- A line under the restaurant name on the bill.
--
-- Matches the SQLite counterpart: `branches` syncs, so a column added on one
-- side and not the other breaks the push.

ALTER TABLE branches ADD COLUMN tagline TEXT;
