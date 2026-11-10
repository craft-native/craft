import { afterAll, afterEach, expect, test } from 'bun:test'
import { createHash } from 'node:crypto'
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { publishNpmArchives, verifyNpmAvailability } from './publish-npm-archives'
import { expectedNpmPackages, npmConsumerManifest, nativeInventory, readArchiveManifest, summarizeBunAudit } from './scan-release-artifacts'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })
const fixture = () => {
  const root = createTempDir('craft-release-artifacts-test-')
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
}, 30_000)

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
  binary(root, 'cross/windows-x64/WebView2Loader.dll', '4d5a')
  const inventory = nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')
  expect(inventory.components.map(component => component.name)).toEqual(['craft-linux-x64', 'craft-windows-x64', 'WebView2Loader', 'zig-std'])
  expect(inventory.components[0]?.hashes).toEqual([{ alg: 'SHA-256', content: createHash('sha256').update(readFileSync(join(root, 'bin/craft'))).digest('hex') }])
  expect(inventory.components[2]?.version).toBe('1.0.4191.47')
  expect(inventory.components[2]?.type).toBe('library')
  expect(inventory.dependencies).toContainEqual({ ref: 'urn:craft:binary:craft-windows-x64', dependsOn: ['urn:craft:zig-std', 'urn:craft:binary:WebView2Loader'] })
  writeFileSync(join(root, 'cross/windows-x64/craft.exe'), 'not a binary')
  expect(() => nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')).toThrow('missing or empty')
  binary(root, 'cross/windows-x64/craft.exe', '7f454c46')
  expect(() => nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')).toThrow('unexpected executable format')
  binary(root, 'cross/windows-x64/craft.exe', '4d5a')
  writeFileSync(join(root, 'cross/windows-x64/WebView2Loader.dll'), 'not a binary')
  expect(() => nativeInventory(root, 'linux', '1.2.3', '0.17.0-dev.1963')).toThrow('WebView2Loader: missing or empty')
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

test('publisher rechecks transferred npm archives before any registry call', () => {
  const prepared = fixture()
  const downloaded = fixture()
  const packages = archives(prepared)
  for (const file of ['manifest.json', ...packages.map(archive => archive.file)])
    copyFileSync(join(prepared, file), join(downloaded, file))

  const calls: string[][] = []
  const command = (args: string[]) => {
    calls.push(args)
    return args[0] === 'view'
      ? { exitCode: 1, stdout: '', stderr: 'E404' }
      : { exitCode: 0, stdout: '', stderr: '' }
  }
  publishNpmArchives(downloaded, command)
  expect(calls.filter(args => args[0] === 'publish')).toHaveLength(packages.length)

  calls.length = 0
  writeFileSync(join(downloaded, packages[0]!.file), 'changed after upload')
  expect(() => publishNpmArchives(downloaded, command)).toThrow('hash mismatch')
  expect(calls).toHaveLength(0)
})

test('accepted uploads stay pending until metadata and the exact public archive are downloadable', async () => {
  const root = fixture()
  const packages = archives(root)
  let time = 0
  const downloads: string[] = []
  await verifyNpmAvailability(root, {
    now: () => time, intervalMs: 10, timeoutMs: 100,
    sleep: async ms => { time += ms },
    request: async (url) => {
      const path = new URL(url).pathname
      const download = path.startsWith('/-/')
      const name = decodeURIComponent(path.slice(download ? 3 : 1).split('/')[0]!)
      const item = packages.find(item => item.name === name)!
      if (time === 0 || (download && time === 10)) return new Response(null, { status: 404 })
      if (download) {
        downloads.push(name)
        return new Response(readFileSync(join(root, item.file)))
      }
      return Response.json({ name, version: item.version, dist: { tarball: `https://registry.npmjs.org/-/${encodeURIComponent(name)}` } })
    },
  })
  expect(time).toBe(20)
  expect(downloads.sort()).toEqual(packages.map(item => item.name).sort())
})

test('an existing version with changed public bytes fails instead of silently skipping', async () => {
  const root = fixture()
  const packages = archives(root)
  const item = packages[0]!
  await expect(verifyNpmAvailability(root, { request: async url => new URL(url).pathname.startsWith('/-/')
    ? new Response('tampered archive')
    : Response.json({ name: item.name, version: item.version, dist: { tarball: 'https://registry.npmjs.org/-/archive' } }) })).rejects.toThrow('hash differs')
})

test('availability times out with a verification-only recovery command and no new publication', async () => {
  const root = fixture()
  archives(root)
  let time = 0
  await expect(verifyNpmAvailability(root, {
    request: async () => new Response(null, { status: 404 }),
    now: () => time, sleep: async ms => { time += ms }, timeoutMs: 25, intervalMs: 10,
  })).rejects.toThrow('--verify-only')
  expect(time).toBe(25)
})

test('availability respects Retry-After and retries temporary network errors', async () => {
  const root = fixture()
  const packages = archives(root)
  let time = 0
  let first = true
  await verifyNpmAvailability(root, {
    now: () => time, sleep: async ms => { time += ms }, timeoutMs: 2000, intervalMs: 10,
    request: async (url) => {
      if (first) { first = false; throw new Error('temporary network failure') }
      if (!time) return new Response(null, { status: 429, headers: { 'retry-after': '1' } })
      const path = new URL(url).pathname
      const download = path.startsWith('/-/')
      const name = decodeURIComponent(path.slice(download ? 3 : 1).split('/')[0]!)
      const item = packages.find(item => item.name === name)!
      return download ? new Response(readFileSync(join(root, item.file)))
        : Response.json({ name, version: item.version, dist: { tarball: `https://registry.npmjs.org/-/${encodeURIComponent(name)}` } })
    },
  })
  expect(time).toBe(1000)
})

test('availability fails closed for authorization errors, foreign archives and locally changed archives', async () => {
  const root = fixture()
  const [item] = archives(root)
  await expect(verifyNpmAvailability(root, { request: async () => new Response(null, { status: 403 }) })).rejects.toThrow('403')
  await expect(verifyNpmAvailability(root, { request: async () => Response.json({ name: item!.name, version: item!.version, dist: { tarball: 'https://example.com/archive.tgz' } }) })).rejects.toThrow('unexpected npm archive URL')
  writeFileSync(join(root, item!.file), 'changed')
  let requested = false
  await expect(verifyNpmAvailability(root, { request: async () => { requested = true; return new Response() } })).rejects.toThrow('hash mismatch')
  expect(requested).toBe(false)
})

// The scan exists to inspect the exact archives about to be published, so it
// must not ask the registry about a sibling it is already holding. The packed
// UI bindings declare `craft-native` at the version being released, and that
// version cannot exist upstream yet -- this scan is what gates publishing it.
// A top-level `file:` entry does not reach that nested requirement; only an
// override does. Without one, every release after the bindings gained a core
// dependency fails with `No version matching "<version>" found`.
test('the release consumer resolves sibling packages from the packed archives', () => {
  const archives = [
    { name: 'craft-native', version: '0.0.442', file: 'craft-native-0.0.442.tgz', sha256: 'a' },
    { name: '@craft-native/react', version: '0.0.442', file: 'craft-native-react-0.0.442.tgz', sha256: 'b' },
  ]
  const manifest = npmConsumerManifest(archives, '/tmp/archives')
  for (const archive of archives) {
    const local = `file:/tmp/archives/${archive.file}`
    expect(manifest.dependencies[archive.name]).toBe(local)
    // The override is what a nested `craft-native@0.0.442` resolves through.
    expect(manifest.overrides[archive.name]).toBe(local)
  }
  expect(manifest.private).toBe(true)
})
