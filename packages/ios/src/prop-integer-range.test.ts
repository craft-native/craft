import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A number too large for an `Int` is clamped or refused; it does not end the app.
 *
 * `Int(_:)` traps on a floating-point value it cannot hold. A prop is whatever
 * the screen's script said, and a JSON number can be `1e30`, or
 * `Number.MAX_VALUE` written to mean "no limit":
 *
 *   <TextInput maxLength={Number.MAX_VALUE} />
 *
 * The iOS host converted props with `Int(_:)`, so that ended the process:
 * `Fatal error: Double value cannot be converted to Int because the result
 * would be greater than Int.max`. Android reads the same props with
 * `Number.toInt()`, which takes the nearest end of its range and carries on
 * (#510).
 *
 * The functions under test are the shipped ones, compiled against real
 * Foundation. Each value is converted in a process of its own, so one that
 * traps is seen as one that trapped. The props themselves are rendered on a
 * simulator in testNumbersTooLargeForAnIntAreClampedAndDoNotEndTheProcess.
 */
const templates = join(import.meta.dir, '../templates')
const screen = readFileSync(join(templates, 'CraftNativeScreen.swift'), 'utf8')
const flatList = readFileSync(join(templates, 'CraftNativeFlatList.swift'), 'utf8')
const workouts = readFileSync(join(templates, 'CraftScheduledWorkouts.swift'), 'utf8')

/** A declaration as shipped, from its first line to the line that closes it. */
function lift(source: string, opening: string, closing: string): string {
  const start = source.indexOf(opening)
  expect(start, `${opening} must still be here to test`).toBeGreaterThan(-1)
  const end = source.indexOf(closing, start)
  expect(end).toBeGreaterThan(start)
  return source.slice(start, end + closing.length)
}

function probe(name: string, source: string, cases: [string[], string][]): string[] {
  const dir = createTempDir(`craft-${name}-`)
  try {
    const main = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(main, source)
    const build = Bun.spawnSync(['swiftc', main, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const wrong: string[] = []
    for (const [args, expected] of cases) {
      const run = Bun.spawnSync([binary, ...args], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      const got = run.exitCode === 0 ? run.stdout.toString().trim() : `the process ended (${run.signalCode ?? run.exitCode}): ${run.stderr.toString().split('\n')[0]}`
      if (got !== expected) wrong.push(`${args.join(' ')}: expected ${expected}, got ${got}`)
    }
    return wrong
  }
  finally { removeTempDir(dir) }
}

test.skipIf(process.platform !== 'darwin')('a prop number becomes the Int that toInt() gives on Android, whatever its size', () => {
  const source = `import Foundation
${lift(screen, 'func craftNativeInt(_ value: Double) -> Int {', '\n}\n')}
let text = CommandLine.arguments[1]
let value = text == "nan" ? Double.nan : text == "inf" ? Double.infinity : text == "-inf" ? -Double.infinity : Double(text)!
print(craftNativeInt(value))
`
  expect(probe('prop-int', source, [
    // What ended the process.
    [['1e30'], '2147483647'],
    [['-1e30'], '-2147483648'],
    [['1.7976931348623157e308'], '2147483647'],
    [['-1.7976931348623157e308'], '-2147483648'],
    [['9223372036854775808'], '2147483647'],
    [['inf'], '2147483647'],
    [['-inf'], '-2147483648'],
    [['nan'], '0'],
    // The ends of the range, and one past each.
    [['2147483647'], '2147483647'],
    [['2147483648'], '2147483647'],
    [['-2147483648'], '-2147483648'],
    [['-2147483649'], '-2147483648'],
    // Ordinary numbers are as Int(_:) had them: toward zero.
    [['0'], '0'],
    [['40'], '40'],
    [['2.9'], '2'],
    [['-2.9'], '-2'],
    [['-0.5'], '0'],
  ])).toEqual([])
}, 300_000)

test.skipIf(process.platform !== 'darwin')('a scheduled workout refuses an hour or minute no Int holds instead of trapping on it', () => {
  const source = `import Foundation
enum CraftScheduledWorkouts {
${lift(workouts, '    private static func number(_ value: Any?) -> Double? {', '\n    }\n')}
${lift(workouts, '    private static func whole(_ value: Any?) -> Int? {', '\n    }\n')}
${lift(workouts, '    static func date(_ body: [String: Any]) -> DateComponents? {', '\n    }\n')}
}
var body: [String: Any] = ["date": "2026-10-12"]
if CommandLine.arguments[1] != "-" { body["hour"] = Double(CommandLine.arguments[1])! }
if CommandLine.arguments[2] != "-" { body["minute"] = Double(CommandLine.arguments[2])! }
if let date = CraftScheduledWorkouts.date(body) { print("\\(date.hour!):\\(date.minute!)") } else { print("refused") }
`
  expect(probe('workout-date', source, [
    [['1e30', '-'], 'refused'],
    [['-', '1e30'], 'refused'],
    [['-1e30', '-1.7976931348623157e308'], 'refused'],
    [['9223372036854775808', '0'], 'refused'],
    // As before: the default time, a time given, and a fraction toward zero.
    [['-', '-'], '7:0'],
    [['18', '30'], '18:30'],
    [['7.9', '59.9'], '7:59'],
    [['24', '0'], 'refused'],
    [['7', '60'], 'refused'],
  ])).toEqual([])
}, 300_000)

test('no prop is converted with the Int(_:) that traps', () => {
  // The forms the conversions took: `Int(number(…))`, `{ Int($0) }` and
  // `{ Int($0.rounded(…)) }` on a number from a prop or an argument.
  const trapping = /\bInt\(number\(|\{ Int\(\$0[.)]/
  for (const [name, source] of [['CraftNativeScreen.swift', screen], ['CraftNativeFlatList.swift', flatList], ['CraftScheduledWorkouts.swift', workouts]] as const) {
    const lines = source.split('\n').filter(line => trapping.test(line))
    expect(lines, name).toEqual([])
  }
  expect(screen).toContain('return integer == number.doubleValue ? String(craftNativeInt(integer)) : nil')
  expect(screen).toContain('order = number(raw["order"]).map { craftNativeInt($0) } ?? 0')
  expect(screen).toContain('compactMap { number($0).map { craftNativeInt($0) } }.filter { $0 >= 0 }')
  expect(screen).toContain('let command = craftNativeInt(from[i])')
  expect(screen).toContain('switch craftNativeInt(n[i]) {')
  expect(screen.match(/craftNativeInt\(number\(props\["numberOfLines"\]\) \?\? 0\)/g)?.length).toBe(3)
  expect(screen.match(/craftNativeInt\(number\(props\["maxLength"\]\) \?\? 0\)/g)?.length).toBe(2)
  expect(screen).toContain('let interval = craftNativeInt(number(props["minuteInterval"]) ?? 1)')
  expect(screen).toContain('columns: craftNativeInt(number(props["numColumns"]) ?? 1),')
  expect(flatList).toContain('let thresholdItems = max(1, craftNativeInt(ceil(Double(dataItemCount) * endReachedThreshold)))')
  expect(workouts).toContain('? 7 : whole(body["hour"])')
  expect(workouts).toContain('? 0 : whole(body["minute"])')
  expect(workouts).toContain('return Int(exactly: value)')
  expect(workouts).toContain('let iterations = whole(block["iterations"] ?? 1) ?? 0')
})
