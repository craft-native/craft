import { expect, test } from 'bun:test'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The peer range admits every Svelte that provides what this adapter uses.
 *
 * The range used to stop at `^4.0.0`. Six of the Svelte advisories on the
 * dependency dashboard (#399) are fixed only in 5.51.5, 5.53.5 and 5.55.7, so
 * a consumer honouring that range could not reach a fixed Svelte at all —
 * the cap, not the dependency, was what held them on a vulnerable major.
 *
 * Nothing technical required the cap. This adapter's entire Svelte surface is
 * `writable`, `derived` and `get` from `svelte/store`, and Svelte 5 still
 * exports all three — checked against the published 5.57.3 tarball, whose
 * `src/store/index-client.js` re-exports `derived`, `get`, `readable`,
 * `readonly` and `writable` from `shared/index.js`.
 *
 * So this test ties the range to the surface rather than to a version
 * someone picked. If the adapter starts importing runes, the compiler, or
 * anything outside `svelte/store`, that assumption no longer holds and this
 * fails — which is the moment to re-examine the range, not after a consumer's
 * build breaks.
 */
const root = join(import.meta.dir, '..')

/** Every `… from 'svelte…'` specifier in the adapter's sources. */
function svelteImports(): { specifier: string, named: string[] }[] {
  const found: { specifier: string, named: string[] }[] = []
  const walk = (directory: string): void => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) { walk(path); continue }
      if (!entry.name.endsWith('.ts')) continue
      const source = readFileSync(path, 'utf8')
      for (const match of source.matchAll(/import\s+(type\s+)?\{([^}]*)\}\s+from\s+'(svelte[^']*)'/g)) {
        found.push({ specifier: match[3]!, named: match[2]!.split(',').map(name => name.trim()).filter(Boolean) })
      }
      for (const match of source.matchAll(/import\s+[^{][^\n]*from\s+'(svelte[^']*)'/g)) {
        found.push({ specifier: match[1]!, named: [] })
      }
    }
  }
  walk(join(root, 'src'))
  return found
}

/**
 * What `svelte/store` has exported continuously through Svelte 3, 4 and 5.
 *
 * Svelte 3 and 4 cannot be resolved from here — only one version is
 * installed — so this half is a claim. The half that matters is not:
 * `the adapter's imports exist in the installed Svelte` below asks the
 * installed package what it actually exports, so widening the range cannot
 * rest on my reading of a changelog.
 */
const storeSurface = new Set(['writable', 'readable', 'derived', 'readonly', 'get', 'Readable', 'Writable', 'Unsubscriber', 'StartStopNotifier'])

test('the adapter only uses svelte/store', () => {
  const imports = svelteImports()
  expect(imports.length, 'the adapter must import something from Svelte').toBeGreaterThan(0)
  const specifiers = [...new Set(imports.map(entry => entry.specifier))]
  // `svelte` itself, `svelte/compiler`, `svelte/internal` and the rune APIs
  // are all majors-sensitive in a way `svelte/store` is not.
  expect(specifiers, `the peer range below assumes svelte/store only, found ${specifiers.join(', ')}`)
    .toEqual(['svelte/store'])
})

test('every name it imports survived into Svelte 5', () => {
  for (const entry of svelteImports()) {
    for (const name of entry.named) {
      expect(storeSurface.has(name), `${name} is not in the store surface this range was widened on`).toBe(true)
    }
  }
})

test('the peer range reaches the majors where the advisories are fixed', () => {
  const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as {
    peerDependencies?: Record<string, string>
  }
  const range = manifest.peerDependencies?.svelte
  expect(range, 'the adapter must declare a Svelte peer range').toBeString()
  // The point of the change: a consumer can resolve a Svelte 5 that carries
  // the fixes for GHSA-crpf-4hrx-3jrp, -f7gr-6p89-r883, -m56q-vw4c-c2cp,
  // -phwv-c562-gvmh, -pr6f-5x2q-rwfp and -rcqx-6q8c-2c42.
  expect(range, 'the range must not cap below the majors carrying the fixes').toContain('^5.0.0')
  // Without dropping the consumers who are still on 3 or 4.
  expect(range).toContain('^3.0.0')
  expect(range).toContain('^4.0.0')
})

test('the adapter builds against the major its range points consumers at', async () => {
  // The defect this closes: the peer range was widened to `^5.0.0` while the
  // devDependency stayed `^4.0.0`, so nothing ever built or tested the adapter
  // against the major being advertised — and the installed Svelte still
  // carried the six advisories the widening was for (#399).
  const installed = JSON.parse(readFileSync(join(root, '../../node_modules/svelte/package.json'), 'utf8')) as { version: string }
  const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as {
    devDependencies?: Record<string, string>
    peerDependencies?: Record<string, string>
  }
  const range = manifest.peerDependencies?.svelte ?? ''
  const highest = [...range.matchAll(/\^(\d+)\./g)].map(found => Number(found[1])).sort((a, b) => b - a)[0]
  expect(highest, 'the peer range must name a major').toBeGreaterThan(0)
  expect(Number(installed.version.split('.')[0]),
    `the range offers ^${highest}.x but the adapter is built against Svelte ${installed.version}`).toBe(highest)
  // And the devDependency, not just whatever happens to be hoisted.
  expect(manifest.devDependencies?.svelte).toBe(`^${highest}.0.0`)
})

test("the adapter's imports exist in the installed Svelte", async () => {
  // Asked of the package rather than asserted from a list, so the range rests
  // on what Svelte exports instead of on what I believed it exports.
  const store = await import('svelte/store') as Record<string, unknown>
  const exported = new Set(Object.keys(store))
  expect(exported.size, 'svelte/store must export something').toBeGreaterThan(0)
  const wanted = [...new Set(svelteImports().flatMap(entry => entry.named))]
    // Type-only names are not runtime exports.
    .filter(name => !/^[A-Z]/.test(name))
  expect(wanted.length, 'the adapter must import runtime names').toBeGreaterThan(0)
  const missing = wanted.filter(name => !exported.has(name))
  expect(missing, `the installed Svelte does not export ${missing.join(', ')}`).toEqual([])
})
