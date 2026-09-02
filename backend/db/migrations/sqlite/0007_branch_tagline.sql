-- A line under the restaurant name on the bill.
--
-- "Authentic Chennai Cuisine", "Since 1998" — the sort of thing that sits on a
-- letterhead. Kept separate from `name` because the name is also what the app
-- shows in its own UI, where a tagline would be noise.

ALTER TABLE branches ADD COLUMN tagline TEXT;
