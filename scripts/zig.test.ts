import { afterAll, afterEach, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pinnedPantryZigPath, pinnedZigVersion, resolveZig, runZig } from './zig'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

function fixture(version = '0.17.0-dev.1963+e00c6c439') {
  const root = realpathSync(createTempDir('craft-zig-toolchain-'))
  roots.push(root)
  mkdirSync(join(root, 'packages/zig'), { recursive: true })
  writeFileSync(join(root, 'pantry.lock'), JSON.stringify({ workspaces: { '': { system: { 'ziglang.org': '0.17.0-dev.1963_e00c6c439' } } } }))
  writeFileSync(join(root, 'package.json'), JSON.stringify({ version: '1.2.3' }))
  const path = join(root, 'zig')
  writeFileSync(path, `#!${process.execPath}\nif (process.argv[2] === 'version') console.log(${JSON.stringify(version)}); else { await Bun.write(process.env.ZIG_TEST_LOG, JSON.stringify({ cwd: process.cwd(), args: process.argv.slice(2) })); process.exit(23); }\n`)
  chmodSync(path, 0o755)
  return { root, path, env: { ...process.env, CRAFT_ZIG: '', CRAFT_ALLOW_UNPINNED_ZIG: '', PATH: root, ZIG_TEST_LOG: join(root, 'invocation.json') } }
}

test('accepts only the locked snapshot by default, even when PATH shadows it', () => {
  const f = fixture('0.17.0-dev.2163+89ff10d56')
  expect(pinnedZigVersion(f.root)).toBe('0.17.0-dev.1963+e00c6c439')
  expect(() => resolveZig(f.root, f.env)).toThrow('version mismatch')
  expect(() => resolveZig(f.root, f.env)).toThrow('CRAFT_ALLOW_UNPINNED_ZIG=1')
  const pinned = fixture()
  expect(resolveZig(f.root, { ...f.env, CRAFT_ZIG: pinned.path })).toEqual({ path: pinned.path, version: '0.17.0-dev.1963+e00c6c439', overridden: false })
})

test.each(['0.17.0-dev.1963+e00c6c439', '0.17.0-dev.1963_e00c6c439'])('accepts the exact generated Zig pin %s without an override', (locked) => {
  const f = fixture()
  writeFileSync(join(f.root, 'pantry.lock'), JSON.stringify({ workspaces: { '': { system: { 'ziglang.org': locked } } } }))
  expect(pinnedZigVersion(f.root)).toBe('0.17.0-dev.1963+e00c6c439')
  expect(resolveZig(f.root, f.env)).toEqual({ path: f.path, version: '0.17.0-dev.1963+e00c6c439', overridden: false })
})

test.each(['^0.17.0', '0.17.0-dev.1963', '0.17.0-dev.1963+nothex', '0.17.0-dev.1963+e00c6c439+extra', '0.17.0-dev.1963_e00c6c439_extra'])('rejects non-exact or malformed Zig pin %s', (locked) => {
  const f = fixture()
  writeFileSync(join(f.root, 'pantry.lock'), JSON.stringify({ workspaces: { '': { system: { 'ziglang.org': locked } } } }))
  expect(() => pinnedZigVersion(f.root)).toThrow('exact Zig version')
})

test.each(['ziglang.org/v', 'ziglang-org/'])('Windows uses the pinned Pantry installation at %s instead of its .bin shim', (layout) => {
  const f = fixture()
  const version = pinnedZigVersion(f.root)
  const packageDir = join(f.root, `pantry/${layout}0.17.0-dev.1963_e00c6c439`)
  const installed = join(packageDir, 'zig.exe')
  expect(pinnedPantryZigPath(f.root, version, f.env, 'win32')).toBeNull()
  mkdirSync(packageDir, { recursive: true })
  writeFileSync(installed, '')
  expect(pinnedPantryZigPath(f.root, version, f.env, 'win32')).toBe(installed)
  const mirrored = join(packageDir, 'bin/zig.exe')
  mkdirSync(join(packageDir, 'bin'))
  writeFileSync(mirrored, '')
  expect(pinnedPantryZigPath(f.root, version, f.env, 'win32')).toBe(installed)
  rmSync(installed)
  expect(pinnedPantryZigPath(f.root, version, f.env, 'win32')).toBe(mirrored)
  expect(pinnedPantryZigPath(f.root, version, { ...f.env, CRAFT_ZIG: f.path }, 'win32')).toBeNull()
  expect(pinnedPantryZigPath(f.root, version, f.env, 'darwin')).toBeNull()
})

test.each([
  ['darwin', 'ziglang.org/v0.17.0-dev.1963+e00c6c439', 'bin/zig'],
  ['linux', 'ziglang.org/v0.17.0-dev.1963_e00c6c439', 'bin/zig'],
  ['linux', 'ziglang.org/v0.17.0-dev.1963_e00c6c439', 'zig'],
  ['darwin', 'ziglang-org/0.17.0-dev.1963_e00c6c439', 'bin/zig'],
])('%s selects the locked local compiler at %s/%s ahead of a stale global PATH', (platform, layout, binary) => {
  const f = fixture('0.17.0-dev.2163+89ff10d56')
  const pinned = fixture()
  const installed = join(f.root, 'pantry', layout!, binary!)
  mkdirSync(join(installed, '..'), { recursive: true })
  writeFileSync(installed, readFileSync(pinned.path))
  chmodSync(installed, 0o755)
  expect(resolveZig(f.root, f.env, platform)).toEqual({ path: installed, version: '0.17.0-dev.1963+e00c6c439', overridden: false })
  // Explicit experiments keep their existing opt-in; no silent pin bypass.
  expect(() => resolveZig(f.root, { ...f.env, CRAFT_ZIG: f.path }, platform)).toThrow('version mismatch')
  expect(resolveZig(f.root, { ...f.env, CRAFT_ZIG: f.path, CRAFT_ALLOW_UNPINNED_ZIG: '1' }, platform).overridden).toBe(true)
}, 30_000)

test('requires an explicit opt-in for unpinned snapshots', () => {
  const f = fixture('0.17.0-dev.2163+89ff10d56')
  expect(() => resolveZig(f.root, { ...f.env, CRAFT_ALLOW_UNPINNED_ZIG: 'true' })).toThrow('version mismatch')
  expect(resolveZig(f.root, { ...f.env, CRAFT_ALLOW_UNPINNED_ZIG: '1' }).overridden).toBe(true)
})

test('fails early for absent executables, invalid lock versions, and invalid compiler output', () => {
  const f = fixture('not a version')
  expect(() => resolveZig(f.root, { ...f.env, CRAFT_ZIG: join(f.root, 'missing') })).toThrow('was not found')
  expect(() => resolveZig(f.root, f.env)).toThrow('Invalid Zig version')
  writeFileSync(join(f.root, 'pantry.lock'), JSON.stringify({ workspaces: { '': { system: { 'ziglang.org': 'latest' } } } }))
  expect(() => pinnedZigVersion(f.root)).toThrow('exact Zig version')
})

test('forwards arguments, core working directory, package version and compiler exit status', () => {
  const f = fixture()
  expect(runZig(f.root, ['--core', '--versioned', 'build', '-Doptimize=ReleaseSafe', '-Dfoo=a b'], f.env)).toBe(23)
  expect(JSON.parse(readFileSync(f.env.ZIG_TEST_LOG, 'utf8'))).toEqual({ cwd: join(f.root, 'packages/zig'), args: ['build', '--build-file', join(f.root, 'packages/zig/build.zig'), '-Doptimize=ReleaseSafe', '-Dfoo=a b', '-Dversion=1.2.3'] })
  expect(runZig(f.root, ['--core', 'fmt', 'src/'], f.env)).toBe(23)
  expect(JSON.parse(readFileSync(f.env.ZIG_TEST_LOG, 'utf8'))).toEqual({ cwd: join(f.root, 'packages/zig'), args: ['fmt', 'src/'] })
  expect(runZig(f.root, ['fmt', 'src/'], f.env)).toBe(23)
  expect(JSON.parse(readFileSync(f.env.ZIG_TEST_LOG, 'utf8'))).toEqual({ cwd: f.root, args: ['fmt', 'src/'] })
}, 30_000)
