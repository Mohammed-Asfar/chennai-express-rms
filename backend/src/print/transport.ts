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
  // A bare name like "TVSE RP3200 Lite" is a Windows print queue, not a path.
  // Writing to it directly creates a file in the working directory — the job
  // reports success and no paper ever comes out.
  if (isWindowsQueueName(address)) {
    return sendToWindowsQueue(address, data)
  }

  try {
    await writeFile(address, data)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    // A missing device is worth retrying — someone may plug it back in.
    throw new PrintError(`Cannot write to printer at ${address}: ${message}`)
  }
}

/**
 * Whether this is a printer's share name rather than a device path.
 *
 * Device paths look like `\\.\COM3`, `LPT1`, `COM1`, or a UNC share. Anything
 * else with spaces or ordinary words is a queue name as Windows reports it.
 */
function isWindowsQueueName(address: string): boolean {
  if (process.platform !== 'win32') return false
  if (address.startsWith('\\\\') || address.startsWith('//')) return false
  if (/^(\\\\\.\\)?(COM|LPT)\d+:?$/i.test(address)) return false
  return true
}

/**
 * Sends raw bytes to a Windows print queue.
 *
 * The bytes are already ESC/POS, so they must reach the printer untouched —
 * hence a RAW job rather than anything that would render them as text. Written
 * to a temp file and handed to the spooler, because there is no way to stream
 * raw data to a queue from Node without a native binding.
 */
async function sendToWindowsQueue(queue: string, data: Buffer): Promise<void> {
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const { randomUUID } = await import('node:crypto')
  const { unlink } = await import('node:fs/promises')
  const { execFile } = await import('node:child_process')
  const { promisify } = await import('node:util')
  const run = promisify(execFile)

  const file = join(tmpdir(), `ce-print-${randomUUID()}.bin`)

  try {
    await writeFile(file, data)

    // `Out-Printer` would reformat the bytes as text; the spooler's RAW
    // datatype passes them through as the printer expects.
    const script = `
      $ErrorActionPreference = 'Stop'
      Add-Type -AssemblyName System.Drawing
      $bytes = [System.IO.File]::ReadAllBytes('${file.replace(/\\/g, '\\\\')}')
      $printer = '${queue.replace(/'/g, "''")}'
      Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public class RawPrinter {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public class DOCINFO { public string pDocName; public string pOutputFile; public string pDataType; }
  [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool OpenPrinter(string src, out IntPtr hPrinter, IntPtr pd);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool ClosePrinter(IntPtr hPrinter);
  [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFO di);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool EndDocPrinter(IntPtr hPrinter);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool StartPagePrinter(IntPtr hPrinter);
  [DllImport("winspool.drv", SetLastError=true)] public static extern bool EndPagePrinter(IntPtr hPrinter);
  [DllImport("winspool.drv", SetLastError=true)]
  public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, int dwCount, out int dwWritten);

  public static void Send(string printer, byte[] bytes) {
    IntPtr h;
    if (!OpenPrinter(printer, out h, IntPtr.Zero)) throw new Exception("Cannot open printer " + printer);
    try {
      DOCINFO di = new DOCINFO();
      di.pDocName = "Chennai Express receipt";
      di.pDataType = "RAW";
      if (!StartDocPrinter(h, 1, di)) throw new Exception("Cannot start the print job");
      try {
        if (!StartPagePrinter(h)) throw new Exception("Cannot start the page");
        IntPtr buf = Marshal.AllocCoTaskMem(bytes.Length);
        try {
          Marshal.Copy(bytes, 0, buf, bytes.Length);
          int written;
          if (!WritePrinter(h, buf, bytes.Length, out written)) throw new Exception("The printer rejected the data");
        } finally { Marshal.FreeCoTaskMem(buf); }
        EndPagePrinter(h);
      } finally { EndDocPrinter(h); }
    } finally { ClosePrinter(h); }
  }
}
'@
      [RawPrinter]::Send($printer, $bytes)
    `

    await run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script], {
      timeout: 15_000,
      windowsHide: true,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new PrintError(`Cannot print to "${queue}": ${message.trim()}`)
  } finally {
    await unlink(file).catch(() => {})
  }
}

export function send(connection: Connection, address: string, data: Buffer): Promise<void> {
  return connection === 'network' ? sendNetwork(address, data) : sendUsb(address, data)
}
