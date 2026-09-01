import { createConnection } from 'node:net'
import { networkInterfaces } from 'node:os'
import { exec } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(exec)

/**
 * Finding printers without making anyone read an IP off a settings printout.
 *
 * Two sources: Windows knows what is plugged in, and a thermal printer on the
 * network answers on port 9100. Neither is exhaustive, so discovery supplements
 * manual entry rather than replacing it.
 */

export interface Discovered {
  name: string
  connection: 'usb' | 'network'
  address: string
  /** Whether this looks like a receipt printer rather than an office one. */
  likelyThermal: boolean
  /** Extra context, such as the Windows port. Null when there is none. */
  detail: string | null
}

/** The port virtually every ESC/POS printer listens on. */
const RAW_PORT = 9100

/** Short, because an unreachable host must not hold up the whole sweep. */
const PROBE_TIMEOUT_MS = 400

/**
 * Model and driver names that mark a receipt printer.
 *
 * Used to sort likely candidates first, never to hide anything — an unknown
 * brand still appears, just lower down.
 */
const THERMAL_HINTS = [
  'thermal', 'receipt', 'pos-', 'pos ', 'escpos', 'esc/pos',
  'tvs', 'tvse', 'epson tm', 'tm-t', 'rp3200', 'rp-3200',
  'star tsp', 'bixolon', 'srp-', 'xprinter', 'xp-', 'rongta',
  '58mm', '80mm', 'everycom', 'iware', 'retsol', 'posiflex',
]

/** Virtual printers that are never a receipt printer. */
const VIRTUAL = ['pdf', 'onenote', 'xps', 'fax', 'microsoft print']

const looksThermal = (text: string): boolean => {
  const lower = text.toLowerCase()
  return THERMAL_HINTS.some((hint) => lower.includes(hint))
}

const isVirtual = (text: string): boolean => {
  const lower = text.toLowerCase()
  return VIRTUAL.some((hint) => lower.includes(hint))
}

/**
 * Printers Windows already knows about.
 *
 * These are queues rather than raw devices, so the address is the printer's
 * share name — writing to it goes through the driver Windows already has.
 */
export async function discoverUsb(): Promise<Discovered[]> {
  if (process.platform !== 'win32') return []

  try {
    const { stdout } = await run(
      'powershell -NoProfile -Command "Get-CimInstance Win32_Printer | ' +
        'Select-Object Name, PortName, DriverName, Default | ConvertTo-Json -Compress"',
      { timeout: 10_000, windowsHide: true },
    )

    const parsed: unknown = JSON.parse(stdout.trim() || '[]')
    const rows = (Array.isArray(parsed) ? parsed : [parsed]) as {
      Name?: string
      PortName?: string
      DriverName?: string
    }[]

    return rows
      .filter((row) => row.Name && !isVirtual(`${row.Name} ${row.DriverName ?? ''}`))
      .map((row) => ({
        name: row.Name!,
        connection: 'usb' as const,
        // The share name, not the port: Windows resolves it, and a raw USB00n
        // path is not directly writable.
        address: row.Name!,
        likelyThermal: looksThermal(`${row.Name} ${row.DriverName ?? ''}`),
        detail: row.PortName ?? null,
      }))
  } catch {
    // Discovery is a convenience. If it fails, manual entry still works.
    return []
  }
}

/** The IPv4 /24 subnets this machine is on. */
function localSubnets(): string[] {
  const found: string[] = []
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family !== 'IPv4' || address.internal) continue
      const parts = address.address.split('.')
      if (parts.length === 4) found.push(`${parts[0]}.${parts[1]}.${parts[2]}`)
    }
  }
  return [...new Set(found)]
}

/** Whether something is listening on a host's raw print port. */
function probe(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host, port })
    let settled = false
    const finish = (open: boolean) => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(open)
    }
    socket.setTimeout(timeoutMs)
    socket.on('connect', () => finish(true))
    socket.on('timeout', () => finish(false))
    socket.on('error', () => finish(false))
  })
}

/**
 * Sweeps the local subnet for anything answering on port 9100.
 *
 * 254 addresses probed in batches: sequentially this would take two minutes,
 * and all at once it would exhaust the socket pool.
 */
export async function discoverNetwork(
  options: {
    subnet?: string
    timeoutMs?: number
    /** Called as the sweep advances, so a caller can stream progress. */
    onProgress?: (progress: { scanned: number; total: number; found?: Discovered }) => void
    /** Checked between batches so a client that disconnects stops the work. */
    isCancelled?: () => boolean
  } = {},
): Promise<Discovered[]> {
  const subnets = options.subnet ? [options.subnet] : localSubnets()
  if (subnets.length === 0) return []

  const timeout = options.timeoutMs ?? PROBE_TIMEOUT_MS
  const found: Discovered[] = []
  const BATCH = 32

  const total = subnets.length * 254
  let scanned = 0

  for (const subnet of subnets) {
    const hosts = Array.from({ length: 254 }, (_, i) => `${subnet}.${i + 1}`)

    for (let i = 0; i < hosts.length; i += BATCH) {
      if (options.isCancelled?.()) return found

      const batch = hosts.slice(i, i + BATCH)
      const results = await Promise.all(
        batch.map(async (host) => ({ host, open: await probe(host, RAW_PORT, timeout) })),
      )
      scanned += batch.length

      for (const { host, open } of results) {
        if (!open) continue
        const printer: Discovered = {
          name: `Printer at ${host}`,
          connection: 'network',
          address: `${host}:${RAW_PORT}`,
          // Anything answering on 9100 is a raw print port by convention.
          likelyThermal: true,
          detail: 'Answers on port 9100',
        }
        found.push(printer)
        options.onProgress?.({ scanned, total, found: printer })
      }

      options.onProgress?.({ scanned, total })
    }
  }

  return found
}

/**
 * Everything discoverable, likely receipt printers first.
 *
 * The two sweeps run together — the network scan is the slow one, and USB
 * enumeration should not wait behind it.
 */
export async function discoverAll(): Promise<Discovered[]> {
  const [usb, network] = await Promise.all([discoverUsb(), discoverNetwork()])

  return [...usb, ...network].sort((a, b) => {
    if (a.likelyThermal !== b.likelyThermal) return a.likelyThermal ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}
