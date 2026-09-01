import { createConnection } from 'node:net'
import { writeFile } from 'node:fs/promises'

/**
 * Getting bytes to a printer.
 *
 * Two transports, because a restaurant has both: the billing printer sits on
 * USB at the counter, and the kitchen printer is on the network at the other
 * end of the building.
 */

export type Connection = 'usb' | 'network'

/** How long to wait before deciding a printer is not going to answer. */
const CONNECT_TIMEOUT_MS = 5_000

export class PrintError extends Error {
  constructor(message: string, readonly retryable = true) {
    super(message)
    this.name = 'PrintError'
  }
}

/**
 * Sends a job to a network printer on raw port 9100.
 *
 * Waits for the socket to drain before resolving. Resolving early would report
 * success for a ticket still sitting in the local buffer, and the retry logic
 * would never fire for a printer that died mid-job.
 */
export function sendNetwork(address: string, data: Buffer): Promise<void> {
  const [host, portText] = address.split(':')
  const port = Number(portText ?? 9100)

  if (!host) {
    return Promise.reject(new PrintError(`Invalid printer address: ${address}`, false))
  }
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    return Promise.reject(new PrintError(`Invalid printer port: ${portText}`, false))
  }

  return new Promise((resolve, reject) => {
    const socket = createConnection({ host, port })
    let settled = false

    const finish = (error?: Error) => {
      if (settled) return
      settled = true
      socket.destroy()
      error ? reject(error) : resolve()
    }

    socket.setTimeout(CONNECT_TIMEOUT_MS)
    socket.on('timeout', () =>
      finish(new PrintError(`Printer at ${address} did not respond`)),
    )
    socket.on('error', (error) =>
      finish(new PrintError(`Cannot reach printer at ${address}: ${error.message}`)),
    )
    socket.on('connect', () => {
      socket.write(data, (error) => {
        if (error) return finish(new PrintError(`Write failed: ${error.message}`))
        // end() flushes, and 'close' fires once the bytes are actually gone.
        socket.end()
      })
    })
    socket.on('close', () => finish())
  })
}

/**
 * Sends a job to a USB or parallel printer via its Windows share name or device
 * path.
 *
 * Windows exposes a shared printer as a writable path, which is why this is a
 * file write rather than a USB protocol implementation. `address` is something
 * like `\\.\COM3`, `LPT1`, or a UNC share.
 */
export async function sendUsb(address: string, data: Buffer): Promise<void> {
  try {
    await writeFile(address, data)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    // A missing device is worth retrying — someone may plug it back in.
    throw new PrintError(`Cannot write to printer at ${address}: ${message}`)
  }
}

export function send(connection: Connection, address: string, data: Buffer): Promise<void> {
  return connection === 'network' ? sendNetwork(address, data) : sendUsb(address, data)
}
