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
}> {
  if (process.platform === 'win32') throw new Error('Native fixture command ownership requires POSIX process groups')
  if (!args.length || !Number.isSafeInteger(options.timeoutMs) || options.timeoutMs <= 0) throw new Error('Expected a command and a positive integer timeout')
  options.signal?.throwIfAborted()
  const descriptor = options.logPath ? openSync(options.logPath, 'wx', 0o600) : undefined
  try {
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
    const output = Promise.all([
      typeof child.stdout === 'number' ? '' : new Response(child.stdout).text(),
      typeof child.stderr === 'number' ? '' : new Response(child.stderr).text(),
    ])
    try {
      const code = await child.exited
      // A child can outlive an already reaped parent and keep its pipe open.
      // Dispose the group before awaiting EOF or releasing the workspace.
      await disposeGroup(child.pid)
      const [stdout, stderr] = await output
      return { code, signal: child.signalCode, stdout, stderr, timedOut, cancelled, processGroup: child.pid, groupDisposed: true }
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
