import { closeSync, fstatSync, openSync } from 'node:fs'

/** Normal native fixture compilation phase; separate from test/capture admission. */
export const nativeFixtureBuildTimeoutMs = 300_000

/**
 * How often the log file is measured when output is not on a pipe.
 *
 * Every real caller passes `logPath`, which hands the child the descriptor and
 * leaves the pipes empty — so without this the progress signal was only ever
 * observable in the tests that exercised the pipe path. Growth of the file is
 * the only evidence a file-logging command is still working.
 */
export const logProgressSampleMs = 100

export interface NativeFixtureCommandOptions {
  cwd: string
  timeoutMs: number
  logPath?: string
  signal?: AbortSignal
}

/** A later successful cleanup cannot erase an earlier missing disposal ACK. */
export class NativeFixtureCommandScope {
  private outstanding = 0
  get allDisposed(): boolean { return this.outstanding === 0 }

  async run(args: string[], options: NativeFixtureCommandOptions): ReturnType<typeof nativeFixtureCommand> {
    this.outstanding++
    const result = await nativeFixtureCommand(args, options)
    this.outstanding--
    return result
  }
}

function groupExists(pid: number): boolean {
  try { process.kill(-pid, 0); return true }
  catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'ESRCH') return false
    // Permission denial is not proof of disappearance. Keep waiting for
    // ESRCH within the same disposal budget, including during OS reaping.
    if (code === 'EPERM') return true
    throw error
  }
}

function signalGroup(pid: number, signal: NodeJS.Signals): void {
  try { process.kill(-pid, signal) }
  catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    // Neither result confirms disposal; disposeGroup must still see ESRCH.
    if (code !== 'ESRCH' && code !== 'EPERM') throw error
  }
}

async function disposeGroup(pid: number): Promise<void> {
  if (!groupExists(pid)) return
  signalGroup(pid, 'SIGTERM')
  const graceful = performance.now() + 250
  while (groupExists(pid) && performance.now() < graceful) await Bun.sleep(10)
  if (!groupExists(pid)) return
  signalGroup(pid, 'SIGKILL')
  const deadline = performance.now() + 1000
  while (groupExists(pid) && performance.now() < deadline) await Bun.sleep(10)
  if (groupExists(pid)) throw new Error('Native command process group remained after forced disposal')
}

/** Own the POSIX command group through completion, timeout and cancellation. */
export async function nativeFixtureCommand(args: string[], options: NativeFixtureCommandOptions): Promise<{
  code: number
  signal: string | null
  stdout: string
  stderr: string
  timedOut: boolean
  cancelled: boolean
  processGroup: number
  groupDisposed: true
  /** Wall time the command actually ran, whether it exited or was killed. */
  elapsedMs: number
  /**
   * How long the command had been silent when it ended.
   *
   * `timedOut` alone cannot tell a starved command from a stalled one: both
   * report the same boolean after the same deadline. A command still writing
   * when the timer fired was making progress too slowly, which is a host
   * problem; one silent for most of its budget was stuck, which is not
   * (#490). Equal to `elapsedMs` when it never wrote anything.
   *
   * On a pipe this is the arrival time of the last chunk. With `logPath` the
   * child writes to the descriptor and the pipes stay empty, so it is the
   * last sample at which the file had grown — accurate to
   * `logProgressSampleMs`, and never later than the write itself.
   */
  msSinceLastOutput: number
  /**
   * Bytes the command produced: chunks read from its pipes, or the final size
   * of its log file.
   *
   * The number behind `msSinceLastOutput`, and the one worth reporting: a
   * command killed on its deadline having written nothing is a different
   * failure from one killed having written megabytes.
   */
  outputBytes: number
}> {
  if (process.platform === 'win32') throw new Error('Native fixture command ownership requires POSIX process groups')
  if (!args.length || !Number.isSafeInteger(options.timeoutMs) || options.timeoutMs <= 0) throw new Error('Expected a command and a positive integer timeout')
  options.signal?.throwIfAborted()
  const descriptor = options.logPath ? openSync(options.logPath, 'wx', 0o600) : undefined
  try {
    const startedAt = performance.now()
    const child = Bun.spawn(args, { cwd: options.cwd, detached: true, stdin: 'ignore', stdout: descriptor ?? 'pipe', stderr: descriptor ?? 'pipe' })
    let timedOut = false, cancelled = false
    let forceKill: ReturnType<typeof setTimeout> | undefined
    const stop = () => {
      signalGroup(child.pid, 'SIGTERM')
      forceKill ??= setTimeout(() => signalGroup(child.pid, 'SIGKILL'), 250)
    }
    const onAbort = () => { cancelled = true; stop() }
    const onExit = () => signalGroup(child.pid, 'SIGKILL')
    const timer = setTimeout(() => { timedOut = true; stop() }, options.timeoutMs)
    options.signal?.addEventListener('abort', onAbort, { once: true })
    process.once('exit', onExit)
    // Read incrementally rather than with Response().text(): the arrival time
    // of the last chunk is what separates slow progress from no progress.
    let lastOutputAt: number | undefined
    let outputBytes = 0
    const decoder = new TextDecoder()
    const drain = async (stream: ReadableStream<Uint8Array> | number | undefined): Promise<string> => {
      if (typeof stream === 'number' || !stream) return ''
      let text = ''
      for await (const chunk of stream as AsyncIterable<Uint8Array>) {
        lastOutputAt = performance.now()
        outputBytes += chunk.byteLength
        text += decoder.decode(chunk, { stream: true })
      }
      return text + decoder.decode()
    }
    // With a log file the pipes stay empty, so the file's growth is the
    // progress signal. Only growth moves the timestamp: a command that has
    // stopped writing still reads as silent however often this samples.
    const sampleLog = descriptor === undefined
      ? () => {}
      : () => {
          try {
            const size = fstatSync(descriptor).size
            if (size > outputBytes) { outputBytes = size; lastOutputAt = performance.now() }
          }
          catch { /* already closed; the receipt keeps what it saw */ }
        }
    const sampler = descriptor === undefined ? undefined : setInterval(sampleLog, logProgressSampleMs)
    const output = Promise.all([drain(child.stdout as never), drain(child.stderr as never)])
    try {
      const code = await child.exited
      // Anything written between the last sample and the exit still counts.
      sampleLog()
      // A child can outlive an already reaped parent and keep its pipe open.
      // Dispose the group before awaiting EOF or releasing the workspace.
      await disposeGroup(child.pid)
      const [stdout, stderr] = await output
      const endedAt = performance.now()
      return { code, signal: child.signalCode, stdout, stderr, timedOut, cancelled, processGroup: child.pid, groupDisposed: true,
        elapsedMs: endedAt - startedAt, msSinceLastOutput: endedAt - (lastOutputAt ?? startedAt), outputBytes }
    }
    finally {
      clearTimeout(timer)
      if (sampler) clearInterval(sampler)
      if (forceKill) clearTimeout(forceKill)
      options.signal?.removeEventListener('abort', onAbort)
      process.off('exit', onExit)
    }
  }
  finally { if (descriptor !== undefined) closeSync(descriptor) }
}

/**
 * The fraction of a command's budget it may be silent for and still count as
 * having been making progress when the deadline fired.
 *
 * Any threshold here is a judgement, so the message states the measured
 * numbers alongside the label rather than only the label.
 */
export const starvedSilenceFraction = 0.25

/** What a failing fixture command's receipt says, in one line for a CI log. */
export function describeFixtureCommandFailure(name: string, result: {
  code: number
  timedOut: boolean
  cancelled: boolean
  groupDisposed?: boolean
  elapsedMs: number
  msSinceLastOutput: number
  outputBytes: number
}, logPath: string): string {
  const ms = (value: number) => `${Math.round(value)} ms`
  const wrote = `${result.outputBytes} bytes written`
  const where = `see ${logPath}`
  if (result.cancelled) return `${name} was cancelled after ${ms(result.elapsedMs)} (${wrote}); ${where}`
  if (result.timedOut) {
    // The distinction #447 measured and #490 kept asking for: a command still
    // writing when the timer fired was too slow, which is the host's problem;
    // one silent for most of its budget was stuck, which is not.
    const starved = result.outputBytes > 0 && result.msSinceLastOutput <= result.elapsedMs * starvedSilenceFraction
    const verdict = starved
      ? `still producing output when it was killed, so it was starved rather than stalled`
      : result.outputBytes === 0
        ? `never produced any output, so nothing shows it started work`
        : `silent for most of its budget, so it was stalled rather than starved`
    return `${name} timed out after ${ms(result.elapsedMs)}, last wrote ${ms(result.msSinceLastOutput)} before the end (${wrote}) — ${verdict}; ${where}`
  }
  if (result.groupDisposed === false) return `${name} left its process group undisposed after ${ms(result.elapsedMs)}; ${where}`
  return `${name} failed (${result.code}) after ${ms(result.elapsedMs)} (${wrote}); ${where}`
}
