import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describeSimulatorBoot, runRecorded, simulatorBootCommand, startSimulatorBoot, type RecordedExit } from '../scripts/simulator-boot'

function deferred<T>(): { promise: Promise<T>, resolve: (value: T) => void, reject: (error: unknown) => void } {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

test('a boot is started without waiting for the device to be ready', async () => {
  const exit = deferred<RecordedExit>()
  const commands: string[][] = []
  const boot = startSimulatorBoot('DEVICE-1', (command) => { commands.push(command); return exit.promise }, () => 10_000)

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
  const boot = startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 0, finishedAt: 124_000 }), () => clock)
  // The build held the event loop for 400 seconds after a 124-second boot.
  clock = 400_000
  expect((await boot.ready).seconds).toBe(124)
})

test('a boot that could not run settles, and is told apart from a ready device', async () => {
  const refused = startSimulatorBoot('DEVICE-1', () => { throw new Error('xcrun is missing') }, () => 0)
  expect(await refused.ready).toEqual({ exitCode: null, seconds: 0 })
  const failed = startSimulatorBoot('DEVICE-1', async () => ({ exitCode: 149, finishedAt: 3_000 }), () => 0)
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
