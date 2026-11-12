import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { launchWait, longLaunchWaitSeconds, simulatorLogWindow, testsBeganAt } from '../scripts/launch-wait'

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

test('the navigation script measures the wait and keeps the log of a long one', () => {
  const script = readFileSync(join(import.meta.dir, '../scripts/test-native-navigation.ts'), 'utf8')
  expect(script).toContain('reportLaunchWait(')
  // The function, from its first line to the one that follows it.
  const report = script.slice(script.indexOf('function reportLaunchWait('), script.indexOf('function assertMutationBundle('))
  expect(report.length).toBeGreaterThan(200)
  expect(report).toContain('launchWait(')
  expect(report).toContain('if (seconds < longLaunchWaitSeconds) return')
  expect(report).toContain('simulatorLogWindow(')
  // It is evidence: reading it must never fail a run that passed, or hide a failure.
  expect(report).toContain('catch (error)')
  // And it runs whether the tests passed or not.
  expect(script).toContain('    finally {\n      if (testCommand) reportLaunchWait(')
})
