import { expect, test } from 'bun:test'
import { assertShippingScope, collectFindings, isToolingOnly, reviewScope } from './sbom-scope'

const match = (name: string, severity: string, paths: string[], id = 'GHSA-test') => ({
  vulnerability: { id, severity },
  artifact: { name, version: '1.0.0', locations: paths.map(path => ({ path })) },
})

test('a benchmark-only High is inventory, not a failure', () => {
  const review = assertShippingScope({ matches: [match('electron', 'High', ['/benchmarks/apps/electron/bun.lock'])] })
  expect(review.tooling).toHaveLength(1)
  expect(review.shipped).toHaveLength(0)
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
