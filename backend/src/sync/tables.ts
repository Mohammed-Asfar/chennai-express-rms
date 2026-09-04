/**
 * Which tables sync, in the order they must be pushed.
 *
 * Order is a foreign-key constraint, not a preference: a child arriving before
 * its parent is rejected by Postgres. Adding a table here without placing it
 * after its parents will fail on the first push that references it.
 */
export interface SyncTable {
  name: string
  columns: string[]
  /** Conflict target for the upsert. Composite for link tables. */
  conflictKeys: string[]
  /**
   * True when the table carries `synced_at` / `sync_attempts` / `sync_error`.
   *
   * False for composite-key tables (`settings`, `reservation_tables`), which have
   * no such columns and are pushed whole each cycle. They are small, and the
   * upsert makes repeating them harmless.
   */
  tracked: boolean
}

const BASE = ['id', 'branch_id', 'created_at', 'updated_at', 'deleted_at']

export const SYNC_TABLES: SyncTable[] = [
  {
    name: 'branches',
    columns: [
      'id', 'name', 'tagline', 'address', 'phone', 'gstin', 'logo', 'logo_bitmap',
      'logo_width', 'logo_height', 'print_logo', 'is_active',
      'created_at', 'updated_at', 'deleted_at',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'users',
    columns: [
      ...BASE, 'username', 'password_hash', 'full_name', 'role',
      'is_active', 'must_change_password',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'sections',
    columns: [...BASE, 'name', 'sort_order', 'is_active'],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'tables',
    columns: [...BASE, 'section_id', 'name', 'seats', 'status', 'sort_order', 'is_active'],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'categories',
    columns: [...BASE, 'name', 'sort_order', 'is_active'],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'menu_items',
    columns: [
      ...BASE, 'category_id', 'name', 'description', 'tax_rate',
      'is_available', 'sort_order',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'menu_item_variants',
    // No branch_id: it belongs to its item.
    columns: [
      'id', 'menu_item_id', 'name', 'price', 'sort_order', 'is_available',
      'created_at', 'updated_at', 'deleted_at',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'reservations',
    columns: [
      ...BASE, 'customer_name', 'customer_phone', 'party_size', 'reserved_at',
      'business_date', 'status', 'order_id', 'notes', 'created_by',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'orders',
    columns: [
      ...BASE, 'order_no', 'business_date', 'type', 'table_id', 'seat_label',
      'status', 'customer_name', 'customer_phone', 'cancel_reason', 'version',
      'created_by',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'order_items',
    columns: [
      'id', 'order_id', 'variant_id', 'item_name', 'variant_name', 'unit_price',
      'tax_rate', 'qty', 'line_base', 'line_tax', 'line_total', 'notes',
      'kot_printed_at', 'created_at', 'updated_at', 'deleted_at',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'bills',
    columns: [
      ...BASE, 'order_id', 'bill_no', 'bill_period', 'bill_number', 'business_date', 'subtotal', 'discount_type',
      'discount_value', 'discount_amount', 'cgst', 'sgst', 'round_off', 'total',
      'amount_paid', 'payment_status', 'tax_mode', 'tax_breakdown', 'settled_at',
      'customer_name', 'customer_phone', 'void_reason', 'voided_at', 'voided_by',
      'reprint_count', 'created_by',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'payments',
    columns: [
      ...BASE, 'bill_id', 'mode', 'amount', 'reference', 'paid_at',
      'business_date', 'reversed_at', 'reversed_by', 'reverse_reason', 'created_by',
    ],
    conflictKeys: ['id'],
    tracked: true,
  },
  {
    name: 'reservation_tables',
    // A link table: no id, no sync columns. Pushed whole with its reservation.
    columns: ['reservation_id', 'table_id'],
    conflictKeys: ['reservation_id', 'table_id'],
    tracked: false,
  },
  {
    // Composite key and no sync columns, so it is pushed whole each cycle rather
    // than tracked per row. It is a handful of rows.
    name: 'settings',
    columns: ['branch_id', 'key', 'value', 'created_at', 'updated_at'],
    conflictKeys: ['branch_id', 'key'],
    // Tracked, unlike the link tables below it. Untracked means "push the whole
    // table every cycle", which for settings meant ten rows upserted to the
    // cloud once a minute for ever, and left the worker unable to tell an idle
    // cycle from a busy one — there was always something pending to send.
    tracked: true,
  },
]

/**
 * `print_jobs` is deliberately absent — print state is meaningless in the cloud,
 * and it has no Postgres table (dropped in migration 0003).
 *
 * `app_releases` is cloud-only: read by the branch, never written by it.
 */
export const NEVER_SYNCED = ['print_jobs', 'app_releases', '_migrations'] as const

/** Rows are quarantined after this many consecutive failures. */
export const MAX_SYNC_ATTEMPTS = 5

/** Retry delay per attempt: 30s, 1m, 2m, 4m, 8m. */
export function backoffMs(attempts: number): number {
  return 30_000 * 2 ** Math.min(attempts, MAX_SYNC_ATTEMPTS - 1)
}
