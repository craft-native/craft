import { afterEach, expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pinnedZigVersion, resolveZig, runZig } from './zig'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

function fixture(version = '0.17.0-dev.1963+e00c6c439') {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'craft-zig-toolchain-')))
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
  expect(JSON.parse(readFileSync(f.env.ZIG_TEST_LOG, 'utf8'))).toEqual({ cwd: join(f.root, 'packages/zig'), args: ['build', '-Doptimize=ReleaseSafe', '-Dfoo=a b', '-Dversion=1.2.3'] })
  expect(runZig(f.root, ['fmt', 'src/'], f.env)).toBe(23)
  expect(JSON.parse(readFileSync(f.env.ZIG_TEST_LOG, 'utf8'))).toEqual({ cwd: f.root, args: ['fmt', 'src/'] })
})
