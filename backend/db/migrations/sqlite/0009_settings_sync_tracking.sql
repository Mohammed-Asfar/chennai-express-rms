-- Sync bookkeeping for settings, so it pushes on change rather than every cycle.
--
-- settings was left untracked and pushed whole on every sync cycle: ten rows
-- upserted to the cloud once a minute, for ever, whether or not anything had
-- changed. It also meant the worker could never tell an idle cycle from a busy
-- one, because there was always something "pending" to send.
--
-- It has carried synced_at since the first migration; only the attempt count and
-- error were missing, which is the pair every tracked table needs for
-- quarantine. See SCHEMA.md section 5.2.
--
-- Existing rows get synced_at = NULL by way of the default, so the next cycle
-- pushes them once and then leaves them alone.

ALTER TABLE settings ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE settings ADD COLUMN sync_error TEXT;
