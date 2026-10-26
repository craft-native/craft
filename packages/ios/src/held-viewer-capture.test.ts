import { describe, expect, test } from 'bun:test'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { captureHeldViewer, HeldViewerTiming, heldViewerTest, includesHeldViewer, prepareHeldViewerCapture, waitForHeldViewerReady } from '../scripts/held-viewer-capture'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

const syntheticTool = { simctl: '/synthetic/Xcode/simctl', simctlSha256: 'synthetic-tool-hash' }
const simulator = '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16'
const begin = 'CRAFT_TAB_LCV_HOLD_BEGIN 100\n'
const gesture = 't = 1.0s Press Home for 6 seconds\nt = 1.1s Synthesize event\n'
// A synthetic pixel tests evidence plumbing, never platform viewer acceptance.
const pixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64')

function ready(): HeldViewerTiming {
  const timing = new HeldViewerTiming()
  timing.line(begin, 100)
  timing.line('Press Home for 6 seconds', 101)
  expect(timing.line('Synthesize event', 102)).toBe(true)
  return timing
}

describe('independent held viewer capture', () => {
  test('baseline and held screenshot execute the same resolved hashed absolute simctl binary', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    const started = performance.now()
    try {
      const log = join(dir, 'log'), done = join(dir, 'done'), output = join(dir, 'evidence'), simctl = join(dir, 'Xcode-simctl')
      const options = { log, done, output, simulator, timeoutMs: 2500 }
      writeFileSync(log, begin + gesture)
      writeFileSync(simctl, 'verified synthetic simctl')
      const screenshotBinaries: string[] = []
      const command: NonNullable<Parameters<typeof prepareHeldViewerCapture>[1]>['command'] = async (args) => {
        if (args.includes('--find')) {
          expect(args).toEqual(['/usr/bin/xcrun', '--find', 'simctl'])
        }
        else {
          expect(args.slice(0, 4)).toEqual([simctl, 'io', simulator, 'screenshot'])
          screenshotBinaries.push(args[0]!)
          await Bun.write(args.at(-1)!, pixel)
          if (args.at(-1)!.endsWith('during-hold.png')) appendFileSync(log, 'CRAFT_TAB_LCV_HOLD_END 108\n')
        }
        return { code: 0, signal: null, stdout: args.includes('--find') ? simctl : '', stderr: '', timedOut: false, cancelled: false, processGroup: 123, groupDisposed: true }
      }
      await captureHeldViewer(options, {
        prepare: () => prepareHeldViewerCapture(options, { command, xcrun: '/usr/bin/xcrun' }), command,
        now: () => 102 + (performance.now() - started) / 1000,
      })
      expect(screenshotBinaries).toEqual([simctl, simctl])
      const receipt = JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8'))
      expect(receipt.resolvedTool).toEqual({ simctl, simctlSha256: new Bun.CryptoHasher('sha256').update('verified synthetic simctl').digest('hex') })
      expect(receipt.verifiedDuringHold).toBe(true)
    }
    finally { removeTempDir(dir) }
  })

  test('positive control records exact tool/device and writes readiness only after verified PNG', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    try {
      const output = join(dir, 'evidence'), ready = join(dir, 'ready'), simctl = join(dir, 'simctl')
      writeFileSync(simctl, 'synthetic public tool binary')
      const calls: string[][] = []
      await prepareHeldViewerCapture({ log: join(dir, 'live.log'), done: join(dir, 'done'), output, ready, simulator }, {
        xcrun: '/usr/bin/xcrun',
        command: async (args, options) => {
          calls.push(args)
          expect(existsSync(ready)).toBe(false)
          expect(options.timeoutMs).toBeGreaterThan(0)
          expect(options.timeoutMs).toBeLessThanOrEqual(30_000)
          if (args.includes('screenshot')) await Bun.write(args.at(-1)!, pixel)
          return { code: 0, signal: null, stdout: args.includes('--find') ? `${simctl}\n` : '', stderr: '', timedOut: false, cancelled: false, processGroup: 123, groupDisposed: true }
        },
      })
      expect(calls).toEqual([['/usr/bin/xcrun', '--find', 'simctl'], [simctl, 'io', simulator, 'screenshot', join(output, 'baseline.png')]])
      expect(existsSync(ready)).toBe(true)
      const receipt = JSON.parse(readFileSync(join(output, 'preflight.json'), 'utf8'))
      expect(receipt.verified).toBe(true)
      expect(receipt.simulator).toBe(simulator)
      expect(receipt.simctlSha256).toBe(new Bun.CryptoHasher('sha256').update('synthetic public tool binary').digest('hex'))
      expect(receipt.sha256).toBe(new Bun.CryptoHasher('sha256').update(pixel).digest('hex'))
    }
    finally { removeTempDir(dir) }
  })

  test('failed or invalid positive control never signals readiness', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    try {
      const simctl = join(dir, 'simctl')
      writeFileSync(simctl, 'synthetic tool')
      for (const mode of ['timeout', 'invalid']) {
        const output = join(dir, mode), ready = join(output, 'preflight-ready')
        await expect(prepareHeldViewerCapture({ log: join(dir, 'log'), done: join(dir, 'done'), output, simulator }, {
          xcrun: '/usr/bin/xcrun',
          command: async (args) => {
            const failed = args.includes('screenshot') && mode === 'timeout'
            if (args.includes('screenshot') && !failed) await Bun.write(args.at(-1)!, 'invalid PNG')
            return { code: failed ? 143 : 0, signal: failed ? 'SIGTERM' : null, stdout: args.includes('--find') ? simctl : '', stderr: '', timedOut: failed, cancelled: false, processGroup: 123, groupDisposed: true }
          },
        })).rejects.toThrow(mode === 'timeout' ? '"timedOut":true' : 'did not produce a PNG')
        expect(existsSync(ready)).toBe(false)
        expect(JSON.parse(readFileSync(join(output, 'preflight.json'), 'utf8')).verified).toBe(false)
      }
    }
    finally { removeTempDir(dir) }
  })

  test('tool resolution consumes the shared preflight budget instead of giving capture another 30 seconds', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    try {
      const simctl = join(dir, 'simctl')
      writeFileSync(simctl, 'synthetic tool')
      for (const elapsed of [28_000, 30_000]) {
        const output = join(dir, String(elapsed))
        let now = 0
        const budgets: number[] = []
        const prepare = prepareHeldViewerCapture({ log: join(dir, 'log'), done: join(dir, 'done'), output, simulator }, {
          xcrun: '/usr/bin/xcrun', monotonicNow: () => now,
          command: async (args, options) => {
            budgets.push(options.timeoutMs)
            if (args.includes('--find')) now = elapsed
            else await Bun.write(args.at(-1)!, pixel)
            return { code: 0, signal: null, stdout: args.includes('--find') ? simctl : '', stderr: '', timedOut: false, cancelled: false, processGroup: 123, groupDisposed: true }
          },
        })
        if (elapsed === 28_000) {
          await prepare
          expect(budgets).toEqual([30_000, 2000])
          expect(existsSync(join(output, 'preflight-ready'))).toBe(true)
        }
        else {
          await expect(prepare).rejects.toThrow('exhausted its shared')
          expect(budgets).toEqual([30_000])
          expect(existsSync(join(output, 'preflight-ready'))).toBe(false)
        }
        const receipt = JSON.parse(readFileSync(join(output, 'preflight.json'), 'utf8'))
        expect(receipt.totalCommandBudgetMs).toBe(30_000)
        expect(receipt.calls[1].timeoutMs).toBe(30_000 - elapsed)
      }
    }
    finally { removeTempDir(dir) }
  })

  test('preflight completes before any held screenshot can run', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    const started = performance.now()
    try {
      const log = join(dir, 'log'), done = join(dir, 'done'), output = join(dir, 'evidence'), ready = join(dir, 'ready')
      writeFileSync(log, begin + gesture)
      await captureHeldViewer({ log, done, output, simulator, timeoutMs: 2500 }, {
        prepare: async () => { await Bun.sleep(25); await Bun.write(ready, 'positive control verified'); return syntheticTool },
        now: () => 102 + (performance.now() - started) / 1000,
        capture: async path => {
          expect(existsSync(ready)).toBe(true)
          await Bun.write(path, pixel)
          appendFileSync(log, 'CRAFT_TAB_LCV_HOLD_END 108\n')
        },
      })
    }
    finally { removeTempDir(dir) }
  })

  test('runner readiness wait fails on watcher exit/deadline and only resolves after actual ready file', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    try {
      const ready = join(dir, 'ready')
      await expect(waitForHeldViewerReady(ready, Promise.resolve(1), 200)).rejects.toThrow('exit 1')
      await expect(waitForHeldViewerReady(ready, new Promise(() => {}), 50)).rejects.toThrow('deadline')
      await expect(waitForHeldViewerReady(ready, Promise.reject(new Error('watcher spawn failed')), 200)).rejects.toThrow('watcher spawn failed')
      const pending = waitForHeldViewerReady(ready, new Promise(() => {}), 500)
      await Bun.sleep(40)
      await Bun.write(ready, 'positive control verified')
      await pending
      expect(existsSync(ready)).toBe(true)
      await expect(waitForHeldViewerReady(ready, Promise.resolve(1), 200)).rejects.toThrow('exit 1')
    }
    finally { removeTempDir(dir) }
  })

  test('preflight failure prevents the held screenshot command entirely', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    let captured = false
    try {
      const log = join(dir, 'log'), done = join(dir, 'done'), output = join(dir, 'evidence')
      writeFileSync(log, begin + gesture)
      await expect(captureHeldViewer({ log, done, output, simulator }, {
        prepare: async () => { throw new Error('Positive control unavailable') },
        capture: async () => { captured = true },
      })).rejects.toThrow('Positive control unavailable')
      expect(captured).toBe(false)
    }
    finally { removeTempDir(dir) }
  })

  test('full/core or explicit viewer selection requires evidence, unit/other UI selectors do not', () => {
    for (const selection of [[], ['NativeNavigationUITests'], ['NativeNavigationUITests/NativeNavigationUITests'], [heldViewerTest]])
      expect(includesHeldViewer(selection)).toBe(true)
    expect(includesHeldViewer(['NativeNavigationUnitTests'])).toBe(false)
    expect(includesHeldViewer(['NativeNavigationUITests/NativeNavigationUITests/testOther'])).toBe(false)
  })

  test('marker and idle activity cannot substitute for the actual six-second press synthesis', () => {
    const timing = new HeldViewerTiming()
    expect(timing.line('Synthesize event', 99)).toBe(false)
    timing.line(begin, 100)
    expect(timing.line('Synthesize event', 101)).toBe(false)
    timing.line('Press Home for 0.1 seconds, then drag', 101)
    expect(timing.line('Synthesize event', 101)).toBe(false)
    timing.line('Press Home for 6 seconds', 101)
    expect(timing.line('Wait for idle', 101)).toBe(false)
    expect(timing.line('Synthesize event', 102)).toBe(true)
    expect(timing.line('Synthesize event', 102)).toBe(false)
  })

  test('public driver trace verifies the same during-hold screenshot timing as native fixtures', () => {
    const timing = new HeldViewerTiming()
    timing.line('DRIVER BEGIN holdtab Today | 6.0 | 100', 100)
    expect(timing.line('Synthesize event', 101)).toBe(false)
    timing.line('t = 1s Press "craft-tab-/" Button[0.5, 0.5] for 6.0 seconds', 101)
    expect(timing.line('t = 2s Synthesize event', 102)).toBe(true)
    timing.captured(102.8, 103.2)
    timing.line('DRIVER END holdtab Today | 108', 108)
    expect(() => timing.verify()).not.toThrow()
    expect(timing.beganAt).toBe(100)
    expect(timing.releasedAt).toBe(108)
  })

  test('public driver markers reject non-six holds, malformed timestamps, mismatched tabs and duplicates', () => {
    for (const marker of [
      'DRIVER BEGIN holdtab Today | 2.0 | 100',
      'DRIVER BEGIN holdtab Today | 6.0 | NaN',
      'DRIVER BEGIN holdtab Today | 6.0 | 100.0.1',
      'DRIVER BEGIN holdtab Today | 6.0 | -100',
      'DRIVER BEGIN holdtab | 6.0 | 100',
    ]) expect(() => new HeldViewerTiming().line(marker, 100)).toThrow()
    for (const marker of [
      'DRIVER END holdtab Health | 108',
      'DRIVER END holdtab Today | Infinity',
      'CRAFT_TAB_LCV_HOLD_END 108',
      'DRIVER BEGIN holdtab Today | 6.0 | 100',
    ]) {
      const timing = new HeldViewerTiming()
      timing.line('DRIVER BEGIN holdtab Today | 6.0 | 100', 100)
      expect(() => timing.line(marker, 108)).toThrow()
    }
  })

  test('public driver complete live trace retains a qualified independent screenshot receipt', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    const started = performance.now()
    try {
      const log = join(dir, 'log'), done = join(dir, 'done'), output = join(dir, 'evidence')
      writeFileSync(log, 'DRIVER BEGIN holdtab Today | 6.0 | 100\n' + gesture)
      await captureHeldViewer({ log, done, output, simulator, timeoutMs: 2500 }, {
        prepare: async () => syntheticTool,
        now: () => 102 + (performance.now() - started) / 1000,
        capture: async path => {
          await Bun.write(path, pixel)
          appendFileSync(log, 'DRIVER END holdtab Today | 108\n')
        },
      })
      const receipt = JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8'))
      expect(receipt.verifiedDuringHold).toBe(true)
      expect(receipt.timing.tab).toBe('Today')
      expect(receipt.timing.captureFinishedAt).toBeLessThan(receipt.timing.releasedAt)
    }
    finally { removeTempDir(dir) }
  })

  test('requires screenshot completion before release and rejects buffered/early captures', () => {
    for (const [start, finish, end] of [[102.8, 103, 108], [102.1, 103, 108], [102.8, 108, 108], [102.8, 109, 108], [102.8, 103, 104]]) {
      const timing = ready()
      timing.captured(start!, finish!)
      timing.line(`CRAFT_TAB_LCV_HOLD_END ${end}`, end!)
      if (end === 108 && finish === 103 && start === 102.8) expect(() => timing.verify()).not.toThrow()
      else expect(() => timing.verify()).toThrow('during the six-second')
    }
    expect(() => ready().verify()).toThrow('Missing')
    const duplicate = ready()
    expect(() => duplicate.line(begin, 104)).toThrow('Duplicate')
  })

  test('tails partial live lines and retains hashed independent PNG with timing receipt', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    const log = join(dir, 'live.log'), done = join(dir, 'done'), output = join(dir, 'evidence')
    const started = performance.now()
    let captureCount = 0
    try {
      writeFileSync(log, `old unrelated output\n${begin}t = 1s Press Home for 6 seconds\nt = 2s Synthesize`)
      const capture = captureHeldViewer({ log, done, output, simulator, startOffset: 'old unrelated output\n'.length, timeoutMs: 3000 }, {
        prepare: async () => syntheticTool,
        now: () => 102 + (performance.now() - started) / 1000,
        capture: async (path) => {
          captureCount++
          await Bun.write(path, pixel)
          // The release marker can arrive while the screenshot Promise resolves.
          appendFileSync(log, 'CRAFT_TAB_LCV_HOLD_END 108\n')
        },
      })
      await Bun.sleep(40)
      appendFileSync(log, ' event\n')
      await capture
      const receipt = JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8'))
      expect(captureCount).toBe(1)
      expect(receipt.verifiedDuringHold).toBe(true)
      expect(receipt.sha256).toBe(new Bun.CryptoHasher('sha256').update(pixel).digest('hex'))
      expect(receipt.timing.captureFinishedAt).toBeLessThan(receipt.timing.releasedAt)
      expect(receipt.visualReviewRequired).toContain('actual system Large Content Viewer')
    }
    finally { removeTempDir(dir) }
  })

  test('completed/buffered hold cannot produce a falsely accepted after-release image', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    let captured = false
    try {
      const log = join(dir, 'live.log'), done = join(dir, 'done'), output = join(dir, 'evidence')
      writeFileSync(log, `${begin}${gesture}CRAFT_TAB_LCV_HOLD_END 108\n`)
      await expect(captureHeldViewer({ log, done, output, simulator, timeoutMs: 2000 }, {
        prepare: async () => syntheticTool,
        now: () => 109,
        capture: async () => { captured = true },
      })).rejects.toThrow('Hold ended before')
      expect(captured).toBe(false)
      expect(JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8')).verifiedDuringHold).toBe(false)
    }
    finally { removeTempDir(dir) }
  })

  test('failed screenshot retains timeout, status, signal and both output streams', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    const commandResult = {
      code: 143, signal: 'SIGTERM', timedOut: true, cancelled: false,
      stdout: 'capture started', stderr: '', processGroup: 123, groupDisposed: true as const,
    }
    try {
      const log = join(dir, 'live.log'), done = join(dir, 'done'), output = join(dir, 'evidence')
      writeFileSync(log, begin + gesture)
      await expect(captureHeldViewer({ log, done, output, simulator, timeoutMs: 2000 }, {
        prepare: async () => syntheticTool,
        now: () => 102,
        command: async (args, options) => {
          expect(args.slice(0, 4)).toEqual([syntheticTool.simctl, 'io', simulator, 'screenshot'])
          expect(options.timeoutMs).toBe(5000)
          return commandResult
        },
      })).rejects.toThrow('"timedOut":true')
      const receipt = JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8'))
      expect(receipt.verifiedDuringHold).toBe(false)
      expect(receipt.screenshotCommand).toEqual(commandResult)
      expect(receipt.screenshotCommandTimeoutMs).toBe(5000)
      expect(receipt.timing.captureStartedAt).toBe(102)
      expect(receipt.timing.captureFinishedAt).toBe(102)
      expect(receipt.captureDelayMs).toBe(750)
    }
    finally { removeTempDir(dir) }
  })

  test('missing markers, corrupt PNG and cancellation fail closed', async () => {
    const dir = createTempDir('craft-held-capture-test-')
    try {
      const log = join(dir, 'live.log'), done = join(dir, 'done')
      writeFileSync(log, 'No held gesture\n')
      writeFileSync(done, 'finished')
      await expect(captureHeldViewer({ log, done, output: join(dir, 'missing'), simulator, timeoutMs: 1200 }, { prepare: async () => syntheticTool })).rejects.toThrow('without a synthesized')
      writeFileSync(log, begin + gesture)
      await expect(captureHeldViewer({ log, done, output: join(dir, 'corrupt'), simulator, timeoutMs: 2000 }, {
        prepare: async () => syntheticTool,
        now: () => 102,
        capture: async path => { await Bun.write(path, 'not a PNG') },
      })).rejects.toThrow('did not produce a PNG')
      const controller = new AbortController()
      const cancelled = captureHeldViewer({ log, done, output: join(dir, 'cancelled'), simulator, signal: controller.signal }, { prepare: async () => syntheticTool })
      controller.abort(new Error('Owned test cancelled'))
      await expect(cancelled).rejects.toThrow('Owned test cancelled')
    }
    finally { removeTempDir(dir) }
  })
})
