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
    const closing = session.dispose()
    expect(session.dispose()).toBe(closing)
    await closing
    expect(session.dispose()).toBe(closing)
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
    const appData = join(owned, 'device.avd/checkpoint-app-data')
    writeFileSync(appData, 'private fixture checkpoint and package registry')
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    // The device is already owned and booted. Its lifecycle must not depend
    // on launching the provisioning JVM a second time during disposal.
    writeFileSync(options.avdmanager, '#!/bin/sh\nprintf "manager unavailable after provisioning\\n" >&2\nexit 1\n', { mode: 0o755 })
    writeFileSync(join(options.sdkRoot, 'platform-tools/adb'), '#!/bin/sh\necho "package manager unavailable after boot" >&2\nexit 1\n', { mode: 0o755 })
    await session.dispose()
    await session.dispose()
    expect(existsSync(owned)).toBe(false)
    expect(existsSync(appData)).toBe(false)
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

const waitForOwnedFile = async (path: string): Promise<void> => {
  const deadline = performance.now() + 2000
  while (!existsSync(path) && performance.now() < deadline) await Bun.sleep(10)
  expect(existsSync(path)).toBe(true)
}

test('a pre-cancelled emulator request starts no SDK command or private registry', async () => {
  const { root, options } = fixture(true)
  const controller = new AbortController()
  controller.abort(new Error('Native acceptance cancelled'))
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    await expect(createAndroidEmulator({ ...options, signal: controller.signal }).then(value => { session = value; return value })).rejects.toThrow('Native acceptance cancelled')
    expect(existsSync(join(options.sdkRoot, 'calls'))).toBe(false)
    expect(existsSync(options.temporaryDirectory!)).toBe(false)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10000)

test('cancelling provisioning reaps its SDK process group before returning and preserves foreign registries', async () => {
  const { root, options } = fixture(true)
  const foreign = join(root, 'user-avds')
  mkdirSync(foreign)
  writeFileSync(join(foreign, 'phone.ini'), 'existing user device')
  options.env = { ANDROID_AVD_HOME: foreign }
  writeFileSync(options.sdkmanager, '#!/bin/sh\nset -eu\necho $$ > "$ANDROID_HOME/provision.pid"\nsleep 2\ntouch "$ANDROID_HOME/after-cancel"\n', { mode: 0o755 })
  const controller = new AbortController()
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    const starting = createAndroidEmulator({ ...options, signal: controller.signal }).then(value => { session = value; return value })
    await waitForOwnedFile(join(options.sdkRoot, 'provision.pid'))
    const pid = Number(readFileSync(join(options.sdkRoot, 'provision.pid'), 'utf8'))
    controller.abort(new Error('Provisioning cancelled'))
    await expect(starting).rejects.toThrow('Provisioning cancelled')
    expect(() => process.kill(-pid, 0)).toThrow()
    expect(existsSync(join(options.sdkRoot, 'after-cancel'))).toBe(false)
    expect(readFileSync(join(foreign, 'phone.ini'), 'utf8')).toBe('existing user device')
    expect(readdirSync(options.temporaryDirectory!)).toEqual([])
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10000)

test('cancelling boot reaps only the owned guest and does not reconnect or stop foreign devices', async () => {
  const { root, options } = fixture(true, false, false, false, 'offline')
  options.bootTimeoutMs = 1000
  const controller = new AbortController()
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    const starting = createAndroidEmulator({ ...options, signal: controller.signal }).then(value => { session = value; return value })
    await waitForOwnedFile(join(options.sdkRoot, 'started'))
    const pid = Number(readFileSync(join(options.sdkRoot, 'emulator.pid'), 'utf8'))
    controller.abort(new Error('Boot cancelled'))
    await expect(starting).rejects.toThrow('Boot cancelled')
    expect(() => process.kill(pid, 0)).toThrow()
    const calls = readFileSync(join(options.sdkRoot, 'calls'), 'utf8')
    expect(calls).not.toContain('kill-server')
    expect(calls).not.toContain('reconnect')
    expect(existsSync(readFileSync(join(options.sdkRoot, 'owned'), 'utf8'))).toBe(false)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 10000)

test('post-return cancellation disposes a TERM-ignoring guest before acknowledging the closed session', async () => {
  const { root, options } = fixture(true)
  const executable = join(options.sdkRoot, 'emulator/emulator')
  writeFileSync(executable, readFileSync(executable, 'utf8').replace("trap 'exit 0' TERM INT", "trap '' TERM INT"), { mode: 0o755 })
  const controller = new AbortController()
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator({ ...options, signal: controller.signal })
    const pid = Number(readFileSync(join(options.sdkRoot, 'emulator.pid'), 'utf8'))
    controller.abort(new Error('Returned session cancelled'))
    expect(session.closed).toBeInstanceOf(Promise)
    await session.closed
    expect(() => process.kill(-pid, 0)).toThrow()
    expect(existsSync(readFileSync(join(options.sdkRoot, 'owned'), 'utf8'))).toBe(false)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 15000)

test('failed guest disposal retains the private registry until its process group can be reaped', async () => {
  const { root, options } = fixture(true)
  const originalKill = process.kill
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  let pid = 0
  try {
    session = await createAndroidEmulator(options)
    pid = Number(readFileSync(join(options.sdkRoot, 'emulator.pid'), 'utf8'))
    const owned = readFileSync(join(options.sdkRoot, 'owned'), 'utf8')
    process.kill = ((selected: number, signal?: NodeJS.Signals | number) => {
      if (selected === -pid && signal !== 0) throw Object.assign(new Error('Fixture signal denied'), { code: 'EPERM' })
      return originalKill(selected, signal)
    }) as typeof process.kill
    await expect(session.dispose()).rejects.toThrow()
    expect(existsSync(owned)).toBe(true)
    expect(() => originalKill(-pid, 0)).not.toThrow()
    process.kill = originalKill
    await session.dispose()
    expect(existsSync(owned)).toBe(false)
    expect(() => originalKill(-pid, 0)).toThrow()
    await expect(session.closed).rejects.toThrow('disposal failed')
  }
  finally {
    process.kill = originalKill
    if (pid) { try { originalKill(-pid, 'SIGKILL') } catch { /* The owned group may already have exited. */ } }
    await session?.dispose().catch(() => {})
    await Bun.sleep(50)
    rmSync(root, { recursive: true, force: true })
  }
}, 15000)

/**
 * A cleanup error is the second thing that went wrong, never the reason the
 * caller asked for. Reporting only "setup and cleanup failed" buried the
 * cancellation under whatever the dispose happened to hit, which is how a
 * loaded macOS runner turned `Boot cancelled` into an unrelated message and
 * failed v0.0.474's `accept exact release source` gate.
 */
test('a failing cleanup still names the cancellation that caused it', async () => {
  const { root, options } = fixture(true)
  writeFileSync(options.sdkmanager, '#!/bin/sh\nset -eu\necho $$ > "$ANDROID_HOME/provision.pid"\ntrap "" TERM INT\nwhile :; do sleep 1; done\n', { mode: 0o755 })
  const originalKill = process.kill
  let pid = 0
  const controller = new AbortController()
  try {
    const outcome = createAndroidEmulator({ ...options, signal: controller.signal }).then(() => undefined, (error: unknown) => error)
    await waitForOwnedFile(join(options.sdkRoot, 'provision.pid'))
    pid = Number(readFileSync(join(options.sdkRoot, 'provision.pid'), 'utf8'))
    // Deny signalling so disposal fails while the cancellation is the cause.
    process.kill = ((selected: number, signal?: NodeJS.Signals | number) => {
      if (selected === -pid && signal !== 0) throw Object.assign(new Error('Fixture provisioning signal denied'), { code: 'EPERM' })
      return originalKill(selected, signal)
    }) as typeof process.kill
    controller.abort(new Error('Boot cancelled'))
    const error = await outcome
    expect(error).toBeInstanceOf(AggregateError)
    // The reason the caller gave must be readable without unwrapping.
    expect(String((error as AggregateError).message)).toContain('Boot cancelled')
    // And the cleanup failure is still retained alongside it.
    expect((error as AggregateError).errors).toHaveLength(2)
  }
  finally {
    process.kill = originalKill
    if (pid) { try { originalKill(-pid, 'SIGKILL') } catch { /* already reaped */ } }
    rmSync(root, { recursive: true, force: true })
  }
}, 30_000)

test('failed provisioning cancellation retains its registry and reports signaling errors through the setup promise', async () => {
  const { root, options } = fixture(true)
  writeFileSync(options.sdkmanager, '#!/bin/sh\nset -eu\necho $$ > "$ANDROID_HOME/provision.pid"\ntrap "" TERM INT\nwhile :; do sleep 1; done\n', { mode: 0o755 })
  const originalKill = process.kill
  const controller = new AbortController()
  let pid = 0
  try {
    const outcome = createAndroidEmulator({ ...options, signal: controller.signal }).then(session => ({ session, error: undefined }), error => ({ session: undefined, error }))
    await waitForOwnedFile(join(options.sdkRoot, 'provision.pid'))
    pid = Number(readFileSync(join(options.sdkRoot, 'provision.pid'), 'utf8'))
    process.kill = ((selected: number, signal?: NodeJS.Signals | number) => {
      if (selected === -pid && signal !== 0) throw Object.assign(new Error('Fixture provisioning signal denied'), { code: 'EPERM' })
      return originalKill(selected, signal)
    }) as typeof process.kill
    expect(() => controller.abort(new Error('Provisioning cancelled'))).not.toThrow()
    const result = await outcome
    expect(result.session).toBeUndefined()
    expect(result.error).toBeInstanceOf(AggregateError)
    expect(readdirSync(options.temporaryDirectory!)).toHaveLength(1)
    expect(() => originalKill(-pid, 0)).not.toThrow()
  }
  finally {
    process.kill = originalKill
    if (pid) { try { originalKill(-pid, 'SIGKILL') } catch { /* Rescue only the owned fixture group. */ } }
    await Bun.sleep(50)
    rmSync(root, { recursive: true, force: true })
  }
}, 10000)

test('post-return signaling failures reject closed without escaping the abort callback and still reap the guest', async () => {
  const { root, options } = fixture(true)
  const originalKill = process.kill
  const controller = new AbortController()
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  let pid = 0
  try {
    session = await createAndroidEmulator({ ...options, signal: controller.signal })
    pid = Number(readFileSync(join(options.sdkRoot, 'emulator.pid'), 'utf8'))
    process.kill = ((selected: number, signal?: NodeJS.Signals | number) => {
      if (selected === -pid && signal === 'SIGTERM') throw Object.assign(new Error('Fixture TERM denied'), { code: 'EPERM' })
      return originalKill(selected, signal)
    }) as typeof process.kill
    expect(() => controller.abort()).not.toThrow()
    await expect(session.closed).rejects.toThrow('disposal failed')
    expect(() => originalKill(-pid, 0)).toThrow()
    expect(existsSync(readFileSync(join(options.sdkRoot, 'owned'), 'utf8'))).toBe(false)
  }
  finally {
    process.kill = originalKill
    if (pid) { try { originalKill(-pid, 'SIGKILL') } catch { /* The owned group may already have exited. */ } }
    await session?.dispose().catch(() => {})
    rmSync(root, { recursive: true, force: true })
  }
}, 15000)

test('an escaped provisioning child holding command pipes open fails promptly and retains the private registry', async () => {
  const { root, options } = fixture(true)
  // Model a vendor daemon escaping the command group while retaining stdout.
  // The helper must not guess at unrelated PIDs or wait forever for pipe EOF.
  const escapedCode = 'await Bun.write(process.env.ANDROID_HOME + "/escaped.pid", String(process.pid)); await Bun.sleep(30000)'
  writeFileSync(options.sdkmanager, `#!${process.execPath}\nBun.spawn([process.execPath, '-e', ${JSON.stringify(escapedCode)}], { detached: true, stdout: 'inherit', stderr: 'inherit' });\nwhile (!await Bun.file(process.env.ANDROID_HOME + '/escaped.pid').exists()) await Bun.sleep(10);\nprocess.exit(0);\n`, { mode: 0o755 })
  let pid = 0
  try {
    const outcome = createAndroidEmulator(options).then(session => ({ session, error: undefined }), error => ({ session: undefined, error }))
    await waitForOwnedFile(join(options.sdkRoot, 'escaped.pid'))
    pid = Number(readFileSync(join(options.sdkRoot, 'escaped.pid'), 'utf8'))
    const started = performance.now()
    const result = await outcome
    expect(result.session).toBeUndefined()
    expect(result.error).toBeInstanceOf(AggregateError)
    expect(performance.now() - started).toBeLessThan(3000)
    expect(readdirSync(options.temporaryDirectory!)).toHaveLength(1)
    expect(() => process.kill(-pid, 0)).not.toThrow()
  }
  finally {
    if (pid) { try { process.kill(-pid, 'SIGKILL') } catch { /* Rescue only the escaped fixture process. */ } }
    await Bun.sleep(50)
    rmSync(root, { recursive: true, force: true })
  }
}, 10000)

test('a timed-out owned ADB readiness probe is reaped and retried within the original boot deadline', async () => {
  const { root, options } = fixture(true)
  options.bootTimeoutMs = 16000
  const adb = join(options.sdkRoot, 'platform-tools/adb')
  writeFileSync(adb, readFileSync(adb, 'utf8').replace('if [ "$1" = devices ]; then', `if [ "$1" = devices ] && [ -f "$ANDROID_HOME/started" ] && [ ! -f "$ANDROID_HOME/probe-timed-out" ]; then
  touch "$ANDROID_HOME/probe-timed-out"
  sleep 30
fi
if [ "$1" = devices ]; then`), { mode: 0o755 })
  let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
  try {
    session = await createAndroidEmulator(options)
    const trace = readFileSync(join(options.artifactsDirectory, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
    expect(trace.some(entry => entry.timedOut && entry.commandGroupDisposed)).toBe(true)
    expect(trace.some(entry => entry.args.includes('sys.boot_completed') && entry.code === 0)).toBe(true)
    const identity = JSON.parse(readFileSync(join(options.artifactsDirectory, 'android-emulator.json'), 'utf8'))
    expect(identity.bootElapsedMs).toBeLessThanOrEqual(options.bootTimeoutMs)
  }
  finally { await session?.dispose(); rmSync(root, { recursive: true, force: true }) }
}, 20000)

test('cancelling between readiness probes preserves the exact abort reason after successful cleanup', async () => {
  const { root, options } = fixture(true, false, false, false, 'offline')
  const controller = new AbortController()
  const reason = new Error('Between-probe cancellation')
  let outcome: Promise<{ session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined, error: unknown }> | undefined
  try {
    outcome = createAndroidEmulator({ ...options, signal: controller.signal }).then(session => ({ session, error: undefined }), error => ({ session: undefined, error }))
    const log = join(options.artifactsDirectory, 'device-commands.jsonl')
    const deadline = performance.now() + 4000
    let waiting = false
    while (!waiting && performance.now() < deadline) {
      waiting = existsSync(log) && readFileSync(log, 'utf8').split('\n').filter(Boolean).some(line => JSON.parse(line).stdout.includes('emulator-5558\toffline'))
      if (!waiting) await Bun.sleep(10)
    }
    expect(waiting).toBe(true)
    controller.abort(reason)
    const result = await outcome
    expect(result.session).toBeUndefined()
    expect(result.error).toBe(reason)
    expect(readdirSync(options.temporaryDirectory!)).toEqual([])
  }
  finally {
    controller.abort(reason)
    await (await outcome)?.session?.dispose().catch(() => {})
    rmSync(root, { recursive: true, force: true })
  }
}, 10000)
