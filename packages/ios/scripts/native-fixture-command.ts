import { closeSync, openSync } from 'node:fs'

/** Normal native fixture compilation phase; separate from test/capture admission. */
export const nativeFixtureBuildTimeoutMs = 300_000

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
   */
  msSinceLastOutput: number
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
    const decoder = new TextDecoder()
    const drain = async (stream: ReadableStream<Uint8Array> | number | undefined): Promise<string> => {
      if (typeof stream === 'number' || !stream) return ''
      let text = ''
      for await (const chunk of stream as AsyncIterable<Uint8Array>) {
        lastOutputAt = performance.now()
        text += decoder.decode(chunk, { stream: true })
      }
      return text + decoder.decode()
    }
    const output = Promise.all([drain(child.stdout as never), drain(child.stderr as never)])
    try {
      const code = await child.exited
      // A child can outlive an already reaped parent and keep its pipe open.
      // Dispose the group before awaiting EOF or releasing the workspace.
      await disposeGroup(child.pid)
      const [stdout, stderr] = await output
      const endedAt = performance.now()
      return { code, signal: child.signalCode, stdout, stderr, timedOut, cancelled, processGroup: child.pid, groupDisposed: true,
        elapsedMs: endedAt - startedAt, msSinceLastOutput: endedAt - (lastOutputAt ?? startedAt) }
    }
    finally {
      clearTimeout(timer)
      if (forceKill) clearTimeout(forceKill)
      options.signal?.removeEventListener('abort', onAbort)
      process.off('exit', onExit)
    }
  }
  finally { if (descriptor !== undefined) closeSync(descriptor) }
}
