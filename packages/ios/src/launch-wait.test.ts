import { expect, test } from 'bun:test'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { hostActivityCommands, launchWait, launchWaitSnapshotSeconds, launchWaitStep, longLaunchWaitSeconds, simulatorLogWindow, testsBeganAt } from '../scripts/launch-wait'

// Lines as two CI jobs and a local run printed them (#508). GitHub prefixes
// its own timestamp; the runner's is the one inside the line.
const slow = `2026-11-12T13:20:09.3050250Z --- xcodebuild: WARNING: Using the first of multiple matching destinations:
2026-11-12T13:20:09.3160190Z { platform:iOS Simulator, arch:arm64, id:2FEACF5E-886C-4FB8-A137-C571FBA5CF5C, OS:26.2, name:iPhone 17 Pro }
2026-11-12T13:26:37.0186900Z 2026-11-12 13:26:36.860770+0000 NativeNavigationUITests-Runner[31286:85371] [Default] Running tests...
2026-11-12T13:26:50.1000000Z Test Case '-[NativeNavigationUITests.NativeNavigationUITests testAButtonUnderTheKeyboardOnATabScreenScrollsIntoView]' started.
`
const local = `2026-11-12 20:16:59.748834+0800 NativeNavigationUITests-Runner[39186:12805948] [Default] Running tests...
`

test('the wait before the first test is read from the runner\'s own clock', () => {
  expect(testsBeganAt(slow)?.toISOString()).toBe('2026-11-12T13:26:36.861Z')
  // The 392 seconds of the leg that took 44 of its 45 minutes.
  expect(launchWait(slow, new Date('2026-11-12T13:20:04.867Z'))).toBe(392)
  // A zone east of Greenwich is the same moment.
  expect(testsBeganAt(local)?.toISOString()).toBe('2026-11-12T12:16:59.749Z')
  expect(launchWait(local, new Date('2026-11-12T12:16:40.000Z'))).toBe(20)
  // And one west of it.
  expect(testsBeganAt('2026-03-01 23:59:58.500000-0530 Runner[1:2] [Default] Running tests...')?.toISOString()).toBe('2026-03-02T05:29:58.500Z')
})

test('a runner that never began has no wait, and a later runner is not the first', () => {
  expect(launchWait('xcodebuild failed before any runner started\n', new Date())).toBeUndefined()
  expect(testsBeganAt('The app printed "Running tests..." in a label\n')).toBeUndefined()
  const twice = `${slow}2026-11-12T13:40:00.0000000Z 2026-11-12 13:40:00.000000+0000 NativeNavigationUITests-Runner[40000:1] [Default] Running tests...\n`
  expect(launchWait(twice, new Date('2026-11-12T13:20:04.867Z'))).toBe(392)
  // A clock that disagrees by a moment is not a negative wait.
  expect(launchWait(slow, new Date('2026-11-12T13:26:37.500Z'))).toBe(0)
})

test('the simulator\'s log is asked for between the two moments, in local time', () => {
  const from = new Date(2026, 10, 12, 13, 20, 4)
  const to = new Date(2026, 10, 12, 13, 26, 37)
  expect(simulatorLogWindow('DEVICE-1', from, to)).toEqual([
    'xcrun', 'simctl', 'spawn', 'DEVICE-1', 'log', 'show', '--style', 'compact',
    '--start', '2026-11-12 13:20:04', '--end', '2026-11-12 13:26:37',
  ])
  // The ordinary waits (36 to 59 s) are not kept; the long ones (392, 444) are.
  expect(longLaunchWaitSeconds).toBeGreaterThan(59)
  expect(longLaunchWaitSeconds).toBeLessThan(392)
})

test('a watcher reports the wait when the runner speaks, and asks the host what it is doing while it is silent', () => {
  const started = new Date('2026-11-12T15:33:25.000Z')
  const at = (seconds: number) => new Date(started.getTime() + seconds * 1000)
  // Silent and ordinary: nothing to do yet.
  expect(launchWaitStep('', started, at(40), 0)).toEqual({ began: false, seconds: 40, snapshot: false })
  expect(launchWaitStep('', started, at(longLaunchWaitSeconds - 1), 0)).toEqual({ began: false, seconds: longLaunchWaitSeconds - 1, snapshot: false })
  // Silent past a long wait: once now, and once a minute after.
  expect(launchWaitStep('', started, at(longLaunchWaitSeconds), 0)).toEqual({ began: false, seconds: longLaunchWaitSeconds, snapshot: true })
  expect(launchWaitStep('', started, at(longLaunchWaitSeconds + 1), 1)).toEqual({ began: false, seconds: longLaunchWaitSeconds + 1, snapshot: false })
  const later = longLaunchWaitSeconds + launchWaitSnapshotSeconds
  expect(launchWaitStep('', started, at(later), 1)).toEqual({ began: false, seconds: later, snapshot: true })
  expect(launchWaitStep('', started, at(later), 2)).toEqual({ began: false, seconds: later, snapshot: false })
  // The leg that reached its 45-minute limit (run 43247407071): 410 seconds.
  const spoke = '2026-11-12T15:40:16.0673890Z 2026-11-12 15:40:15.292700+0000 NativeNavigationUITests-Runner[32517:87707] [Default] Running tests...\n'
  expect(launchWaitStep(spoke, started, at(411), 6)).toEqual({ began: true, seconds: 410, keepLog: true })
  // An ordinary one is reported and nothing is kept.
  expect(launchWaitStep(spoke, new Date('2026-11-12T15:39:37.000Z'), at(411), 0)).toEqual({ began: true, seconds: 38, keepLog: false })
  expect(hostActivityCommands.map(command => command[0])).toEqual(['sysctl', 'ps'])
})

const watcher = join(import.meta.dir, '../scripts/launch-wait-watch.ts')

/** The runner's first line, dated `seconds` after `started`, as xcodebuild prints it. */
function runnerSpoke(started: Date, seconds: number): string {
  const at = new Date(started.getTime() + seconds * 1000).toISOString().replace('T', ' ').replace('Z', '000+0000')
  return `${at} NativeNavigationUITests-Runner[100:200] [Default] Running tests...\n`
}

async function untilPrinted(read: () => string, wanted: string, milliseconds: number): Promise<string> {
  const deadline = Date.now() + milliseconds
  while (!read().includes(wanted) && Date.now() < deadline) await Bun.sleep(100)
  return read()
}

test.skipIf(process.platform !== 'darwin')('the watcher writes the wait down while the test command is still running', async () => {
  const dir = createTempDir('craft-launch-wait-')
  try {
    const log = join(dir, 'navigation.log'), kept = join(dir, 'navigation.xcresult.launch-wait.log'), out = join(dir, 'watch.out')
    writeFileSync(log, 'printed by the build, before the test command\n')
    const before = readFileSync(log).length
    // A command that started 200 seconds ago and whose runner has said nothing.
    const started = new Date(Date.now() - 200_000)
    const watch = Bun.spawn([process.execPath, watcher, log, String(before), String(started.getTime()), 'NO-SUCH-DEVICE', kept, String(process.pid)], { stdout: Bun.file(out), stderr: 'pipe' })
    const printed = () => existsSync(out) ? readFileSync(out, 'utf8') : ''
    // It has already said so, and written what the host is busy with, though nothing has ended.
    expect(await untilPrinted(printed, 'XCTest has not begun running tests', 20_000)).toMatch(/XCTest has not begun running tests 20\ds after the test command; what the host is busy with is in /)
    const host = readFileSync(join(dir, 'navigation.xcresult.launch-wait.host.txt'), 'utf8')
    expect(host).toMatch(/after the test command, XCTest still silent/)
    expect(host).toContain('vm.loadavg')
    expect(host).toContain('%CPU')
    // The runner speaks, 203 seconds after the command.
    appendFileSync(log, runnerSpoke(started, 203))
    expect(await untilPrinted(printed, 'simulator\'s log', 150_000)).toContain('XCTest began running tests 203s after the test command\n')
    // What the host was busy with as the tests began is written on every run.
    expect(readFileSync(join(dir, 'navigation.xcresult.launch-wait.host.txt'), 'utf8')).toMatch(/203s after the test command, XCTest running tests/)
    // A long wait asks for the simulator's log; there is no such device here, and that is said, not thrown.
    expect(printed()).toContain('Could not read the simulator\'s log for that wait')
    expect(await watch.exited).toBe(0)
  }
  finally { removeTempDir(dir) }
}, 200_000)

test.skipIf(process.platform !== 'darwin')('a watcher told the command returned says when no runner ever began', async () => {
  const dir = createTempDir('craft-launch-wait-')
  try {
    const log = join(dir, 'navigation.log'), out = join(dir, 'watch.out')
    writeFileSync(log, '')
    const watch = Bun.spawn([process.execPath, watcher, log, '0', String(Date.now()), 'NO-SUCH-DEVICE', join(dir, 'kept.log'), String(process.pid)], { stdout: Bun.file(out), stderr: 'pipe' })
    await Bun.sleep(1500)
    watch.kill('SIGTERM')
    expect(await watch.exited).toBe(0)
    expect(readFileSync(out, 'utf8')).toBe('XCTest did not report that it began running tests\n')
    // A runner that never began leaves nothing.
    expect(existsSync(join(dir, 'kept.log'))).toBe(false)
    expect(existsSync(join(dir, 'kept.host.txt'))).toBe(false)
  }
  finally { removeTempDir(dir) }
}, 60_000)

test('the navigation script starts the watcher before the test command and tells it when the command returns', () => {
  const script = readFileSync(join(import.meta.dir, '../scripts/test-native-navigation.ts'), 'utf8')
  // The function, from its first line to the one that follows it.
  const watch = script.slice(script.indexOf('function watchLaunchWait('), script.indexOf('function assertMutationBundle('))
  expect(watch.length).toBeGreaterThan(200)
  expect(watch).toContain('\'launch-wait-watch.ts\'')
  expect(watch).toContain('watch.kill(\'SIGTERM\')')
  // Started with the command, not after it: a job at its limit never reaches a `finally`.
  expect(script).toContain('      launchWatch = watchLaunchWait(liveLog, device.udid, resultBundle)\n      runXcodeTests([')
  expect(script).toContain('    finally {\n      await launchWatch?.stop()')
  expect(script).not.toContain('reportLaunchWait')
})
