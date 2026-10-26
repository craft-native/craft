import { closeSync, existsSync, mkdirSync, openSync, readSync, statSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { nativeFixtureCommand } from './native-fixture-command'
import { validateHeldVideoFrame } from './held-viewer-video'
import { verifyHeldViewerExtractor } from './held-viewer-extractor'

export const heldViewerTest = 'NativeNavigationUITests/NativeNavigationUITests/testTabBarLargeContentViewerDuringAccessibilityHold'

export function includesHeldViewer(selection: readonly string[]): boolean {
  return !selection.length || selection.some(value => heldViewerTest === value || heldViewerTest.startsWith(`${value}/`))
}

export async function waitForHeldViewerReady(ready: string, exited: Promise<number>, timeoutMs = 35_000): Promise<void> {
  if (!isAbsolute(ready) || !Number.isFinite(timeoutMs) || timeoutMs <= 0)
    throw new Error('Expected an absolute readiness path and a positive timeout')
  let code: number | undefined, failure: unknown
  void exited.then(value => { code = value }, error => { failure = error })
  await Promise.resolve()
  const deadline = performance.now() + timeoutMs
  while (performance.now() < deadline) {
    if (failure) throw failure
    if (code !== undefined) throw new Error(`Viewer watcher exited before readiness (exit ${code})`)
    if (existsSync(ready)) return
    await Bun.sleep(25)
  }
  throw new Error('Viewer screenshot positive control did not become ready before its deadline')
}

/** Log evidence is a timing gate, never a substitute for reviewing the PNG. */
export class HeldViewerTiming {
  beganAt?: number
  synthesisObservedAt?: number
  captureStartedAt?: number
  captureFinishedAt?: number
  releasedAt?: number
  tab?: string
  private press = false
  private markerKind?: 'fixture' | 'driver'

  line(value: string, observedAt: number): boolean {
    const fixtureBegin = /\bCRAFT_TAB_LCV_HOLD_BEGIN (\S+)\s*$/.exec(value)
    const fixtureEnd = /\bCRAFT_TAB_LCV_HOLD_END (\S+)\s*$/.exec(value)
    const driverBegin = /\bDRIVER BEGIN holdtab ([^|]+?)\s*\|\s*(\S+)\s*\|\s*(\S+)\s*$/.exec(value)
    const driverEnd = /\bDRIVER END holdtab ([^|]+?)\s*\|\s*(\S+)\s*$/.exec(value)
    if ((value.includes('CRAFT_TAB_LCV_HOLD_BEGIN') && !fixtureBegin)
      || (value.includes('CRAFT_TAB_LCV_HOLD_END') && !fixtureEnd)
      || (value.includes('DRIVER BEGIN holdtab') && !driverBegin)
      || (value.includes('DRIVER END holdtab') && !driverEnd))
      throw new Error('Malformed viewer hold marker')
    const timestamp = (raw: string): number => {
      if (!/^\d+(?:\.\d+)?$/.test(raw) || !Number.isFinite(Number(raw)) || Number(raw) <= 0)
        throw new Error('Invalid viewer hold timestamp')
      return Number(raw)
    }
    if (driverBegin && (!/^6(?:\.0+)?$/.test(driverBegin[2]!) || !driverBegin[1]!.trim()))
      throw new Error('Viewer capture requires a named six-second public driver hold')
    if (fixtureBegin || driverBegin) {
      if (this.beganAt !== undefined) throw new Error('Duplicate viewer hold marker')
      this.markerKind = driverBegin ? 'driver' : 'fixture'
      this.tab = driverBegin?.[1]?.trim()
      this.beganAt = timestamp((driverBegin?.[3] ?? fixtureBegin?.[1])!)
    }
    if (fixtureEnd || driverEnd) {
      if (this.beganAt === undefined || this.releasedAt !== undefined)
        throw new Error('Unmatched or duplicate viewer release marker')
      if ((driverEnd ? 'driver' : 'fixture') !== this.markerKind || (driverEnd && driverEnd[1]!.trim() !== this.tab))
        throw new Error('Viewer release does not match the held tab')
      this.releasedAt = timestamp((driverEnd?.[2] ?? fixtureEnd?.[1])!)
    }
    if (this.beganAt === undefined || this.releasedAt !== undefined) return false
    if (/\bPress\b.*\bfor 6(?:\.0+)? seconds\b/.test(value)) this.press = true
    if (this.press && this.synthesisObservedAt === undefined && value.includes('Synthesize event')) {
      this.synthesisObservedAt = observedAt
      return true
    }
    return false
  }

  captured(start: number, finish: number): void {
    this.captureStartedAt = start
    this.captureFinishedAt = finish
  }

  verify(): void {
    const { beganAt: begin, synthesisObservedAt: synthesis, captureStartedAt: start, captureFinishedAt: finish, releasedAt: end } = this
    if ([begin, synthesis, start, finish, end].some(value => value === undefined || !Number.isFinite(value)))
      throw new Error('Missing hold, synthesis, screenshot or release evidence')
    if (!(begin! <= synthesis! && synthesis! + 0.7 <= start! && start! <= finish! && finish! < end!
      && end! - synthesis! >= 5.5))
      throw new Error('The independent screenshot did not complete during the six-second synthesized hold')
  }
}

interface CaptureOptions {
  log: string
  simulator: string
  output: string
  done: string
  startOffset?: number
  signal?: AbortSignal
  timeoutMs?: number
  parentPid?: number
  ready?: string
  extractorManifest?: string
}

async function pngHash(path: string): Promise<string> {
  const bytes = await Bun.file(path).arrayBuffer()
  if (bytes.byteLength < 8 || Buffer.from(bytes.slice(0, 8)).toString('hex') !== '89504e470d0a1a0a')
    throw new Error('Independent capture did not produce a PNG')
  return new Bun.CryptoHasher('sha256').update(bytes).digest('hex')
}

/** Positive control completes before the runner may begin XCTest's held gesture. */
export interface ResolvedScreenshotTool {
  simctl: string
  simctlSha256: string
}

export async function prepareHeldViewerCapture(options: CaptureOptions, dependencies: {
  command?: typeof nativeFixtureCommand
  xcrun?: string
  monotonicNow?: () => number
} = {}): Promise<ResolvedScreenshotTool> {
  const ready = options.ready ?? join(options.output, 'preflight-ready')
  if (!isAbsolute(ready)) throw new Error('Viewer readiness path must be absolute')
  if (existsSync(ready)) throw new Error('Viewer readiness evidence already exists; use a fresh result directory')
  mkdirSync(options.output, { recursive: true })
  const command = dependencies.command ?? nativeFixtureCommand
  const calls: { args: string[], timeoutMs: number, startedAt: number, finishedAt?: number, result?: Awaited<ReturnType<typeof nativeFixtureCommand>> }[] = []
  const baseline = join(options.output, 'baseline.png')
  const xcrun = dependencies.xcrun ?? Bun.which('xcrun')
  const monotonicNow = dependencies.monotonicNow ?? (() => performance.now())
  const deadline = monotonicNow() + 30_000
  let simctl: string | undefined, simctlSha256: string | undefined, sha256: string | undefined
  const receipt = (verified: boolean, error?: string) => ({
    verified, error, simulator: options.simulator, xcrun, simctl, simctlSha256,
    developerDir: process.env.DEVELOPER_DIR ?? null, calls, screenshot: baseline, sha256,
    totalCommandBudgetMs: 30_000,
  })
  const run = async (args: string[]) => {
    const timeoutMs = Math.max(0, Math.floor(deadline - monotonicNow()))
    const call: typeof calls[number] = { args, timeoutMs, startedAt: Date.now() / 1000 }
    calls.push(call)
    try {
      if (timeoutMs <= 0) throw new Error('Viewer screenshot positive control exhausted its shared 30-second command budget')
      const result = await command(args, { cwd: options.output, timeoutMs, signal: options.signal })
      call.result = result
      if (result.code !== 0 || result.timedOut || result.cancelled)
        throw new Error(`Viewer screenshot positive control failed: ${JSON.stringify(result)}`)
      return result
    }
    finally { call.finishedAt = Date.now() / 1000 }
  }
  try {
    if (!xcrun || !isAbsolute(xcrun)) throw new Error('Cannot resolve the public xcrun executable')
    const resolved = await run([xcrun, '--find', 'simctl'])
    simctl = resolved.stdout.trim()
    if (!isAbsolute(simctl)) throw new Error('xcrun did not resolve an absolute simctl executable')
    simctlSha256 = new Bun.CryptoHasher('sha256').update(await Bun.file(simctl).arrayBuffer()).digest('hex')
    await run([simctl, 'io', options.simulator, 'screenshot', baseline])
    sha256 = await pngHash(baseline)
    await Bun.write(join(options.output, 'preflight.json'), JSON.stringify(receipt(true), null, 2))
    await Bun.write(ready, 'Screenshot positive control verified\n')
    return { simctl, simctlSha256 }
  }
  catch (error) {
    await Bun.write(join(options.output, 'preflight.json'), JSON.stringify(receipt(false, String(error)), null, 2))
    throw error
  }
}

/** Runs in an independent process while the existing xcode command stays synchronous. */
export async function captureHeldViewer(options: CaptureOptions, dependencies: {
  now?: () => number
  capture?: (png: string, signal: AbortSignal) => Promise<void>
  command?: typeof nativeFixtureCommand
  prepare?: () => Promise<ResolvedScreenshotTool>
} = {}): Promise<void> {
  if (![options.log, options.output, options.done].every(isAbsolute) || !/^[\da-f-]{36}$/i.test(options.simulator))
    throw new Error('Viewer capture needs absolute evidence paths and a simulator UUID')
  let offset = options.startOffset ?? 0
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('Invalid live log offset')
  mkdirSync(options.output, { recursive: true })
  const timing = new HeldViewerTiming()
  const now = dependencies.now ?? (() => Date.now() / 1000)
  const stop = new AbortController()
  const signal = options.signal ? AbortSignal.any([stop.signal, options.signal]) : stop.signal
  const png = join(options.output, 'during-hold.png')
  let resolvedTool: ResolvedScreenshotTool | undefined
  let screenshotCommand: Awaited<ReturnType<typeof nativeFixtureCommand>> | undefined
  const capture = dependencies.capture ?? (async (path, abort) => {
    if (!resolvedTool || !isAbsolute(resolvedTool.simctl)) throw new Error('Held capture requires the verified absolute simctl tool')
    const result = await (dependencies.command ?? nativeFixtureCommand)([resolvedTool.simctl, 'io', options.simulator, 'screenshot', path], {
      cwd: options.output, timeoutMs: 5000, signal: abort,
    })
    screenshotCommand = result
    if (result.code !== 0 || result.timedOut || result.cancelled)
      throw new Error(`Independent simulator screenshot failed: ${JSON.stringify(result)}`)
  })
  let pending: Promise<void> | undefined, failure: unknown, finished = false, remainder = ''
  let doneAt: number | undefined
  const deadline = performance.now() + (options.timeoutMs ?? 45 * 60_000)
  const receipt = (verifiedDuringHold: boolean, error?: string) => ({
    verifiedDuringHold, error, timing, simulator: options.simulator,
    screenshot: png, captureDelayMs: 750, screenshotCommandTimeoutMs: 5000, screenshotCommand,
    preflight: join(options.output, 'preflight.json'), resolvedTool,
    beforeAfter: ['XCTest attachment: Large content viewer before hold', 'XCTest attachment: Large content viewer after release'],
    visualReviewRequired: 'The during-hold PNG must show the actual system Large Content Viewer.',
  })
  try {
    resolvedTool = await (dependencies.prepare ?? (() => prepareHeldViewerCapture({ ...options, signal })))()
    while (performance.now() < deadline) {
      signal.throwIfAborted()
      if (options.parentPid) {
        try { process.kill(options.parentPid, 0) }
        catch { throw new Error('Native test harness exited before capture completed') }
      }
      if (existsSync(options.log)) {
        const size = statSync(options.log).size
        if (size < offset) throw new Error('Live navigation log was truncated during capture')
        if (size > offset) {
          const file = openSync(options.log, 'r')
          const chunk = Buffer.alloc(size - offset)
          let read = 0
          try { read = readSync(file, chunk, 0, chunk.length, offset) }
          finally { closeSync(file) }
          offset += read
          const lines = (remainder + chunk.subarray(0, read).toString()).split('\n')
          remainder = lines.pop()!
          for (const line of lines) {
            if (timing.line(line, now())) {
              pending = (async () => {
                await Bun.sleep(750)
                signal.throwIfAborted()
                if (timing.releasedAt !== undefined) throw new Error('Hold ended before the independent capture started')
                const started = now()
                try { await capture(png, signal) }
                finally { timing.captured(started, now()) }
                await pngHash(png)
                finished = true
              })().catch(error => { failure = error })
            }
          }
        }
      }
      if (failure) throw failure
      if (timing.releasedAt !== undefined && finished) {
        timing.verify()
        const hash = new Bun.CryptoHasher('sha256').update(await Bun.file(png).arrayBuffer()).digest('hex')
        await Bun.write(join(options.output, 'receipt.json'), JSON.stringify({ ...receipt(true), sha256: hash }, null, 2))
        return
      }
      if (existsSync(options.done)) {
        doneAt ??= performance.now()
        if (performance.now() - doneAt > 500 && !pending)
          throw new Error('XCTest finished without a synthesized viewer hold')
        if (performance.now() - doneAt > 4000)
          throw new Error('XCTest finished without complete during-hold evidence')
      }
      await Bun.sleep(25)
    }
    throw new Error('Independent viewer capture exceeded the native job backstop')
  }
  catch (error) {
    await Bun.write(join(options.output, 'receipt.json'), JSON.stringify(receipt(false, String(error)), null, 2))
    throw error
  }
  finally {
    stop.abort()
    await pending
  }
}

/** Record before XCTest is released, then extract an actual frame captured during its real hold.
 * Screenshot RPCs can block while XCTest synthesizes a held touch; public simctl video
 * retains independently timestamped frames without making that RPC during the gesture.
 */
export async function captureHeldViewerVideo(options: CaptureOptions, dependencies: {
  command?: typeof nativeFixtureCommand
  prepare?: () => Promise<ResolvedScreenshotTool>
  now?: () => number
} = {}): Promise<void> {
  if (![options.log, options.output, options.done].every(isAbsolute) || !/^[\da-f-]{36}$/i.test(options.simulator))
    throw new Error('Viewer capture needs absolute evidence paths and a simulator UUID')
  let offset = options.startOffset ?? 0
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('Invalid live log offset')
  mkdirSync(options.output, { recursive: true })
  const timing = new HeldViewerTiming()
  const command = dependencies.command ?? nativeFixtureCommand
  const now = dependencies.now ?? (() => Date.now() / 1000)
  const stop = new AbortController()
  const signal = options.signal ? AbortSignal.any([stop.signal, options.signal]) : stop.signal
  const png = join(options.output, 'during-hold.png'), movie = join(options.output, 'held-screen.mov')
  const recordReady = join(options.output, 'recording-ready'), recordStop = join(options.output, 'recording-stop')
  const recordReceipt = join(options.output, 'recording.json'), frameReceipt = join(options.output, 'frame.json')
  let extractor: string | undefined, extractorBuild: Awaited<ReturnType<typeof verifyHeldViewerExtractor>> | undefined
  const setupDeadline = performance.now() + 30_000
  const deadline = performance.now() + (options.timeoutMs ?? 45 * 60_000)
  let recordingResult: Awaited<ReturnType<typeof nativeFixtureCommand>> | undefined
  let recordingFailure: unknown, recording: Promise<void> | undefined
  let tool: ResolvedScreenshotTool | undefined
  let remainder = '', doneAt: number | undefined
  const receipt = (verifiedDuringHold: boolean, error?: string) => ({
    verifiedDuringHold, error, method: 'public-simctl-recordVideo-decoded-frame', timing,
    simulator: options.simulator, screenshot: png, movie, recording: recordReceipt, frame: frameReceipt,
    recordingResult, resolvedTool: tool, extractorBuild, extractorManifest: options.extractorManifest,
    compositorStimulus: 'Opt-in native ActivityIndicator in the maintained test fixture; no system display override.',
    preflight: join(options.output, 'preflight.json'),
    beforeAfter: ['XCTest attachment: Large content viewer before hold', 'XCTest attachment: Large content viewer after release'],
    visualReviewRequired: 'The actual decoded during-hold PNG must show the system Large Content Viewer.',
  })
  try {
    const publicReady = options.ready ?? join(options.output, 'preflight-ready')
    if (!isAbsolute(publicReady)) throw new Error('Viewer readiness path must be absolute')
    if ([publicReady, movie, recordReady, recordStop, recordReceipt, frameReceipt].some(existsSync))
      throw new Error('Viewer recording evidence already exists; use a fresh result directory')
    if (!options.extractorManifest || !isAbsolute(options.extractorManifest))
      throw new Error('Viewer capture requires its verified fixture-build extractor manifest')
    extractorBuild = await verifyHeldViewerExtractor(options.extractorManifest, options.output)
    extractor = extractorBuild.path
    // Keep the runner blocked until both the old positive control and actual
    // recording first-frame acknowledgement succeed within the same setup budget.
    tool = await (dependencies.prepare ?? (() => prepareHeldViewerCapture({ ...options, signal, ready: join(options.output, 'screenshot-control-ready') })))()
    recording = command([process.execPath, join(import.meta.dir, 'held-viewer-record.ts'), tool.simctl,
      options.simulator, movie, recordReady, recordStop, recordReceipt], {
      cwd: options.output, timeoutMs: Math.max(1, Math.floor(deadline - performance.now())), signal,
    }).then(result => { recordingResult = result }, error => { recordingFailure = error })
    while (!existsSync(recordReady)) {
      signal.throwIfAborted()
      if (recordingFailure) throw recordingFailure
      if (recordingResult) throw new Error(`Public recording exited before readiness: ${JSON.stringify(recordingResult)}`)
      if (performance.now() >= setupDeadline) throw new Error('Public recording was not ready within its shared setup budget')
      await Bun.sleep(25)
    }
    const anchor = await Bun.file(recordReceipt).json()
    if (!Number.isFinite(anchor.spawnWall) || !Number.isFinite(anchor.readyWall) || anchor.spawnWall > anchor.readyWall)
      throw new Error('Public recording first-frame anchor is invalid')
    await Bun.write(publicReady, 'Screenshot control and public recording first frame verified\n')
    while (performance.now() < deadline) {
      signal.throwIfAborted()
      if (recordingFailure) throw recordingFailure
      if (recordingResult) throw new Error(`Public recording ended before the held gesture: ${JSON.stringify(recordingResult)}`)
      if (options.parentPid) {
        try { process.kill(options.parentPid, 0) }
        catch { throw new Error('Native test harness exited before video evidence completed') }
      }
      if (existsSync(options.log)) {
        const size = statSync(options.log).size
        if (size < offset) throw new Error('Live navigation log was truncated during capture')
        if (size > offset) {
          const file = openSync(options.log, 'r'), chunk = Buffer.alloc(size - offset)
          let read = 0
          try { read = readSync(file, chunk, 0, chunk.length, offset) }
          finally { closeSync(file) }
          offset += read
          const lines = (remainder + chunk.subarray(0, read).toString()).split('\n')
          remainder = lines.pop()!
          for (const line of lines) timing.line(line, now())
        }
      }
      if (timing.releasedAt !== undefined) {
        const { beganAt, synthesisObservedAt, releasedAt } = timing
        if (beganAt === undefined || synthesisObservedAt === undefined
          || beganAt > synthesisObservedAt || releasedAt - synthesisObservedAt < 5.5)
          throw new Error('Missing actual six-second synthesized hold evidence')
        await Bun.write(recordStop, 'Actual synthesized hold released\n')
        await recording
        if (recordingFailure) throw recordingFailure
        const finalized = recordingResult as Awaited<ReturnType<typeof nativeFixtureCommand>> | undefined
        if (!finalized || finalized.code !== 0 || finalized.timedOut || finalized.cancelled)
          throw new Error(`Public recording did not finalize normally: ${JSON.stringify(finalized)}`)
        const record = await Bun.file(recordReceipt).json()
        if (!record.completed || !Number.isFinite(record.spawnWall) || !Number.isFinite(record.readyWall)
          || record.readyWall >= synthesisObservedAt)
          throw new Error('Recording first frame did not precede actual synthesized hold')
        const result = await command([extractor, movie, png, frameReceipt,
          String(record.spawnWall), String(record.readyWall), String(synthesisObservedAt), String(releasedAt)], {
          cwd: options.output, timeoutMs: 30_000, signal,
        })
        if (result.code !== 0 || result.timedOut || result.cancelled)
          throw new Error(`Actual during-hold frame extraction failed: ${JSON.stringify(result)}`)
        const frame = await Bun.file(frameReceipt).json()
        if (!frame.verified) throw new Error('Video extractor did not verify an actual during-hold frame')
        if (frame.recordSpawnWall !== record.spawnWall || frame.recordingStartedObservedWall !== record.readyWall
          || frame.synthesisWall !== synthesisObservedAt || frame.releasedWall !== releasedAt)
          throw new Error('Frame timing does not match the original recording and held gesture')
        const validated = validateHeldVideoFrame(frame)
        const sha256 = await pngHash(png)
        if (sha256 !== frame.pngSha256) throw new Error('Extracted PNG differs from the frame receipt')
        const movieHasher = new Bun.CryptoHasher('sha256')
        for await (const chunk of Bun.file(movie).stream()) movieHasher.update(chunk)
        const movieSha256 = movieHasher.digest('hex')
        if (movieSha256 !== frame.movieSha256) throw new Error('Original movie differs from the frame receipt')
        await Bun.write(join(options.output, 'receipt.json'), JSON.stringify({ ...receipt(true), sha256, movieSha256, validated }, null, 2))
        return
      }
      if (existsSync(options.done)) {
        doneAt ??= performance.now()
        if (performance.now() - doneAt > 500) throw new Error('XCTest finished without a complete synthesized viewer hold')
      }
      await Bun.sleep(25)
    }
    throw new Error('Independent video capture exceeded the native job backstop')
  }
  catch (error) {
    stop.abort()
    await recording
    await Bun.write(join(options.output, 'receipt.json'), JSON.stringify(receipt(false, String(error)), null, 2))
    throw error
  }
  finally {
    stop.abort()
    await recording
  }
}

if (import.meta.main) {
  const [log, simulator, output, done, rawOffset, rawParent, ready, extractorManifest] = process.argv.slice(2)
  const controller = new AbortController()
  const cancel = () => controller.abort()
  process.once('SIGTERM', cancel)
  process.once('SIGINT', cancel)
  try {
    if (!log || !simulator || !output || !done) throw new Error('Expected live log, simulator, evidence directory, completion marker and offset')
    await captureHeldViewerVideo({ log, simulator, output, done, startOffset: Number(rawOffset ?? 0), parentPid: Number(rawParent) || undefined, signal: controller.signal, ready, extractorManifest })
  }
  catch (error) { console.error(error); process.exitCode = 1 }
  finally { process.off('SIGTERM', cancel); process.off('SIGINT', cancel) }
}
