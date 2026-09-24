import { expect, test } from 'bun:test'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { manifestTargets, verifyArchiveTargets, verifyNpmPackages } from './npm-packages'

test('rejects absent built entries even when the manifest advertises them', () => {
  const pkg = { name: '@craft-native/react', main: 'dist/index.js', exports: { '.': { import: './dist/index.mjs', types: './dist/index.d.ts' } } }
  expect(() => verifyArchiveTargets(pkg, ['package/package.json', 'package/README.md']))
    .toThrow('packed artifact is missing dist/index.js')
})

test('checks each export condition, legacy field and string or named bin', () => {
  const pkg = {
    name: 'fixture', main: 'dist/index.cjs', module: 'dist/index.js', types: 'dist/index.d.ts', svelte: 'src/index.ts',
    bin: { fixture: './dist/cli.js' },
    exports: { '.': { types: './dist/index.d.ts', import: './dist/index.js', require: './dist/index.cjs', svelte: './src/index.ts' }, './mobile': './dist/mobile.js' },
  }
  const targets = manifestTargets(pkg)
  expect(targets).toHaveLength(6)
  const entries = targets.map(target => `package/${target}`)
  expect(() => verifyArchiveTargets(pkg, entries)).not.toThrow()
  for (const missing of entries)
    expect(() => verifyArchiveTargets(pkg, entries.filter(entry => entry !== missing))).toThrow('packed artifact is missing')
  expect(manifestTargets({ name: 'cli', bin: './bin/cli.ts' })).toEqual(['bin/cli.ts'])
})

test('a directory with the target name does not count as a file', () => {
  expect(() => verifyArchiveTargets({ name: 'fixture', types: './dist/index.d.ts' }, ['package/dist/index.d.ts/']))
    .toThrow('packed artifact is missing')
})

test('fails closed for targets that escape the package or need wildcard handling', () => {
  for (const target of ['../outside.js', '/outside.js', './dist/../outside.js', '.\\outside.js', './dist/*.js'])
    expect(() => manifestTargets({ name: 'fixture', exports: target })).toThrow()
})

test('exports every verified npm archive with its exact digest', async () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-npm-archive-test-'))
  const output = join(root, 'archives')
  try {
    await verifyNpmPackages(false, output)
    const manifest = JSON.parse(readFileSync(join(output, 'manifest.json'), 'utf8')) as { packages: { name: string, file: string, sha256: string }[] }
    expect(manifest.packages).toHaveLength(8)
    for (const archive of manifest.packages) {
      const path = join(output, archive.file)
      expect(existsSync(path)).toBe(true)
      expect(createHash('sha256').update(readFileSync(path)).digest('hex')).toBe(archive.sha256)
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 120_000)
