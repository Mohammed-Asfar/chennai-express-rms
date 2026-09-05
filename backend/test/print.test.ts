import { EscPosBuilder, CHARS_PER_LINE } from '../src/print/escpos.js'
import { renderKot, renderBill, renderTest } from '../src/print/tickets.js'
import { test, assertEqual } from './helpers.js'

/**
 * Strips ESC/POS control bytes so the printed text can be read.
 *
 * Walks the stream rather than pattern-matching it: each command takes a known
 * number of argument bytes, and a regex that guesses wrong silently eats the
 * first character of the text that follows.
 */
function readable(buffer: Buffer): string {
  /** ESC command byte -> how many argument bytes follow. */
  const ESC_ARGS: Record<number, number> = {
    0x40: 0, // @ reset
    0x61: 1, // a align
    0x45: 1, // E bold
    0x2d: 1, // - underline
    0x64: 1, // d feed n
    0x70: 3, // p drawer kick
  }
  const GS_ARGS: Record<number, number> = {
    0x21: 1, // ! character size
    0x56: 1, // V cut
  }

  let out = ''
  let i = 0
  while (i < buffer.length) {
    const byte = buffer[i] ?? 0
    const next = i + 1 < buffer.length ? (buffer[i + 1] ?? 0) : -1

    if (byte === 0x1b && next >= 0) {
      const args = ESC_ARGS[next]
      if (args !== undefined) {
        i += 2 + args
        continue
      }
    }
    if (byte === 0x1d && next >= 0) {
      const args = GS_ARGS[next]
      if (args !== undefined) {
        i += 2 + args
        continue
      }
    }
    out += String.fromCharCode(byte)
    i++
  }
  return out
}

const lines = (buffer: Buffer): string[] =>
  readable(buffer).split('\n').map((l) => l.trimEnd())

// --- the builder ---

test('columns puts the amount hard against the right edge', () => {
  const b = new EscPosBuilder('80mm')
  b.columns('Subtotal', '304.76')
  const line = lines(b.build()).find((l) => l.includes('Subtotal'))!
  assertEqual(line.length, 48, 'fills the full width')
  assertEqual(line.endsWith('304.76'), true, 'amount is flush right')
})

test('columns truncates the label, never the amount', () => {
  const b = new EscPosBuilder('58mm')
  const long = 'Chicken Biryani Full Portion Extra Spicy Special'
  b.columns(long, '1234.00')
  const line = lines(b.build()).find((l) => l.includes('1234.00'))!
  assertEqual(line.length <= 32, true, 'fits 58mm paper')
  assertEqual(line.endsWith('1234.00'), true, 'the price survives intact')
})

test('paper width decides the column count', () => {
  assertEqual(new EscPosBuilder('58mm').width, 32)
  assertEqual(new EscPosBuilder('80mm').width, 48)
  assertEqual(CHARS_PER_LINE['80mm'], 48)
})

test('rupee sign becomes Rs. rather than garbage', () => {
  // CP437 has no rupee glyph; sending it raw prints a random character.
  const b = new EscPosBuilder('80mm')
  b.line('Total ₹450.00')
  const text = readable(b.build())
  assertEqual(text.includes('Rs.450.00'), true)
  assertEqual(text.includes('₹'), false, 'no raw rupee byte reaches the printer')
})

test('wrapped text breaks on words, not mid-word', () => {
  const b = new EscPosBuilder('58mm')
  b.wrapped('Extra spicy no onion no garlic please make it quick')
  for (const line of lines(b.build())) {
    assertEqual(line.length <= 32, true, `"${line}" fits`)
  }
})

test('every ticket starts by resetting the printer', () => {
  // Otherwise a previous job leaves it bold or double-height.
  const buffer = new EscPosBuilder('80mm').build()
  assertEqual(buffer[0], 0x1b)
  assertEqual(buffer[1], 0x40)
})

// --- the kitchen ticket ---

const kotBase = {
  orderNo: 12,
  type: 'dine_in' as const,
  tableName: 'A4',
  seatLabel: null,
  printedAt: new Date('2026-09-01T13:30:00Z'),
  kind: 'new' as const,
  lines: [
    { name: 'Mutton Biryani', variantName: 'Full', qty: 2 },
    { name: 'Filter Coffee', variantName: 'Standard', qty: 3 },
  ],
}

test('KOT shows no money at all', () => {
  const text = readable(renderKot(kotBase))
  assertEqual(text.includes('Rs.'), false, 'prices would be noise to a cook')
  assertEqual(/\d+\.\d{2}/.test(text), false, 'no decimal amounts')
})

test('KOT leads with the quantity', () => {
  const text = readable(renderKot(kotBase))
  assertEqual(text.includes('2  Mutton Biryani'), true)
  assertEqual(text.includes('3  Filter Coffee'), true)
})

test('KOT names the table and the order', () => {
  const text = readable(renderKot(kotBase))
  assertEqual(text.includes('A4'), true)
  assertEqual(text.includes('Order #12'), true)
})

test('the kitchen can tell a delivery from a takeaway', () => {
  // Both leave the counter with no table, so the ticket heading is the only
  // thing distinguishing them. One waits at the counter; the other goes out
  // with a rider, and the kitchen packs them differently.
  const takeaway = readable(renderKot({ ...kotBase, type: 'takeaway', tableName: null }))
  assertEqual(takeaway.includes('TAKEAWAY'), true)
  assertEqual(takeaway.includes('DELIVERY'), false)

  const delivery = readable(renderKot({ ...kotBase, type: 'delivery', tableName: null }))
  assertEqual(delivery.includes('DELIVERY'), true)
  assertEqual(delivery.includes('TAKEAWAY'), false)
})

test('a follow-up ticket is marked, so the kitchen does not cook twice', () => {
  const text = readable(renderKot({ ...kotBase, kind: 'additional' }))
  assertEqual(text.includes('ADDED ITEMS'), true)
})

test('a cancellation is unmistakable', () => {
  const text = readable(renderKot({ ...kotBase, kind: 'cancel' }))
  assertEqual(text.includes('CANCELLED'), true)
})

test('takeaway says so instead of naming a table', () => {
  const text = readable(
    renderKot({ ...kotBase, type: 'takeaway', tableName: null }),
  )
  assertEqual(text.includes('TAKEAWAY'), true)
})

test('KOT carries item notes, which are why the ticket exists', () => {
  const text = readable(
    renderKot({
      ...kotBase,
      lines: [{ name: 'Veg Biryani', variantName: 'Half', qty: 1, notes: 'no onion' }],
    }),
  )
  assertEqual(text.includes('no onion'), true)
})

test('a note sits indented under its dish, not flush left', () => {
  // Flush left, a note reads as a separate item on the ticket.
  const printed = lines(
    renderKot({
      ...kotBase,
      lines: [{ name: 'Veg Biryani', variantName: 'Half', qty: 1, notes: 'no onion' }],
    }),
  )
  const note = printed.find((l) => l.includes('no onion'))!
  assertEqual(note.startsWith('    '), true, `"${note}" is indented`)
})

test('a long note wraps with every line indented', () => {
  const printed = lines(
    renderKot({
      ...kotBase,
      lines: [
        {
          name: 'Veg Biryani',
          variantName: 'Half',
          qty: 1,
          notes: 'no onion no garlic extra raita on the side and please make it very spicy',
        },
      ],
    }),
  )
  const noteLines = printed.filter((l) => l.trim().length > 0 && l.startsWith('    '))
  assertEqual(noteLines.length >= 2, true, 'the note wrapped')
  for (const line of noteLines) {
    assertEqual(line.length <= 48, true, `"${line}" fits`)
  }
})

test('Standard is not printed as a portion name', () => {
  // "Filter Coffee (Standard)" is noise; the dish has only one size.
  const text = readable(renderKot(kotBase))
  assertEqual(text.includes('(Standard)'), false)
  assertEqual(text.includes('(Full)'), true, 'a real portion still shows')
})

// --- the bill ---

const billBase = {
  billNumber: '0042',
  branchName: 'Chennai Express',
  branchAddress: '12 Mount Road, Chennai',
  gstin: '33ABCDE1234F1Z5',
  orderNo: 12,
  type: 'dine_in' as const,
  tableName: 'A4',
  printedAt: new Date('2026-09-01T13:30:00Z'),
  lines: [
    {
      name: 'Mutton Biryani',
      variantName: 'Full',
      qty: 2,
      unitPrice: 38_000,
      lineTotal: 76_000,
    },
  ],
  subtotal: 72_381,
  discountAmount: 0,
  cgst: 1_810,
  sgst: 1_809,
  roundOff: 0,
  total: 76_000,
  taxMode: 'inclusive' as const,
  payments: [{ mode: 'cash', amount: 76_000 }],
  footer: 'Thank you, come again',
}

test('a bill says which kind of order it was', () => {
  // Delivery and takeaway are both counter sales with no table, so the label
  // is the only thing on the printed bill telling them apart.
  const delivery = readable(renderBill({ ...billBase, type: 'delivery', tableName: null }))
  assertEqual(delivery.includes('Delivery'), true)

  const takeaway = readable(renderBill({ ...billBase, type: 'takeaway', tableName: null }))
  assertEqual(takeaway.includes('Takeaway'), true)
  assertEqual(takeaway.includes('Delivery'), false)
})

test('bill shows the number, the branch and the total', () => {
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('0042'), true)
  assertEqual(text.includes('Chennai Express'), true)
  assertEqual(text.includes('760.00'), true)
})

test('bill shows CGST and SGST separately, as a GST invoice must', () => {
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('CGST'), true)
  assertEqual(text.includes('SGST'), true)
  assertEqual(text.includes('18.10'), true)
  assertEqual(text.includes('18.09'), true)
})

test('inclusive mode says the price already contains GST', () => {
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('includes GST'), true)
})

test('a bill carries no reprint marking', () => {
  // The printout is what the customer is handed, and a remark on it changes
  // what they receive. Repeat prints are recorded on the bill's reprint_count,
  // not written on the paper.
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('DUPLICATE'), false)
})

test('unit price is shown when the quantity is not one', () => {
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('380.00'), true, 'justifies the line total')
})

test('a discount appears only when there is one', () => {
  assertEqual(readable(renderBill(billBase)).includes('Discount'), false)
  const discounted = readable(renderBill({ ...billBase, discountAmount: 5_000 }))
  assertEqual(discounted.includes('Discount'), true)
  assertEqual(discounted.includes('-50.00'), true, 'shown as a deduction')
})

test('round off appears only when it is not zero, with its sign', () => {
  assertEqual(readable(renderBill(billBase)).includes('Round off'), false)
  const up = readable(renderBill({ ...billBase, roundOff: 40 }))
  assertEqual(up.includes('+0.40'), true)
  const down = readable(renderBill({ ...billBase, roundOff: -30 }))
  assertEqual(down.includes('-0.30'), true)
})

test('the branch footer replaces the default, never stacks with it', () => {
  const custom = readable(renderBill(billBase))
  assertEqual(custom.includes('Thank you, come again'), true)
  assertEqual(custom.includes('Thank you!'), false, 'only one sign-off')

  // With no footer configured, the default still appears.
  const bare = readable(renderBill({ ...billBase, footer: null }))
  assertEqual(bare.includes('Thank you!'), true)

  // A blank setting is the same as none.
  const blank = readable(renderBill({ ...billBase, footer: '   ' }))
  assertEqual(blank.includes('Thank you!'), true)
})

test('UPI prints as an initialism, not as a word', () => {
  const text = readable(
    renderBill({ ...billBase, payments: [{ mode: 'upi', amount: 76_000 }] }),
  )
  assertEqual(text.includes('UPI'), true)
  assertEqual(text.includes('Upi'), false)
})

test('split payments are each listed', () => {
  const text = readable(
    renderBill({
      ...billBase,
      payments: [
        { mode: 'cash', amount: 40_000 },
        { mode: 'card', amount: 36_000 },
      ],
    }),
  )
  assertEqual(text.includes('Cash'), true)
  assertEqual(text.includes('Card'), true)
  assertEqual(text.includes('400.00'), true)
  assertEqual(text.includes('360.00'), true)
})

test('every bill line fits the paper', () => {
  for (const paper of ['58mm', '80mm'] as const) {
    const width = CHARS_PER_LINE[paper]
    for (const line of lines(renderBill(billBase, paper))) {
      assertEqual(line.length <= width, true, `${paper}: "${line}" (${line.length})`)
    }
  }
})

test('a long dish name does not push the amount off the paper', () => {
  const text = renderBill(
    {
      ...billBase,
      lines: [
        {
          name: 'Special Hyderabadi Dum Mutton Biryani Family Pack',
          variantName: 'Extra Large',
          qty: 1,
          unitPrice: 120_000,
          lineTotal: 120_000,
        },
      ],
    },
    '58mm',
  )
  for (const line of lines(text)) {
    assertEqual(line.length <= 32, true, `"${line}" fits 58mm`)
  }
  assertEqual(readable(text).includes('1200.00'), true, 'the price survives')
})

// --- the test page ---

test('the test page reveals a wrong paper width', () => {
  const narrow = readable(renderTest('Kitchen', '58mm'))
  assertEqual(narrow.includes('58mm'), true)
  assertEqual(narrow.includes('32'), true, 'states the column count')

  for (const line of lines(renderTest('Kitchen', '58mm'))) {
    assertEqual(line.length <= 32, true, `"${line}" fits`)
  }
})

// --- the total and the payment status ---

test('the total keeps its amount on the paper', async () => {
  // Double *width* halves the usable columns and pushes the amount off the
  // edge — the one line that must always be readable.
  for (const paper of ['58mm', '80mm'] as const) {
    const printed = lines(renderBill(billBase, paper))
    const total = printed.find((l) => l.includes('TOTAL'))!
    assertEqual(total.includes('760.00'), true, `${paper}: "${total}"`)
    assertEqual(total.length <= CHARS_PER_LINE[paper], true, `${paper} fits`)
  }
})

test('a settled bill says so', async () => {
  const text = readable(renderBill(billBase))
  assertEqual(text.includes('PAID'), true)
  assertEqual(text.includes('BALANCE DUE'), false, 'nothing is owed')
})

test('a part-paid bill shows what is still due', async () => {
  const text = readable(
    renderBill({ ...billBase, payments: [{ mode: 'cash', amount: 40_000 }] }),
  )
  assertEqual(text.includes('BALANCE DUE'), true)
  assertEqual(text.includes('360.00'), true, '760.00 less 400.00')
})

test('a bill with no payment is marked unpaid', async () => {
  const text = readable(renderBill({ ...billBase, payments: [] }))
  assertEqual(text.includes('UNPAID'), true)
  assertEqual(text.includes('PAID'), true, 'UNPAID contains PAID, so check both')
})

test('the balance line fits the paper', async () => {
  for (const paper of ['58mm', '80mm'] as const) {
    const printed = lines(
      renderBill({ ...billBase, payments: [{ mode: 'cash', amount: 1_000 }] }, paper),
    )
    for (const line of printed) {
      assertEqual(line.length <= CHARS_PER_LINE[paper], true, `${paper}: "${line}"`)
    }
  }
})

test('the phone prints under the address', async () => {
  const text = readable(
    renderBill({ ...billBase, branchPhone: '04412345678' }),
  )
  assertEqual(text.includes('Ph: 04412345678'), true)

  // A restaurant that has not set one gets no empty line.
  assertEqual(readable(renderBill(billBase)).includes('Ph:'), false)
})

// --- the bill header ---

/** Reads the GS ! byte in force when `needle` is printed. */
function scaleAt(buffer: Buffer, needle: string): { height: number; width: number } {
  const text = Buffer.from(needle, 'ascii')
  let n = 0
  for (let i = 0; i < buffer.length; i++) {
    if (buffer[i] === 0x1d && buffer[i + 1] === 0x21) {
      n = buffer[i + 2] ?? 0
      continue
    }
    if (buffer.subarray(i, i + text.length).equals(text)) {
      return { height: (n & 0x07) + 1, width: ((n >> 4) & 0x07) + 1 }
    }
  }
  throw new Error(`${needle} never printed`)
}

test('with no logo the name takes the space the logo would have used', () => {
  // The name is the only thing identifying the bill at a glance, so it has to
  // carry the top of the receipt on its own.
  const { height } = scaleAt(renderBill({ ...billBase, logo: null }), 'Chennai Express')
  assertEqual(height, 3)
})

test('with a logo the name stays at double height', () => {
  // Competing with the image would look crowded rather than emphatic.
  const logo = { data: Buffer.alloc(48).toString('base64'), width: 48, height: 8 }
  const { height } = scaleAt(renderBill({ ...billBase, logo }), 'Chennai Express')
  assertEqual(height, 2)
})

test('the name never doubles past double width', () => {
  // Width is what costs columns. Height is free.
  for (const logo of [null, { data: Buffer.alloc(48).toString('base64'), width: 48, height: 8 }]) {
    const { width } = scaleAt(renderBill({ ...billBase, logo }), 'Chennai Express')
    assertEqual(width, 2, 'two is the most a 48-column line can carry')
  }
})

test('the size is put back before the address', () => {
  // Left at triple height, every line below it would print enormous.
  const { height, width } = scaleAt(renderBill({ ...billBase, logo: null }), '12 Mount Road')
  assertEqual(height, 1)
  assertEqual(width, 1)
})

test('a long name wraps at the width the wider characters leave', () => {
  // At double width a 48-column line holds 24 characters. Wrapping at 48 would
  // run the name off the paper.
  const long = 'Chennai Express Family Restaurant And Banquet Hall'
  const text = readable(renderBill({ ...billBase, branchName: long, logo: null }))
  for (const line of text.split('\n')) {
    if (line.includes('Chennai') || line.includes('Banquet')) {
      assertEqual(line.trimEnd().length <= 24, true, `too wide: "${line}"`)
    }
  }
  // Every word still survives the wrap.
  for (const word of long.split(' ')) {
    assertEqual(text.includes(word), true, `lost "${word}"`)
  }
})

test('a tagline prints under the name, in normal type', () => {
  const buffer = renderBill({ ...billBase, branchTagline: 'Since 1998', logo: null })
  const text = readable(buffer)
  assertEqual(text.includes('Since 1998'), true)

  // Normal size: a second large line would fight the name rather than support it.
  const { height, width } = scaleAt(buffer, 'Since 1998')
  assertEqual(height, 1)
  assertEqual(width, 1)

  const lines = text.split('\n').map((l) => l.trim())
  const name = lines.findIndex((l) => l.includes('Chennai Express'))
  const tagline = lines.findIndex((l) => l.includes('Since 1998'))
  const address = lines.findIndex((l) => l.includes('12 Mount Road'))
  assertEqual(name < tagline && tagline < address, true, 'sits between name and address')
})

test('no tagline prints no blank line', () => {
  // An empty setting must not push the whole bill down by a line.
  const without = readable(renderBill({ ...billBase, logo: null }))
  const withEmpty = readable(renderBill({ ...billBase, branchTagline: null, logo: null }))
  assertEqual(without, withEmpty)
})

// --- printing a bill before it is paid ---

test('a bill with no payments prints UNPAID', () => {
  // Handed to a table so they can see what they owe. Without this the bill is
  // indistinguishable from a settled one, and a paid bill gets asked for twice.
  const text = readable(renderBill({ ...billBase, payments: [] }))
  assertEqual(text.includes('*** UNPAID ***'), true)
  assertEqual(text.includes('*** PAID ***'), false)
})

test('an unpaid bill still shows its total', () => {
  // The whole reason for printing it: the table needs the amount.
  const text = readable(renderBill({ ...billBase, payments: [] }))
  assertEqual(text.includes('760.00'), true)
})

test('a part-paid bill prints the balance, not UNPAID', () => {
  const text = readable(
    renderBill({ ...billBase, payments: [{ mode: 'cash', amount: 30_000 }] }),
  )
  assertEqual(text.includes('BALANCE DUE'), true)
  assertEqual(text.includes('460.00'), true, '760.00 less 300.00')
  assertEqual(text.includes('*** UNPAID ***'), false, 'something was paid')
  assertEqual(text.includes('*** PAID ***'), false, 'but not all of it')
})

test('an unpaid bill carries no marking either', () => {
  const text = readable(renderBill({ ...billBase, payments: [] }))
  assertEqual(text.includes('DUPLICATE'), false)
})

test('a bill with no tax prints no GST lines', () => {
  // A restaurant below the registration threshold should see nothing about
  // GST on its paper — not CGST 0.00 twice on every bill.
  const text = readable(renderBill({ ...billBase, cgst: 0, sgst: 0 }))
  assertEqual(text.includes('CGST'), false)
  assertEqual(text.includes('SGST'), false)
})

test('the inclusive note is dropped when no tax was charged', () => {
  // tax_mode stays 'inclusive' with GST switched off, so the note would claim
  // a tax the bill never charged.
  const inclusive = { ...billBase, taxMode: 'inclusive' as const }
  assertEqual(
    readable(renderBill(inclusive)).includes('includes GST'),
    true,
    'still shown when there is tax to include',
  )
  assertEqual(
    readable(renderBill({ ...inclusive, cgst: 0, sgst: 0 })).includes('includes GST'),
    false,
  )
})

test('a bill with no tax still totals correctly', () => {
  // The subtotal is the total when nothing is added on top, and both must
  // still print.
  const text = readable(
    renderBill({ ...billBase, cgst: 0, sgst: 0, subtotal: 76_000, total: 76_000 }),
  )
  assertEqual(text.includes('Subtotal'), true)
  assertEqual(text.includes('TOTAL'), true)
  assertEqual(text.includes('760.00'), true)
})
