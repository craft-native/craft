import { expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { describePushSuspension, describeSimulatorBoot, hostIsVirtual, recordedScript, runRecorded, simulatorBootCommand, startSimulatorBoot, suspendPushCommand, suspendSimulatorPush, type RecordedExit } from '../scripts/simulator-boot'

function deferred<T>(): { promise: Promise<T>, resolve: (value: T) => void, reject: (error: unknown) => void } {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

test('a boot is started without waiting for the device to be ready', async () => {
  const exit = deferred<RecordedExit>()
  const commands: string[][] = []
  const boot = startSimulatorBoot('DEVICE-1', (command) => { commands.push(command); return exit.promise }, () => 10_000, false)

  // Returned while the device is still booting: the build can start now.
  expect(commands).toEqual([['xcrun', 'simctl', 'bootstatus', 'DEVICE-1', '-b']])
  let settled = false
  void boot.ready.then(() => { settled = true })
  await Promise.resolve()
  await Promise.resolve()
  expect(settled).toBe(false)

  exit.resolve({ exitCode: 0, finishedAt: 150_000 })
  expect(await boot.ready).toEqual({ exitCode: 0, seconds: 140 })
})

test('the boot is timed by when it finished, not by when the build let the result be read', async () => {
  let clock = 0
  const boot = startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 0, finishedAt: 124_000 }), () => clock, false)
  // The build held the event loop for 400 seconds after a 124-second boot.
  clock = 400_000
  expect((await boot.ready).seconds).toBe(124)
})

test('a boot that could not run settles, and is told apart from a ready device', async () => {
  const refused = startSimulatorBoot('DEVICE-1', () => { throw new Error('xcrun is missing') }, () => 0, false)
  expect(await refused.ready).toEqual({ exitCode: null, seconds: 0 })
  const failed = startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 149, finishedAt: 3_000 }), () => 0, false)
  const result = await failed.ready
  expect(result).toEqual({ exitCode: 149, seconds: 3 })
  expect(describeSimulatorBoot(result, 0)).toBe('Simulator boot ended after 3s with exit code 149; xcodebuild decides whether the device is usable; waited 0s for it after the build')
  expect(describeSimulatorBoot({ exitCode: 0, seconds: 582 }, 265.6)).toBe('Simulator ready 582s after its boot began; waited 266s for it after the build')
})

test('the boot command boots a device that is shut down and waits for it', () => {
  expect(simulatorBootCommand('DEVICE-1')).toEqual(['xcrun', 'simctl', 'bootstatus', 'DEVICE-1', '-b'])
})

test.skipIf(process.platform === 'win32')('a recorded command reports its own exit code and finish time', async () => {
  const before = Date.now()
  const recorded = await runRecorded(['/bin/sh', '-c', 'echo noise; echo more >&2; exit 3'])
  expect(recorded.exitCode).toBe(3)
  // `date +%s` truncates to the second the command ended in.
  expect(recorded.finishedAt).toBeGreaterThanOrEqual(before - 1000)
  expect(recorded.finishedAt).toBeLessThanOrEqual(Date.now())
  expect((await runRecorded(['/usr/bin/true'])).exitCode).toBe(0)
})

// #521: on a hosted runner the simulator's push daemon reconnects 5 to 20
// times a second for the whole job. It is suspended once the device is up.
test('on a virtual host the push daemon is suspended the moment the device is ready', async () => {
  const calls: (string[] | undefined)[][] = []
  const boot = startSimulatorBoot('DEVICE-1', async (command, then) => { calls.push([command, then]); return { exitCode: 0, finishedAt: 108_000, followedBy: 0 } }, () => 0, true)
  // In the same shell as the boot, so it does not wait for the build to let go.
  expect(calls).toEqual([[['xcrun', 'simctl', 'bootstatus', 'DEVICE-1', '-b'], suspendPushCommand('DEVICE-1')]])
  // Suspended, not removed: its place is held, and nothing connected to it sees a change.
  expect(suspendPushCommand('DEVICE-1')).toEqual([
    '/bin/sh', '-c',
    'xcrun simctl spawn "$1" launchctl kill SIGSTOP user/foreground/com.apple.apsd || xcrun simctl spawn "$1" launchctl kill SIGSTOP system/com.apple.apsd',
    'sh', 'DEVICE-1',
  ])
  expect(suspendPushCommand('DEVICE-1').join(' ')).not.toContain('bootout')
  const result = await boot.ready
  expect(result).toEqual({ exitCode: 0, seconds: 108, pushSuspended: true })
  expect(describeSimulatorBoot(result, 0)).toBe(`Simulator ready 108s after its boot began; waited 0s for it after the build\n${describePushSuspension(true)}`)
  expect(describePushSuspension(true)).toContain('Suspended the simulator\'s push daemon')

  // A suspension that failed is said, and the boot is still a boot.
  const stubborn = await startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 0, finishedAt: 5_000, followedBy: 3 }), () => 0, true).ready
  expect(stubborn).toEqual({ exitCode: 0, seconds: 5, pushSuspended: false })
  expect(describeSimulatorBoot(stubborn, 0)).toContain('Could not suspend the simulator\'s push daemon')
  // A device that did not boot has no daemon to suspend, and nothing is claimed.
  const dead = await startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 22, finishedAt: 0 }), () => 0, true).ready
  expect(dead).toEqual({ exitCode: 22, seconds: 0 })
})

test('on a real Mac the push daemon is left alone', async () => {
  const calls: (string[] | undefined)[][] = []
  const boot = startSimulatorBoot('DEVICE-1', async (command, then) => { calls.push([command, then]); return { exitCode: 0, finishedAt: 9_000 } }, () => 0, false)
  expect(calls).toEqual([[['xcrun', 'simctl', 'bootstatus', 'DEVICE-1', '-b'], undefined]])
  const result = await boot.ready
  expect(result).toEqual({ exitCode: 0, seconds: 9 })
  expect(describeSimulatorBoot(result, 0)).toBe('Simulator ready 9s after its boot began; waited 0s for it after the build')
  // The script that waits for its own boot asks the same question.
  const ran: string[][] = []
  expect(suspendSimulatorPush('DEVICE-1', false, (command) => { ran.push(command); return 0 })).toBeUndefined()
  expect(ran).toEqual([])
  expect(suspendSimulatorPush('DEVICE-1', true, (command) => { ran.push(command); return 0 })).toBe(describePushSuspension(true))
  expect(ran).toEqual([suspendPushCommand('DEVICE-1')])
  expect(suspendSimulatorPush('DEVICE-1', true, () => 1)).toBe(describePushSuspension(false))
})

test('a virtual host is one whose kernel says so', () => {
  expect(hostIsVirtual(() => '1\n')).toBe(true)
  expect(hostIsVirtual(() => '0\n')).toBe(false)
  // Not a Mac, or a sysctl that does not know the name.
  expect(hostIsVirtual(() => '')).toBe(false)
  expect(hostIsVirtual(() => { throw new Error('no sysctl') })).toBe(false)
})

test.skipIf(process.platform === 'win32')('what follows a recorded command runs only after its success, and changes neither its exit code nor its time', async () => {
  const dir = createTempDir('craft-recorded-')
  try {
    const marker = join(dir, 'followed')
    // Succeeds: the follower runs, and its own exit code is reported beside the command's.
    const followed = await runRecorded(['/usr/bin/true'], ['/bin/sh', '-c', `echo ran > '${marker}'; exit 7`])
    expect(followed.exitCode).toBe(0)
    expect(followed.followedBy).toBe(7)
    expect(readFileSync(marker, 'utf8')).toBe('ran\n')
    expect(followed.finishedAt).toBeLessThanOrEqual(Date.now())
    // Fails: the follower does not run.
    const skipped = await runRecorded(['/bin/sh', '-c', 'exit 22'], ['/bin/sh', '-c', `echo again >> '${marker}'`])
    expect(skipped.exitCode).toBe(22)
    expect(skipped.followedBy).toBeUndefined()
    expect(readFileSync(marker, 'utf8')).toBe('ran\n')
    // Words are passed as words, whatever is in them.
    const odd = join(dir, 'it\'s here; $HOME')
    expect((await runRecorded(['/usr/bin/touch', odd])).exitCode).toBe(0)
    expect(existsSync(odd)).toBe(true)
    expect(recordedScript(['a', 'b c'])).toBe('\'a\' \'b c\' >/dev/null 2>&1; code=$?; date +%s; exit $code')
  }
  finally { removeTempDir(dir) }
})

test('the render script suspends the push daemon of the device it tests on, before it builds', () => {
  const script = readFileSync(join(import.meta.dir, '../scripts/test-native-render.ts'), 'utf8')
  const booted = script.indexOf('await bootSimulator(device)')
  const suspended = script.indexOf('suspendSimulatorPush(device.udid)')
  expect(booted).toBeGreaterThan(-1)
  expect(suspended).toBeGreaterThan(booted)
  expect(script.indexOf('\'xcodebuild\'', suspended)).toBeGreaterThan(suspended)
})

for (const name of ['test-native-navigation.ts', 'test-hybrid-navigation.ts']) {
  test(`${name} builds while the simulator boots and waits for it only before the tests`, () => {
    const script = readFileSync(join(import.meta.dir, '../scripts', name), 'utf8')
    const started = script.indexOf('startSimulatorBoot(device.udid)')
    const built = script.indexOf("'build-for-testing'], output)")
    const ready = script.indexOf('await boot.ready')
    const tested = script.indexOf("'test-without-building'")
    expect(started).toBeGreaterThan(-1)
    expect(built).toBeGreaterThan(started)
    expect(ready).toBeGreaterThan(built)
    expect(tested).toBeGreaterThan(ready)
    // Waiting for the boot before the build is what this replaced.
    expect(script).not.toContain('bootSimulator')
    // A fixture that is only prepared boots nothing.
    expect(script.indexOf('if (prepareOnly)')).toBeLessThan(started)
  })
}
