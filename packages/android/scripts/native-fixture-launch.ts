/** Intent transport and first native draw have different ownership boundaries. */
export async function launchAndroidNativeFixture(options: {
  label: string
  packageName: string
  readyText: string
  adb: (...args: string[]) => string[]
  run: (label: string, args: string[], timeoutMs: number) => Promise<string>
  waitForUi: (text: string, label: string, deadline: number) => Promise<string>
  now?: () => number
}): Promise<{ pid: string, xml: string, elapsedMs: number, boundMs: number }> {
  const now = options.now ?? (() => performance.now())
  const started = now(), boundMs = 30000, deadline = started + boundMs
  const remaining = () => {
    const value = Math.floor(deadline - now())
    if (!Number.isFinite(value) || value <= 0) throw new Error('Native activity readiness exceeded its original 30000ms bound')
    return value
  }
  // -W would spend the native draw wait inside the ordinary command's 10s cap.
  // Observe the real UI explicitly, sharing one 30s budget with intent and PID.
  await options.run(`${options.label}-launch`, options.adb('shell', 'am', 'start', '-n', `${options.packageName}/.MainActivity`), Math.min(10000, remaining()))
  const xml = await options.waitForUi(options.readyText, options.label, deadline)
  remaining()
  if (!xml.includes(`package="${options.packageName}"`)) throw new Error('Native readiness belongs to a different application')
  const pid = (await options.run(`${options.label}-pid`, options.adb('shell', 'pidof', options.packageName), Math.min(10000, remaining()))).trim()
  remaining()
  if (!/^[1-9]\d*$/.test(pid)) throw new Error('Expected exactly one fixture app process')
  return { pid, xml, elapsedMs: now() - started, boundMs }
}

/** Capture one native UI observation inside the existing command budget. */
export async function captureAndroidNativeUi(options: {
  label: string
  adb: (...args: string[]) => string[]
  run: (label: string, args: string[], timeoutMs: number) => Promise<string>
  deadline: number
  now?: () => number
}): Promise<string | null> {
  const now = options.now ?? (() => performance.now())
  const deadline = Math.min(options.deadline, now() + 10000)
  const remaining = () => {
    const value = Math.floor(deadline - now())
    if (!Number.isFinite(value) || value <= 0) throw new Error(`Native UI capture exceeded its original bound: ${options.label}`)
    return value
  }
  const path = `/data/local/tmp/craft-checkpoint-${crypto.randomUUID()}.xml`
  const output = await options.run(`${options.label}-dump`, options.adb('shell', 'uiautomator', 'dump', '--compressed', path), remaining())
  remaining()
  // Android reports this pre-draw state with status zero and writes no file.
  // It is an observation of no tree, never permission to read a stale tree.
  if (output.trim() === 'ERROR: null root node returned by UiTestAutomationBridge.') return null
  if (!output.includes(`UI hierchary dumped to: ${path}`)) throw new Error(`Native UI dump did not produce a tree: ${options.label}`)
  const xml = await options.run(`${options.label}-xml`, options.adb('shell', 'cat', path), remaining())
  remaining()
  if (!/^\s*<\?xml\b/.test(xml) || !/<hierarchy\b[^>]*>/.test(xml) || !/<\/hierarchy>\s*$/.test(xml)) throw new Error(`Native UI dump produced an invalid tree: ${options.label}`)
  await options.run(`${options.label}-remove`, options.adb('shell', 'rm', path), remaining())
  remaining()
  return xml
}

/** Read display/process state after failure; never request another frame or retry acceptance. */
export async function captureAndroidNativeDiagnostics(options: {
  packageName: string
  adb: (...args: string[]) => string[]
  run: (label: string, args: string[], timeoutMs: number) => Promise<string>
  now?: () => number
}): Promise<Array<{ name: string, status: 'captured' | 'failed', error?: string }>> {
  const now = options.now ?? (() => performance.now())
  const deadline = now() + 8000
  const results: Array<{ name: string, status: 'captured' | 'failed', error?: string }> = []
  const commands = [
    ['display-surfaceflinger', ['dumpsys', 'SurfaceFlinger']],
    ['display-app-frames', ['dumpsys', 'gfxinfo', options.packageName]],
    ['display-windows', ['dumpsys', 'window', 'windows']],
    ['display-processes', ['ps', '-A', '-o', 'PID,PPID,USER,NAME,STAT,WCHAN']],
  ] as const
  for (const [name, args] of commands) {
    const remaining = Math.floor(deadline - now())
    if (remaining <= 0) break
    try {
      await options.run(name, options.adb('shell', ...args), Math.min(2000, remaining))
      results.push({ name, status: 'captured' })
    }
    catch (error) { results.push({ name, status: 'failed', error: String(error).slice(0, 400) }) }
  }
  return results
}
