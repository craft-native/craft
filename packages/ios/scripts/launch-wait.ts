/**
 * How long XCTest took to begin, read from the job's own log.
 *
 * Between `xcodebuild test-without-building` and the runner's first line,
 * "Running tests...", a CI simulator has taken 36, 40, 41, 59, 392 and 444
 * seconds on the same fixture (#508), with nothing printed in between and the
 * simulator long since booted. On a leg limited to 45 minutes that is the
 * largest cost nobody can explain. These say when it happened and name the
 * window, so the simulator's own log for it can be kept.
 */

/** The runner's first line carries its own clock: `2026-11-12 13:26:36.860770+0000 …Runner[…] [Default] Running tests...`. */
const began = /(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)([+-])(\d\d)(\d\d) \S*\[\d+:\d+\] \[Default\] Running tests\.\.\./

/** When the first runner in `log` began its tests, or undefined when none did. */
export function testsBeganAt(log: string): Date | undefined {
  const match = began.exec(log)
  if (!match) return undefined
  const [, year, month, day, hour, minute, second, fraction, sign, offsetHours, offsetMinutes] = match
  const utc = Date.UTC(+year, +month - 1, +day, +hour, +minute, +second, Math.round(+`0.${fraction}` * 1000))
  const offset = (+offsetHours * 60 + +offsetMinutes) * 60_000 * (sign === '-' ? -1 : 1)
  return new Date(utc - offset)
}

/**
 * Seconds from the test command to the first test, from what the command
 * printed after it started. Undefined when the runner never began.
 */
export function launchWait(logSinceCommand: string, commandStarted: Date): number | undefined {
  const at = testsBeganAt(logSinceCommand)
  return at ? Math.max(0, Math.round((at.getTime() - commandStarted.getTime()) / 1000)) : undefined
}

/** A wait this long is worth the simulator's log; the ordinary ones were under a minute. */
export const longLaunchWaitSeconds = 90

/**
 * `log show` for the simulator's log between two moments. It takes local
 * times without a zone, and the simulator shares the host's.
 */
export function simulatorLogWindow(udid: string, from: Date, to: Date): string[] {
  const local = (date: Date) => {
    const pad = (value: number) => String(value).padStart(2, '0')
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  }
  return ['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--style', 'compact', '--start', local(from), '--end', local(to)]
}
