import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { coreLeg, nativeNavigationGroup, nativeNavigationGroups, verifyNativeNavigationResults } from '../scripts/native-navigation-groups'

const source = readFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationUITests.swift'), 'utf8')

const selector = (name: string) => `NativeNavigationUITests/NativeNavigationUITests/${name}`

test('required UI groups cover every actual navigation test exactly once', () => {
  const all = [...source.matchAll(/^\s*func\s+(test\w+)\s*\(/gm)].map(match => selector(match[1]!))
  expect(nativeNavigationGroups).toEqual(['core-1', 'core-2', 'controls-1', 'controls-2'])
  const groups = Object.fromEntries(nativeNavigationGroups.map(group => [group, nativeNavigationGroup(source, group)]))
  expect(all.length).toBeGreaterThanOrEqual(19)
  // The controls journeys were one case of 697 lines (#505), then one leg of
  // six that reached the job's limit; now two legs of three, balanced by
  // measured time (#508), in the order they run.
  expect(groups['controls-1']).toEqual([
    'testImagesListsAndControlStylesReconcile',
    'testGridFlexAndMeasuredLayoutFrames',
    'testAShortScrollFromAPressableDoesNotPressIt',
  ].map(selector))
  expect(groups['controls-2']).toEqual([
    'testLinksPressablesAndAccessibilityState',
    'testSwitchPickerModalSliderAndIndicators',
    'testPushNativeBackSwipeReplaceAndRetainedHomeState',
  ].map(selector))
  const every = Object.values(groups).flat()
  expect(every.sort()).toEqual([...all].sort())
  expect(new Set(every).size).toBe(all.length)
  // Neither core leg is a token one: today they hold 16 and 17 cases.
  for (const group of ['core-1', 'core-2'])
    expect(groups[group]!.length).toBeGreaterThanOrEqual(Math.floor((all.length - 6) / 3))
})

test('a case keeps its core leg from its name alone, whatever is added around it', () => {
  const before = nativeNavigationGroup(source, 'core-1')
  const added = `${source}\nfunc testFutureNativeControl() {}\nfunc testAnotherFutureCase() {}`
  const after = nativeNavigationGroup(added, 'core-1')
  expect(after.filter(name => before.includes(name))).toEqual(before)
  expect(nativeNavigationGroup(added, 'core-2').filter(name => before.includes(name))).toEqual([])
  for (const name of ['testFutureNativeControl', 'testAnotherFutureCase'])
    expect(nativeNavigationGroup(added, `core-${coreLeg(name)}`)).toContain(selector(name))
})

test('new UI cases join required coverage without updating a selector list', () => {
  const added = `${source}\nfunc testFutureNativeControl() {}`
  expect([...nativeNavigationGroup(added, 'core-1'), ...nativeNavigationGroup(added, 'core-2')])
    .toContain(selector('testFutureNativeControl'))
})

test('invalid, empty or ambiguous native UI coverage fails closed', () => {
  for (const group of ['optional', 'core', 'controls', 'core-3', 'controls-0'])
    expect(() => nativeNavigationGroup(source, group), group).toThrow('Unknown')
  expect(() => nativeNavigationGroup('', 'core-1')).toThrow('coverage')
  // Any one controls journey going missing fails closed, in every group.
  for (const journey of ['controls-1', 'controls-2'].flatMap(group => nativeNavigationGroup(source, group)).map(name => name.split('/').pop()!)) {
    for (const group of nativeNavigationGroups)
      expect(() => nativeNavigationGroup(source.replace(`func ${journey}`, 'func renamedAway'), group), `${journey} renamed, ${group}`).toThrow('coverage')
  }
  expect(() => nativeNavigationGroup(`${source}\nfunc testTabSwipeSwitchesNativeRootsAndReturns() {}`, 'core-1')).toThrow('coverage')
})

test('XCTest must execute every selected case without failures or skips', () => {
  const expected = nativeNavigationGroup(source, 'core-1').length
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
