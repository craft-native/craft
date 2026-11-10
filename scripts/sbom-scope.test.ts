import { expect, test } from 'bun:test'
import { assertShippingScope, collectFindings, isToolingOnly, reviewScope } from './sbom-scope'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const match = (name: string, severity: string, paths: string[], id = 'GHSA-test') => ({
  vulnerability: { id, severity },
  artifact: { name, version: '1.0.0', locations: paths.map(path => ({ path })) },
})

test('a benchmark-only High is inventory, not a failure', () => {
  const review = assertShippingScope({ matches: [match('electron', 'High', ['/benchmarks/apps/electron/bun.lock'])] })
  expect(review.tooling).toHaveLength(1)
  expect(review.shipped).toHaveLength(0)
})

test('the Electron benchmark stays outside the vulnerable release line', () => {
  // This used to pin the literal `^42.0.1`, which is a floor OSV reports
  // thirteen advisories for: it named the release line and admitted the
  // vulnerable start of it. 42.11.18 is the version OSV was asked about and
  // answered with none (#399). The floor may rise; it may not fall below that.
  const clean = [42, 11, 18] as const
  const version = (text: string | undefined): number[] | null => {
    const parts = /^(\d+)\.(\d+)\.(\d+)$/.exec(text ?? '')
    return parts ? parts.slice(1).map(Number) : null
  }
  const atLeast = (left: number[], right: readonly number[]): boolean => {
    for (let at = 0; at < 3; at += 1) if (left[at] !== right[at]) return left[at]! > right[at]!
    return true
  }
  const app = join(import.meta.dir, '..', 'benchmarks/apps/electron')
  const packageJson = JSON.parse(readFileSync(join(app, 'package.json'), 'utf8')) as { dependencies?: { electron?: string } }
  const declared = packageJson.dependencies?.electron ?? ''
  expect(declared, 'a caret range, so the floor is what the range says').toMatch(/^\^\d+\.\d+\.\d+$/)
  const floor = version(declared.slice(1))!
  expect(atLeast(floor, clean), `the declared floor ${declared} admits a version below ${clean.join('.')}`).toBe(true)

  // And what the benchmark installs is inside the range it declares: the two
  // drifted apart once already, with the manifest naming a floor nothing used.
  const locked = version(/"electron": \["electron@([\d.]+)"/.exec(readFileSync(join(app, 'bun.lock'), 'utf8'))?.[1])
  expect(locked, 'the lockfile must resolve electron').not.toBeNull()
  expect(locked![0], 'a caret range stays on its major').toBe(floor[0]!)
  expect(atLeast(locked!, floor), `the lockfile resolves ${locked!.join('.')}, below the declared ${declared}`).toBe(true)
})

test('the Go runtime inside the compiler binary is inventory', () => {
  const review = assertShippingScope({ matches: [match('stdlib', 'High', ['/node_modules/@typescript/typescript-linux-x64/lib/tsc'], 'GO-2026-5026')] })
  expect(review.tooling).toHaveLength(1)
})

test('a High in Craft source fails, and the message locates it', () => {
  expect(() => assertShippingScope({ matches: [match('someLib', 'High', ['/packages/typescript/package.json'])] }))
    .toThrow('/packages/typescript/package.json')
})

test('a package in both a benchmark and Craft is Craft\'s problem', () => {
  expect(() => assertShippingScope({ matches: [match('minimatch', 'High', ['/benchmarks/apps/electron/bun.lock', '/packages/zig/build.zig.zon'])] }))
    .toThrow('not confined to tooling paths')
})

test('an unlocatable High is never waved through', () => {
  expect(isToolingOnly({ package: 'x', version: '1', severity: 'High', id: 'y', locations: [] })).toBe(false)
  expect(() => assertShippingScope({ matches: [match('mystery', 'High', [])] }))
    .toThrow('no recorded location')
})

test('Medium and below are inventory wherever they sit', () => {
  const review = reviewScope(collectFindings({ matches: [
    match('lodash', 'Medium', ['/packages/typescript/package.json']),
    match('lodash', 'Low', ['/packages/typescript/package.json']),
  ] }))
  expect(review.shipped).toHaveLength(0)
  expect(review.tooling).toHaveLength(0)
})

test('Critical is gated exactly like High', () => {
  expect(() => assertShippingScope({ matches: [match('bad', 'Critical', ['/packages/zig/src/main.zig'])] }))
    .toThrow('High or Critical')
  expect(assertShippingScope({ matches: [match('bad', 'Critical', ['/benchmarks/x/bun.lock'])] }).tooling).toHaveLength(1)
})

test('a missing or malformed report is never a clean scan', () => {
  expect(() => collectFindings(null)).toThrow('expected an object')
  expect(() => collectFindings({})).toThrow('absent results are not a clean scan')
  expect(() => collectFindings({ matches: [{ vulnerability: { id: 'x', severity: 'Spicy' }, artifact: { name: 'a' } }] })).toThrow('Invalid Grype severity')
  expect(() => collectFindings({ matches: [{ vulnerability: { severity: 'High' }, artifact: { name: 'a' } }] })).toThrow('vulnerability id and package name are required')
})

test('an empty report passes and reports nothing', () => {
  const review = assertShippingScope({ matches: [] })
  expect(review.tooling).toHaveLength(0)
  expect(review.shipped).toHaveLength(0)
})
