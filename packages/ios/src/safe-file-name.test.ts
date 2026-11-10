import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A name made for a kept file is one the disk will take, and a long one
 * keeps its extension.
 *
 * `safeName` cut a long name at 120 characters wherever that fell, so
 * `…a long report title.pdf` became a file with no extension: the share sheet
 * offered it as a blank document and an upload sent it with no type to go by.
 * And 120 characters is not always short enough — the file system takes 255
 * UTF-16 units, which 120 flags or family emoji exceed, so such a name failed
 * the write it was made for.
 *
 * The function under test is the shipped one, lifted from the template and
 * run. Android's `safeFileName` is held to the same properties by
 * `packages/android/src/file-download.test.ts`.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeFiles.swift'), 'utf8')

function safeNameSource(): string {
  const start = template.indexOf('    static func safeName(_ name: String) -> String {')
  expect(start, 'safeName must still be here to test').toBeGreaterThan(0)
  const end = template.indexOf('\n    }\n', start)
  return template.slice(start, end + '\n    }\n'.length)
}

const flag = '\u{1F1EF}\u{1F1F5}'
const cases: Record<string, string> = {
  plain: 'route.csv',
  path: '../../etc/passwd',
  dots: '..',
  hidden: '.env',
  empty: '   ',
  long: `${'a'.repeat(300)}.pdf`,
  longNoExtension: 'b'.repeat(300),
  longSentence: `${'Mr. Smith and the very long title of a report '.repeat(6)}`,
  flags: `${flag.repeat(120)}.png`,
  boundary: `${'c'.repeat(116)}.pdf`,
}

test.skipIf(process.platform !== 'darwin')('a kept file\'s name fits the disk and keeps its extension', () => {
  const dir = createTempDir('craft-safe-name-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe'), input = join(dir, 'cases.json')
    writeFileSync(probe, `import Foundation
enum CraftNativeFiles {
${safeNameSource()}}
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [String: String]
var answers: [String: String] = [:]
for (label, name) in cases { answers[label] = CraftNativeFiles.safeName(name) }
// And the question the name exists to answer: will the disk take it.
var written: [String: Bool] = [:]
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
for (label, name) in answers {
    written[label] = FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
}
print(String(decoding: try! JSONSerialization.data(withJSONObject: ["names": answers, "written": written]), as: UTF8.self))
`)
    writeFileSync(input, JSON.stringify(cases))
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, input, dir], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)
    const { names, written } = JSON.parse(run.stdout.toString()) as { names: Record<string, string>, written: Record<string, boolean> }

    expect(Object.keys(names).sort(), 'every case must be answered').toEqual(Object.keys(cases).sort())
    for (const [label, name] of Object.entries(names)) {
      expect(name.length, `${label} must have a name`).toBeGreaterThan(0)
      expect(name, `${label} must not leave its folder`).not.toMatch(/[/\\]/)
      expect(name.startsWith('.'), `${label} must not be hidden or a folder: ${name}`).toBe(false)
      // JavaScript's length is UTF-16 units, the same count the disk uses.
      expect(name.length, `${label} is longer than the disk takes`).toBeLessThanOrEqual(255)
      expect([...new Intl.Segmenter().segment(name)].length, `${label} is longer than 120 characters`).toBeLessThanOrEqual(120)
      expect(written[label], `the disk refused the name made for ${label}`).toBe(true)
    }

    expect(names.plain).toBe('route.csv')
    expect(names.dots).toBe('file')
    expect(names.empty).toBe('file')
    expect(names.hidden).toBe('env')
    // Cut, and still a PDF.
    expect(names.long, 'a long name lost its extension').toMatch(/^a{116}\.pdf$/)
    expect(names.flags, 'a name of flags lost its extension').toMatch(/\.png$/)
    // Nothing to keep: no extension, or a full stop that is only punctuation.
    expect(names.longNoExtension).toBe('b'.repeat(120))
    expect(names.longSentence.length).toBeLessThanOrEqual(120)
    // Exactly at the limit is left alone.
    expect(names.boundary).toBe(cases.boundary!)
  }
  finally { removeTempDir(dir) }
}, 300_000)
