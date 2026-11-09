import { expect, test } from 'bun:test'
import { statSync } from 'node:fs'
import { join } from 'node:path'
import { describeFixtureCommandFailure, nativeFixtureCommand, starvedSilenceFraction } from '../scripts/native-fixture-command'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * `timedOut` alone cannot tell a starved command from a stalled one — both
 * report the same boolean after the same deadline, which is why #490's
 * failures arrive as bare timeouts with nothing to decide them by.
 *
 * Both transports are covered, because they are not the same code path and
 * only one of them was exercised. With `logPath` — which every real caller
 * passes — the child writes to the descriptor and the pipes stay empty, so a
 * command producing output continuously reported `msSinceLastOutput` equal to
 * its whole run, documented to mean it never wrote anything.
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

/**
 * The same three shapes through a log file. Measured before the sampler
 * existed: a command writing every 50 ms for 1009 ms reported 1009 ms of
 * silence while its log held 85 bytes.
 */
for (const [label, script, silence] of [
  ['still writing when the deadline fires', 'while :; do echo tick; sleep 0.05; done', 'recent'],
  ['writes once then hangs', 'echo once; sleep 30', 'long'],
  ['never writes at all', 'sleep 30', 'total'],
] as const) {
  test.skipIf(process.platform === 'win32')(`a log-writing command ${label} reports ${silence} silence`, async () => {
    const dir = createTempDir('craft-fixture-progress-')
    try {
      const logPath = join(dir, 'command.log')
      const result = await nativeFixtureCommand(['/bin/sh', '-c', script], { timeoutMs: 1000, logPath })
      expect(result.timedOut).toBe(true)
      // The pipes are empty either way; the receipt must not read that as no output.
      expect(result.stdout).toBe('')
      expect(result.outputBytes).toBe(statSync(logPath).size)
      if (silence === 'recent') {
        expect(result.outputBytes).toBeGreaterThan(0)
        expect(result.msSinceLastOutput).toBeLessThan(result.elapsedMs / 2)
      }
      else if (silence === 'long') {
        expect(result.outputBytes).toBe('once\n'.length)
        expect(result.msSinceLastOutput).toBeGreaterThan(result.elapsedMs / 2)
        expect(result.msSinceLastOutput).toBeLessThan(result.elapsedMs)
      }
      else {
        expect(result.outputBytes).toBe(0)
        expect(result.msSinceLastOutput).toBeGreaterThanOrEqual(result.elapsedMs - 1)
      }
    }
    finally { removeTempDir(dir) }
  }, 20_000)
}

test.skipIf(process.platform === 'win32')('the pipe path reports the bytes it read', async () => {
  const result = await nativeFixtureCommand(['/bin/sh', '-c', 'printf \'ab\'; printf \'cde\' >&2'], { timeoutMs: 10_000 })
  expect(result.timedOut).toBe(false)
  expect(result.outputBytes).toBe(5)
}, 20_000)

/**
 * What a reader actually sees. The receipt's numbers were reaching the
 * evidence JSON but not the thrown error, so the three production callers all
 * reported `failed (null)` for a timeout — the same line whether the command
 * had written nothing or megabytes.
 */
test('a timeout failure line says which kind of timeout it was', () => {
  const base = { code: 0, timedOut: true, cancelled: false, groupDisposed: true }
  const starved = describeFixtureCommandFailure('metal-build', { ...base, elapsedMs: 300_000, msSinceLastOutput: 40, outputBytes: 4_194_304 }, '/e/metal-build.log')
  expect(starved).toContain('timed out after 300000 ms')
  expect(starved).toContain('last wrote 40 ms before the end (4194304 bytes written)')
  expect(starved).toContain('starved rather than stalled')
  expect(starved).toContain('see /e/metal-build.log')

  const stalled = describeFixtureCommandFailure('metal-build', { ...base, elapsedMs: 300_000, msSinceLastOutput: 299_000, outputBytes: 12 }, '/e/x.log')
  expect(stalled).toContain('stalled rather than starved')

  // Output but no progress evidence at all is its own case: a command that
  // never wrote cannot be called stalled on this evidence, because nothing
  // shows it reached the work.
  const silent = describeFixtureCommandFailure('metal-build', { ...base, elapsedMs: 300_000, msSinceLastOutput: 300_000, outputBytes: 0 }, '/e/x.log')
  expect(silent).toContain('never produced any output')

  // The threshold is a judgement, so it is stated rather than hidden: exactly
  // at the boundary still counts as progress.
  const boundary = { ...base, elapsedMs: 1000, msSinceLastOutput: 1000 * starvedSilenceFraction, outputBytes: 1 }
  expect(describeFixtureCommandFailure('x', boundary, '/l')).toContain('starved rather than stalled')
  expect(describeFixtureCommandFailure('x', { ...boundary, msSinceLastOutput: 1000 * starvedSilenceFraction + 1 }, '/l')).toContain('stalled rather than starved')
})

test('the other failure kinds keep their own line', () => {
  const base = { code: 0, timedOut: false, cancelled: false, groupDisposed: true, elapsedMs: 1234, msSinceLastOutput: 10, outputBytes: 99 }
  // Cancellation first: a cancelled command is usually also past its deadline,
  // and calling that a timeout would blame the command for the interruption.
  expect(describeFixtureCommandFailure('a', { ...base, cancelled: true, timedOut: true }, '/l')).toContain('was cancelled after 1234 ms (99 bytes written)')
  expect(describeFixtureCommandFailure('b', { ...base, groupDisposed: false }, '/l')).toContain('left its process group undisposed after 1234 ms')
  expect(describeFixtureCommandFailure('c', { ...base, code: 7 }, '/l')).toContain('failed (7) after 1234 ms (99 bytes written)')
})
