import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * No number a screen can put in a style ends the app.
 *
 * A style is whatever the script said, and its numbers come from data.
 * `flex: Number.MAX_VALUE` is finite, so it passed every check, and became an
 * infinite share of a row, an infinite frame, and then UIKit's
 * `NSLayoutConstraint constant is not finite! That's illegal`, an exception
 * nothing catches. A `padding` of the same on a button reached UIKit as an
 * inset and came back as `CALayer position contains NaN`. Either ended the
 * process.
 *
 * `HostileNumbersUnitTests` renders every component with every prop and style
 * key the host reads set to such numbers, on a simulator. This file keeps
 * that honest: its lists are the keys the templates actually read, so a prop
 * or style added to the host is drawn with hostile numbers from the day it
 * is added. It also runs the one function everything now passes through.
 */
const templates = join(import.meta.dir, '../templates')
const screen = readFileSync(join(templates, 'CraftNativeScreen.swift'), 'utf8')
const flatList = readFileSync(join(templates, 'CraftNativeFlatList.swift'), 'utf8')
const fixture = readFileSync(join(import.meta.dir, '../fixtures/native-screen/HostileNumbersUnitTests.swift'), 'utf8')

function listed(name: string): string[] {
  const start = fixture.indexOf(`static let ${name}: [String] = [`)
  expect(start, `the fixture must still list its ${name}`).toBeGreaterThan(-1)
  const body = fixture.slice(start, fixture.indexOf('\n    ]\n', start))
  return [...body.matchAll(/"([A-Za-z]+)"/g)].map(match => match[1]!)
}

function read(pattern: RegExp): string[] {
  return [...new Set([...`${screen}\n${flatList}`.matchAll(pattern)].map(match => match[1]!))].sort()
}

test('the fixture draws every prop the host reads', () => {
  expect(listed('props')).toEqual(read(/props\["([A-Za-z]+)"\]/g))
})

test('the fixture draws every style the host reads', () => {
  expect(listed('styles')).toEqual(read(/(?:style|raw)\["([A-Za-z]+)"\]/g))
})

test('the fixture draws every component the host builds, bar the four it names', () => {
  const start = screen.indexOf('    private func makeView(_ type: String, props: [String: Any]) -> UIView {')
  const built = [...screen.slice(start, screen.indexOf('\n    }\n', start)).matchAll(/case ((?:"[A-Za-z]+"(?:, )?)+):/g)]
    .flatMap(match => [...match[1]!.matchAll(/"([A-Za-z]+)"/g)].map(name => name[1]!))
  expect(built.length).toBeGreaterThan(20)
  // Not drawn here: a Modal presents a controller, a Video and a Map start
  // players and tile loads, and a StatusBar draws nothing. Their style
  // numbers are read by the same functions as everyone else's.
  const left = ['Modal', 'Video', 'Map', 'StatusBar']
  expect([...listed('types'), ...left].sort()).toEqual([...new Set(built)].sort())
})

test('every style number is read through the bound, and every flex frame leaves through it', () => {
  // The plain reader accepts any finite number; a style must not use it.
  expect(screen).not.toContain('number(style[')
  expect(screen).not.toContain('number(transform[')
  expect(screen).toContain('guard let value = styleNumber(value), value >= 0 else { return nil }')
  expect(screen).toContain('return value.isFinite ? craftNativeLayoutNumber(value) : nil')
  expect(screen).toContain('self = .points(craftNativeLayoutNumber(points))')
  expect(screen).toContain('self = .percent(craftNativeLayoutNumber(CGFloat(fraction) / 100))')
  expect(screen).toContain('func snap(_ value: CGFloat) -> CGFloat { (craftNativeLayoutNumber(value) * scale).rounded() / scale }')
  expect(screen).toContain('func up(_ value: CGFloat) -> CGFloat { (craftNativeLayoutNumber(value) * scale - 0.001).rounded(.up) / scale }')
})

test.skipIf(process.platform !== 'darwin')('a layout number is held inside 2^25 either side of zero, and is 0 when it is not a number', () => {
  const limit = 'let craftNativeLayoutLimit: CGFloat = 33_554_432'
  expect(screen).toContain(limit)
  const start = screen.indexOf('func craftNativeLayoutNumber(_ value: CGFloat) -> CGFloat {')
  expect(start, 'craftNativeLayoutNumber must still be here to test').toBeGreaterThan(-1)
  const dir = createTempDir('craft-layout-number-')
  try {
    const main = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(main, `import Foundation
${limit}
${screen.slice(start, screen.indexOf('\n}\n', start) + 3)}
let text = CommandLine.arguments[1]
let value: CGFloat = text == "nan" ? .nan : text == "inf" ? .infinity : text == "-inf" ? -.infinity : CGFloat(Double(text)!)
let held = craftNativeLayoutNumber(value)
// What the flex engine does with it: a Float, and a few multiplied together.
let product = Float(held) * Float(held) * Float(held) * Float(held) * Float(held)
print("\\(held) \\(product.isFinite)")
`)
    const build = Bun.spawnSync(['swiftc', main, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const cases: [string, string][] = [
      ['1.7976931348623157e308', '33554432.0 true'],
      ['-1.7976931348623157e308', '-33554432.0 true'],
      ['1e30', '33554432.0 true'],
      ['inf', '33554432.0 true'],
      ['-inf', '-33554432.0 true'],
      ['nan', '0.0 true'],
      ['33554433', '33554432.0 true'],
      // Ordinary numbers are what they were.
      ['33554432', '33554432.0 true'],
      ['390', '390.0 true'],
      ['-12.5', '-12.5 true'],
      ['0', '0.0 true'],
    ]
    const wrong: string[] = []
    for (const [given, expected] of cases) {
      const run = Bun.spawnSync([binary, given], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      const got = run.exitCode === 0 ? run.stdout.toString().trim() : `the process ended (${run.signalCode ?? run.exitCode})`
      if (got !== expected) wrong.push(`${given}: expected ${expected}, got ${got}`)
    }
    expect(wrong).toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)
