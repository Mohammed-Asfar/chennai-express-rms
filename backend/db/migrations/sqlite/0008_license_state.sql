-- The branch's cached copy of its licence.
--
-- The cloud holds the authority; this holds what the till last heard, so it can
-- keep billing when the internet is down. Without a local cache every activation
-- check would be a network call, and a dropped connection would stop service —
-- which is the one thing sync and updates are both built never to do.
--
-- Single row, enforced by the CHECK. There is one licence per installation.

CREATE TABLE license_state (
  id                INTEGER PRIMARY KEY CHECK (id = 1),

  key               TEXT NOT NULL,
  branch_code       TEXT NOT NULL,
  restaurant        TEXT NOT NULL,
  fingerprint       TEXT NOT NULL,

  -- Mirrors licenses.status in the cloud as of the last successful check.
  status            TEXT NOT NULL
                    CHECK (status IN ('active', 'revoked')),

  activated_at      TEXT NOT NULL,

  -- The grace period counts from here. A check that reaches the cloud updates it;
  -- one that fails leaves it alone, so the window shrinks while offline rather
  -- than resetting on every failed attempt.
  last_verified_at  TEXT NOT NULL,

  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
