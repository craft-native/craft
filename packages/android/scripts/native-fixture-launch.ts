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
