import { expect, test } from 'bun:test'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../packages/typescript/src/temp-dir'
import { assessPantryAvailability, bindPantryBytes, compareVersions, digestBinaries, pantryPlatformAssets, publishedPantryPlatforms } from './pantry-availability'

const digest = (fill: string) => fill.repeat(64).slice(0, 64)
const entry = (fill: string, size = 1024) => ({ tarball: 'binaries/craft-native.org/x/y.tar.gz', sha256: digest(fill), size, uploadedAt: '2026-11-02T12:53:36.748Z' })

function registry(versions: Record<string, Record<string, unknown>>, latestVersion: string) {
  return { name: 'craft-native.org', latestVersion, versions: Object.fromEntries(Object.entries(versions).map(([version, platforms]) => [version, { platforms }])) }
}

test('the expected platforms are read off the job that builds them', () => {
  // Derived, not pinned. A literal list here agrees with itself: adding a
  // third platform to the `pantry` matrix would leave the receipt silently
  // not checking it while this test still passed.
  //
  // The matrix is what this repository builds archives for, not what uploads
  // them — nothing here uploads a platform binary to the registry at all.
  // The release publishes four assets and the registry has only ever indexed
  // three platforms, darwin-x86-64 last at 0.0.37 and windows-x86-64 never,
  // so the asset list would report a gap no release can close.
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

test('every platform the matrix builds has a release asset to bind against', () => {
  // Derived from the same matrix the receipt expects, so a platform added to
  // release.yml without an asset name here fails rather than binding nothing.
  for (const platform of publishedPantryPlatforms) {
    expect(pantryPlatformAssets[platform], `${platform} has no release asset to compare against`).toBeString()
  }
})

test('the same binaries under the same names bind, whatever the container', () => {
  // The real 0.0.487 darwin-arm64 reading: the registry's `.tar.gz` holds its
  // four binaries under `bin/` while the release's `.zip` holds them flat,
  // the two container digests have nothing to do with each other, and all
  // four binaries are the same bytes. Binding by container would have called
  // that a mismatch, which is why an earlier pass on #454 recorded the
  // comparison as impossible.
  const published = {
    'craft': digest('a'),
    'craft-app-store': digest('b'),
    'craft-webview': digest('c'),
    'craft-webview-app-store': digest('d'),
  }
  const binding = bindPantryBytes('darwin-arm64', published, { ...published })
  expect(binding.bound).toBe(true)
  expect(binding.binaries).toHaveLength(4)
  expect(binding.binaries.every(entry => entry.matches)).toBe(true)
  expect(binding.note).toContain('byte for byte')
})

test('a registry archive missing a binary is not bound', () => {
  const binding = bindPantryBytes('darwin-arm64', { 'craft': digest('a'), 'craft-webview': digest('c') }, { craft: digest('a') })
  expect(binding.bound).toBe(false)
  expect(binding.note).toContain('absent from the registry archive: craft-webview')
  expect(binding.binaries.find(entry => entry.name === 'craft')!.matches).toBe(true)
})

test('a binary of the same name with different bytes is not bound', () => {
  // The case that matters most: a registry serving something that is not
  // what this release built, under the name consumers install.
  const binding = bindPantryBytes('linux-x86-64', { craft: digest('a') }, { craft: digest('f') })
  expect(binding.bound).toBe(false)
  expect(binding.note).toContain('different bytes under the same name: craft')
  expect(binding.binaries[0]!.matches).toBe(false)
})

test('a registry archive carrying an extra binary is not bound either', () => {
  const binding = bindPantryBytes('linux-x86-64', { craft: digest('a') }, { craft: digest('a'), 'craft-webview': digest('c') })
  expect(binding.bound).toBe(false)
  expect(binding.note).toContain('in the registry archive only: craft-webview')
})

test('two empty archives claim nothing rather than binding', () => {
  const binding = bindPantryBytes('darwin-arm64', {}, {})
  expect(binding.bound).toBe(false)
  expect(binding.binaries).toEqual([])
  expect(binding.note).toContain('nothing is claimed')
})

test('digests are taken per binary, flat or nested, and a collision throws', () => {
  const dir = createTempDir('pantry-digest-')
  try {
    mkdirSync(join(dir, 'bin'), { recursive: true })
    writeFileSync(join(dir, 'bin/craft'), 'one')
    writeFileSync(join(dir, 'bin/craft-webview'), 'two')
    const nested = digestBinaries(dir)
    expect(Object.keys(nested).sort()).toEqual(['craft', 'craft-webview'])

    const flat = createTempDir('pantry-digest-flat-')
    try {
      writeFileSync(join(flat, 'craft'), 'one')
      writeFileSync(join(flat, 'craft-webview'), 'two')
      // The whole point: the containers nest differently and bind anyway.
      expect(digestBinaries(flat)).toEqual(nested)
    }
    finally { removeTempDir(flat) }

    mkdirSync(join(dir, 'other'), { recursive: true })
    writeFileSync(join(dir, 'other/craft'), 'three')
    expect(() => digestBinaries(dir)).toThrow(/Two files named craft/)
  }
  finally { removeTempDir(dir) }
})

test('a pending reading says why one taken at release time means little', () => {
  // The release workflow records this receipt in `notify-registry`, moments
  // after publication, which is the one moment it cannot read `available`.
  // Without saying so the warning it raises on every healthy release trains
  // its readers to ignore it.
  const receipt = assessPantryAvailability(registry({ '0.0.424': { 'darwin-arm64': entry('a') } }, '0.0.424'), '0.0.489')
  expect(receipt.outcome).toBe('pending')
  expect(receipt.note).toContain('on its own schedule')
  expect(receipt.note).toContain('Only a later reading')
})
