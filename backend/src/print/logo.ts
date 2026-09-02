import sharp from 'sharp'
import type { PaperWidth } from './escpos.js'

/**
 * Turning an uploaded image into something a thermal printer can print.
 *
 * A receipt printer has no greys: each dot is burned or it is not. Converting
 * once at upload rather than per bill is deliberate — rasterising on every
 * print would cost more than the three-second target allows, and the result
 * only changes when the image or the paper width changes.
 */

/** Printable dots across, by paper. The margin is already excluded. */
export const LOGO_WIDTH = {
  '58mm': 384,
  '80mm': 576,
} as const

/** Taller than this and the logo pushes the whole bill down the roll. */
const MAX_HEIGHT = 240

export interface LogoRaster {
  /** Packed 1-bit rows, base64. 1 means burn the dot. */
  data: string
  /** Dots across. Always a multiple of 8, so each row packs whole bytes. */
  width: number
  height: number
}

/**
 * Converts an image to a printable monochrome raster.
 *
 * Greyscale, then Floyd–Steinberg dithering rather than a hard threshold: a
 * photograph or a logo with any gradient turns into flat black blobs under a
 * threshold, while dithering keeps it legible at one bit.
 */
export async function rasterise(
  input: Buffer,
  paper: PaperWidth,
): Promise<LogoRaster> {
  const targetWidth = LOGO_WIDTH[paper]

  const image = sharp(input, { failOn: 'none' })
  const meta = await image.metadata()
  if (!meta.width || !meta.height) {
    throw new Error('That file does not look like an image')
  }

  // Flattened onto white first: a transparent PNG would otherwise dither its
  // transparent areas into noise.
  const scaled = await image
    .flatten({ background: '#ffffff' })
    .resize({
      width: targetWidth,
      height: MAX_HEIGHT,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .greyscale()
    .normalise()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const { data, info } = scaled

  // Padded to a byte boundary so each row is a whole number of bytes, which is
  // what the ESC/POS raster command expects.
  const width = Math.ceil(info.width / 8) * 8
  const height = info.height
  const bytesPerRow = width / 8
  const packed = Buffer.alloc(bytesPerRow * height, 0)

  // Floyd–Steinberg needs a mutable copy at higher precision than the source.
  const grey = new Float32Array(info.width * height)
  for (let i = 0; i < grey.length; i++) grey[i] = data[i * info.channels] ?? 255

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < info.width; x++) {
      const index = y * info.width + x
      const old = grey[index] ?? 255
      const black = old < 128
      const newValue = black ? 0 : 255
      const error = old - newValue

      if (black) {
        // Bit 7 is the leftmost dot in each byte.
        const byte = y * bytesPerRow + (x >> 3)
        packed[byte] = (packed[byte] ?? 0) | (0x80 >> (x & 7))
      }

      // Push the rounding error onto neighbours not yet visited, which is what
      // makes a gradient read as a gradient rather than a band.
      spread(grey, info.width, height, x + 1, y, error * 7 / 16)
      spread(grey, info.width, height, x - 1, y + 1, error * 3 / 16)
      spread(grey, info.width, height, x, y + 1, error * 5 / 16)
      spread(grey, info.width, height, x + 1, y + 1, error * 1 / 16)
    }
  }

  return { data: packed.toString('base64'), width, height }
}

function spread(
  buffer: Float32Array,
  width: number,
  height: number,
  x: number,
  y: number,
  error: number,
): void {
  if (x < 0 || x >= width || y < 0 || y >= height) return
  const index = y * width + x
  buffer[index] = (buffer[index] ?? 0) + error
}

/**
 * Renders a stored raster back to a PNG, for showing on screen.
 *
 * Drawn from the dithered one-bit data rather than the original upload, so what
 * is shown is exactly what burns onto the paper — including how the dithering
 * turned out. Previewing the original would hide the one thing worth checking.
 */
export async function rasterToPng(logo: LogoRaster): Promise<Buffer> {
  const bytesPerRow = logo.width / 8
  const packed = Buffer.from(logo.data, 'base64')

  // Greyscale, one byte per dot: 0 where the printer burns, 255 where it does
  // not. The stored bit is set for a burned dot, so it inverts here.
  const pixels = Buffer.alloc(logo.width * logo.height, 255)
  for (let y = 0; y < logo.height; y++) {
    for (let x = 0; x < logo.width; x++) {
      const byte = packed[y * bytesPerRow + (x >> 3)] ?? 0
      if ((byte >> (7 - (x & 7))) & 1) pixels[y * logo.width + x] = 0
    }
  }

  return sharp(pixels, {
    raw: { width: logo.width, height: logo.height, channels: 1 },
  })
    .png()
    .toBuffer()
}

/**
 * The ESC/POS command that prints a stored raster.
 *
 * `GS v 0` takes the width in bytes and the height in dots, both little-endian,
 * followed by the packed rows.
 */
export function rasterCommand(logo: LogoRaster): Buffer {
  const bytesPerRow = logo.width / 8
  const header = Buffer.from([
    0x1d,
    0x76,
    0x30,
    0x00,
    bytesPerRow & 0xff,
    (bytesPerRow >> 8) & 0xff,
    logo.height & 0xff,
    (logo.height >> 8) & 0xff,
  ])
  return Buffer.concat([header, Buffer.from(logo.data, 'base64')])
}
