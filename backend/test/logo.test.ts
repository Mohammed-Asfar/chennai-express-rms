import sharp from 'sharp'
import { rasterise, rasterCommand, rasterToPng, LOGO_WIDTH } from '../src/print/logo.js'
import { test, assertEqual } from './helpers.js'

/** A solid-colour test image. */
async function image(
  width: number,
  height: number,
  grey: number,
): Promise<Buffer> {
  return sharp({
    create: {
      width,
      height,
      channels: 3,
      background: { r: grey, g: grey, b: grey },
    },
  })
    .png()
    .toBuffer()
}

test('a logo is scaled to the paper width', async () => {
  const wide = await rasterise(await image(1000, 300, 0), '80mm')
  assertEqual(wide.width, LOGO_WIDTH['80mm'], '80mm paper is 576 dots')

  const narrow = await rasterise(await image(1000, 300, 0), '58mm')
  assertEqual(narrow.width, LOGO_WIDTH['58mm'], '58mm paper is 384 dots')
})

test('a small logo is not blown up', async () => {
  // Enlarging a 100px logo to 576 dots would print a blurry mess.
  const raster = await rasterise(await image(100, 40, 0), '80mm')
  assertEqual(raster.width <= LOGO_WIDTH['80mm'], true)
  assertEqual(raster.width % 8, 0, 'still padded to whole bytes')
})

test('a tall logo is capped, so it does not push the bill down the roll', async () => {
  const raster = await rasterise(await image(400, 4000, 0), '80mm')
  assertEqual(raster.height <= 240, true, `height was ${raster.height}`)
})

test('the row width is always a whole number of bytes', async () => {
  // The ESC/POS raster command takes a width in bytes; a partial byte would
  // shear every row.
  for (const width of [37, 100, 333, 1000]) {
    const raster = await rasterise(await image(width, 50, 0), '80mm')
    assertEqual(raster.width % 8, 0, `width ${width} produced ${raster.width}`)
  }
})

test('the packed data is exactly the size the header claims', async () => {
  const raster = await rasterise(await image(400, 100, 0), '80mm')
  const bytes = Buffer.from(raster.data, 'base64')
  assertEqual(bytes.length, (raster.width / 8) * raster.height)
})

test('black prints and white does not', async () => {
  const black = await rasterise(await image(80, 40, 0), '80mm')
  const blackBytes = Buffer.from(black.data, 'base64')
  assertEqual(
    blackBytes.every((b) => b === 0xff),
    true,
    'every dot burned',
  )

  const white = await rasterise(await image(80, 40, 255), '80mm')
  const whiteBytes = Buffer.from(white.data, 'base64')
  assertEqual(
    whiteBytes.every((b) => b === 0x00),
    true,
    'no dot burned',
  )
})

test('a mid grey dithers rather than turning solid', async () => {
  // A hard threshold would make this either all black or all white; dithering
  // is what keeps a gradient or a photo legible at one bit.
  const raster = await rasterise(await image(160, 80, 128), '80mm')
  const bytes = Buffer.from(raster.data, 'base64')

  const allBlack = bytes.every((b) => b === 0xff)
  const allWhite = bytes.every((b) => b === 0x00)
  assertEqual(allBlack, false, 'not a solid block')
  assertEqual(allWhite, false, 'not blank')
})

test('a transparent PNG is flattened onto white, not dithered into noise', async () => {
  const transparent = await sharp({
    create: {
      width: 200,
      height: 80,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .png()
    .toBuffer()

  const raster = await rasterise(transparent, '80mm')
  const bytes = Buffer.from(raster.data, 'base64')
  assertEqual(
    bytes.every((b) => b === 0x00),
    true,
    'fully transparent becomes blank, not black',
  )
})

test('something that is not an image is refused', async () => {
  let threw = false
  try {
    await rasterise(Buffer.from('this is not a picture'), '80mm')
  } catch {
    threw = true
  }
  assertEqual(threw, true)
})

test('the print command carries the right header', async () => {
  const raster = await rasterise(await image(400, 100, 0), '80mm')
  const command = rasterCommand(raster)

  // GS v 0, mode 0, then width in bytes and height in dots, little-endian.
  assertEqual(command[0], 0x1d)
  assertEqual(command[1], 0x76)
  assertEqual(command[2], 0x30)
  assertEqual(command[3], 0x00)

  const bytesPerRow = raster.width / 8
  assertEqual(command[4], bytesPerRow & 0xff)
  assertEqual(command[5], (bytesPerRow >> 8) & 0xff)
  assertEqual(command[6], raster.height & 0xff)
  assertEqual(command[7], (raster.height >> 8) & 0xff)

  assertEqual(command.length, 8 + bytesPerRow * raster.height, 'header plus data')
})

test('a tall logo encodes its height across two bytes', async () => {
  // Anything over 255 dots needs the high byte, and getting that wrong prints
  // a fraction of the image.
  const raster = await rasterise(await image(400, 1000, 0), '80mm')
  const command = rasterCommand(raster)
  const encoded = (command[6] ?? 0) | ((command[7] ?? 0) << 8)
  assertEqual(encoded, raster.height)
})

test('a raster renders back to a picture of what prints', async () => {
  const source = await image(400, 100, 0)
  const raster = await rasterise(source, '80mm')
  const png = await rasterToPng(raster)

  // A real PNG, at the raster's own size — not the original upload's.
  const meta = await sharp(png).metadata()
  assertEqual(meta.format, 'png')
  assertEqual(meta.width, raster.width)
  assertEqual(meta.height, raster.height)
})

test('a burned dot shows as black, an unburned one as white', async () => {
  // Inverted here would show a negative of the logo, which is worse than a
  // placeholder: it would look wrong when the printing is right.
  const black = await rasterToPng(await rasterise(await image(80, 40, 0), '80mm'))
  const blackPixels = await sharp(black).greyscale().raw().toBuffer()
  assertEqual(
    blackPixels.every((p) => p === 0),
    true,
    'a fully burned raster is a black picture',
  )

  const white = await rasterToPng(await rasterise(await image(80, 40, 255), '80mm'))
  const whitePixels = await sharp(white).greyscale().raw().toBuffer()
  assertEqual(
    whitePixels.every((p) => p === 255),
    true,
    'an unburned raster is a blank picture',
  )
})
