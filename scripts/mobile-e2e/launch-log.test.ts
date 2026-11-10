import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { launchLogPredicate, logShowStart } from './ios'

/**
 * The window that answers #450 is kept while it still exists.
 *
 * #450 is down to one question — why SpringBoard accepted a tap on a
 * resolved, enabled banner and began no launch. Only SpringBoard's own log
 * can answer it, and in both retained occurrences that log starts minutes
 * *after* the failure: the job-level step runs `log show --last 10m` at
 * teardown, on a device writing roughly three thousand lines a second, so the
 * window is gone before anything looks for it.
 *
 * These pin the two things that make the replacement work: a start bound
 * taken from when the invocation began, and a predicate narrow enough that
 * the capture is not itself unmanageable.
 */
const harness = readFileSync(join(import.meta.dir, 'ios.ts'), 'utf8').replace(/^\s*\/\/[^\n]*$/gm, '')

test('the start bound is local wall-clock to the second, as log show wants', () => {
  // `log show --start` parses local time. An ISO string with a `T` and a `Z`
  // is both the wrong shape and the wrong zone, and silently yields a window
  // that is hours wide or empty.
  const at = new Date(2026, 10, 4, 21, 8, 28, 597)
  expect(logShowStart(at)).toBe('2026-11-04 21:08:28')
  expect(logShowStart(at)).not.toContain('T')
  expect(logShowStart(at)).not.toContain('Z')
})

test('single-digit months, days and times stay two digits', () => {
  // 2026-1-4 1:2:3 is not a time log show accepts.
  expect(logShowStart(new Date(2026, 0, 4, 1, 2, 3))).toBe('2026-01-04 01:02:03')
})

test('the predicate names the processes that decide a launch', () => {
  const predicate = launchLogPredicate()
  // SpringBoard decides it; runningboardd and launchd_sim carry it out.
  // Without these three the capture cannot answer the question it exists for.
  for (const process of ['SpringBoard', 'runningboardd', 'launchd_sim', 'usernotificationsd']) {
    expect(predicate, `${process} must be kept`).toContain(`process == "${process}"`)
  }
  // A filter is an enumeration, so it is at least an honest disjunction
  // rather than something that quietly matches nothing.
  expect(predicate).toMatch(/^process == "[^"]+"( OR process == "[^"]+")+$/)
})

test('the capture is bounded by when the invocation began, not by a fixed window', () => {
  // `--last 10m` is what fails today: anchored at the moment of collection,
  // so it can never reach a failure older than its own fixed span.
  expect(harness).toContain("'--start', logShowStart(since)")
  expect(harness, 'a fixed window cannot follow the failure').not.toMatch(/'--last'/)
})

test('the capture runs while the window still exists', () => {
  // Right after the invocation it covers, not at job teardown. The start
  // timestamp must be taken before the test is spawned, or the window begins
  // after the thing it is meant to contain.
  const spawnAt = harness.indexOf('const notificationStartedAt = new Date()')
  const useAt = harness.indexOf('captureLaunchLog(device.udid, notificationStartedAt')
  const exitAt = harness.indexOf('await tapping.exited')
  expect(spawnAt, 'the invocation must record when it began').toBeGreaterThan(0)
  expect(exitAt, 'the invocation must be awaited').toBeGreaterThan(spawnAt)
  expect(useAt, 'the window must be captured after the invocation it covers').toBeGreaterThan(exitAt)
  expect(harness.indexOf("const tapping = Bun.spawn(uiTest('NotificationTapColdStartTests')"))
    .toBeGreaterThan(spawnAt)
})
