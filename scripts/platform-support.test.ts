import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const root = join(import.meta.dir, '..')
const support = readFileSync(join(root, 'packages/zig/PLATFORM_SUPPORT.md'), 'utf8')
const readme = readFileSync(join(root, 'README.md'), 'utf8')

/** The namespaces the documented table says each desktop platform serves. */
function documented(): { windows: string[], linux: string[], macos: string[] } {
  const table = support.match(/<!-- desktop-bridge-table:start -->([\s\S]*?)<!-- desktop-bridge-table:end -->/)?.[1]
  if (!table) throw new Error('PLATFORM_SUPPORT.md lost its desktop bridge table markers')
  const rows = table.split('\n').filter(line => /^\| `/.test(line)).map((line) => {
    const cells = line.split('|').slice(1, -1).map(cell => cell.trim())
    return { namespace: cells[0]!.replaceAll('`', ''), macos: cells[2], windows: cells[3], linux: cells[4] }
  })
  for (const row of rows) {
    for (const value of [row.macos, row.windows, row.linux]) expect(['yes', 'no']).toContain(value!)
  }
  const served = (platform: 'macos' | 'windows' | 'linux') => rows.filter(row => row[platform] === 'yes').map(row => row.namespace).sort()
  return { windows: served('windows'), linux: served('linux'), macos: served('macos') }
}

/**
 * The namespaces a platform's page-message router dispatches: every string a
 * message kind is compared against. `fileDrop` is how the injected script
 * hands dropped files back on Windows, not something a page calls.
 */
function routed(file: string): string[] {
  const source = readFileSync(join(root, 'packages/zig/src', file), 'utf8')
  const kinds = new Set<string>()
  for (const match of source.matchAll(/eql\(u8, (?:envelope\.)?kind, "(\w+)"\)/g)) kinds.add(match[1]!)
  kinds.delete('fileDrop')
  return [...kinds].sort()
}

test('the documented Windows bridge is exactly what windows.zig routes', () => {
  expect(documented().windows).toEqual(routed('windows.zig'))
})

test('the documented Linux bridge is exactly what linux.zig routes', () => {
  expect(documented().linux).toEqual(routed('linux.zig'))
})

test('an unrouted namespace is refused, not ignored', () => {
  for (const file of ['windows.zig', 'linux.zig']) {
    const source = readFileSync(join(root, 'packages/zig/src', file), 'utf8')
    const handler = source.slice(source.indexOf('fn handleDesktopAction('))
    expect(handler.slice(0, handler.indexOf('\n}\n'))).toContain('return error.PlatformNotSupported;')
  }
})

test('the documents do not claim the dialogs or the support level they used to', () => {
  // Linux dialogs are GTK, and were never reachable through zenity from a page.
  expect(support).not.toContain('zenity')
  expect(support).not.toMatch(/\| Windows \| ✅ Full/)
  expect(support).not.toMatch(/\| Linux \| ✅ Full/)
  // Anything CI cannot perform is named as unverified in so many words.
  expect(support).toContain('Nothing in CI performs an OLE drag')
  expect(readme).toContain('packages/zig/PLATFORM_SUPPORT.md')
  expect(readme).toContain('PLATFORM_NOT_SUPPORTED')
})

test('the README no longer advertises process output streaming', () => {
  const process = readFileSync(join(root, 'packages/typescript/src/api/process.ts'), 'utf8')
  for (const name of ['onStdout(', 'onStderr(', 'onExit(']) expect(process).not.toContain(name)
  expect(readme).toContain('has no `onStdout`, `onStderr`, `onExit`')
})
