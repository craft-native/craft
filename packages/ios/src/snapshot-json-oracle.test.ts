import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * The recorded Foundation verdicts are still Foundation's.
 *
 * `packages/android/src/snapshot-json-cases.json` is what holds Android's
 * snapshot scanner to UIKit's grammar (#396). A recording is only worth what
 * its oracle is, so this half re-runs every payload through real
 * `JSONSerialization` and requires the file to still be right.
 *
 * The two halves are separated because no CI job has both Swift and Kotlin:
 * the Kotlin side runs in the Linux Android suite against this recording, and
 * this side runs wherever Swift is — `packages/ios`'s suite, which
 * `ios-native-templates` runs whole on macOS.
 *
 * If Apple ever changes the grammar — the trailing comma being the obvious
 * candidate — this fails rather than Android silently drifting away from a
 * host that has moved.
 */
interface Recorded { note: string, cases: { payload: string, accepted: boolean }[] }
const recordedPath = join(import.meta.dir, '../../android/src/snapshot-json-cases.json')
const recorded = JSON.parse(readFileSync(recordedPath, 'utf8')) as Recorded

test.skipIf(process.platform !== 'darwin')('every recorded verdict is what Foundation gives today', () => {
  const dir = createTempDir('craft-json-oracle-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'oracle'), input = join(dir, 'cases.json')
    writeFileSync(probe, `import Foundation
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [String]
for text in cases {
    let ok = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    print(ok ? "accept" : "reject")
}
`)
    writeFileSync(input, JSON.stringify(recorded.cases.map(entry => entry.payload)))
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, input], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)

    const verdicts = run.stdout.toString().trim().split('\n')
    expect(verdicts.length, 'every payload must get a verdict').toBe(recorded.cases.length)
    // Name the payload and both verdicts: which one moved is the question.
    const drifted = recorded.cases
      .map((entry, index) => ({ ...entry, today: verdicts[index] === 'accept' }))
      .filter(entry => entry.today !== entry.accepted)
      .map(entry => `${JSON.stringify(entry.payload)} recorded=${entry.accepted ? 'accept' : 'reject'} today=${entry.today ? 'accept' : 'reject'}`)
    expect(drifted, 'Foundation no longer agrees with the recording Android is held to').toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)

test('the recording says where it came from', () => {
  // So the next reader does not take it for a hand-written table.
  expect(recorded.note).toContain('JSONSerialization')
  expect(recorded.note).toContain('fragmentsAllowed')
})
