import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { assessPantryAvailability, compareVersions, publishedPantryPlatforms } from './pantry-availability'

const digest = (fill: string) => fill.repeat(64).slice(0, 64)
const entry = (fill: string, size = 1024) => ({ tarball: 'binaries/craft-native.org/x/y.tar.gz', sha256: digest(fill), size, uploadedAt: '2026-11-02T12:53:36.748Z' })

function registry(versions: Record<string, Record<string, unknown>>, latestVersion: string) {
  return { name: 'craft-native.org', latestVersion, versions: Object.fromEntries(Object.entries(versions).map(([version, platforms]) => [version, { platforms }])) }
}

test('the published platforms are read off the job that publishes them', () => {
  // Derived, not pinned. A literal list here agrees with itself: adding a
  // third platform to the `pantry` matrix would leave the receipt silently
  // not checking it while this test still passed.
  //
  // Not every GitHub release asset, either: `publish-pantry` packages Zig
  // source and does not rebuild a platform binary, so windows-x64 and
  // darwin-x64 have never been on this registry.
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/release.yml'), 'utf8')) as {
    jobs: Record<string, { strategy?: { matrix?: { platform?: { name?: string }[] } } }>
  }
  const pantry = workflow.jobs.pantry
  expect(pantry).toBeDefined()
  const published = pantry!.strategy?.matrix?.platform?.map(platform => platform.name)
  expect(published).toBeArray()
  expect(published!.every(name => typeof name === 'string' && name.length > 0)).toBe(true)
  expect([...publishedPantryPlatforms].sort()).toEqual([...published!].sort() as string[])
})

test('every published platform present reads as available', () => {
  const receipt = assessPantryAvailability(registry({ '0.0.473': { 'darwin-arm64': entry('a'), 'linux-x86-64': entry('b') } }, '0.0.473'), '0.0.473')
  expect(receipt.outcome).toBe('available')
  expect(receipt.platforms.map(p => p.present)).toEqual([true, true])
  expect(receipt.platforms[0]!.sha256).toBe(digest('a'))
})

test('a row carrying only some platforms is partial, not available', () => {
  // The real registry's newest row, 0.0.424, carries darwin-arm64 alone.
  const receipt = assessPantryAvailability(registry({ '0.0.424': { 'darwin-arm64': entry('a') } }, '0.0.424'), '0.0.424')
  expect(receipt.outcome).toBe('partial')
  expect(receipt.platforms.find(p => p.platform === 'linux-x86-64')!.present).toBe(false)
  expect(receipt.note).toBe('1 of 2 published platforms are on the registry for 0.0.424.')
})

test('an accepted queue notification with absent metadata is pending, not available', () => {
  // v0.0.435's case: the notify step logged "queued for indexing" while the
  // registry's newest row was 0.0.424.
  const receipt = assessPantryAvailability(registry({ '0.0.424': { 'darwin-arm64': entry('a'), 'linux-x86-64': entry('b') } }, '0.0.424'), '0.0.435')
  expect(receipt.outcome).toBe('pending')
  expect(receipt.latestVersion).toBe('0.0.424')
  expect(receipt.note).toContain('indexing has not reached it')
})

test('a version the registry skipped is unavailable rather than pending', () => {
  const receipt = assessPantryAvailability(registry({ '0.0.480': { 'darwin-arm64': entry('a'), 'linux-x86-64': entry('b') } }, '0.0.480'), '0.0.473')
  expect(receipt.outcome).toBe('unavailable')
  expect(receipt.note).toContain('skipped rather than queued')
})

test('a platform entry without usable bytes does not count as present', () => {
  const rows = { '0.0.473': { 'darwin-arm64': entry('a'), 'linux-x86-64': { tarball: 'x', sha256: 'not-a-digest', size: 0 } } }
  const receipt = assessPantryAvailability(registry(rows, '0.0.473'), '0.0.473')
  expect(receipt.outcome).toBe('partial')
  expect(receipt.platforms.find(p => p.platform === 'linux-x86-64')!.present).toBe(false)
})

test('unreadable metadata claims nothing rather than guessing', () => {
  for (const bad of [null, undefined, 42, 'text', { versions: [] }, { latestVersion: '1.0.0' }]) {
    const receipt = assessPantryAvailability(bad, '0.0.473')
    expect(receipt.outcome).toBe('unreadable')
    expect(receipt.platforms).toEqual([])
  }
})

test('versions order numerically, including the registry\'s four-segment rows', () => {
  expect(compareVersions('0.0.424', '0.0.435')).toBe(-1)
  expect(compareVersions('0.0.435', '0.0.424')).toBe(1)
  expect(compareVersions('0.0.424', '0.0.424')).toBe(0)
  // '0.0.423.1' is a real row in the published metadata.
  expect(compareVersions('0.0.423', '0.0.423.1')).toBe(-1)
  expect(compareVersions('0.0.423.1', '0.0.424')).toBe(-1)
  // Lexical ordering would put 0.0.99 after 0.0.424; numeric must not.
  expect(compareVersions('0.0.99', '0.0.424')).toBe(-1)
})

test('a version or platform set must be given', () => {
  expect(() => assessPantryAvailability(registry({}, '0.0.1'), '')).toThrow('needs a version')
  expect(() => assessPantryAvailability(registry({}, '0.0.1'), '0.0.1', [])).toThrow('at least one platform')
})
