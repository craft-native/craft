import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * Every row of a list has an identity of its own, whatever its key.
 *
 * Rows that share a key are told apart by a suffix: `run`, then `run#1`. A
 * row whose own key was `run#1` then had the identity of the second `run`,
 * and the list built its table with `Dictionary(uniqueKeysWithValues:)`,
 * which traps on a repeated key: three tags keyed `run`, `run` and `run#1`
 * ended the process (`Fatal error: Duplicate values for key: 'run#1'`).
 *
 * The function under test is the shipped one, compiled against Foundation,
 * on the table Android's copy of the rule is run on
 * (`packages/android/src/list-row-identity-cases.json`), so the two hosts give
 * a row the same identity. The rows themselves are drawn on a simulator in
 * testListRowsWhoseKeysCollideWithTheSuffixOfARepeatAreAllDrawn.
 */
const list = readFileSync(join(import.meta.dir, '../templates/CraftNativeFlatList.swift'), 'utf8')
const cases: { keys: string[], identities: string[], why: string }[] = JSON.parse(readFileSync(join(import.meta.dir, '../../android/src/list-row-identity-cases.json'), 'utf8'))

test.skipIf(process.platform !== 'darwin')('UIKit gives rows the identities Android does, and none twice', () => {
  const start = list.indexOf('    static func uniqueIdentity(_ base: String, seen: inout [String: Int], taken: inout Set<String>) -> String {')
  expect(start, 'uniqueIdentity must still be here to test').toBeGreaterThan(-1)
  const end = list.indexOf('\n    }\n', start)
  const dir = createTempDir('craft-row-identity-')
  try {
    const main = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(main, `import Foundation
enum CraftNativeFlatList {
${list.slice(start, end + '\n    }\n'.length)}}
let keys = try! JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as! [String]
var seen: [String: Int] = [:]
var taken = Set<String>()
let identities = keys.map { CraftNativeFlatList.uniqueIdentity($0, seen: &seen, taken: &taken) }
print(String(decoding: try! JSONSerialization.data(withJSONObject: identities), as: UTF8.self))
`)
    const build = Bun.spawnSync(['swiftc', main, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const wrong: string[] = []
    expect(cases.length).toBeGreaterThanOrEqual(9)
    for (const { keys, identities: expected, why } of cases) {
      const run = Bun.spawnSync([binary, JSON.stringify(keys)], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      const got = run.exitCode === 0 ? JSON.stringify(JSON.parse(run.stdout.toString())) : `the process ended (${run.signalCode ?? run.exitCode}): ${run.stderr.toString().split('\n')[0]}`
      if (got !== JSON.stringify(expected)) wrong.push(`${JSON.stringify(keys)} (${why}): expected ${JSON.stringify(expected)}, UIKit ${got}`)
    }
    expect(wrong).toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)

test('the list gives each row that identity, and its table no longer traps on a repeat', () => {
  expect(list).toContain('let identity = Self.uniqueIdentity(base, seen: &seen, taken: &taken)')
  expect(list).toContain('itemsByIdentity = Dictionary(next.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })')
  expect(list).not.toContain('uniqueKeysWithValues')
})
