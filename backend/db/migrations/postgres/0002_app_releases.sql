-- Published application versions. Cloud-only: a branch reads this table but never
-- writes it, and it has no SQLite counterpart (0002 is postgres-only by design).

CREATE TABLE app_releases (
  id                 TEXT PRIMARY KEY,
  version            TEXT NOT NULL,
  build_number       INTEGER NOT NULL,
  channel            TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta')),
  download_url       TEXT NOT NULL,
  file_size          BIGINT NOT NULL,
  sha256             TEXT NOT NULL,
  release_notes      TEXT NOT NULL DEFAULT '',
  is_mandatory       BOOLEAN NOT NULL DEFAULT FALSE,
  min_supported_build INTEGER NOT NULL DEFAULT 0,
  released_at        TIMESTAMPTZ NOT NULL,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL,
  updated_at         TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX idx_releases_build ON app_releases(channel, build_number);
CREATE INDEX idx_releases_latest ON app_releases(channel, build_number DESC) WHERE is_active;
