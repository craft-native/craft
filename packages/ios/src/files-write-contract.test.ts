import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * `craft.files.write` writes the string it was given, or refuses, and UIKit
 * answers the cases every host is held to.
 *
 * UIKit was the host the others were wrong against: it already refused a
 * name or contents that were not strings, where Android and the browser host
 * wrote "42", "null" or the JSON text of a byte array and called it a
 * success. The cases (`packages/android/src/files-write-cases.json`) are the
 * arguments as they cross the bridge, and the bytes written or `null` where
 * the call must reject with `INVALID_ARGUMENT`.
 *
 * It had one case of its own to fix. An `encoding` that was not a string at
 * all, a number say, was read as absent and the contents written as utf8,
 * where Android refuses it.
 *
 * The functions under test are the shipped `write` and `decodeBase64`,
 * compiled against real Foundation and writing real files. Where the file
 * goes and how it is described are replaced, since those belong to the app's
 * sandbox. The arguments are taken apart as the dispatcher does it, and that
 * text is pinned below.
 */
const files = readFileSync(join(import.meta.dir, '../templates/CraftNativeFiles.swift'), 'utf8')
const actions = readFileSync(join(import.meta.dir, '../templates/CraftNativeActions.swift'), 'utf8')
const table = readFileSync(join(import.meta.dir, '../../android/src/files-write-cases.json'), 'utf8')
const { cases } = JSON.parse(table) as { cases: { label: string, args: unknown[], bytes: string | null }[] }

/** A static member of `CraftNativeFiles`, from its signature to its closing brace. */
function member(signature: string): string {
  const start = files.indexOf(`    static func ${signature}`)
  expect(start, `${signature} must still be here to test`).toBeGreaterThan(0)
  const end = files.indexOf('\n    }\n', start)
  return files.slice(start, end + '\n    }\n'.length)
}

test('the dispatcher takes the arguments apart as the probe does', () => {
  expect(actions).toContain(`            let name = args.first as? String ?? ""
            let data = args.count > 1 ? args[1] : nil
            let options = args.count > 2 ? args[2] as? [String: Any] ?? [:] : [:]`)
  expect(actions).toContain('CraftNativeFiles.write(name: name, data: data, options: options)')
})

test.skipIf(process.platform !== 'darwin')('UIKit writes what the shared cases say, and refuses the rest', () => {
  const dir = createTempDir('craft-files-write-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe'), input = join(dir, 'cases.json')
    writeFileSync(probe, `import Foundation
struct CraftNativeActionError: Error { let code: String; let message: String }
enum CraftNativeFiles {
    static let root = URL(fileURLWithPath: CommandLine.arguments[2])
    static func newFile(named name: String) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("written")
    }
    static func describe(_ url: URL, type: String) -> [String: Any] { ["path": url.path, "type": type] }
${member('decodeBase64(')}
${member('write(name: String')}}
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let table = (try! JSONSerialization.jsonObject(with: raw) as! [String: Any])["cases"] as! [[String: Any]]
for row in table {
    let args = row["args"] as! [Any]
    let name = args.first as? String ?? ""
    let data = args.count > 1 ? args[1] : nil
    let options = args.count > 2 ? args[2] as? [String: Any] ?? [:] : [:]
    switch CraftNativeFiles.write(name: name, data: data, options: options) {
    case .failure(let error): print(error.code)
    case .success(let described):
        let path = (described as! [String: Any])["path"] as! String
        let bytes = try! Data(contentsOf: URL(fileURLWithPath: path))
        print("wrote " + bytes.map { String(format: "%02x", $0) }.joined())
    }
}
`)
    writeFileSync(input, table)
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, input, join(dir, 'written')], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)

    const answers = run.stdout.toString().trimEnd().split('\n')
    expect(answers.length, 'every case must get an answer').toBe(cases.length)
    const wrong = cases
      .map((row, at) => ({ label: row.label, expected: row.bytes === null ? 'INVALID_ARGUMENT' : `wrote ${row.bytes}`, got: answers[at] }))
      .filter(row => row.expected !== row.got)
      .map(row => `${row.label}: expected ${row.expected}, UIKit ${row.got}`)
    expect(wrong, 'UIKit differs from the shared cases').toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)
