import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { validateReleaseCheckout, validateReleaseFormatting, validateReleaseGit, checkReleaseVersion, validateReleaseVersion } from './release-version'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

test('accepts a matching tag, including a prerelease', () => {
  for (const version of ['0.0.93', '1.2.3-rc.1', '1.2.3+build.4'])
    expect(() => validateReleaseVersion(`refs/tags/v${version}`, version, { sdk: version })).not.toThrow()
})

test('rejects branch dispatch, missing refs, mismatched tags and malformed versions', () => {
  for (const ref of ['refs/heads/main', '', 'refs/tags/v0.0.92', 'refs/tags/0.0.93', 'refs/tags/v0.0.93/extra'])
    expect(() => validateReleaseVersion(ref, '0.0.93', {})).toThrow()
  for (const version of ['latest', '1.2', '01.2.3', '1.2.3\nversion=4.5.6', '1.2.3-01', '1.2.3-alpha..1', '1.2.3+foo..bar'])
    expect(() => validateReleaseVersion(`refs/tags/v${version}`, version, {})).toThrow()
})

test('reports every mismatched manifest in one diagnostic', () => {
  try {
    validateReleaseVersion('refs/tags/v1.2.3', '1.2.3', { 'packages/android/package.json': '1.2.2', 'packages/ios/package.json': undefined, 'packages/zig/build.zig.zon': '1.0.0' })
    throw new Error('expected validation to reject')
  }
  catch (error) {
    expect(String(error)).toContain('packages/android/package.json')
    expect(String(error)).toContain('packages/ios/package.json')
    expect(String(error)).toContain('packages/zig/build.zig.zon')
  }
})

test('discovers public workspaces and Zig metadata, excluding private examples', () => {
  const temp = createTempDir('craft-release-version-')
  try {
    for (const name of ['sdk', 'example', 'zig']) mkdirSync(join(temp, 'packages', name), { recursive: true })
    writeFileSync(join(temp, 'package.json'), JSON.stringify({ version: '1.2.3' }))
    writeFileSync(join(temp, 'packages/sdk/package.json'), JSON.stringify({ name: 'fixture', version: '1.2.3' }))
    writeFileSync(join(temp, 'packages/example/package.json'), JSON.stringify({ private: true, version: '0.0.1' }))
    writeFileSync(join(temp, 'packages/zig/build.zig.zon'), '.{ .version = "1.2.3", }')
    writeFileSync(join(temp, 'packages/zig/pantry.json'), JSON.stringify({ version: '1.2.3' }))
    expect(checkReleaseVersion(temp, 'refs/tags/v1.2.3')).toBe('1.2.3')
    writeFileSync(join(temp, 'packages/sdk/package.json'), JSON.stringify({ name: 'fixture', version: '1.2.2' }))
    expect(() => checkReleaseVersion(temp, 'refs/tags/v1.2.3')).toThrow('packages/sdk/package.json')
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
})

test('refuses an incomplete sparse release checkout before a version bump', () => {
  const root = createTempDir('craft-release-checkout-')
  mkdirSync(join(root, 'packages', 'react'), { recursive: true })
  const manifest = join(root, 'packages/react/package.json')
  writeFileSync(manifest, '{"version":"1.2.3"}')
  expect(Bun.spawnSync(['git', 'init', '-q'], { cwd: root }).exitCode).toBe(0)
  expect(Bun.spawnSync(['git', 'add', '.'], { cwd: root }).exitCode).toBe(0)
  expect(() => validateReleaseCheckout(root)).not.toThrow()
  rmSync(manifest)
  expect(() => validateReleaseCheckout(root)).toThrow('packages/react/package.json')
})

test('release preflight rejects missing tools before changing package versions or tags', () => {
  const root = createTempDir('craft-release-prerequisites-')
  mkdirSync(join(root, 'scripts'))
  const manifest = '{"version":"1.2.3"}\n'
  writeFileSync(join(root, 'package.json'), manifest)
  writeFileSync(join(root, 'scripts/release-version.ts'), readFileSync(join(import.meta.dir, 'release-version.ts')))
  writeFileSync(join(root, 'scripts/zig.ts'), readFileSync(join(import.meta.dir, 'zig.ts')))
  expect(Bun.spawnSync(['git', 'init', '-q'], { cwd: root }).exitCode).toBe(0)
  const result = Bun.spawnSync([process.execPath, 'scripts/release-version.ts', '--preflight'], { cwd: root, stdout: 'pipe', stderr: 'pipe' })
  expect(result.exitCode).not.toBe(0)
  expect(result.stderr.toString()).toContain('bun install --frozen-lockfile')
  expect(readFileSync(join(root, 'package.json'), 'utf8')).toBe(manifest)
  expect(Bun.spawnSync(['git', 'tag', '--list'], { cwd: root, stdout: 'pipe' }).stdout.toString()).toBe('')
})

test('release formatting checks the core project, propagates failure and rejects an unpinned override', () => {
  const root = createTempDir('craft-release-format-')
  const core = join(root, 'packages/zig')
  mkdirSync(join(core, 'src'), { recursive: true })
  mkdirSync(join(root, 'scripts'))
  writeFileSync(join(root, 'scripts/zig.ts'), readFileSync(join(import.meta.dir, 'zig.ts')))
  const version = '0.18.0-dev.146+35accc06e'
  writeFileSync(join(root, 'pantry.lock'), JSON.stringify({ workspaces: { '': { system: { 'ziglang.org': version } } } }))
  const compiler = join(root, 'zig')
  const script = `#!/bin/sh
if [ "$1" = version ]; then printf '%s\\n' '${version}'; exit 0; fi
[ "$*" = 'fmt --check src/ build.zig' ] || exit 9
pwd > checked-directory
exit "\${CRAFT_FORMAT_RESULT:-0}"
`
  writeFileSync(compiler, script, { mode: 0o755 })
  const env = { ...process.env, CRAFT_ZIG: compiler, CRAFT_FORMAT_RESULT: '0' }
  expect(() => validateReleaseFormatting(root, env)).not.toThrow()
  expect(realpathSync(readFileSync(join(core, 'checked-directory'), 'utf8').trim())).toBe(realpathSync(core))
  expect(() => validateReleaseFormatting(root, { ...env, CRAFT_FORMAT_RESULT: '23' })).toThrow('Release Zig formatting check failed')
  writeFileSync(compiler, script.replace(version, '0.17.0'))
  expect(() => validateReleaseFormatting(root, { ...env, CRAFT_ALLOW_UNPINNED_ZIG: '1' })).toThrow('Zig version mismatch')
})

test('release Git preflight requires clean main and checks the current remote', () => {
  // This integration fixture creates two real checkouts and a bare remote;
  // process startup time is not a release-preflight performance contract.
  const root = createTempDir('craft-release-main-')
  const remote = join(root, 'remote.git')
  const work = join(root, 'work')
  mkdirSync(work)
  const git = (cwd: string, ...args: string[]) => {
    const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    return result.stdout.toString()
  }
  git(root, 'init', '--bare', remote)
  git(work, 'init', '-b', 'main')
  git(work, 'config', 'user.email', 'release@example.com')
  git(work, 'config', 'user.name', 'Release fixture')
  git(work, 'commit', '--allow-empty', '-m', 'chore: initial release')
  git(work, 'remote', 'add', 'origin', remote)
  git(work, 'push', '-u', 'origin', 'main')
  expect(() => validateReleaseGit(work)).not.toThrow()
  writeFileSync(join(work, 'unfinished.txt'), 'unfinished')
  expect(() => validateReleaseGit(work)).toThrow('clean main')
  rmSync(join(work, 'unfinished.txt'))
  git(work, 'switch', '-c', 'feature')
  expect(() => validateReleaseGit(work)).toThrow('Release from main')
  git(work, 'switch', 'main')
  const peer = join(root, 'peer')
  git(root, 'clone', '--branch', 'main', remote, peer)
  git(peer, 'config', 'user.email', 'peer@example.com')
  git(peer, 'config', 'user.name', 'Release peer')
  git(peer, 'commit', '--allow-empty', '-m', 'chore: another source change')
  git(peer, 'push', 'origin', 'main')
  expect(() => validateReleaseGit(work)).toThrow('must match origin/main')
}, 30000)
