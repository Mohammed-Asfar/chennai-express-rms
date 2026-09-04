# Sync

How a branch's data reaches the cloud, and why it is built the way it is.

`SCHEMA.md` §5 lists which tables sync and what columns carry the bookkeeping.
This is the reasoning behind the timing — the decisions that look arbitrary from
the code alone, and the ones already reconsidered and kept.

---

## 1. What actually pushes a bill

**The write hook, not the heartbeat.**

Every successful non-GET request signals the sync worker, through one
`onResponse` hook in `server.ts`:

```ts
app.addHook('onResponse', async (request, reply) => {
  if (request.method === 'GET' || request.method === 'HEAD') return
  if (reply.statusCode >= 400) return
  if (request.url.startsWith('/sync/')) return
  app.sync.signal()
})
```

A hook rather than a call in each route: a new endpoint would otherwise have to
remember, and forgetting means its writes sit unsynced with nothing to show for
it. `signal()` debounces by two seconds, so a burst of order edits becomes one
push rather than ten.

**A payment therefore reaches the cloud about two seconds after it is taken.**
That is the path that matters, and no timer is involved in it.

---

## 2. The four triggers

| Trigger | When | What it is for |
|---|---|---|
| `write` | ~2s after any successful write | **Every bill, order and payment** |
| `retry` | 30s, 1m, 2m, 4m, 8m after a failure | Recovering from an outage |
| `startup` | Process start | Whatever was pending when it last stopped |
| `heartbeat` | Every 5 minutes | The three cases below, and nothing else |

---

## 3. Why the heartbeat exists at all

It was set to one minute, questioned, and reduced to five rather than removed.
Three things depend on it, and none of them is delivering a bill.

### 3.1 A capped batch leaves rows behind

`pushPending` takes at most 200 rows per table per cycle. A branch coming back
from an outage with 500 pending rows pushes 200 and stops — and **nothing
re-signals**, because `pendingSignal` is only set by writes and no write
happened. A quiet spell after a rush would strand the remainder.

### 3.2 A write outside the API cannot signal

`scripts/seed-menu.mjs` writes straight to SQLite. So does anyone running a
one-off `UPDATE` against the database file. The running backend has no idea, so
the `onResponse` hook never fires, and only the heartbeat carries those rows up.

### 3.3 It is what makes the backup screen honest

This is the one that rules out removing it.

The screen's verdict comes from `consecutiveFailures`, which only changes when a
cycle actually runs. **With no heartbeat, a dead cloud reads as healthy:** the
screen shows "Last backed up: 2 hours ago" in a green state, because nothing has
tried and failed since. The owner has no reason to press *Back up now* — the
screen is telling them everything is fine.

That inverts the point of the feature. The screen exists to answer "is my
trading data safe anywhere other than this PC", and it can only answer that if
something checks.

---

## 4. Why not rely on the "Back up now" button

The button exists, and it works. It is not a substitute:

- **It needs a reason to be pressed.** §3.3 — without a periodic check the
  screen never tells anyone to press it.
- **It needs someone at the till.** A branch that closes at midnight with rows
  pending would leave them until someone opens the app and thinks to look.
- **It is a repair, not a routine.** Asking staff to remember a daily backup
  step is asking them to be the system's error handling.

---

## 5. Why five minutes and not one

At one minute the worker dialled sixty times an hour. Each connection keeps the
cloud awake for about ten seconds (`idle_timeout`), so a till that was merely
switched on held compute open roughly **17% of every hour** — and on an idle
till none of those wake-ups moved a single row.

| | Every 60s | Every 5 min |
|---|---|---|
| Connections per hour | 60 | 12 |
| Cloud awake | ~17% of the hour | ~3% |

**What five minutes costs:** a till sitting idle can take five minutes rather
than one to notice the cloud has gone. A till taking orders still notices in two
seconds, because every write dials regardless.

Nobody acts differently on that difference. The response to a dead cloud is the
same either way, and the data is safe locally throughout.

**The retry backoff still wins.** It fires at 30s, 1m, 2m and 4m — all sooner
than the heartbeat — so outage recovery did not get slower. Past the fourth
attempt the backoff reaches 8 minutes, at which point the 5-minute heartbeat
actually recovers *sooner* than the backoff would have.

---

## 6. Tracked and untracked tables

A **tracked** table carries `synced_at`, `sync_attempts` and `sync_error`, and
pushes only rows where `synced_at IS NULL`.

An **untracked** table has no such columns, so `selectPending` returns the whole
table on every cycle and relies on the upsert being idempotent.

`settings` was untracked until migration `0009`. Ten rows were upserted to the
cloud once a minute, for ever, changed or not — and worse, it meant the worker
could never tell an idle cycle from a busy one, because something always looked
pending. It is tracked now.

`reservation_tables` is still untracked: it is a link table with no sync columns
and is usually empty, so pushing it whole costs nothing worth a migration.

---

## 7. Sync never blocks billing

Non-negotiable, and the reason several things above look over-careful:

- Writes go to SQLite and succeed with no internet.
- A failed cycle resolves to `null`, never a thrown error.
- A route never waits on `signal()` — it is synchronous and returns immediately.
- One malformed row is quarantined after five attempts rather than blocking the
  queue behind it, and surfaces in the UI with a Retry.

A restaurant must be able to take money with the internet unplugged. Everything
here is downstream of that.

---

## 8. One cloud, one branch

A branch's identity is its `branch_id`, and order numbers are unique per branch
per trading day:

```sql
CREATE UNIQUE INDEX idx_orders_no ON orders(branch_id, business_date, order_no);
```

Two databases pushing as the same branch will therefore collide: each allocates
its own #1 for the day, and the cloud can hold only one. That is the index doing
its job — the alternative is one restaurant's order silently overwriting
another's.

This happened with `pnpm run dev`, which uses its own SQLite but the same
`.env`. A development server now needs `SYNC_IN_DEV=true` to reach the cloud at
all; without it, it runs offline.
