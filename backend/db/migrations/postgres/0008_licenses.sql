-- Licence keys. Cloud-only: minted here, claimed by a branch, never pushed up
-- from one. The branch keeps a cached copy in its own `license_state` table.
--
-- A key is bound to one machine at first activation. The binding is what stops a
-- restaurant copying the install folder to a second till, which is the realistic
-- threat — not a determined attacker.

CREATE TABLE licenses (
  key           TEXT PRIMARY KEY,
  branch_code   TEXT NOT NULL,
  restaurant    TEXT NOT NULL,

  -- Hashed Windows MachineGuid. NULL until first activation, then the key only
  -- works on that machine. Cleared by hand when a client replaces their PC.
  fingerprint   TEXT,

  -- unclaimed: minted, never activated
  -- active:    bound to a machine and in good standing
  -- revoked:   access withdrawn; the branch stops after its grace period
  status        TEXT NOT NULL DEFAULT 'unclaimed'
                CHECK (status IN ('unclaimed', 'active', 'revoked')),

  notes         TEXT,
  activated_at  TIMESTAMPTZ,
  -- Last time the branch successfully checked in. Drives nothing on the server;
  -- it is here so a dead install is visible without asking the restaurant.
  last_seen_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One key per branch code. A second key for BR1 would let the same branch run on
-- two machines, which is the thing the fingerprint exists to prevent.
CREATE UNIQUE INDEX licenses_branch_code_idx ON licenses (branch_code);

CREATE INDEX licenses_status_idx ON licenses (status);
