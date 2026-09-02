/**
 * Turns a rendered ticket back into readable lines.
 *
 * Deliberately decodes the same bytes the printer receives rather than
 * re-rendering from the data: a preview built from a second code path would
 * drift from the paper, and the whole point is to see the real thing without
 * spending a roll on it.
 */

/** ESC command byte to how many argument bytes follow it. */
const ESC_ARGS: Record<number, number> = {
  0x40: 0, // @  reset
  0x61: 1, // a  align
  0x45: 1, // E  bold
  0x2d: 1, // -  underline
  0x64: 1, // d  feed n lines
  0x70: 3, // p  drawer kick
}

const GS_ARGS: Record<number, number> = {
  0x21: 1, // !  character size
  0x56: 1, // V  cut
}

export interface PreviewLine {
  text: string
  /** Doubled height, used for the total. */
  large: boolean
  bold: boolean
  align: 'left' | 'center' | 'right'
  /**
   * The real multipliers from `GS !`, 1-8.
   *
   * Carried separately from `large` because height and width are independent
   * and only height can be shown safely on screen: a wider glyph would push a
   * 48-column line off the preview even though it prints correctly.
   */
  heightScale: number
  widthScale: number
}

export interface TicketPreview {
  lines: PreviewLine[]
  /** Columns for the paper, so the client can size a monospaced box. */
  width: number
  /** Whether a logo raster was included, which cannot be shown as text. */
  hasLogo: boolean
}

/**
 * Decodes a ticket, keeping the styling that changes how a line reads.
 *
 * Bold, centring and double height are carried through because they are what
 * make a total look like a total. Everything else is dropped.
 */
export function decodeTicket(buffer: Buffer, width: number): TicketPreview {
  const lines: PreviewLine[] = []
  let current = ''
  let align: PreviewLine['align'] = 'left'
  let bold = false
  let heightScale = 1
  let widthScale = 1
  let hasLogo = false

  const flush = () => {
    lines.push({
      text: current,
      large: heightScale > 1 || widthScale > 1,
      bold,
      align,
      heightScale,
      widthScale,
    })
    current = ''
  }

  let i = 0
  while (i < buffer.length) {
    const byte = buffer[i] ?? 0
    const next = i + 1 < buffer.length ? (buffer[i + 1] ?? 0) : -1

    if (byte === 0x1b && next >= 0 && ESC_ARGS[next] !== undefined) {
      const args = ESC_ARGS[next] ?? 0
      const value = buffer[i + 2] ?? 0

      if (next === 0x61) align = value === 1 ? 'center' : value === 2 ? 'right' : 'left'
      if (next === 0x45) bold = value === 1
      if (next === 0x64) {
        // A feed is blank lines, which matter to the shape of the receipt.
        for (let n = 0; n < value; n++) {
          lines.push({
            text: '',
            large: false,
            bold: false,
            align,
            heightScale: 1,
            widthScale: 1,
          })
        }
      }

      i += 2 + args
      continue
    }

    if (byte === 0x1d && next >= 0) {
      // The raster command carries its length in the header, so the image data
      // can be skipped without mistaking it for text.
      if (next === 0x76 && (buffer[i + 2] ?? 0) === 0x30) {
        const bytesPerRow = (buffer[i + 4] ?? 0) | ((buffer[i + 5] ?? 0) << 8)
        const height = (buffer[i + 6] ?? 0) | ((buffer[i + 7] ?? 0) << 8)
        hasLogo = true
        i += 8 + bytesPerRow * height
        continue
      }

      const args = GS_ARGS[next]
      if (args !== undefined) {
        if (next === 0x21) {
          // GS ! packs width in the high nibble and height in the low one, each
          // as "times minus one" — 0x11 is double both ways, not 17×.
          const n = buffer[i + 2] ?? 0
          widthScale = ((n >> 4) & 0x07) + 1
          heightScale = (n & 0x07) + 1
        }
        i += 2 + args
        continue
      }
    }

    if (byte === 0x0a) {
      flush()
      i++
      continue
    }

    current += String.fromCharCode(byte)
    i++
  }

  if (current.length > 0) flush()

  // Trailing blanks come from the feed before the cut, and are just paper.
  while (lines.length > 0 && (lines[lines.length - 1]?.text ?? '').trim() === '') {
    lines.pop()
  }

  return { lines, width, hasLogo }
}
