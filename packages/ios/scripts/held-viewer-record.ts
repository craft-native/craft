import { existsSync } from 'node:fs'
import { isAbsolute } from 'node:path'

export interface HeldRecordingOptions {
  simctl: string
  simulator: string
  movie: string
  ready: string
  stop: string
  receipt: string
}

/** The caller owns this host and simctl in one POSIX process group. */
export async function recordHeldViewer(options: HeldRecordingOptions): Promise<void> {
  if (![options.simctl, options.movie, options.ready, options.stop, options.receipt].every(isAbsolute)
    || !/^[\da-f-]{36}$/i.test(options.simulator))
    throw new Error('Expected absolute recording paths and a simulator UUID')
  if ([options.movie, options.ready, options.stop, options.receipt].some(existsSync))
    throw new Error('Refusing to overwrite retained recording evidence')
  const args = [options.simctl, 'io', options.simulator, 'recordVideo', '--codec=h264', options.movie]
  const spawnWall = Date.now() / 1000, spawnMonotonic = performance.now() / 1000
  const child = Bun.spawn(args, { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' })
  let readyWall: number | undefined, readyMonotonic: number | undefined, stopWall: number | undefined
  let stderr = '', stopped = false
  let code: number | undefined, failure: unknown
  const stdout = new Response(child.stdout).text()
  const errors = (async () => {
    for await (const chunk of child.stderr) {
      stderr += new TextDecoder().decode(chunk)
      if (readyWall === undefined && stderr.includes('Recording started')) {
        readyWall = Date.now() / 1000
        readyMonotonic = performance.now() / 1000
        await writeReceipt(false)
        await Bun.write(options.ready, 'Public simctl first frame acknowledged\n')
      }
    }
  })()
  void child.exited.then(value => { code = value }, error => { failure = error })
  async function writeReceipt(completed: boolean, error?: string) { return Bun.write(options.receipt, JSON.stringify({
    completed, error, args, spawnWall, spawnMonotonic, readyWall, readyMonotonic, stopWall,
    exitWall: completed ? Date.now() / 1000 : undefined, code, signal: child.signalCode,
    stderr, stdout: completed ? await stdout : undefined,
    firstFrameWallBracket: readyWall === undefined ? undefined : [spawnWall, readyWall],
  }, null, 2)) }
  const cancel = () => child.kill('SIGTERM')
  process.once('SIGTERM', cancel)
  process.once('SIGINT', cancel)
  try {
    const readyDeadline = performance.now() + 30_000
    while (!existsSync(options.stop)) {
      if (failure) throw failure
      if (code !== undefined) throw new Error(`Public video recording exited before its stop request (${code})`)
      if (readyWall === undefined && performance.now() >= readyDeadline)
        throw new Error('Public video recording never acknowledged its first frame')
      await Bun.sleep(25)
    }
    if (readyWall === undefined) throw new Error('Public video recording stopped before its first frame')
    stopWall = Date.now() / 1000
    child.kill('SIGINT')
    // SIGINT is simctl's documented normal movie finalization, not cancellation.
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const finalization = Promise.withResolvers<never>()
      timer = setTimeout(() => finalization.reject(new Error('Public video movie finalization exceeded 30 seconds')), 30_000)
      code = await Promise.race([child.exited, finalization.promise])
    }
    finally { clearTimeout(timer) }
    stopped = true
    await errors
    if (code !== 0) throw new Error(`Public video recording failed (${code}): ${stderr}`)
    await writeReceipt(true)
  }
  catch (error) {
    await writeReceipt(false, String(error))
    throw error
  }
  finally {
    process.off('SIGTERM', cancel)
    process.off('SIGINT', cancel)
    if (!stopped) {
      child.kill('SIGTERM')
      const force = setTimeout(() => child.kill('SIGKILL'), 250)
      await child.exited
      clearTimeout(force)
      await errors
    }
  }
}

if (import.meta.main) {
  const [simctl, simulator, movie, ready, stop, receipt] = process.argv.slice(2)
  if (!simctl || !simulator || !movie || !ready || !stop || !receipt)
    throw new Error('Expected public simctl, simulator, movie, readiness, stop and receipt paths')
  await recordHeldViewer({ simctl, simulator, movie, ready, stop, receipt })
}
