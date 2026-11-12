import { expect, test } from 'bun:test'
import { resolve } from 'node:path'
import { describeStaleMarker, findStaleRegionMarkers, readRegionMarkers } from './test-region-markers'

const root = resolve(import.meta.dir, '..')

test('both ends of a sliced region are read as markers', () => {
  const source = 'const body = file.slice(file.indexOf(\'fun openPDF(\'), file.indexOf(\'// ==== Contacts\'))\n'
  expect(readRegionMarkers('a.test.ts', source).map(entry => entry.marker)).toEqual(['fun openPDF(', '// ==== Contacts'])
})

test('a marker holding unbalanced parens does not swallow the rest of the file', () => {
  // The scanner's own version of the defect it hunts: counting parens without
  // tracking strings never returns to depth zero here, so the argument list
  // ran to the end of the source and every later literal looked like a marker.
  const source = [
    'const a = file.slice(file.indexOf(\'private fun updateImage((\'), file.indexOf(\'private fun imageFailure(\'))',
    'expect(other).toContain(\'a literal that is not a boundary\')',
    'const b = file.slice(file.indexOf(\'second region start\'), file.indexOf(\'second region end\'))',
  ].join('\n')
  expect(readRegionMarkers('a.test.ts', source).map(entry => entry.marker))
    .toEqual(['private fun updateImage((', 'private fun imageFailure(', 'second region start', 'second region end'])
})

test('positions compared rather than sliced are not region boundaries', () => {
  // -1 is a legitimate answer when the point is the ordering, and a marker the
  // test builds itself is not looking for anything in a source file.
  const source = [
    'expect(result.indexOf(\'  AppTests:\')).toBeLessThan(result.indexOf(\'schemes:\'))',
    'const made = insertTargets(project, \'  AppTests:\\n    type: bundle.unit-test\')',
  ].join('\n')
  expect(readRegionMarkers('a.test.ts', source)).toEqual([])
})

test('short and interpolated markers are left alone', () => {
  const source = 'const x = f.slice(f.indexOf(\'ab\'), f.indexOf(`start ${name}`))\n'
  expect(readRegionMarkers('a.test.ts', source)).toEqual([])
})

test('a stale marker is named with what it does to the region', () => {
  const markers = readRegionMarkers('a.test.ts', 'const b = f.slice(f.indexOf(\'still here\'), f.indexOf(\'long gone marker\'))\n')
  const stale = findStaleRegionMarkers(markers, 'a source file that is still here')
  expect(stale.map(entry => entry.marker)).toEqual(['long gone marker'])
  expect(describeStaleMarker(stale[0]!)).toContain('runs to the end of the file')
})

test('every sliced region in this repository is still bounded', async () => {
  // Derived, so the next renamed boundary is caught when it is renamed.
  const sources = ['packages/*/templates/**/*', 'packages/*/src/**/*.ts', 'packages/*/scripts/**/*.ts', 'packages/zig/src/**/*.zig', 'packages/*/fixtures/**/*', 'scripts/**/*.ts', 'docs/**/*.md', '.github/**/*.yml', 'packages/typescript/types/*.d.ts']
  let corpus = ''
  for (const pattern of sources) {
    for (const file of new Bun.Glob(pattern).scanSync({ cwd: root })) {
      if (file.includes('node_modules') || file.includes('/dist/') || file.endsWith('.test.ts')) continue
      try { corpus += await Bun.file(resolve(root, file)).text() }
      catch { /* not text; it cannot hold a marker either way */ }
    }
  }
  expect(corpus.length).toBeGreaterThan(1_000_000)

  const markers: ReturnType<typeof readRegionMarkers> = []
  for (const file of [...new Bun.Glob('{packages,scripts}/**/*.test.ts').scanSync({ cwd: root })].sort()) {
    if (file.includes('node_modules') || file.includes('/dist/')) continue
    markers.push(...readRegionMarkers(file, await Bun.file(resolve(root, file)).text()))
  }
  expect(markers.length).toBeGreaterThan(100)
  expect(findStaleRegionMarkers(markers, corpus).map(describeStaleMarker)).toEqual([])
})
