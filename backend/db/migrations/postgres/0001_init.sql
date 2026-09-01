-- Chennai Express RMS — initial schema (Postgres / Neon)
-- Mirrors db/migrations/sqlite/0001_init.sql. Both dialects change together.
-- Money is INTEGER paise. Rates are INTEGER basis points (5% = 500).
-- See SCHEMA.md for the full reference.

CREATE TABLE branches (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  address     TEXT,
  phone       TEXT,
  gstin       TEXT,
  logo        TEXT,
  logo_bitmap TEXT,
  logo_width  INTEGER,
  logo_height INTEGER,
  print_logo  BOOLEAN NOT NULL DEFAULT TRUE,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL,
  synced_at   TIMESTAMPTZ,
  deleted_at  TIMESTAMPTZ
);

CREATE TABLE users (
  id                   TEXT PRIMARY KEY,
  branch_id            TEXT NOT NULL REFERENCES branches(id),
  username             TEXT NOT NULL,
  password_hash        TEXT NOT NULL,
  full_name            TEXT NOT NULL,
  role                 TEXT NOT NULL CHECK (role IN ('admin', 'cashier')),
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
  created_at           TIMESTAMPTZ NOT NULL,
  updated_at           TIMESTAMPTZ NOT NULL,
  synced_at            TIMESTAMPTZ,
  deleted_at           TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_users_username ON users(branch_id, username) WHERE deleted_at IS NULL;

CREATE TABLE sections (
  id         TEXT PRIMARY KEY,
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  name       TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  synced_at  TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_sections_name ON sections(branch_id, name) WHERE deleted_at IS NULL;

CREATE TABLE tables (
  id         TEXT PRIMARY KEY,
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  section_id TEXT NOT NULL REFERENCES sections(id),
  name       TEXT NOT NULL,
  seats      INTEGER NOT NULL DEFAULT 4,
  status     TEXT NOT NULL DEFAULT 'free' CHECK (status IN ('free', 'occupied', 'reserved')),
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  synced_at  TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_tables_name ON tables(branch_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_tables_section ON tables(branch_id, section_id, sort_order);

CREATE TABLE reservations (
  id             TEXT PRIMARY KEY,
  branch_id      TEXT NOT NULL REFERENCES branches(id),
  customer_name  TEXT NOT NULL,
  customer_phone TEXT,
  party_size     INTEGER NOT NULL,
  reserved_at    TIMESTAMPTZ NOT NULL,
  business_date  DATE NOT NULL,
  status         TEXT NOT NULL DEFAULT 'booked'
                 CHECK (status IN ('booked', 'seated', 'no_show', 'cancelled')),
  order_id       TEXT,
  notes          TEXT,
  created_by     TEXT NOT NULL REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL,
  synced_at      TIMESTAMPTZ,
  deleted_at     TIMESTAMPTZ
);

CREATE INDEX idx_reservations_date ON reservations(branch_id, business_date, status);

CREATE TABLE reservation_tables (
  reservation_id TEXT NOT NULL REFERENCES reservations(id),
  table_id       TEXT NOT NULL REFERENCES tables(id),
  PRIMARY KEY (reservation_id, table_id)
);

CREATE INDEX idx_res_tables_table ON reservation_tables(table_id);

CREATE TABLE categories (
  id         TEXT PRIMARY KEY,
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  name       TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  synced_at  TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_categories_name ON categories(branch_id, name) WHERE deleted_at IS NULL;

-- menu_items holds no price. Price lives on menu_item_variants.
CREATE TABLE menu_items (
  id           TEXT PRIMARY KEY,
  branch_id    TEXT NOT NULL REFERENCES branches(id),
  category_id  TEXT NOT NULL REFERENCES categories(id),
  name         TEXT NOT NULL,
  description  TEXT,
  tax_rate     INTEGER NOT NULL CHECK (tax_rate >= 0),
  is_available BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL,
  synced_at    TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_menu_items_cat ON menu_items(category_id, is_available);

-- Every item has at least one variant. Items without portions get 'Standard'.
CREATE TABLE menu_item_variants (
  id           TEXT PRIMARY KEY,
  menu_item_id TEXT NOT NULL REFERENCES menu_items(id),
  name         TEXT NOT NULL,
  price        BIGINT NOT NULL CHECK (price >= 0),
  sort_order   INTEGER NOT NULL DEFAULT 0,
  is_available BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL,
  synced_at    TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_variants_name ON menu_item_variants(menu_item_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_variants_item ON menu_item_variants(menu_item_id);

CREATE TABLE orders (
  id             TEXT PRIMARY KEY,
  branch_id      TEXT NOT NULL REFERENCES branches(id),
  order_no       INTEGER NOT NULL,
  business_date  DATE NOT NULL,
  type           TEXT NOT NULL CHECK (type IN ('dine_in', 'takeaway')),
  table_id       TEXT REFERENCES tables(id),
  seat_label     TEXT,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'billed', 'cancelled')),
  customer_name  TEXT,
  customer_phone TEXT,
  cancel_reason  TEXT,
  version        INTEGER NOT NULL DEFAULT 1,
  created_by     TEXT NOT NULL REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL,
  synced_at      TIMESTAMPTZ,
  deleted_at     TIMESTAMPTZ,
  CHECK (type = 'takeaway' OR table_id IS NOT NULL)
);

CREATE UNIQUE INDEX idx_orders_no ON orders(branch_id, business_date, order_no);
CREATE INDEX idx_orders_table_open ON orders(branch_id, table_id, status)
  WHERE status = 'open' AND deleted_at IS NULL;
CREATE INDEX idx_orders_date ON orders(branch_id, business_date);
CREATE INDEX idx_orders_sync ON orders(synced_at) WHERE synced_at IS NULL;

-- item_name, variant_name, unit_price and tax_rate are SNAPSHOTS taken when the
-- line was added. Never read them live from the menu — see CLAUDE.md section 3.
CREATE TABLE order_items (
  id             TEXT PRIMARY KEY,
  order_id       TEXT NOT NULL REFERENCES orders(id),
  variant_id     TEXT NOT NULL REFERENCES menu_item_variants(id),
  item_name      TEXT NOT NULL,
  variant_name   TEXT NOT NULL,
  unit_price     BIGINT NOT NULL CHECK (unit_price >= 0),
  tax_rate       INTEGER NOT NULL CHECK (tax_rate >= 0),
  qty            INTEGER NOT NULL CHECK (qty > 0),
  line_base      BIGINT NOT NULL DEFAULT 0,
  line_tax       BIGINT NOT NULL DEFAULT 0,
  line_total     BIGINT NOT NULL DEFAULT 0,
  notes          TEXT,
  kot_printed_at TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL,
  synced_at      TIMESTAMPTZ,
  deleted_at     TIMESTAMPTZ
);

CREATE INDEX idx_order_items_order ON order_items(order_id);

CREATE TABLE bills (
  id              TEXT PRIMARY KEY,
  branch_id       TEXT NOT NULL REFERENCES branches(id),
  order_id        TEXT NOT NULL REFERENCES orders(id),
  bill_no         INTEGER NOT NULL,
  business_date   DATE NOT NULL,
  subtotal        BIGINT NOT NULL,
  discount_type   TEXT NOT NULL DEFAULT 'none' CHECK (discount_type IN ('none', 'fixed', 'percent')),
  discount_value  INTEGER NOT NULL DEFAULT 0,
  discount_amount BIGINT NOT NULL DEFAULT 0,
  cgst            BIGINT NOT NULL DEFAULT 0,
  sgst            BIGINT NOT NULL DEFAULT 0,
  round_off       BIGINT NOT NULL DEFAULT 0,
  total           BIGINT NOT NULL,
  amount_paid     BIGINT NOT NULL DEFAULT 0,
  payment_status  TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
  tax_mode        TEXT NOT NULL CHECK (tax_mode IN ('inclusive', 'exclusive')),
  tax_breakdown   JSONB NOT NULL DEFAULT '[]',
  settled_at      TIMESTAMPTZ,
  customer_name   TEXT,
  customer_phone  TEXT,
  void_reason     TEXT,
  voided_at       TIMESTAMPTZ,
  voided_by       TEXT REFERENCES users(id),
  reprint_count   INTEGER NOT NULL DEFAULT 0,
  created_by      TEXT NOT NULL REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL,
  synced_at       TIMESTAMPTZ,
  deleted_at      TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_bills_no ON bills(branch_id, business_date, bill_no);
CREATE UNIQUE INDEX idx_bills_order ON bills(order_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_bills_date ON bills(branch_id, business_date);
CREATE INDEX idx_bills_unpaid ON bills(branch_id, payment_status)
  WHERE payment_status != 'paid' AND deleted_at IS NULL;
CREATE INDEX idx_bills_sync ON bills(synced_at) WHERE synced_at IS NULL;

-- A bill has many payments: Rs500 cash + Rs300 card is two rows.
CREATE TABLE payments (
  id             TEXT PRIMARY KEY,
  branch_id      TEXT NOT NULL REFERENCES branches(id),
  bill_id        TEXT NOT NULL REFERENCES bills(id),
  mode           TEXT NOT NULL CHECK (mode IN ('cash', 'card', 'upi')),
  amount         BIGINT NOT NULL CHECK (amount > 0),
  reference      TEXT,
  paid_at        TIMESTAMPTZ NOT NULL,
  business_date  DATE NOT NULL,
  reversed_at    TIMESTAMPTZ,
  reversed_by    TEXT REFERENCES users(id),
  reverse_reason TEXT,
  created_by     TEXT NOT NULL REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL,
  synced_at      TIMESTAMPTZ,
  deleted_at     TIMESTAMPTZ
);

CREATE INDEX idx_payments_bill ON payments(bill_id) WHERE reversed_at IS NULL;
CREATE INDEX idx_payments_date ON payments(branch_id, business_date, mode);
CREATE INDEX idx_payments_sync ON payments(synced_at) WHERE synced_at IS NULL;

CREATE TABLE printers (
  id          TEXT PRIMARY KEY,
  branch_id   TEXT NOT NULL REFERENCES branches(id),
  name        TEXT NOT NULL,
  connection  TEXT NOT NULL CHECK (connection IN ('usb', 'network')),
  address     TEXT NOT NULL,
  role        TEXT NOT NULL CHECK (role IN ('bill', 'kot', 'both')),
  paper_width TEXT NOT NULL DEFAULT '80mm' CHECK (paper_width IN ('58mm', '80mm')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL,
  synced_at   TIMESTAMPTZ,
  deleted_at  TIMESTAMPTZ
);

-- Branch-local: print state is meaningless in the cloud, so no sync columns.
CREATE TABLE print_jobs (
  id         TEXT PRIMARY KEY,
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  printer_id TEXT REFERENCES printers(id),
  type       TEXT NOT NULL CHECK (type IN ('bill', 'kot', 'kot_additional', 'kot_cancel', 'test')),
  ref_id     TEXT,
  payload    JSONB NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'printed', 'failed')),
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  printed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_print_jobs_pending ON print_jobs(status) WHERE status != 'printed';

CREATE TABLE settings (
  branch_id  TEXT NOT NULL REFERENCES branches(id),
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  synced_at  TIMESTAMPTZ,
  PRIMARY KEY (branch_id, key)
);
