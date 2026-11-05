import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A system picker's Cancel must be tapped when it can take the tap.
 *
 * `waitForExistence` only proves the button is in the hierarchy. A sheet still
 * animating in is there and not yet hittable, and the tap synthesized then
 * lands on nothing — XCTest records the event as sent, the sheet stays up, and
 * the page never answers. That is how
 * testLibraryPickerAbortAndScreenDisposalReleaseBusySlot failed on main: the
 * status stayed at the previous step's value until the wait expired.
 */
const fixture = readFileSync(join(import.meta.dir, '../fixtures/native-screen/NativeRenderUITests.swift'), 'utf8')

test('every system-sheet Cancel is tapped only once it is hittable', () => {
  // No site may go back to tapping the bare element.
  expect(fixture).not.toContain('cancel.tap()')
  expect(fixture.match(/tapWhenHittable\(cancel, "picker Cancel"\)/g)?.length).toBe(5)
})

test('the hittable wait observes hittability and keeps the sheet deadline', () => {
  const start = fixture.indexOf('    private func tapWhenHittable(')
  const end = fixture.indexOf('    private func waitForValue(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const helper = fixture.slice(start, end)
  // The condition that was always meant, inside the patience the sheet had.
  expect(helper).toContain('while !element.isHittable && Date() < deadline')
  expect(helper).toContain('Date().addingTimeInterval(systemSheetTimeout)')
  // It must fail loudly rather than tap into the void after the deadline.
  expect(helper).toContain('XCTAssertTrue(element.isHittable')
  expect(helper.indexOf('XCTAssertTrue(element.isHittable')).toBeLessThan(helper.indexOf('element.tap()'))
})
