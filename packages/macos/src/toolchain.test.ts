import { expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { macosToolchain, pantryExecutable, resolveMacOSToolchain, resolveZig, toolchainCacheDir } from './toolchain'

test('the toolchain is pinned to exact revisions', () => {
  expect(macosToolchain.zig).toMatch(/^\d+\.\d+\.\d+-dev\.\d+\+[0-9a-f]+$/)
  for (const source of Object.values(macosToolchain.sources)) expect(source.revision).toMatch(/^[0-9a-f]{40}$/)
})

test('the cache is shared across apps unless told otherwise', () => {
  expect(toolchainCacheDir({ HOME: '/home/a' })).toBe('/home/a/.cache/craft/toolchain')
  expect(toolchainCacheDir({ HOME: '/home/a', XDG_CACHE_HOME: '/x' })).toBe('/x/craft/toolchain')
  expect(toolchainCacheDir({ CRAFT_TOOLCHAIN_DIR: '/y' })).toBe('/y')
})

test('Pantry is found from PANTRY_BIN first, then the project, then the user', () => {
  expect(pantryExecutable({ PANTRY_BIN: '/p', HOME: '/h' }, path => path === '/p')).toBe('/p')
  expect(pantryExecutable({ HOME: '/h' }, path => path === '/h/.local/bin/pantry')).toBe('/h/.local/bin/pantry')
  expect(pantryExecutable({ HOME: '/h' }, () => false)).toBe('pantry')
})

test('CRAFT_ZIG overrides Pantry and nothing is installed', async () => {
  const calls: string[][] = []
  expect(await resolveZig({ env: { CRAFT_ZIG: '/zig' }, run: async (args) => { calls.push(args); return { exitCode: 0, stdout: '' } } })).toBe('/zig')
  expect(calls).toEqual([])
})

test('missing pieces are installed from Pantry, fetched at the pin and built once, in order', async () => {
  const cache = mkdtempSync(join(tmpdir(), 'craft-toolchain-'))
  const calls: string[] = []
  const zig = join(cache, 'pantry/ziglang.org', `v${macosToolchain.zig}`, 'bin/zig')
  const run = async (args: string[], cwd?: string) => {
    calls.push(`${args[0]!.split('/').pop()} ${args.slice(1, 3).join(' ')}`)
    if (args[1] === 'install') { mkdirSync(join(zig, '..'), { recursive: true }); writeFileSync(zig, '') }
    if (args[1] === 'init') mkdirSync(join(cwd!, '.git'), { recursive: true })
    if (args[1] === 'build') { mkdirSync(join(cwd!, 'zig-out/lib'), { recursive: true }); writeFileSync(join(cwd!, 'zig-out/lib/libzig-js.a'), '') }
    return { exitCode: 0, stdout: args[1] === 'rev-parse' ? macosToolchain.sources['zig-js'].revision : '' }
  }
  try {
    const first = await resolveMacOSToolchain({ cacheDir: cache, env: {}, run })
    expect(first.zig).toBe(zig)
    expect(first.zigJS.library).toBe(join(cache, 'sources/zig-js/zig-out/lib/libzig-js.a'))
    expect(calls.some(call => call.includes('install ziglang.org@'))).toBe(true)
    expect(calls.filter(call => call.includes('build home-tool-bootstrap'))).toHaveLength(1)
    // A second resolution finds everything in place and builds nothing.
    calls.length = 0
    await resolveMacOSToolchain({ cacheDir: cache, env: {}, run })
    expect(calls.some(call => call.includes('build') || call.includes('install'))).toBe(false)
  }
  finally { rmSync(cache, { recursive: true, force: true }) }
})
