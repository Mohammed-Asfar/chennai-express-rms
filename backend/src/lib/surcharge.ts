/**
 * What an air-conditioned table adds to an item's price.
 *
 * A restaurant charging more for AC seating adds a flat amount per item — ₹10
 * on a ₹75 soup makes it ₹85. The amount lives on the section, so a Terrace can
 * differ from an AC room, and an item may override it.
 *
 * **This is applied when the line is created, never at billing time.** The
 * surcharged figure is what goes into `order_items.unit_price`, which is the
 * snapshot every downstream rule already relies on: tax computes on the price
 * actually charged, a reprint reads the same number, and moving a party to
 * another section cannot silently reprice food they already ate.
 */
export interface SurchargeInput {
  /** The section's amount in paise. Null when the order has no table. */
  section: number | null
  /** The item's own amount, or null to follow the section. */
  item: number | null
}

function assertPaise(value: number, what: string): void {
  if (!Number.isInteger(value)) {
    throw new Error(`${what} must be integer paise, got ${value}`)
  }
  // A negative surcharge would be a discount that skips the discount rules —
  // unrecorded, and able to take a line below zero.
  if (value < 0) {
    throw new Error(`${what} cannot be negative, got ${value}`)
  }
}

/**
 * The amount to add to one item, in paise.
 *
 * An item's own value wins when set, including when it is zero — that is the
 * exemption, and the reason the column is nullable. Null means "follow the
 * section", so raising a section from ₹10 to ₹15 carries every ordinary item
 * with it.
 */
export function surchargeFor(input: SurchargeInput): number {
  if (input.item !== null) assertPaise(input.item, 'item surcharge')
  if (input.section !== null) assertPaise(input.section, 'section surcharge')

  // No table means no air-conditioned room to charge for. A takeaway or a
  // delivery pays the menu price, whatever any item says.
  if (input.section === null) return 0

  return input.item ?? input.section
}

/**
 * The unit price to snapshot onto an order line, in paise.
 *
 * Per item rather than per order: three soups at an AC table each cost ₹85, so
 * the party pays ₹30 more, not ₹10.
 */
export function pricedAt(menuPrice: number, input: SurchargeInput): number {
  assertPaise(menuPrice, 'menu price')
  return menuPrice + surchargeFor(input)
}
