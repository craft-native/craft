import { afterEach, expect, test } from 'bun:test'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { publishNpmArchives } from './publish-npm-archives'
import { expectedNpmPackages, nativeInventory, readArchiveManifest, summarizeBunAudit } from './scan-release-artifacts'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const fixture = () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-release-artifacts-test-'))
  roots.push(root)
  return root
}

function archives(root: string) {
  const packages = expectedNpmPackages().map((name, index) => {
    const file = `${index}.tgz`
    const bytes = `${name}@1.2.3`
    writeFileSync(join(root, file), bytes)
    return { name, version: '1.2.3', file, sha256: createHash('sha256').update(bytes).digest('hex') }
  })
  writeFileSync(join(root, 'manifest.json'), JSON.stringify({ packages }))
  return packages
}

test('release manifest requires every public archive and unchanged bytes', () => {
  const root = fixture()
  const packages = archives(root)
  expect(readArchiveManifest(root)).toHaveLength(packages.length)
  writeFileSync(join(root, packages[0]!.file), 'changed')
  expect(() => readArchiveManifest(root)).toThrow('hash mismatch')
  writeFileSync(join(root, packages[0]!.file), `${packages[0]!.name}@1.2.3`)
  packages[0]!.file = '../escape.tgz'
  writeFileSync(join(root, 'manifest.json'), JSON.stringify({ packages }))
  expect(() => readArchiveManifest(root)).toThrow('Malformed')
  packages.shift()
  writeFileSync(join(root, 'manifest.json'), JSON.stringify({ packages }))
  expect(() => readArchiveManifest(root)).toThrow('does not cover every')
})

test('Bun audit parser fails closed and only High or Critical blocks', () => {
  expect(summarizeBunAudit({})).toEqual({ Critical: 0, High: 0 })
  expect(summarizeBunAudit({ svelte: [{ severity: 'moderate' }], unsafe: [{ severity: 'high' }, { severity: 'critical' }] }))
    .toEqual({ Critical: 1, High: 1 })
  for (const invalid of [null, [], { package: null }, { package: [{}] }, { package: [{ severity: 'unknown' }] }])
    expect(() => summarizeBunAudit(invalid)).toThrow()
})

test('release scanner rejects extra arguments before scanning', () => {
  const result = Bun.spawnSync([
    process.execPath,
    join(import.meta.dir, 'scan-release-artifacts.ts'),
    'linux', '/missing', '/missing', 'done',
  ], { stdout: 'pipe', stderr: 'pipe' })
  expect(result.exitCode).not.toBe(0)
  expect(result.stderr.toString()).toContain('Usage: scan-release-artifacts.ts')
})

function binary(root: string, path: string, magic: string) {
  const absolute = join(root, path)
  mkdirSync(join(absolute, '..'), { recursive: true })
  const bytes = Buffer.alloc(2048)
  Buffer.from(magic, 'hex').copy(bytes)
  writeFileSync(absolute, bytes)
}

test('native inventory binds exact binaries and Zig runtime version', () => {
  const root = fixture()
  binary(root, 'bin/craft', '7f454c46')
  binary(root, 'cross/windows-x64/craft.exe', '4d5a')
  const inventory = nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')
  expect(inventory.components.map(component => component.name)).toEqual(['craft-linux-x64', 'craft-windows-x64', 'zig-std'])
  expect(inventory.components[0]?.hashes).toEqual([{ alg: 'SHA-256', content: createHash('sha256').update(readFileSync(join(root, 'bin/craft'))).digest('hex') }])
  writeFileSync(join(root, 'cross/windows-x64/craft.exe'), 'not a binary')
  expect(() => nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')).toThrow('missing or empty')
  binary(root, 'cross/windows-x64/craft.exe', '7f454c46')
  expect(() => nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')).toThrow('unexpected executable format')
})

test('publisher uses only hash-verified archives and skips an existing version', () => {
  const root = fixture()
  const packages = archives(root)
  const calls: string[][] = []
  publishNpmArchives(root, (args) => {
    calls.push(args)
    if (args[0] === 'view')
      return args[1] === `${packages[0]!.name}@1.2.3`
        ? { exitCode: 0, stdout: '"1.2.3"', stderr: '' }
        : { exitCode: 1, stdout: '', stderr: 'E404' }
    return { exitCode: 0, stdout: '', stderr: '' }
  })
  expect(calls.filter(args => args[0] === 'publish')).toHaveLength(packages.length - 1)
  expect(calls.find(args => args[0] === 'publish')).toContain('--ignore-scripts')
  expect(calls.find(args => args[0] === 'publish')).toContain('--provenance')
  expect(calls.some(args => args[0] === 'publish' && args[1] === join(root, packages[0]!.file))).toBe(false)
})
