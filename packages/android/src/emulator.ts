import { appendFileSync, closeSync, mkdirSync, mkdtempSync, openSync, rmSync } from 'node:fs'
import { availableParallelism, cpus, tmpdir, totalmem } from 'node:os'
import { basename, isAbsolute, join, resolve } from 'node:path'

export interface AndroidEmulatorOptions {
  sdkRoot: string
  sdkmanager: string
  avdmanager: string
  image: string
  acceleration: 'hardware' | 'software'
  artifactsDirectory: string
  temporaryDirectory?: string
  port?: number
  acceptLicenses?: boolean
  /** Defaults to 10 minutes; hardware is capped there, software cold provisioning at 20 minutes. */
  bootTimeoutMs?: number
  /** Requested guest RAM, 1536–8192 MB (Android emulator limits); defaults to 2048. */
  memoryMb?: number
  /** Requested guest CPU count, 1–8; defaults to 2. */
  virtualCpus?: number
  env?: Record<string, string | undefined>
}

export interface AndroidEmulatorSession {
  serial: string
  adb: string
  env: Record<string, string | undefined>
  /** Stops only this session's process and removes only its disposable AVD. */
  dispose: () => Promise<void>
}

/** Provision and own a real Android emulator on a macOS or Linux SDK host. */
export async function createAndroidEmulator(options: AndroidEmulatorOptions): Promise<AndroidEmulatorSession> {
  if (!['darwin', 'linux'].includes(process.platform)) throw new Error('Android emulator sessions require macOS or Linux')
  if (!['hardware', 'software'].includes(options.acceleration)) throw new Error('Select hardware or software Android emulation explicitly')
  if (![options.sdkmanager, options.avdmanager].every(isAbsolute)) throw new Error('Select absolute Android command-line tool paths')
  const abi = process.arch === 'arm64' ? 'arm64-v8a' : process.arch === 'x64' ? 'x86_64' : undefined
  if (!abi || !/^system-images;android-\d+;[^;\s]+;[^;\s]+$/.test(options.image) || !options.image.endsWith(`;${abi}`))
    throw new Error('The Android system image must match the host architecture')
  if (options.acceleration === 'software' && process.arch !== 'x64')
    throw new Error('Android software emulation requires an x86_64 host and system image')
  const bootTimeoutMs = options.bootTimeoutMs ?? 600_000
  const requiresPlayStore = options.image.split(';')[2] === 'google_apis_playstore'
  const maximumBootTimeoutMs = options.acceleration === 'software' ? 1_200_000 : 600_000
  if (!Number.isSafeInteger(bootTimeoutMs) || bootTimeoutMs < 1000 || bootTimeoutMs > maximumBootTimeoutMs)
    throw new Error(`Android bootTimeoutMs must be an integer between 1000 and ${maximumBootTimeoutMs} milliseconds`)
  const memoryMb = options.memoryMb ?? 2048
  if (!Number.isSafeInteger(memoryMb) || memoryMb < 1536 || memoryMb > 8192)
    throw new Error('Android memoryMb must be an integer between 1536 and 8192 megabytes')
  const virtualCpus = options.virtualCpus ?? 2
  if (!Number.isSafeInteger(virtualCpus) || virtualCpus < 1 || virtualCpus > 8)
    throw new Error('Android virtualCpus must be an integer between 1 and 8')
  const port = options.port ?? 5558
  if (!Number.isInteger(port) || port < 5554 || port > 5682 || port % 2 !== 0) throw new Error('Android console ports must be even and between 5554 and 5682')
  const sdk = resolve(options.sdkRoot)
  const artifacts = resolve(options.artifactsDirectory)
  const temporary = options.temporaryDirectory ?? tmpdir()
  mkdirSync(artifacts, { recursive: true })
  mkdirSync(temporary, { recursive: true })
  const owned = mkdtempSync(join(temporary, 'craft-android-emulator-'))
  const name = basename(owned)
  const serial = `emulator-${port}`
  const env: Record<string, string | undefined> = {
    ...process.env, ...options.env,
    ANDROID_HOME: sdk,
    ANDROID_SDK_ROOT: sdk,
    ANDROID_SDK_HOME: owned,
    ANDROID_USER_HOME: join(owned, '.android'),
    ANDROID_EMULATOR_HOME: join(owned, '.android'),
    ANDROID_AVD_HOME: join(owned, 'avd'),
    ANDROID_SERIAL: serial,
    // avdmanager uses this location to resolve --package against sdkRoot,
    // even when Pantry installed the command-line tools in a separate prefix.
    AVDMANAGER_OPTS: `'-Dcom.android.sdkmanager.toolsdir=${join(sdk, 'cmdline-tools/latest')}'`,
  }
  const adb = join(sdk, 'platform-tools/adb')
  const executable = join(sdk, 'emulator/emulator')
  let child: ReturnType<typeof Bun.spawn> | undefined
  let log: number | undefined
  let created = false
  let sequence = 0
  let disposal: Promise<void> | undefined
  let bootStartedAt = 0
  let cpuStart = 0
  let idleStart = 0
  let identity: Record<string, unknown> | undefined
  async function recordBootResult(status: 'booted' | 'failed', endedAt = Date.now()): Promise<void> {
    if (!identity) return
    const cpuEnd = cpus()
    const totalDeltaMs = cpuEnd.reduce((total, cpu) => total + Object.values(cpu.times).reduce((sum, value) => sum + value, 0), 0) - cpuStart
    const idleDeltaMs = cpuEnd.reduce((total, cpu) => total + cpu.times.idle, 0) - idleStart
    await Bun.write(join(artifacts, 'android-emulator.json'), JSON.stringify({
      ...identity, status, [status === 'booted' ? 'bootedAt' : 'failedAt']: new Date(endedAt).toISOString(),
      bootElapsedMs: endedAt - bootStartedAt,
      hostCpuInterval: { totalDeltaMs, idleDeltaMs, busyDeltaMs: totalDeltaMs - idleDeltaMs },
    }, null, 2) + '\n')
  }
  async function run(args: string[], input?: string, timeout = 900_000, allowFailure = false): Promise<{ code: number, stdout: string }> {
    const startedAt = new Date().toISOString()
    const command = Bun.spawn(args, { env, stdin: input === undefined ? 'ignore' : new TextEncoder().encode(input), stdout: 'pipe', stderr: 'pipe', signal: AbortSignal.timeout(timeout) })
    const [code, stdout, stderr] = await Promise.all([command.exited, new Response(command.stdout).text(), new Response(command.stderr).text()])
    // A cold boot may need hundreds of ADB readiness polls. Keep their full
    // diagnostics together so artifact collectors can retain the emulator log.
    appendFileSync(join(artifacts, 'device-commands.jsonl'), JSON.stringify({ sequence: ++sequence, startedAt, finishedAt: new Date().toISOString(), args, code, stdout, stderr }) + '\n')
    if (code !== 0 && !allowFailure) throw new Error(`${basename(args[0]!)} failed with exit ${code}; inspect ${artifacts}`)
    return { code, stdout }
  }
  const dispose = (): Promise<void> => disposal ??= (async () => {
    try {
      if (child && child.exitCode === null) {
        child.kill('SIGTERM')
        await Promise.race([child.exited, Bun.sleep(10_000)])
        if (child.exitCode === null) child.kill('SIGKILL')
        await child.exited
      }
      if (created) await run([options.avdmanager, 'delete', 'avd', '--name', name], undefined, 30_000)
    }
    finally {
      if (log !== undefined) closeSync(log)
      rmSync(owned, { recursive: true, force: true })
    }
  })()
  try {
    mkdirSync(env.ANDROID_AVD_HOME!, { recursive: true })
    mkdirSync(env.ANDROID_USER_HOME!, { recursive: true })
    if (options.acceptLicenses) await run([options.sdkmanager, `--sdk_root=${sdk}`, '--licenses'], 'y\n'.repeat(100))
    // Preserve the vendor download URL and exception details in the command
    // artifact when SDK provisioning fails before an emulator can start.
    await run([options.sdkmanager, `--sdk_root=${sdk}`, '--verbose', 'platform-tools', 'emulator'], options.acceptLicenses ? 'y\n'.repeat(100) : undefined)
    const acceleration = await run([executable, '-accel-check'], undefined, 30_000, true)
    if (options.acceleration === 'hardware' && acceleration.code !== 0)
      throw new Error(`Android hardware acceleration is unavailable; inspect ${artifacts}`)
    await run([options.sdkmanager, `--sdk_root=${sdk}`, '--verbose', options.image], options.acceptLicenses ? 'y\n'.repeat(100) : undefined)
    const devices = (await run([adb, 'devices'], undefined, 10_000)).stdout
    if (devices.split('\n').some(line => line.startsWith(`${serial}\t`))) throw new Error(`${serial} is already in use`)
    await run([options.avdmanager, 'create', 'avd', '--name', name, '--package', options.image, '--device', 'pixel_6'], 'no\n')
    created = true
    log = openSync(join(artifacts, 'emulator.log'), 'w')
    bootStartedAt = Date.now()
    const hostCpus = cpus()
    cpuStart = hostCpus.reduce((total, cpu) => total + Object.values(cpu.times).reduce((sum, value) => sum + value, 0), 0)
    idleStart = hostCpus.reduce((total, cpu) => total + cpu.times.idle, 0)
    child = Bun.spawn([executable, '-avd', name, '-port', String(port), '-no-window', '-no-snapshot', '-no-audio', '-no-boot-anim', '-gpu', 'software', '-memory', String(memoryMb), '-cores', String(virtualCpus), '-accel', options.acceleration === 'software' ? 'off' : 'on'], { env, stdout: log, stderr: log })
    identity = {
      image: options.image, acceleration: options.acceleration, accelerationProbeExitCode: acceleration.code,
      bootTimeoutMs, bootStartedAt: new Date(bootStartedAt).toISOString(),
      host: { cpuModel: hostCpus[0]?.model, logicalCpus: hostCpus.length, availableParallelism: availableParallelism(), memoryBytes: totalmem() },
      virtualCpus, memoryMb, serial, avdDirectory: env.ANDROID_AVD_HOME, emulatorPid: child.pid,
    }
    await Bun.write(join(artifacts, 'android-emulator.json'), JSON.stringify(identity, null, 2) + '\n')
    const deadline = bootStartedAt + bootTimeoutMs
    const probeTimeout = (): number => Math.max(1, Math.min(10_000, deadline - Date.now()))
    let connected = false
    let lastReconnectAt = 0
    while (Date.now() < deadline && child.exitCode === null) {
      let booted = false
      // Nonzero ADB exits are expected while services initialize. Filesystem,
      // logging and process-launch errors must remain fatal and visible.
      const connection = await run([adb, 'devices'], undefined, probeTimeout(), true)
      const state = connection.stdout.split(/\r?\n/).find(line => line.startsWith(`${serial}\t`))?.split(/\s+/)[1]
      // A cold boot can restart adbd after its initial connection. Recover the
      // owned stale transport without restarting the shared server or touching
      // other devices. A never-connected guest still needs to finish booting.
      if (connection.code === 0 && state === 'offline' && connected && Date.now() - lastReconnectAt >= 30_000 && Date.now() < deadline) {
        lastReconnectAt = Date.now()
        await run([adb, '-s', serial, 'reconnect'], undefined, probeTimeout(), true)
      }
      if (connection.code === 0 && state === 'device') {
        connected = true
        const completion = await run([adb, '-s', serial, 'shell', 'getprop', 'sys.boot_completed'], undefined, probeTimeout(), true)
        if (completion.code === 0 && completion.stdout.trim() === '1') {
          // boot_completed can precede SettingsProvider and System UI readiness.
          const settings = await run([adb, '-s', serial, 'shell', 'settings', 'get', 'global', 'animator_duration_scale'], undefined, probeTimeout(), true)
          const packages = await run([adb, '-s', serial, 'shell', 'pm', 'path', 'android'], undefined, probeTimeout(), true)
          // A stock Play image can expose the framework package and HOME while
          // first-boot provisioning is still registering its bundled apps.
          const playStore = requiresPlayStore
            ? await run([adb, '-s', serial, 'shell', 'pm', 'path', 'com.android.vending'], undefined, probeTimeout(), true)
            : undefined
          const systemUi = await run([adb, '-s', serial, 'shell', 'pidof', 'com.android.systemui'], undefined, probeTimeout(), true)
          // Native acceptance must be able to observe platform crashes before
          // launching any app. boot_completed/System UI can precede logd's ADB
          // event stream. Require a complete history read so a partial transport
          // read cannot admit the device before its first health check.
          const events = await run([adb, '-s', serial, 'logcat', '-b', 'events', '-d', '-v', 'threadtime'], undefined, probeTimeout(), true)
          if (events.code === 0 && /^\S+\s+\S+\s+\d+\s+\d+\s+[A-Z]\s+am_(?:anr|crash)\s*:/m.test(events.stdout))
            throw new Error(`Android emulator reported a platform ANR or crash during boot; inspect ${artifacts}`)
          // AOSP's first boot can report all those services ready while its
          // automatic SDK setup activity still owns HOME. Launching HOME then
          // opens that transient activity; after it finishes UI automation has
          // AOSP and stock Play first boots can report those services ready
          // while their automatic SDK setup activity still owns HOME. Launching
          // HOME then opens that transient activity; after it finishes UI automation has
          // no foreground root. Wait for the real HOME destination instead of
          // modifying device setup or relaxing native acceptance.
          const home = await run([adb, '-s', serial, 'shell', 'cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME'], undefined, probeTimeout(), true)
          const homeActivity = home.stdout.trim().split(/\r?\n/).at(-1) ?? ''
          const temporaryHome = homeActivity.startsWith('com.android.sdksetup/')
            || homeActivity.startsWith('com.google.android.googlesdksetup/')
            || /^com\.android\.settings\/(?:\.|com\.android\.settings\.)FallbackHome$/.test(homeActivity)
            || /^android\/.*(?:Resolver|Chooser)Activity$/.test(homeActivity)
          // Resolving HOME can precede its first input window during cold
          // provisioning. Hand off only once the launcher actually has focus.
          const windows = await run([adb, '-s', serial, 'shell', 'dumpsys', 'window'], undefined, probeTimeout(), true)
          const focusedPackage = windows.stdout.match(/^\s*mCurrentFocus\s*=\s*Window\{[^}\r\n]*\bu\d+\s+([\w.]+)\//m)?.[1]
          booted = settings.code === 0 && packages.code === 0 && systemUi.code === 0 && events.code === 0
            && /^package:\/\S+/m.test(packages.stdout) && /^\d+(?:\s+\d+)*$/.test(systemUi.stdout.trim())
            && (!requiresPlayStore || (playStore?.code === 0 && /^package:\/\S+/m.test(playStore.stdout)))
            && home.code === 0 && /^[\w.]+\/[\w.$]+$/.test(homeActivity) && !temporaryHome
            && windows.code === 0 && focusedPackage === homeActivity.split('/')[0]
        }
      }
      const checkedAt = Date.now()
      if (booted && checkedAt <= deadline) {
        await recordBootResult('booted', checkedAt)
        return { serial, adb, env, dispose }
      }
      await Bun.sleep(Math.min(2000, Math.max(0, deadline - Date.now())))
    }
    if (child.exitCode !== null) throw new Error(`The owned Android emulator exited with code ${child.exitCode} before boot; inspect ${join(artifacts, 'emulator.log')}`)
    throw new Error(`The owned Android emulator did not boot within ${bootTimeoutMs}ms; inspect ${artifacts}`)
  }
  catch (error) {
    if (child) {
      try { await recordBootResult('failed') }
      catch (diagnostic) { console.error(`Could not retain emulator boot timing: ${diagnostic}`) }
      for (const args of [['logcat', '-d', '-b', 'all'], ['shell', 'getprop'], ['shell', 'dumpsys', 'activity', 'processes']]) {
        try { await run([adb, '-s', serial, ...args], undefined, 10_000, true) }
        catch { /* The emulator log remains available if ADB has disconnected. */ }
      }
    }
    try { await dispose() }
    catch (cleanup) { throw new AggregateError([error, cleanup], 'Android emulator setup and cleanup failed') }
    throw error
  }
}
