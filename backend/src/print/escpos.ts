/**
 * ESC/POS command generation for thermal receipt printers.
 *
 * Written directly rather than pulled from a package: the command set used here
 * is small and stable, and a printing bug on a billing PC is easier to fix in
 * code we own than in a dependency. Everything is a byte buffer — no string
 * concatenation, because receipt text is not UTF-8 on most of these printers.
 */

const ESC = 0x1b
const GS = 0x1d
const LF = 0x0a

/** Characters per line, which depends on the paper. */
export const CHARS_PER_LINE = {
  '58mm': 32,
  '80mm': 48,
} as const

export type PaperWidth = keyof typeof CHARS_PER_LINE

export type Align = 'left' | 'center' | 'right'

/**
 * Builds a receipt as a byte buffer.
 *
 * Chainable so a ticket reads top to bottom in the order it prints, which makes
 * it possible to compare the code against a physical receipt.
 */
export class EscPosBuilder {
  private readonly chunks: Buffer[] = []
  readonly width: number

  constructor(private readonly paper: PaperWidth = '80mm') {
    this.width = CHARS_PER_LINE[paper]
    // Every ticket starts from a known state: the previous job may have left
    // the printer bold, double-height or centred.
    this.raw(ESC, 0x40)
  }

  raw(...bytes: number[]): this {
    this.chunks.push(Buffer.from(bytes))
    return this
  }

  /**
   * Encodes text for the printer's character set.
   *
   * CP437 is the default on virtually every ESC/POS printer. Characters outside
   * it — including the rupee sign — are replaced rather than sent raw, which
   * would print as garbage. Money is written as "Rs." for that reason.
   */
  text(value: string): this {
    const cleaned = value.replace(/₹/g, 'Rs.')
    const bytes = Buffer.from(
      cleaned.replace(/[^\x20-\x7e\n]/g, '?'),
      'ascii',
    )
    this.chunks.push(bytes)
    return this
  }

  line(value = ''): this {
    return this.text(value).raw(LF)
  }

  align(mode: Align): this {
    const code = mode === 'center' ? 1 : mode === 'right' ? 2 : 0
    return this.raw(ESC, 0x61, code)
  }

  bold(on: boolean): this {
    return this.raw(ESC, 0x45, on ? 1 : 0)
  }

  /** Doubles character height, and optionally width. Used for totals. */
  size(double: boolean, wide = double): this {
    const n = (double ? 0x01 : 0) | (wide ? 0x10 : 0)
    return this.raw(GS, 0x21, n)
  }

  /**
   * Character size as explicit multipliers, 1-8.
   *
   * `size()` only reaches 2×. A restaurant name standing in for a logo needs
   * to be taller than that, and height and width must be set independently:
   * widening halves the usable columns, which is how an amount silently falls
   * off the edge of the paper.
   */
  scale(height: number, width: number): this {
    const clamp = (value: number) => Math.min(8, Math.max(1, Math.round(value))) - 1
    return this.raw(GS, 0x21, (clamp(width) << 4) | clamp(height))
  }

  underline(on: boolean): this {
    return this.raw(ESC, 0x2d, on ? 1 : 0)
  }

  /** A full-width rule. */
  rule(char = '-'): this {
    return this.line(char.repeat(this.width))
  }

  /**
   * A label on the left and a value hard against the right edge.
   *
   * The core of a receipt: prices must form a clean right column or the total is
   * hard to find. When the two would collide the label is truncated, never the
   * amount — a wrong-looking price is worse than a shortened dish name.
   */
  columns(left: string, right: string): this {
    const space = this.width - right.length
    const label = left.length > space - 1 ? left.slice(0, Math.max(0, space - 2)) + '.' : left
    const gap = Math.max(1, this.width - label.length - right.length)
    return this.line(label + ' '.repeat(gap) + right)
  }

  /** Wraps text that will not fit, indenting the continuation. */
  wrapped(value: string, indent = 0): this {
    const usable = this.width - indent
    const words = value.split(/\s+/)
    let current = ''

    for (const word of words) {
      if (current.length === 0) {
        current = word
      } else if (current.length + 1 + word.length <= usable) {
        current += ' ' + word
      } else {
        this.line(' '.repeat(indent) + current)
        current = word
      }
    }
    if (current.length > 0) this.line(' '.repeat(indent) + current)
    return this
  }

  /**
   * Wraps to the columns left after widening the characters.
   *
   * At double width the paper holds half as many characters, so wrapping at
   * the nominal width would run a long restaurant name off the edge.
   */
  wrappedAtScale(value: string, widthScale: number): this {
    const usable = Math.max(1, Math.floor(this.width / Math.max(1, widthScale)))
    const words = value.split(/\s+/).filter((w) => w.length > 0)
    let current = ''

    for (const word of words) {
      if (current.length === 0) {
        current = word
      } else if (current.length + 1 + word.length <= usable) {
        current += ' ' + word
      } else {
        this.line(current)
        current = word
      }
    }
    if (current.length > 0) this.line(current)
    return this
  }

  feed(lines = 1): this {
    return this.raw(ESC, 0x64, lines)
  }

  /**
   * Cuts the paper.
   *
   * Feeds first: the cutter sits above the print head, so cutting immediately
   * would slice through the last few lines.
   */
  cut(): this {
    return this.feed(4).raw(GS, 0x56, 0x00)
  }

  /** Opens a cash drawer wired to the printer's kick port. */
  openDrawer(): this {
    return this.raw(ESC, 0x70, 0x00, 0x19, 0xfa)
  }

  build(): Buffer {
    return Buffer.concat(this.chunks)
  }
}
