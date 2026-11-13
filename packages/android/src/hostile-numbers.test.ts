import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * No number a screen can put in a prop or a style ends the app, or blanks it.
 *
 * A prop is whatever the script said, and a script's numbers come from data.
 * On Android `numColumns={Number.MAX_VALUE}` reached `GridLayoutManager` as
 * the largest Int and came back as `NegativeArraySizeException` in layout,
 * where nothing catches it. A slider whose minimum and maximum were the same
 * huge number divided nothing by nothing and threw on rounding it. A
 * transform that multiplied past a Float was refused by `View.setScaleX`. A
 * grid told to have 2^31 rows made a list that long (#528).
 *
 * `NativeHostileNumbersTest` renders every component with every prop and
 * style key set to such numbers, on an emulator. This file keeps that
 * honest: every key the templates read from a node's props or style is in
 * that fixture, so a prop or style added to the host is drawn with hostile
 * numbers from the day it is added. It also pins the bounds the host now
 * puts those numbers through.
 */
const templates = join(import.meta.dir, '../templates')
const main = readFileSync(join(templates, 'MainActivityNative.kt.template'), 'utf8')
const flatList = readFileSync(join(templates, 'CraftNativeFlatList.kt.template'), 'utf8')
const refreshable = readFileSync(join(templates, 'CraftNativeRefreshableFlatList.kt.template'), 'utf8')
const host = `${main}\n${flatList}\n${refreshable}`
const fixture = readFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeHostileNumbersTest.kt'), 'utf8')

function listed(name: string): string[] {
  const start = fixture.indexOf(`val ${name} = listOf(`)
  expect(start, `the fixture must still list its ${name}`).toBeGreaterThan(-1)
  return [...fixture.slice(start, fixture.indexOf('\n        )\n', start)).matchAll(/"([A-Za-z]+)"/g)].map(match => match[1]!)
}

function read(...patterns: RegExp[]): string[] {
  return [...new Set(patterns.flatMap(pattern => [...host.matchAll(pattern)].map(match => match[1]!)))].sort()
}

test('the fixture sets every prop the host reads', () => {
  const props = read(/\bprops\??\.(?:opt\w*|has|isNull)\("([A-Za-z]+)"/g, /craftNative\w+\(props, "([A-Za-z]+)"/g)
  expect(props.length).toBeGreaterThan(100)
  expect(props.filter(name => !listed('props').includes(name))).toEqual([])
})

test('the fixture sets every style the host reads', () => {
  const styles = read(
    /\b(?:style|raw)\??\.(?:opt\w*|has|isNull)\("([A-Za-z]+)"/g,
    /craftNative\w+\((?:style|raw), "([A-Za-z]+)"/g,
    // The layout style and a drawing read theirs through local functions.
    /\b(?:length|numeric|number|decimal|spacing)\("([A-Za-z]+)"\)/g,
  )
  expect(styles.length).toBeGreaterThan(70)
  // Read the same way, and not a view's style: a drawing's own attributes, a
  // celebration and a chart's inspection. The fixture sets each where it
  // belongs, so it is enough that it names them.
  const elsewhere = ['enabled', 'fillOpacity', 'points', 'replay', 'strokeDashoffset', 'strokeMiterlimit', 'strokeOpacity', 'title']
  expect(styles.filter(name => !listed('styles').includes(name)).sort()).toEqual(elsewhere)
  for (const name of elsewhere) expect(fixture, name).toContain(`"${name}"`)
})

test('the fixture draws every component the host builds, bar the four it names', () => {
  const start = main.indexOf('        val control = when (type) {')
  expect(start).toBeGreaterThan(-1)
  const built = [...main.slice(start, main.indexOf('\n            else -> ', start)).matchAll(/^ {12}((?:"[A-Za-z]+"(?:, )?)+) ->/gm)]
    .flatMap(match => [...match[1]!.matchAll(/"([A-Za-z]+)"/g)].map(name => name[1]!))
  expect(built.length).toBeGreaterThan(20)
  // Not drawn here: a Modal moves into the screen's own view, a Video and a
  // Map start players and tile loads, and a StatusBar draws nothing. Their
  // style numbers are read by the same functions as everyone else's.
  const left = ['Modal', 'Video', 'Map', 'StatusBar']
  expect([...listed('types'), ...left].sort()).toEqual([...new Set(built)].sort())
})

test('a list and a grid are given no more tracks than a screen could show', () => {
  expect(flatList).toContain('internal const val CRAFT_NATIVE_FLAT_LIST_MAX_COLUMNS = 1024')
  expect(flatList).toContain('val nextColumns = columns.coerceIn(1, CRAFT_NATIVE_FLAT_LIST_MAX_COLUMNS)')
  expect(flatList).not.toContain('columns.coerceAtLeast(1)')
  expect(main).toContain('internal const val CRAFT_NATIVE_GRID_TRACK_LIMIT = 1024')
  expect(main).toContain('if (value is Number) return value.toInt().coerceIn(1, CRAFT_NATIVE_GRID_TRACK_LIMIT)')
  // A count too long for an Int is still too many, not the two words it is.
  expect(main).toContain('return (digits.toIntOrNull() ?: CRAFT_NATIVE_GRID_TRACK_LIMIT).coerceIn(1, CRAFT_NATIVE_GRID_TRACK_LIMIT)')
  expect(main).toContain('private fun craftNativeGridColumnCount(value: Any?): Int = craftNativeGridTrackCount(value) ?: 1')
  expect(main).toContain('private fun craftNativeGridRowCount(value: Any?): Int? = craftNativeGridTrackCount(value)')
  expect(main).not.toContain('return max(1, value.toInt())')
})

test('a slider has a range that is a number, and a value inside it', () => {
  expect(main).toContain('val bound = Double.MAX_VALUE / 4')
  expect(main).toContain('val minimum = craftNativeFiniteNumber(props, "minimumValue", 0.0).coerceIn(-bound, bound)')
  expect(main).toContain('val maximum = if (maximumCandidate > minimum) maximumCandidate else Math.nextUp(minimum)')
  expect(main).toContain('val requested = craftNativeFiniteNumber(props, "value", minimum).coerceIn(minimum, maximum)')
  expect(main).not.toContain('minimum + Double.MIN_VALUE')
})

test('what reaches a view as a scale, an offset or an angle goes through one bound', () => {
  expect(main).toContain('internal const val CRAFT_NATIVE_LAYOUT_LIMIT = 33_554_432f')
  const start = main.indexOf('    private fun applyTransform(view: View, transforms: JSONArray?) {')
  const body = main.slice(start, main.indexOf('\n    }\n', start))
  // Summed and multiplied into locals, and set once each, bounded.
  expect(body).not.toMatch(/view\.(?:translationX|translationY|scaleX|scaleY|rotation|rotationX|rotationY) [+*]?= (?!craftNativeLayoutNumber\()/)
  for (const property of ['translationX', 'translationY', 'scaleX', 'scaleY', 'rotation', 'rotationX', 'rotationY'])
    expect(body).toContain(`view.${property} = craftNativeLayoutNumber(${property})`)
  expect(main).toContain('?.let { craftNativeLayoutNumber(it).coerceAtLeast(0.5f) } ?: 1f')
})
