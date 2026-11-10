import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * `craft.files.write` reads base64 on UIKit as `atob` does.
 *
 * Foundation's `Data(base64Encoded:)` wants the padding there, so UIKit
 * refused `"YQ"`, which the browser host and Android both read as one byte —
 * and it lets a third `=` by, which neither of them does. UIKit now reads the
 * text itself, to `atob`'s grammar, and hands Foundation only what is already
 * known to be valid, padded.
 *
 * The payloads are the ones Android is held to
 * (`packages/android/src/base64-cases.json`), and the verdict for each is
 * whatever `atob` gives when this runs. The function under test is the
 * shipped one, lifted from the template, with real Foundation underneath.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeFiles.swift'), 'utf8')
const { cases } = JSON.parse(readFileSync(join(import.meta.dir, '../../android/src/base64-cases.json'), 'utf8')) as { cases: string[] }

function expected(payload: string): string | null {
  try { return [...atob(payload)].map(letter => letter.charCodeAt(0).toString(16).padStart(2, '0')).join('') }
  catch { return null }
}

function readerSource(): string {
  const start = template.indexOf('    static func decodeBase64(_ text: String) -> Data? {')
  expect(start, 'decodeBase64 must still be here to test').toBeGreaterThan(0)
  const end = template.indexOf('\n    }\n', start)
  return template.slice(start, end + '\n    }\n'.length)
}

test('files.write reads its base64 through that function', () => {
  // The function is only worth testing while it is the one in use.
  expect(template).toContain('guard let decoded = decodeBase64(text) else {')
  expect(template, 'files.write must not go back to Foundation directly').not.toContain('Data(base64Encoded: text')
})

test.skipIf(process.platform !== 'darwin')('UIKit reads base64 as atob does', () => {
  const dir = createTempDir('craft-base64-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe'), input = join(dir, 'cases.json')
    writeFileSync(probe, `import Foundation
enum CraftNativeFiles {
${readerSource()}}
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
// Each payload arrives as its UTF-16 code units, so a lone surrogate or a
// NUL is asked exactly as written.
let cases = try! JSONSerialization.jsonObject(with: raw) as! [[Int]]
for units in cases {
    let payload = String(decoding: units.map { UInt16($0) }, as: UTF16.self)
    print(CraftNativeFiles.decodeBase64(payload).map { $0.map { String(format: "%02x", $0) }.joined() + "." } ?? "reject")
}
`)
    writeFileSync(input, JSON.stringify(cases.map(payload => Array.from({ length: payload.length }, (_, at) => payload.charCodeAt(at)))))
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, input], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)

    const answers = run.stdout.toString().trimEnd().split('\n').map(line => line === 'reject' ? null : line.slice(0, -1))
    expect(answers.length, 'every payload must get an answer').toBe(cases.length)
    const wrong = cases
      .map((payload, at) => ({ payload, atob: expected(payload), uikit: answers[at] }))
      .filter(row => row.atob !== row.uikit)
      .map(row => `${JSON.stringify(row.payload)} atob=${row.atob} uikit=${row.uikit}`)
    expect(wrong, 'UIKit reads these differently from atob').toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)
