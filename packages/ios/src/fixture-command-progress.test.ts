import { expect, test } from 'bun:test'
import { nativeFixtureCommand } from '../scripts/native-fixture-command'

/**
 * `timedOut` alone cannot tell a starved command from a stalled one — both
 * report the same boolean after the same deadline, which is why #490's
 * failures arrive as bare timeouts with nothing to decide them by.
 */
test.skipIf(process.platform === 'win32')('a command still writing when the deadline fires reports recent output', async () => {
  // Writes every 50ms and never exits: progress, just not enough of it.
  const result = await nativeFixtureCommand(['/bin/sh', '-c', 'while :; do echo tick; sleep 0.05; done'], { timeoutMs: 600 })
  expect(result.timedOut).toBe(true)
  expect(result.stdout).toContain('tick')
  expect(result.elapsedMs).toBeGreaterThanOrEqual(500)
  // It was producing output right up to the kill, so silence is short.
  expect(result.msSinceLastOutput).toBeLessThan(result.elapsedMs)
  expect(result.msSinceLastOutput).toBeLessThan(400)
}, 20_000)

test.skipIf(process.platform === 'win32')('a command that writes once then hangs reports a long silence', async () => {
  const result = await nativeFixtureCommand(['/bin/sh', '-c', 'echo once; sleep 30'], { timeoutMs: 800 })
  expect(result.timedOut).toBe(true)
  expect(result.stdout).toContain('once')
  // Silence covers nearly the whole budget: stalled, not merely slow.
  expect(result.msSinceLastOutput).toBeGreaterThan(400)
}, 20_000)

test.skipIf(process.platform === 'win32')('a command that never writes reports silence equal to its whole run', async () => {
  const result = await nativeFixtureCommand(['/bin/sh', '-c', 'sleep 30'], { timeoutMs: 500 })
  expect(result.timedOut).toBe(true)
  expect(result.stdout).toBe('')
  expect(result.msSinceLastOutput).toBeGreaterThanOrEqual(result.elapsedMs - 1)
}, 20_000)

test.skipIf(process.platform === 'win32')('a command that exits normally still reports its elapsed time', async () => {
  const result = await nativeFixtureCommand(['/bin/sh', '-c', 'echo done'], { timeoutMs: 10_000 })
  expect(result.timedOut).toBe(false)
  expect(result.code).toBe(0)
  expect(result.stdout.trim()).toBe('done')
  expect(result.elapsedMs).toBeGreaterThan(0)
  expect(result.elapsedMs).toBeLessThan(10_000)
}, 20_000)
