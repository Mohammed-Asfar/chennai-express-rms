let passed = 0
let failed = 0
const failures: string[] = []
const pending: Promise<void>[] = []

/**
 * Registers a test. Async bodies are awaited by `settle()` before reporting.
 *
 * Async tests start immediately and run concurrently. That is fine for
 * in-memory SQLite, but tests sharing one external database must use
 * `serialTest` — concurrent schema statements deadlock against each other.
 */
export function test(name: string, fn: () => void | Promise<void>): void {
  const record = (error: unknown): void => {
    failed++
    failures.push(`  ${name}\n    ${error instanceof Error ? error.message : String(error)}`)
  }

  try {
    const result = fn()
    if (result instanceof Promise) {
      pending.push(result.then(() => void passed++, record))
    } else {
      passed++
    }
  } catch (error) {
    record(error)
  }
}

const serialQueue: { name: string; fn: () => Promise<void> }[] = []

/**
 * Registers a test that must not run alongside the others.
 *
 * For tests sharing an external database: concurrent TRUNCATEs deadlock, and
 * one test's fixture would wipe another's rows mid-run.
 */
export function serialTest(name: string, fn: () => Promise<void>): void {
  serialQueue.push({ name, fn })
}

export async function settle(): Promise<void> {
  await Promise.all(pending)

  for (const entry of serialQueue) {
    try {
      await entry.fn()
      passed++
    } catch (error) {
      failed++
      failures.push(
        `  ${entry.name}
    ${error instanceof Error ? error.message : String(error)}`,
      )
    }
  }
}

export function assertEqual<T>(actual: T, expected: T, message?: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message ? message + ': ' : ''}expected ${String(expected)}, got ${String(actual)}`,
    )
  }
}

export function assertThrows(fn: () => unknown, message?: string): void {
  try {
    fn()
  } catch {
    return
  }
  throw new Error(message ?? 'expected the function to throw, but it did not')
}

export function report(suite: string): void {
  console.log(`\n${suite}: ${passed} passed, ${failed} failed`)
  if (failures.length > 0) {
    console.log(`\nFailures:\n${failures.join('\n')}`)
  }
}

export function exitCode(): number {
  return failed > 0 ? 1 : 0
}
