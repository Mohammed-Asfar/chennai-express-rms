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

test('a reprint is stamped DUPLICATE', () => {
  // Two identical bills in the drawer is a sale counted twice at closing.
  const text = readable(renderBill({ ...billBase, isReprint: true }))
  assertEqual(text.includes('DUPLICATE'), true)
  assertEqual(readable(renderBill(billBase)).includes('DUPLICATE'), false)
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
