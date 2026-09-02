import { renderBill } from '../src/print/tickets.js'
import { decodeTicket } from '../src/print/preview.js'
import { CHARS_PER_LINE, EscPosBuilder } from '../src/print/escpos.js'
import { test, assertEqual } from './helpers.js'

const sample = {
  billNumber: 'CE-0042',
  branchName: 'Chennai Express',
  branchAddress: '12 Mount Road, Chennai',
  gstin: '33ABCDE1234F1Z5',
  orderNo: 7,
  type: 'dine_in' as const,
  tableName: 'A4',
  printedAt: new Date('2026-09-02T13:30:00Z'),
  lines: [
    { name: 'Mutton Biryani', variantName: 'Full', qty: 2, unitPrice: 38_000, lineTotal: 76_000 },
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

const textOf = (preview: { lines: { text: string }[] }) =>
  preview.lines.map((l) => l.text).join('\n')

test('the preview shows what the paper would say', async () => {
  const preview = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  const text = textOf(preview)

  assertEqual(text.includes('Chennai Express'), true)
  assertEqual(text.includes('CE-0042'), true)
  assertEqual(text.includes('GSTIN: 33ABCDE1234F1Z5'), true)
  assertEqual(text.includes('Mutton Biryani'), true)
  assertEqual(text.includes('760.00'), true)
  assertEqual(text.includes('Thank you, come again'), true)
})

test('no control bytes leak into the preview text', async () => {
  // A stray ESC in the output would render as a box in the UI.
  const preview = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  for (const line of preview.lines) {
    assertEqual(
      /[\x00-\x09\x0b-\x1f]/.test(line.text),
      false,
      `"${line.text}" contains a control byte`,
    )
  }
})

test('the total is marked large, so it reads as the total', async () => {
  const preview = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  const total = preview.lines.find((l) => l.text.includes('TOTAL'))
  assertEqual(total !== undefined, true)
  assertEqual(total!.large, true)
})

test('the branch name is centred', async () => {
  const preview = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  const name = preview.lines.find((l) => l.text.includes('Chennai Express'))
  assertEqual(name!.align, 'center')
})

test('no line is wider than the paper', async () => {
  for (const paper of ['58mm', '80mm'] as const) {
    const preview = decodeTicket(renderBill(sample, paper), CHARS_PER_LINE[paper])
    assertEqual(preview.width, CHARS_PER_LINE[paper])
    for (const line of preview.lines) {
      assertEqual(
        line.text.length <= CHARS_PER_LINE[paper],
        true,
        `${paper}: "${line.text}" is ${line.text.length}`,
      )
    }
  }
})

test('a logo is reported but not turned into text', async () => {
  // The raster is image data; decoding it as characters would fill the preview
  // with noise.
  const withLogo = decodeTicket(
    renderBill({
      ...sample,
      logo: { data: Buffer.alloc(48 * 20, 0xff).toString('base64'), width: 384, height: 20 },
    }),
    CHARS_PER_LINE['80mm'],
  )
  assertEqual(withLogo.hasLogo, true)
  for (const line of withLogo.lines) {
    assertEqual(
      /[\x00-\x09\x0b-\x1f]/.test(line.text),
      false,
      'image bytes leaked into the text',
    )
  }

  const without = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  assertEqual(without.hasLogo, false)
})

test('the trailing feed before the cut is trimmed', async () => {
  const preview = decodeTicket(renderBill(sample), CHARS_PER_LINE['80mm'])
  const last = preview.lines[preview.lines.length - 1]
  assertEqual(last!.text.trim().length > 0, true, 'ends on real content')
})

test('the decoder reports how much taller a line prints', () => {
  // A boolean was not enough: the preview drew a triple-height name the same as
  // a double-height one, so the screen said the size setting did nothing.
  const b = new EscPosBuilder('80mm')
  b.scale(3, 2).line('CHENNAI EXPRESS').scale(1, 1).line('normal')

  const { lines } = decodeTicket(b.build(), 48)
  const name = lines.find((l) => l.text.includes('CHENNAI'))!
  const normal = lines.find((l) => l.text.includes('normal'))!

  assertEqual(name.heightScale, 3)
  assertEqual(name.widthScale, 2)
  assertEqual(normal.heightScale, 1)
  assertEqual(normal.widthScale, 1)
})

test('height and width are read independently', () => {
  // GS ! packs them in separate nibbles; reading one for the other would show
  // a line as enlarged in the wrong direction.
  const b = new EscPosBuilder('80mm')
  b.scale(4, 1).line('tall').scale(1, 4).line('wide')

  const { lines } = decodeTicket(b.build(), 48)
  const tall = lines.find((l) => l.text === 'tall')!
  const wide = lines.find((l) => l.text === 'wide')!

  assertEqual(tall.heightScale, 4)
  assertEqual(tall.widthScale, 1)
  assertEqual(wide.heightScale, 1)
  assertEqual(wide.widthScale, 4)
})

test('the old double-size command still reads as 2x', () => {
  // size() is still what the total uses; it must decode the same as before.
  const b = new EscPosBuilder('80mm')
  b.size(true, false).line('TOTAL').size(false)

  const { lines } = decodeTicket(b.build(), 48)
  const total = lines.find((l) => l.text === 'TOTAL')!
  assertEqual(total.heightScale, 2)
  assertEqual(total.widthScale, 1)
  assertEqual(total.large, true, 'large stays true for anything enlarged')
})

test('scale is clamped to what the command can carry', () => {
  // GS ! has three bits per axis. Asking for 20x must not wrap around to a
  // small number and silently print the name tiny.
  const b = new EscPosBuilder('80mm')
  b.scale(20, 0).line('clamped')

  const { lines } = decodeTicket(b.build(), 48)
  const line = lines.find((l) => l.text === 'clamped')!
  assertEqual(line.heightScale, 8, 'capped at the maximum')
  assertEqual(line.widthScale, 1, 'floored at the minimum')
})
