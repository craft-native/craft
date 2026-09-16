import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const HERE = import.meta.dir

export interface CommandOptions {
  cwd?: string
  /** Append the command line and its output here, for the evidence upload. */
  logPath?: string
  /** Record the failure and carry on, for teardown steps whose failure is not the story. */
  allowFailure?: boolean
  stdin?: string
  /** Added to the inherited environment, not a replacement for it. */
  env?: Record<string, string>
  /**
   * Write raw stdout bytes here instead of returning them as text.
   *
   * `adb exec-out screencap -p` emits a PNG; decoding that as UTF-8 to hand it
   * back as a string is how a screenshot becomes an unopenable file.
   */
  outPath?: string
}

export interface CommandResult {
  exitCode: number
  stdout: string
  stderr: string
}

/**
 * Run a command, keep its output, and fail loudly by default.
 *
 * Everything a leg does to a device goes through here so that the evidence
 * upload contains the actual command lines. A failing `xcodebuild` whose log
 * is three screens of Swift diagnostics is useless as an exception message and
 * invaluable as a file.
 */
export async function command(argv: string[], options: CommandOptions = {}): Promise<CommandResult> {
  const spawned = Bun.spawn(argv, {
    cwd: options.cwd,
    env: options.env ? { ...process.env, ...options.env } : undefined,
    stdin: options.stdin === undefined ? 'ignore' : new TextEncoder().encode(options.stdin),
    stdout: 'pipe',
    stderr: 'pipe',
  })

  const [raw, stderr] = await Promise.all([
    new Response(spawned.stdout).arrayBuffer(),
    new Response(spawned.stderr).text(),
  ])
  const exitCode = await spawned.exited

  if (options.outPath) writeFileSync(options.outPath, new Uint8Array(raw))
  const stdout = options.outPath ? '' : new TextDecoder().decode(raw)

  if (options.logPath) {
    appendFileSync(options.logPath, [
      `$ ${argv.join(' ')}`,
      options.cwd ? `# cwd ${options.cwd}` : '',
      stdout,
      stderr,
      `# exit ${exitCode}`,
      '',
    ].filter(Boolean).join('\n'))
  }

  if (exitCode !== 0 && !options.allowFailure) {
    const tail = `${stdout}\n${stderr}`.trim().split('\n').slice(-25).join('\n')
    throw new Error(`${argv.join(' ')} exited with ${exitCode}\n${tail}`)
  }

  return { exitCode, stdout, stderr }
}

/**
 * Wait for a file to say what we are waiting for.
 *
 * `refresh` exists because the two platforms deliver output differently: iOS
 * streams the app's stderr straight into the file, so there is nothing to do
 * between polls, while Android has to be asked - `adb logcat -d` dumps and
 * exits. Streaming logcat instead would mean killing it at exactly the right
 * moment, and the dump costs nothing.
 *
 * Returns false on the deadline rather than throwing, because a run that
 * produced no terminating event still has a log worth keeping and a screenshot
 * worth taking - and the caller does both before it decides anything. Throwing
 * here would skip the evidence for the failure that most needs it.
 */
export async function waitForFile(
  path: string,
  timeoutMs: number,
  done: (text: string) => boolean,
  refresh?: () => Promise<void>,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    if (refresh) await refresh()
    if (existsSync(path)) {
      const text = readFileSync(path, 'utf8')
      if (done(text)) return true
    }
    await Bun.sleep(refresh ? 1000 : 250)
  }

  return false
}

/**
 * The test page, with this run's nonce baked in.
 *
 * One page serves both platforms: `window.craft` is injected by each runtime
 * with the same shape, so the suite that runs on a simulator is the same file
 * that runs on an emulator, and a case can only diverge where it says it does.
 */
export function driverPage(nonce: string, platform: string): string {
  const template = readFileSync(join(HERE, 'driver.html'), 'utf8')

  // Both placeholders checked, because a silently unsubstituted one turns its
  // case into an assertion about a constant the page chose for itself.
  for (const placeholder of ['__CRAFT_E2E_NONCE__', '__CRAFT_E2E_PLATFORM__']) {
    if (!template.includes(placeholder))
      throw new Error(`driver.html no longer carries the ${placeholder} placeholder`)
  }

  return template
    .replaceAll('__CRAFT_E2E_NONCE__', nonce)
    .replaceAll('__CRAFT_E2E_PLATFORM__', platform)
}
