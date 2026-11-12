import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A case that pulls to refresh says so if the app does not settle after it.
 *
 * On one CI run the app never reported its animations idle after a pull to
 * refresh. XCTest waited its 60 seconds before each of the eight steps that
 * followed and then carried on, so the case passed after 516 seconds instead
 * of 30 and its leg reached the 45-minute limit with nothing to show what
 * was moving (#522). The first tap after each pull now fails within a minute
 * and keeps a picture.
 */
const fixture = readFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationUITests.swift'), 'utf8')

test('every pull to refresh is followed by a tap that fails when the app has not settled', () => {
  const pulls = [...fixture.matchAll(/\.swipeDown\(\)/g)].map(match => match.index)
  expect(pulls.length).toBeGreaterThan(0)
  for (const [index, pull] of pulls.entries()) {
    // Up to the next pull, or the end of the case it is in.
    const end = Math.min(pulls[index + 1] ?? fixture.length, fixture.indexOf('\n    }\n', pull))
    const after = fixture.slice(pull, end)
    const line = fixture.slice(0, pull).split('\n').length
    expect(after, `the pull on line ${line} is followed by no settled tap`).toContain('guard tapExpectingIdle(')
    // And by no plain tap before it, which would wait the full minute and pass.
    expect(after.slice(0, after.indexOf('guard tapExpectingIdle(')), `a plain tap follows the pull on line ${line}`).not.toMatch(/\.tap\(\)/)
  }
})

test('a tap that took half of XCTest\'s animation wait fails the case and keeps a picture', () => {
  const start = fixture.indexOf('    private func tapExpectingIdle(')
  const helper = fixture.slice(start, fixture.indexOf('    private func waitForLabel(', start))
  expect(helper.length).toBeGreaterThan(300)
  expect(helper).toContain('guard waited > Self.settleLimit else { return true }')
  expect(helper).toContain('XCTAttachment(screenshot: app.screenshot())')
  expect(helper).toContain('picture.lifetime = .keepAlways')
  expect(helper).toContain('XCTFail(')
  expect(helper).toContain('return false')
  // XCTest gives animations 60 seconds; an ordinary tap takes under five.
  const limit = Number(/private static let settleLimit: TimeInterval = (\d+)/.exec(helper)?.[1])
  expect(limit).toBeGreaterThanOrEqual(15)
  expect(limit).toBeLessThan(60)
})
