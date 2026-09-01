# Chennai Express RMS — Project Rules

Restaurant management and billing system. Node.js + Fastify + SQLite backend,
Flutter Windows frontend, Neon Postgres cloud sync, ESC/POS thermal printing.

**Read first:** `PRD.md` (requirements), `SCHEMA.md` (database).

---

## 1. Keep documents in step

| When you change | Also update |
|---|---|
| A table's columns (migration) | `SCHEMA.md` §3 — columns, types, constraints |
| An index | `SCHEMA.md` §4 |
| A relationship between tables | `SCHEMA.md` §2 ER diagram |
| Which tables sync | `SCHEMA.md` §5 |
| A feature's behaviour | `PRD.md` §6 requirements |
| A new edge case or its handling | `PRD.md` §7 |
| A colour, text style, or spacing value | `core/theme/` only — never a widget |
| The stack or a rejected option | `PRD.md` §3 |

`SCHEMA.md` is hand-maintained, not generated. It goes stale unless updated in the
same change as the migration. **Update it in the same commit — never "later".**

If a change makes a document wrong and you are not updating it, say so explicitly
rather than leaving it silently inconsistent.

---

## 2. Money and tax — the rules that produce wrong bills if broken

These are the defects that ship silently and surface weeks later at reconciliation.

| Rule | Detail |
|---|---|
| **Money is integer paise** | ₹450.00 → `45000`. Never float, never decimal, anywhere — not in the DB, not in TypeScript, not in JSON over the API. |
| **Rates are integer basis points** | 5% → `500`, 2.5% → `250`. A `0.05` float reintroduces the drift paise avoids. |
| **Basis points divide by 10000, not 100** | `line_base × rate / 10000`. Using `/100` overcharges by 100×. |
| **Discount before tax** | Tax is computed on the discounted amount. Taxing the pre-discount total overcharges the customer. |
| **Convert only at the boundary** | `toPaise()` on input, `formatMoney()` on display. Everything between is integer arithmetic. |
| **Round once, per line** | Never round a running total. Never round twice. |
| **Split CGST/SGST per rate group, not per line** | `cgst = group_tax / 2`, `sgst = group_tax − cgst`. Summing per-line halves drifts — three lines taxed 7 paise give 12 vs 9 instead of 10 vs 11. |
| **Inclusive mode: `line_tax = gross_net − base`** | Guarantees the parts sum to the price actually charged. If the customer sees ₹100, the components add to ₹100. |
| **Tax is per line, then summed** | Never applied once to the subtotal. Items can carry different rates. |
| **Distributed discounts: last line takes the remainder** | Proportional shares must sum back to the discount exactly. |
| **`amount_paid` and `payment_status` are derived** | Recalculated from live `payments` rows in the same transaction as any payment write. Never set directly. |
| **Payments are reversed, never deleted** | A wrong payment gets a reversal row plus a correct one. Both stay for audit. |
| **Sales date and cash date are different things** | Sales use `bills.business_date`; cash collection uses `payments.business_date`. A Monday bill paid Wednesday counts in both places, on different days. |

**Order of operations, always:** line amounts → discount → tax → CGST/SGST split →
round-off.

Billing changes require tests **before** the implementation. See `PRD.md` §9.1 for
the required cases.

---

## 3. Order lines are snapshots

`item_name`, `variant_name`, `unit_price`, and `tax_rate` are **copied onto
`order_items` when the item is added**.

Never read price, name, or tax rate from `menu_items` or `menu_item_variants` at
billing or reprint time. Doing so means renaming a dish or repricing it silently
rewrites bills that were already printed.

`variant_id` on an order line is a reference for reporting only. It is never used
for pricing.

Same rule for `bills.tax_mode` — snapshotted, because a branch switching from
inclusive to exclusive must not change what last month's bills mean.

---

## 4. Architecture boundaries

| Rule | Why |
|---|---|
| **Flutter holds no business logic and no database** | It is a pure UI layer. All calculation, validation, and state lives in the backend. |
| **Order and bill numbers are allocated backend-side, inside the insert transaction** | Two terminals would otherwise allocate the same number. |
| **A print failure never blocks an order or a bill** | The record saves; the job queues with a retry. A kitchen printer on wifi will go offline. |
| **Sync never touches the billing path** | Writes go to SQLite and succeed offline. The sync worker is separate and failure-tolerant. |
| **Validate every request with Zod at the API boundary** | Trust nothing from the client, including a client you wrote. |

---

## 5. Database

| Rule | Detail |
|---|---|
| `branch_id` on every new business table | v1 uses one branch, but retrofitting this onto live billing data means migrating financial records. |
| UUID v4 primary keys, backend-generated | Never auto-increment — prevents branch↔cloud collisions. |
| Timestamps stored UTC | SQLite ISO-8601 text, Postgres `TIMESTAMPTZ`. |
| Soft delete on transactional rows | Orders and bills are never hard-deleted. |
| **Migrations are append-only once applied** | Never edit a migration that has run on real data. Fix forward with a new one. Checksums are verified at boot. |
| Both dialects change together | A SQLite migration without its Postgres counterpart breaks sync. |
| Reports use `business_date`, not `created_at` | A restaurant open past midnight keeps 1 AM sales on the previous trading day. |

---

## 6. Flutter structure

**Feature-based, not layer-based.** Everything a feature needs lives in its folder.

```
lib/
  core/
    theme/
      app_colors.dart      ← THE colour source of truth
      app_theme.dart       ← THE ThemeData source of truth
      app_text_styles.dart
      app_spacing.dart
    api/                   ← http client, interceptors, error mapping
    router/
    utils/                 ← money formatting, date helpers
    widgets/               ← shared widgets used by 2+ features
  features/
    orders/
      data/                ← models, api calls
      presentation/        ← screens, widgets, state
    menu/
    tables/
    billing/
    printers/
    reports/
    settings/
  main.dart
```

| Rule | Detail |
|---|---|
| A feature never imports another feature's internals | Shared code moves to `core/`. If two features need it, it is core. |
| `core/` never imports from `features/` | Dependencies point one way only. |
| A file belongs to the feature that owns it | Not to a global `screens/` or `models/` folder. |
| Shared widget = used by 2+ features | One user means it stays in that feature. |

### 6.1 Theme and colours — one source of truth

| Rule | Detail |
|---|---|
| **All colours live in `core/theme/app_colors.dart`** | Nowhere else. |
| **All theme config lives in `core/theme/app_theme.dart`** | One `ThemeData`, built from `AppColors`. |
| **Never hardcode a colour in a widget** | No `Color(0xFF...)`, no `Colors.red`, no hex literals outside `app_colors.dart`. |
| **Never hardcode a `TextStyle`** | Read from `Theme.of(context).textTheme` or `AppTextStyles`. |
| **Never hardcode spacing** | Use `AppSpacing` constants, not bare `EdgeInsets.all(16)` scattered about. |
| **Widgets read from the theme** | `Theme.of(context).colorScheme.primary`, not `AppColors.primary` directly in build methods where a theme lookup is available. |

```dart
// wrong — colour defined at the point of use
Container(color: Color(0xFFD32F2F))
Text('Total', style: TextStyle(fontSize: 18, color: Colors.black))

// right — one definition, referenced everywhere
Container(color: Theme.of(context).colorScheme.error)
Text('Total', style: Theme.of(context).textTheme.titleMedium)
```

**Why this is a hard rule:** a restaurant will ask to change the accent colour, and it
must be a one-line change. Hex literals spread through widgets turn that into a hunt
through every file, and the ones you miss show up as visual inconsistency the client
notices before you do.

Changing a colour or text style means editing `core/theme/` — never a widget.

---

## 7. Code conventions

| | |
|---|---|
| Database | `snake_case`, plural tables, `<singular>_id` foreign keys |
| TypeScript | `camelCase`; explicit types on exported functions |
| Errors | Fail loudly in billing paths. Never swallow an exception that could produce a wrong total. |
| Comments | Explain *why*, not *what*. The snapshot rules and rounding rules deserve comments; a getter does not. |

---

## 8. Commits

- **No `Co-Authored-By` trailer.**
- **No mention of Claude, AI, or generated code** in commit messages, code comments,
  or documentation.
- Present tense, imperative: `add variant support to menu items`
- Commit only when asked.
- If on the default branch, create a feature branch first.

---

## 9. Before saying something is done

- [ ] Tests pass — actually run them, do not assume
- [ ] `SCHEMA.md` updated if the schema changed
- [ ] `PRD.md` updated if behaviour changed
- [ ] Both SQLite and Postgres migrations written
- [ ] Money paths use integers end to end
- [ ] No hardcoded colours, text styles, or spacing in widgets
- [ ] No debug logging left in

Report what actually happened. If tests fail, say so with the output. If something
was skipped, say that. Do not describe partial work as complete.
