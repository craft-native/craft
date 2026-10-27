import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createAndroidEmulator } from '../../../android/src/emulator'
import type { AndroidEmulatorOptions } from '../../../android/src/emulator'

function fixture(hardware: boolean, delayedSettings = false, delayedEvents = false, delayedHome = false, connection: 'normal' | 'stale' | 'offline' = 'normal', bootstrapHome = 'com.android.sdksetup/.DefaultActivity', playStore: 'ready' | 'delayed' | 'missing' = 'ready', homeFocus: 'ready' | 'delayed' | 'foreign' = 'ready'): { root: string, options: AndroidEmulatorOptions } {
  const root = mkdtempSync(join(tmpdir(), 'craft emulator fixture '))
  const sdk = join(root, 'managed sdk')
  for (const directory of ['bin', 'platform-tools', 'emulator']) mkdirSync(join(sdk, directory), { recursive: true })
  const program = (name: string, body: string): string => {
    const file = join(sdk, name)
    writeFileSync(file, `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 })
    return file
  }
  const sdkmanager = program('bin/sdkmanager', 'printf "sdkmanager %s\\n" "$*" >> "$ANDROID_HOME/calls"')
  const avdmanager = program('bin/avdmanager', `printf "avdmanager %s\\n" "$*" >> "$ANDROID_HOME/calls"
if [ "$1" = create ]; then
  printf '%s' "$ANDROID_AVD_HOME" > "$ANDROID_HOME/owned"
  mkdir -p "$ANDROID_AVD_HOME/fixture.avd"
  printf 'private device' > "$ANDROID_AVD_HOME/fixture.avd/config.ini"
  printf 'private registry' > "$ANDROID_AVD_HOME/fixture.ini"
else touch "$ANDROID_HOME/deleted"; fi`)
  program('platform-tools/adb', `printf 'adb %s\\n' "$*" >> "$ANDROID_HOME/calls"
if [ "$1" = devices ]; then
  printf 'List of devices attached\\n'
  printf 'foreign-emulator\\toffline\\n'
  if [ -f "$ANDROID_HOME/started" ]; then
    if [ '${connection}' = offline ] || { [ '${connection}' = stale ] && [ -f "$ANDROID_HOME/connected-once" ] && [ ! -f "$ANDROID_HOME/reconnected" ]; }; then
      printf '%s\\toffline\\n' "$ANDROID_SERIAL"
    else
      touch "$ANDROID_HOME/connected-once"
      printf '%s\\tdevice\\n' "$ANDROID_SERIAL"
    fi
  fi
else
  case "$*" in
    '-s '$ANDROID_SERIAL' reconnect') touch "$ANDROID_HOME/reconnected" ;;
    *'getprop sys.boot_completed')
      if [ '${connection}' = stale ] && [ ! -f "$ANDROID_HOME/reconnected" ]; then printf '\\n'; else printf '1\\n'; fi ;;
    *'settings get global animator_duration_scale')
      if [ '${delayedSettings ? 'yes' : 'no'}' = yes ] && [ ! -f "$ANDROID_HOME/settings-ready" ]; then
        touch "$ANDROID_HOME/settings-ready"
        exit 255
      fi
      printf '1\\n' ;;
    *'pm path android') printf 'package:/system/framework/framework-res.apk\\n' ;;
    *'pm path com.android.vending')
      if [ '${playStore}' = missing ]; then exit 1; fi
      if [ '${playStore}' = delayed ] && [ ! -f "$ANDROID_HOME/play-ready" ]; then
        touch "$ANDROID_HOME/play-ready"
        exit 1
      fi
      printf 'package:/product/priv-app/Phonesky/Phonesky.apk\\n' ;;
    *'pidof com.android.systemui') printf '1234\\n' ;;
    *'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME')
      if [ '${delayedHome ? 'yes' : 'no'}' = yes ] && [ ! -f "$ANDROID_HOME/home-ready" ]; then
        touch "$ANDROID_HOME/home-ready"
        printf '${bootstrapHome}\\n'
      else
        printf 'com.android.launcher3/.Launcher\\n'
      fi ;;
    *'dumpsys window')
      if [ '${homeFocus}' = foreign ]; then
        printf 'mCurrentFocus=Window{abc u0 com.android.settings/com.android.settings.FallbackHome}\\nmFocusedApp=ActivityRecord{com.android.launcher3/.Launcher}\\n'
      elif [ '${homeFocus}' = delayed ] && [ ! -f "$ANDROID_HOME/home-focused" ]; then
        touch "$ANDROID_HOME/home-focused"
        printf 'mCurrentFocus=null\\n'
      else
        printf 'mCurrentFocus=Window{abc u0 com.android.launcher3/com.android.launcher3.Launcher}\\n'
      fi ;;
    *'logcat -b events -d -t 1') printf 'latest event ready\\n' ;;
    *'logcat -b events -d -v threadtime')
      if [ '${delayedEvents ? 'yes' : 'no'}' = yes ] && [ ! -f "$ANDROID_HOME/events-ready" ]; then
        touch "$ANDROID_HOME/events-ready"
        printf 'partial boot history\\n'
        exit 255
      fi
      if [ -f "$ANDROID_HOME/platform-events" ]; then cat "$ANDROID_HOME/platform-events"; else printf 'event stream ready\\n'; fi ;;
    *) printf '1\\n' ;;
  esac
fi`)
  program('emulator/emulator', `if [ "$1" = -accel-check ]; then exit ${hardware ? 0 : 1}; fi
printf '%s' "$$" > "$ANDROID_HOME/emulator.pid"
printf 'emulator %s\\n' "$*" >> "$ANDROID_HOME/calls"
touch "$ANDROID_HOME/started"
trap 'exit 0' TERM INT
while :; do sleep 1; done`)
  return { root, options: {
    sdkRoot: sdk, sdkmanager, avdmanager,
    image: `system-images;android-35;google_apis_playstore;${process.arch === 'arm64' ? 'arm64-v8a' : 'x86_64'}`,
    acceleration: 'hardware', artifactsDirectory: join(root, 'artifacts'), temporaryDirectory: join(root, 'temporary'),
  } }
}

test('hardware emulation refuses unavailable acceleration before creating a device', async () => {
  const { root, options } = fixture(false)
  try {
    await expect(createAndroidEmulator(options)).rejects.toThrow('hardware acceleration is unavailable')
    expect(existsSync(join(options.sdkRoot, 'owned'))).toBe(false)
    expect(existsSync(options.sdkmanager)).toBe(true)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

for (const event of ['am_anr', 'am_crash'] as const) test(`a platform ${event} in the retained boot history refuses readiness and disposes the owned emulator`, async () => {
  const { root, options } = fixture(true)
  // Captured from the failed stock Play software boot. Launcher recovery must
  // not erase the platform fault observed during this owned session.
  writeFileSync(join(options.sdkRoot, 'platform-events'), `10-24 08:31:21.416 593 1637 I ${event} : [0,1440,com.android.systemui,550026765,failed to complete startup]\n`)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  let failure: unknown
  try {
    try { session = await createAndroidEmulator(options) }
    catch (error) { failure = error }
    expect(failure).toBeInstanceOf(Error)
    expect(String(failure)).toContain('platform ANR or crash')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.status).toBe('failed')
    expect(existsSync(identity.avdDirectory)).toBe(false)
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
    expect(readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8')).toContain(event)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a boot history message mentioning a crash tag is not a platform crash event', async () => {
  const { root, options } = fixture(true)
  writeFileSync(join(options.sdkRoot, 'platform-events'), '10-24 08:31:21.416 593 1637 I auditd : process_name=am_crash:normal-value\n')
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    expect(JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8')).status).toBe('booted')
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a cold boot reconnects only its previously connected stale ADB transport', async () => {
  const { root, options } = fixture(true, false, false, false, 'stale')
  options.bootTimeoutMs = 12_000
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const reconnects = trace.filter(entry => entry.args.includes('reconnect'))
    expect(reconnects.map(entry => entry.args.slice(1))).toEqual([['-s', session.serial, 'reconnect']])
    expect(trace.some(entry => entry.args.includes('kill-server') || entry.args.includes('offline'))).toBe(false)
    const completion = trace.filter(entry => entry.args.includes('sys.boot_completed'))
    expect(completion.map(entry => entry.stdout.trim())).toEqual(['', '1'])
    expect(trace.some(entry => entry.args.includes('resolve-activity'))).toBe(true)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.status).toBe('booted')
    expect(identity.bootTimeoutMs).toBe(12_000)
    expect(identity.bootElapsedMs).toBeLessThanOrEqual(identity.bootTimeoutMs)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 20_000)

test('an offline guest that never connected still fails its deadline and is disposed', async () => {
  const { root, options } = fixture(true, false, false, false, 'offline')
  options.bootTimeoutMs = 1000
  try {
    await expect(createAndroidEmulator(options)).rejects.toThrow('did not boot within 1000ms')
    const calls = readFileSync(join(options.sdkRoot, 'calls'), 'utf8')
    expect(calls).not.toContain('reconnect')
    expect(calls).not.toContain('kill-server')
    expect(existsSync(readFileSync(join(options.sdkRoot, 'owned'), 'utf8'))).toBe(false)
    expect(existsSync(join(options.sdkRoot, 'deleted'))).toBe(false)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.status).toBe('failed')
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('explicit guest memory reaches the emulator process and its retained identity', async () => {
  const { root, options } = fixture(true)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator({ ...options, memoryMb: 4096 })
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).toContain('-memory 4096')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.memoryMb).toBe(4096)
    expect(identity.virtualCpus).toBe(2)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('explicit guest CPU count reaches the emulator process and its retained identity', async () => {
  const { root, options } = fixture(true)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator({ ...options, virtualCpus: 4 })
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).toContain('-cores 4')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.virtualCpus).toBe(4)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('invalid boot budgets fail before starting tools or creating owned device data', async () => {
  const { root, options } = fixture(true)
  try {
    const modes: AndroidEmulatorOptions['acceleration'][] = process.arch === 'x64' ? ['hardware', 'software'] : ['hardware']
    for (const acceleration of modes) {
      const maximum = acceleration === 'software' ? 1_200_000 : 600_000
      for (const budget of [NaN, Infinity, -Infinity, -1, 0, 999, 1000.5, maximum + 1, Number.MAX_SAFE_INTEGER + 1]) {
        await expect(createAndroidEmulator({ ...options, acceleration, bootTimeoutMs: budget })).rejects.toThrow('bootTimeoutMs')
        expect(existsSync(join(options.sdkRoot, 'calls'))).toBe(false)
        expect(existsSync(options.temporaryDirectory!)).toBe(false)
      }
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

test('invalid guest memory fails before starting tools or creating owned device data', async () => {
  const { root, options } = fixture(true)
  try {
    for (const memoryMb of [NaN, Infinity, -Infinity, 0, 1535, 8193, 4096.5]) {
      await expect(createAndroidEmulator({ ...options, memoryMb })).rejects.toThrow('memoryMb')
      expect(existsSync(join(options.sdkRoot, 'calls'))).toBe(false)
      expect(existsSync(options.temporaryDirectory!)).toBe(false)
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

test('invalid guest CPU counts fail before starting tools or creating owned device data', async () => {
  const { root, options } = fixture(true)
  try {
    for (const virtualCpus of [NaN, Infinity, -Infinity, 0, 0.5, 9, 8.5]) {
      await expect(createAndroidEmulator({ ...options, virtualCpus })).rejects.toThrow('virtualCpus')
      expect(existsSync(join(options.sdkRoot, 'calls'))).toBe(false)
      expect(existsSync(options.temporaryDirectory!)).toBe(false)
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})

test('boot completion alone does not admit a device before SettingsProvider is usable', async () => {
  const { root, options } = fixture(true, true)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    expect(existsSync(join(options.sdkRoot, 'settings-ready'))).toBe(true)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.bootedAt).toBeString()
    expect(identity.bootTimeoutMs).toBe(600_000)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const readiness = trace.filter(entry => entry.args.includes('animator_duration_scale'))
    expect(readiness.map(entry => entry.code)).toEqual([255, 0])
    expect(trace.every(entry => Number.isFinite(Date.parse(entry.startedAt)) && Number.isFinite(Date.parse(entry.finishedAt)))).toBe(true)
    expect(trace.map(entry => entry.sequence)).toEqual(trace.map((_, index) => index + 1))
    expect(readdirSync(options.artifactsDirectory).sort()).toEqual(['android-emulator.json', 'device-commands.jsonl', 'emulator.log'])
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('boot and System UI do not admit a device before its event log is readable', async () => {
  const { root, options } = fixture(true, false, true)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    expect(existsSync(join(options.sdkRoot, 'events-ready'))).toBe(true)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const events = trace.filter(entry => entry.args.includes('logcat'))
    expect(events.map(entry => entry.code)).toEqual([255, 0])
    expect(events[0].stdout).toContain('partial boot history')
    expect(events.every(entry => entry.args.includes('-d') && entry.args.includes('events'))).toBe(true)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(Date.parse(events[1].finishedAt)).toBeLessThanOrEqual(Date.parse(identity.bootedAt))
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a Play image waits for its bundled store after framework and HOME readiness', async () => {
  const { root, options } = fixture(true, false, false, false, 'normal', 'com.android.sdksetup/.DefaultActivity', 'delayed')
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const store = trace.filter(entry => entry.args.includes('com.android.vending'))
    expect(store.map(entry => entry.code)).toEqual([1, 0])
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(Date.parse(store[1].finishedAt)).toBeLessThanOrEqual(Date.parse(identity.bootedAt))
    expect(identity.bootTimeoutMs).toBe(600_000)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a missing Play package fails the existing boot deadline and disposes its owned device', async () => {
  const { root, options } = fixture(true, false, false, false, 'normal', 'com.android.sdksetup/.DefaultActivity', 'missing')
  options.bootTimeoutMs = 5000
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    await expect((async () => { session = await createAndroidEmulator(options) })()).rejects.toThrow('did not boot within 5000ms')
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    expect(trace.filter(entry => entry.args.includes('com.android.vending')).length).toBeGreaterThan(0)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.status).toBe('failed')
    expect(existsSync(identity.avdDirectory)).toBe(false)
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a non-Play image does not require an unrelated store package', async () => {
  const { root, options } = fixture(true, false, false, false, 'normal', 'com.android.sdksetup/.DefaultActivity', 'missing')
  options.image = options.image.replace(';google_apis_playstore;', ';google_apis;')
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).not.toContain('com.android.vending')
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('boot completion waits for the automatic SDK setup activity to release HOME', async () => {
  const { root, options } = fixture(true, false, false, true)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const home = trace.filter(entry => entry.args.includes('resolve-activity'))
    expect(home.map(entry => entry.stdout.trim())).toEqual(['com.android.sdksetup/.DefaultActivity', 'com.android.launcher3/.Launcher'])
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(Date.parse(home[1].finishedAt)).toBeLessThanOrEqual(Date.parse(identity.bootedAt))
    expect(identity.bootTimeoutMs).toBe(600_000)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test.each(['com.android.settings/.FallbackHome', 'android/com.android.internal.app.ResolverActivity', 'com.google.android.googlesdksetup/.DefaultActivity'])('boot readiness rejects the temporary HOME destination %s', async (bootstrapHome) => {
  const { root, options } = fixture(true, false, false, true, 'normal', bootstrapHome)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const home = trace.filter(entry => entry.args.includes('resolve-activity'))
    expect(home.map(entry => entry.stdout.trim())).toEqual([bootstrapHome, 'com.android.launcher3/.Launcher'])
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('the SDK process fixture records hardware mode and reaps only its owned process', async () => {
  const { root, options } = fixture(true)
  options.bootTimeoutMs = 42_000
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.acceleration).toBe('hardware')
    expect(identity.memoryMb).toBe(2048)
    expect(identity.bootedAt).toBeString()
    expect(identity.bootTimeoutMs).toBe(42_000)
    expect(identity.bootElapsedMs).toBeGreaterThanOrEqual(0)
    expect(identity.bootElapsedMs).toBeLessThanOrEqual(identity.bootTimeoutMs)
    expect(identity.host.logicalCpus).toBeGreaterThan(0)
    expect(identity.hostCpuInterval.totalDeltaMs).toBeGreaterThanOrEqual(0)
    expect(session.serial).toBe('emulator-5558')
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).toContain('-gpu software')
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).not.toContain('swiftshader_indirect')
    const owned = readFileSync(join(options.sdkRoot, 'owned'), 'utf8')
    await session.dispose()
    await session.dispose()
    expect(existsSync(owned)).toBe(false)
    expect(existsSync(join(options.sdkRoot, 'deleted'))).toBe(false)
    expect(existsSync(options.sdkmanager)).toBe(true)
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
})

test('disposal reaps the process and removes its private registry without consulting a mutable external manager', async () => {
  const { root, options } = fixture(true)
  const foreign = join(root, 'existing-user-avds')
  mkdirSync(foreign)
  writeFileSync(join(foreign, 'my-phone.ini'), 'user-owned device')
  options.env = { ANDROID_AVD_HOME: foreign }
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const owned = session.env.ANDROID_AVD_HOME!
    expect(owned).not.toBe(foreign)
    mkdirSync(join(owned, 'device.avd'))
    writeFileSync(join(owned, 'device.ini'), 'private registry entry')
    writeFileSync(join(owned, 'device.avd/config.ini'), 'private device')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    // The device is already owned and booted. Its lifecycle must not depend
    // on launching the provisioning JVM a second time during disposal.
    writeFileSync(options.avdmanager, '#!/bin/sh\nprintf "manager unavailable after provisioning\\n" >&2\nexit 1\n', { mode: 0o755 })
    await session.dispose()
    await session.dispose()
    expect(existsSync(owned)).toBe(false)
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
    expect(readFileSync(join(foreign, 'my-phone.ini'), 'utf8')).toBe('user-owned device')
    expect(existsSync(options.sdkmanager)).toBe(true)
  }
  finally {
    try { await session?.dispose() }
    finally { rmSync(root, { recursive: true, force: true }) }
  }
})

test('software execution is explicit and cannot be mistaken for hardware acceleration', async () => {
  const { root, options } = fixture(false)
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    options.acceleration = 'software'
    options.bootTimeoutMs = 1_200_000
    if (process.arch !== 'x64') {
      await expect(createAndroidEmulator(options)).rejects.toThrow('requires an x86_64 host')
      return
    }
    session = await createAndroidEmulator(options)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.acceleration).toBe('software')
    expect(identity.bootTimeoutMs).toBe(1_200_000)
    expect(identity.accelerationProbeExitCode).toBe(1)
    expect(readFileSync(join(options.sdkRoot, 'calls'), 'utf8')).toContain('-accel off')
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
})


test('a resolved HOME waits for its actual input window before handing off the device', async () => {
  const { root, options } = fixture(true, false, false, false, 'normal', 'com.android.sdksetup/.DefaultActivity', 'ready', 'delayed')
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    expect(existsSync(join(options.sdkRoot, 'home-focused'))).toBe(true)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    const focus = trace.filter(entry => entry.args.includes('window'))
    expect(focus).toHaveLength(2)
    expect(focus[0].stdout.trim()).toBe('mCurrentFocus=null')
    expect(focus[1].stdout).toContain('com.android.launcher3/com.android.launcher3.Launcher')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(Date.parse(focus[1].finishedAt)).toBeLessThanOrEqual(Date.parse(identity.bootedAt))
    expect(identity.bootTimeoutMs).toBe(600_000)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)

test('a foreign focused window cannot admit an otherwise ready emulator', async () => {
  const { root, options } = fixture(true, false, false, false, 'normal', 'com.android.sdksetup/.DefaultActivity', 'ready', 'foreign')
  options.bootTimeoutMs = 5000
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    await expect(createAndroidEmulator(options).then(value => { session = value; return value })).rejects.toThrow('did not boot within 5000ms')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.status).toBe('failed')
    expect(existsSync(identity.avdDirectory)).toBe(false)
    expect(() => process.kill(identity.emulatorPid, 0)).toThrow()
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10_000)


test('an emulator process that exits before boot reports its exit instead of a fictitious timeout', async () => {
  const { root, options } = fixture(true)
  writeFileSync(join(options.sdkRoot, 'emulator/emulator'), '#!/bin/sh\nif [ "$1" = -accel-check ]; then exit 0; fi\necho "Insufficient disk space" >&2\nexit 28\n', { mode: 0o755 })
  try {
    await expect(createAndroidEmulator(options)).rejects.toThrow('exited with code 28 before boot')
    expect(readFileSync(join(options.artifactsDirectory, 'emulator.log'), 'utf8')).toContain('Insufficient disk space')
    expect(existsSync(readFileSync(join(options.sdkRoot, 'owned'), 'utf8'))).toBe(false)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})
