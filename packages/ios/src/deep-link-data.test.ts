import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A link that names a parameter twice opens the app; it does not close it.
 *
 * A deep link is whatever its sender wrote: a web page, another app, a QR
 * code. `deepLinkData` describes one to the screens, and built its
 * `queryParams` with `Dictionary(uniqueKeysWithValues:)`, which traps on a
 * repeated key. So
 *
 *   myapp://open?tag=a&tag=b
 *
 * ended the process as the app was being opened by it:
 * `Fatal error: Duplicate values for key: 'tag'`. Android describes the same
 * link with the first value.
 *
 * The function under test is the shipped one, compiled against real
 * Foundation. Each link is described in a process of its own, so one that
 * traps is seen as one that trapped.
 */
const actions = readFileSync(join(import.meta.dir, '../templates/CraftNativeActions.swift'), 'utf8')

function describer(): string {
  const start = actions.indexOf('    static func deepLinkData(_ url: URL) -> [String: Any] {')
  expect(start, 'deepLinkData must still be here to test').toBeGreaterThan(0)
  const end = actions.indexOf('\n    }\n', start)
  return actions.slice(start, end + '\n    }\n'.length)
}

const links: [string, Record<string, string>][] = [
  ['myapp://open?tag=a&id=7', { tag: 'a', id: '7' }],
  // The link that closed the app, and its relatives.
  ['myapp://open?tag=a&tag=b', { tag: 'a' }],
  ['myapp://open?tag=a&id=7&tag=b&tag=c&id=8', { tag: 'a', id: '7' }],
  ['myapp://open?a&a', { a: '' }],
  ['myapp://open?a=&a=1', { a: '' }],
  ['myapp://open?q=a%20b&q=c', { q: 'a b' }],
  // And the ordinary ones are as they were.
  ['myapp://open', {}],
  ['myapp://open?', {}],
  ['myapp://open?a=1&b=', { a: '1', b: '' }],
  ['https://example.com/m/workout/42?from=push#top', { from: 'push' }],
  ['myapp:open?x=1', { x: '1' }],
]

test.skipIf(process.platform !== 'darwin')('UIKit describes a link with a repeated parameter instead of trapping on it', () => {
  const dir = createTempDir('craft-deep-link-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(probe, `import Foundation
enum CraftNativeActions {
${describer()}}
let described = CraftNativeActions.deepLinkData(URL(string: CommandLine.arguments[1])!)
let params = described["queryParams"] as! [String: String]
print(String(decoding: try! JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), as: UTF8.self))
`)
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const wrong: string[] = []
    for (const [link, expected] of links) {
      const run = Bun.spawnSync([binary, link], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      const sorted = JSON.stringify(Object.fromEntries(Object.entries(expected).sort(([a], [b]) => a < b ? -1 : 1)))
      const got = run.exitCode === 0 ? JSON.stringify(JSON.parse(run.stdout.toString())) : `the process ended (${run.signalCode ?? run.exitCode}): ${run.stderr.toString().split('\n')[0]}`
      if (got !== sorted) wrong.push(`${link}: expected ${sorted}, UIKit ${got}`)
    }
    expect(wrong).toEqual([])
  }
  finally { removeTempDir(dir) }
}, 300_000)
