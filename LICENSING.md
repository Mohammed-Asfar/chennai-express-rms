# Licensing and Activation

How a Chennai Express RMS installation is authorised, and how you administer it.

**Audience:** the vendor. Nothing in this document belongs on a restaurant's PC.

---

## 1. What it does

Each installation must be activated with a key before anyone can sign in. A key
binds to the first PC that activates it, so an install folder copied to a second
machine will not run. You can withdraw access without visiting the restaurant.

What it is **not**: protection against a determined attacker. It stops a
restaurant copying the software to a second till, or passing it to another
restaurant. Someone technical who can edit files on the billing PC can bypass it
until the app is packaged (§8).

---

## 2. The daily workflow

### Selling to a new restaurant

```bash
npm run license:new -- --branch BR1 --restaurant "Chennai Express"
```

```
  CX-7K4M-9PQR-2XYZ

  branch      BR1
  restaurant  Chennai Express
  status      unclaimed
```

Keep that key. Nothing has been activated yet — the row simply exists.

Branch codes are yours to allocate: `BR1`, `BR2`, and so on. One key per branch
code, enforced by a unique index.

### Installing

Type the key into the activation screen on first launch. That is the whole
process — the key binds to that PC and the screen never appears again.

### Seeing what is out there

```bash
npm run license:list
```

```
  CX-7K4M-9PQR-2XYZ  BR1    active     bound          last seen 2026-09-02 14:20
                     Chennai Express
```

`last seen` is the last time that installation reached the licence server. A date
that stops moving means the PC is off, offline, or the install is gone.

### Withdrawing access

```bash
npm run license:revoke -- --key CX-7K4M-9PQR-2XYZ
```

The restaurant keeps billing for **7 more days**, with a warning, then stops.
Reverse it any time with `license:restore`.

### They replaced their PC

```bash
npm run license:reset -- --key CX-7K4M-9PQR-2XYZ
```

Clears the machine binding so the same key activates on the new machine. This is
also the answer to a failed hard drive or a Windows reinstall.

---

## 3. How activation works

```
  You                    Restaurant PC                  Neon
   │                          │                          │
   │  license:new             │                          │
   ├──────────────────────────┼─────────────────────────►│  row: unclaimed
   │                          │                          │
   │  key (WhatsApp, phone)   │                          │
   ├─────────────────────────►│                          │
   │                          │  key + fingerprint       │
   │                          ├─────────────────────────►│  claim
   │                          │◄─────────────────────────┤  active, bound
   │                          │                          │
   │                          │  cached locally          │
   │                          │  works offline 7 days    │
```

The claim is a single statement, so two PCs racing with the same key cannot both
win:

```sql
UPDATE licenses
   SET fingerprint = $1, status = 'active', activated_at = COALESCE(activated_at, now())
 WHERE key = $2
   AND status <> 'revoked'
   AND (fingerprint IS NULL OR fingerprint = $1)
RETURNING branch_code, restaurant, status, activated_at
```

The first PC writes its fingerprint. The second no longer matches the `WHERE`
clause and gets zero rows. A read-then-write would let both through.

Re-running it on the **same** machine is a no-op that returns the same row, which
is what makes a repeated launch or a reinstall on that PC harmless.

### The machine fingerprint

The Windows `MachineGuid` from
`HKLM\SOFTWARE\Microsoft\Cryptography`, hashed with SHA-256.

It survives reboots, app updates, and hardware changes short of a Windows
reinstall. It is hashed rather than stored raw: the cloud has no use for the
actual GUID, and a hash cannot be used to identify that machine anywhere else.

Off Windows, a hostname-derived fallback keeps development and tests working.

---

## 4. The grace period

**An activation check never stops a restaurant billing because the internet is
down.** This is the same rule sync and update checks follow.

| Days since last successful check | Behaviour |
|---|---|
| 0 | Normal. Nothing shown. |
| 1–4 | Normal. Nothing shown. |
| 5–7 | Billing continues, with a warning naming the days left |
| 7+ | Billing stops |

A revoked licence gets the same 7 days. Cutting a restaurant off the instant a
flag flips would cost them a day's takings over what is usually a billing
dispute.

A failed check leaves `last_verified_at` untouched, so the window **counts down**
rather than resetting. An install that never reaches the cloud again does
eventually stop — but not today, and not mid-service.

A corrupted or unparseable timestamp fails **closed**, not open.

---

## 5. Schema

### Cloud — `licenses` (Postgres, migration 0008)

| Column | Notes |
|---|---|
| `key` | `CX-XXXX-XXXX-XXXX`, primary key |
| `branch_code` | `BR1`, `BR2`. Unique — one key per branch |
| `restaurant` | Display name, shown on the activation screen |
| `fingerprint` | Hashed MachineGuid. `NULL` until first activation |
| `status` | `unclaimed` \| `active` \| `revoked` |
| `activated_at` | First successful claim |
| `last_seen_at` | Last check-in. Diagnostic only |

Cloud-only. Never pushed up by a branch, never in `SYNC_TABLES`.

### Branch — `license_state` (SQLite, migration 0008)

A single row (`CHECK (id = 1)`) caching what the till last heard, so it can keep
billing offline. `last_verified_at` drives the grace period.

---

## 6. Endpoints

Both are unauthenticated by necessity — they run before anyone can sign in.

### `GET /activation/status`

Returns the verdict from the local cache and refreshes from the cloud in the
background, so a slow or dead cloud never delays the login screen.

```json
{
  "allowed": true,
  "activated": true,
  "status": "active",
  "branchCode": "BR1",
  "restaurant": "Chennai Express",
  "graceDaysRemaining": null,
  "warn": false,
  "message": null,
  "lastVerifiedAt": "2026-09-02T14:20:00.000Z"
}
```

### `POST /activation/claim`

```json
{ "key": "CX-7K4M-9PQR-2XYZ" }
```

Keys are normalised before use — lowercase, missing dashes, and pasted whitespace
all work, because someone reading a key off a phone screen should not have to
fight the field.

**Every failure returns the same message.** Wrong key, already bound elsewhere,
and revoked are indistinguishable to the caller: telling them which would let
someone probe for valid keys.

---

## 7. Key format

`CX-XXXX-XXXX-XXXX` from a 30-character alphabet that omits `O/0`, `I/1` and
`S/5` — the pairs people confuse reading a key aloud.

30^12 ≈ 5.3 × 10^17 combinations. These are handed out one at a time rather than
guessed at scale, and the fingerprint binding is the real control.

---

## 8. Known limitation

Until the app is packaged, `.env` is a readable file on the billing PC. Someone
who can edit it can point the backend at their own database and mint themselves a
licence.

Activation is still worth having now — it stops the realistic threat, which is a
restaurant copying the folder to a second till. But it is not airtight until
packaging lands (PRD step 12): Node bundled to a single binary, the connection
string embedded rather than sitting in a file, and the install directory
ACL-locked so a non-administrator cannot write to it.

---

## 9. Testing

`backend/test/license.test.ts` — 21 cases covering key format and normalisation,
fingerprint stability, the full grace-period ladder, revocation, fail-closed on a
corrupt timestamp, and the single-row constraint.

Each was verified by deliberately breaking the implementation: the grace period
never expiring, and a revoked licence running forever. Both were caught.
