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

```
┌──────────────────────────────────┐
│            [ logo ]              │
│                                  │
│         Activate this PC         │
│              ────                │
│  Enter the activation key        │
│  supplied with your licence.     │
│  It will be linked to this PC.   │
│                                  │
│  ┌────────────────────────────┐  │
│  │ CX-V8G8-GWAE-KD9F          │  │
│  └────────────────────────────┘  │
│                                  │
│  ┌────────────────────────────┐  │
│  │         Activate           │  │
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

The field upper-cases and inserts the dashes as you type, and stops at a full
key — someone reading it off a phone screen does not have to get the punctuation
right.

Once the grace period is nearly spent, a banner appears above the work area
naming the days left, with a **Retry now** button. It never blocks anything.

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

## 8. What an installed till actually protects

Packaging is in place. On an installed PC:

| | |
|---|---|
| Source code | Not present — one bundled `server.mjs` |
| Connection string | In `config.dat`, DPAPI-encrypted to that machine |
| JWT secret | Generated per installation |
| Install directory | Under Program Files, so a standard user cannot modify it |

A cashier cannot read the connection string, replace the server, or point the
backend at their own database. A `config.dat` copied to another PC will not
decrypt.

**What it still does not stop: an administrator on the billing PC.** The service
must decrypt the config to work, so anyone who can run code as the service
account can read what the service reads. That is true of every scheme short of a
hardware security module, and it is the reason the ACL — not the encryption — is
the load-bearing part.

The threat this is built for is a restaurant copying the install to a second
till, or a curious member of staff opening files. It is not built to withstand a
determined attacker with administrator rights on hardware they own.

See `backend/scripts/README.md` for the install steps.

---

## 9. The desktop app

`desktop/lib/features/activation/`

The gate sits **ahead of the auth gate** in `app.dart`. An unlicensed
installation never reaches a login screen.

| Phase | Screen |
|---|---|
| `checking` | Loading |
| `backendDown` | The existing "service unreachable" screen |
| `blocked` | Activation screen |
| `allowed` | Continues to the auth gate |

**`backendDown` is separate from `blocked` on purpose.** The Windows service and
the app start together and the service does not always win. Treating a slow start
as "not activated" would put an activated restaurant in front of the key screen
every morning.

A licence that is activated but out of grace, or revoked, shows the same screen
with no key field — the key they hold is the right one, so offering the field
would send staff round a loop that cannot succeed. They get **Check again**
instead.

---

## 10. Testing

`backend/test/license.test.ts` — 21 cases covering key format and normalisation,
fingerprint stability, the full grace-period ladder, revocation, fail-closed on a
corrupt timestamp, and the single-row constraint.

`desktop/test/activation_test.dart` — 13 cases covering the verdict model, the
banner's visibility rules, and key entry formatting.

Each was verified by deliberately breaking the implementation:

| Break | Caught by |
|---|---|
| Grace period never expires | `billing stops once the grace period is spent` |
| Revoked licence runs forever | `a revoked licence stops after its grace period` |
| Missing `allowed` defaults to true | `an empty response fails closed` |
| No length cap on key entry | `the field stops at a full key` |

The claim cycle was also run against the real Neon database: a second PC with the
same key is rejected, the same PC re-launching succeeds, a revoked key is
rejected, and an unbound key activates on a new machine.
