-- The cloud counterpart of the SQLite migration of the same name.
--
-- The columns are unused here — the cloud is written to, never synced from —
-- but both dialects change together, or a push naming a column Postgres does
-- not have breaks sync for every branch at once.

ALTER TABLE settings ADD COLUMN IF NOT EXISTS sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS sync_error TEXT;
