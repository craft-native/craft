import { closeSync, openSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

interface NativeWindowsCommandOptions {
  cwd: string
  timeoutMs: number
  logPath?: string
  signal?: AbortSignal
  env?: NodeJS.ProcessEnv
}
export interface NativeWindowsCommandResult {
  code: number
  processId: number
  timedOut: boolean
  cancelled: boolean
  jobDisposed: true
  osError: number
  stdout: string
  stderr: string
}

/** Execute through a prebuilt first-party owner, never a shell or taskkill. */
export async function nativeWindowsCommand(ownerBinary: string, args: string[], options: NativeWindowsCommandOptions): Promise<NativeWindowsCommandResult> {
  if (process.platform !== 'win32') throw new Error('Native Windows command ownership requires Windows Job Objects')
  if (!args.length || !Number.isSafeInteger(options.timeoutMs) || options.timeoutMs <= 0 || options.timeoutMs > 1_800_000) throw new Error('Expected a command and a bounded positive timeout')
  options.signal?.throwIfAborted()
  const owner = realpathSync(ownerBinary)
  const executable = Bun.which(args[0]!, { PATH: options.env?.PATH ?? process.env.PATH })
  if (!executable) throw new Error(`Native command executable is unavailable: ${args[0]}`)
  const directory = await mkdtemp(join(tmpdir(), 'craft-windows-command-'))
  const receiptPath = join(directory, 'receipt.json'), cancellationPath = join(directory, 'cancel')
  let descriptor: number | undefined
  let disposed = false
  let cancellationFailure: unknown
  try {
    descriptor = options.logPath ? openSync(options.logPath, 'wx', 0o600) : undefined
    const child = Bun.spawn([owner, String(process.pid), String(options.timeoutMs), receiptPath, cancellationPath, executable, ...args.slice(1)], {
      cwd: options.cwd, env: options.env, stdin: 'ignore', stdout: descriptor ?? 'pipe', stderr: descriptor ?? 'pipe',
    })
    const output = Promise.all([
      typeof child.stdout === 'number' ? '' : new Response(child.stdout).text(),
      typeof child.stderr === 'number' ? '' : new Response(child.stderr).text(),
    ])
    const cancel = () => {
      try { writeFileSync(cancellationPath, '', { flag: 'wx', mode: 0o600 }) }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'EEXIST') return
        cancellationFailure = error
        // The owner's last Job Object handle closes with this process. Keep
        // its workspace because a killed owner cannot acknowledge disposal.
        try { child.kill() }
        catch (killError) { cancellationFailure = new AggregateError([error, killError], 'Cannot signal the native Windows owner') }
      }
    }
    options.signal?.addEventListener('abort', cancel, { once: true })
    if (options.signal?.aborted) cancel()
    try {
      const code = await child.exited
      const [stdout, stderr] = await output
      const receipt = JSON.parse(readFileSync(receiptPath, 'utf8')) as NativeWindowsCommandResult
      const uint32 = (value: unknown) => Number.isInteger(value) && Number(value) >= 0 && Number(value) <= 0xffffffff
      if (!uint32(receipt.code) || !uint32(receipt.processId) || !uint32(receipt.osError)
        || typeof receipt.timedOut !== 'boolean' || typeof receipt.cancelled !== 'boolean' || receipt.jobDisposed !== true) throw new Error('Native Windows owner returned no complete disposal receipt')
      disposed = true
      if (code !== 0 || receipt.osError !== 0 || cancellationFailure) throw new Error(`Native Windows command owner failed (${code}, OS ${receipt.osError}): ${String(cancellationFailure ?? '')}`)
      return { ...receipt, stdout, stderr }
    }
    finally { options.signal?.removeEventListener('abort', cancel) }
  }
  finally {
    if (descriptor !== undefined) closeSync(descriptor)
    if (disposed) await rm(directory, { recursive: true, force: true })
    else console.error(`Native Windows ownership evidence retained: ${directory}`)
  }
}
