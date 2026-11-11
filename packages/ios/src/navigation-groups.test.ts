import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { nativeNavigationGroup, verifyNativeNavigationResults } from '../scripts/native-navigation-groups'

const source = readFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationUITests.swift'), 'utf8')

test('required UI groups cover every actual navigation test exactly once', () => {
  const all = [...source.matchAll(/^\s*func\s+(test\w+)\s*\(/gm)].map(match => `NativeNavigationUITests/NativeNavigationUITests/${match[1]}`)
  const core = nativeNavigationGroup(source, 'core')
  const controls = nativeNavigationGroup(source, 'controls')
  expect(all.length).toBeGreaterThanOrEqual(19)
  // The controls journeys were one case of 697 lines (#505), now five, in
  // the order they run; the journey the old name described keeps it. A
  // scroll that must not press is with them, on the same home screen.
  expect(controls).toEqual([
    'testImagesListsAndControlStylesReconcile',
    'testGridFlexAndMeasuredLayoutFrames',
    'testAShortScrollFromAPressableDoesNotPressIt',
    'testLinksPressablesAndAccessibilityState',
    'testSwitchPickerModalSliderAndIndicators',
    'testPushNativeBackSwipeReplaceAndRetainedHomeState',
  ].map(name => `NativeNavigationUITests/NativeNavigationUITests/${name}`))
  expect(core.length).toBe(all.length - controls.length)
  expect([...core, ...controls].sort()).toEqual(all.sort())
  expect(new Set([...core, ...controls]).size).toBe(all.length)
})

test('new UI cases join required coverage without updating a selector list', () => {
  expect(nativeNavigationGroup(`${source}\nfunc testFutureNativeControl() {}`, 'core'))
    .toContain('NativeNavigationUITests/NativeNavigationUITests/testFutureNativeControl')
})

test('invalid, empty or ambiguous native UI coverage fails closed', () => {
  expect(() => nativeNavigationGroup(source, 'optional')).toThrow('Unknown')
  expect(() => nativeNavigationGroup('', 'core')).toThrow('coverage')
  // Any one controls journey going missing fails closed, in either group.
  for (const journey of nativeNavigationGroup(source, 'controls').map(selector => selector.split('/').pop()!)) {
    for (const group of ['controls', 'core'])
      expect(() => nativeNavigationGroup(source.replace(`func ${journey}`, 'func renamedAway'), group), `${journey} renamed, ${group}`).toThrow('coverage')
  }
  expect(() => nativeNavigationGroup(`${source}\nfunc testTabSwipeSwitchesNativeRootsAndReturns() {}`, 'core')).toThrow('coverage')
})

test('XCTest must execute every selected case without failures or skips', () => {
  const expected = nativeNavigationGroup(source, 'core').length
  const passed = { result: 'Passed', totalTestCount: expected, passedTests: expected, failedTests: 0, skippedTests: 0 }
  expect(verifyNativeNavigationResults(passed, expected)).toBe(expected)
  expect(() => verifyNativeNavigationResults({ ...passed, totalTestCount: expected - 1, passedTests: expected - 1 }, expected)).toThrow('complete')
  for (const incomplete of [
    { ...passed, result: 'Failed' },
    { ...passed, totalTestCount: 0, passedTests: 0 },
    { ...passed, passedTests: expected - 1 },
    { ...passed, failedTests: 1 },
    { ...passed, skippedTests: 1 },
  ]) expect(() => verifyNativeNavigationResults(incomplete, expected)).toThrow('complete')
})
