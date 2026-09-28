import { afterAll, describe, expect, it } from 'bun:test'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { checkReleaseVersion } from './release-version'
import { syncReleaseVersion } from './sync-release-version'

const root = resolve(import.meta.dir, '..')
const scratch = mkdtempSync(join(tmpdir(), 'craft-sync-version-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

describe('syncReleaseVersion', () => {
  it('makes a bumped repository pass the Releaser version gate', () => {
    // The real manifests, with package.json files bumped the way bumpx does
    // and the Zig ones left behind - the state that failed v0.0.93.
    mkdirSync(join(scratch, 'packages/zig'), { recursive: true })
    for (const file of ['packages/zig/build.zig.zon', 'packages/zig/pantry.json'])
      cpSync(join(root, file), join(scratch, file))
    const bump = (path: string, version: string) => {
      const pkg = JSON.parse(readFileSync(join(root, path), 'utf8'))
      mkdirSync(join(scratch, path, '..'), { recursive: true })
      writeFileSync(join(scratch, path), JSON.stringify({ ...pkg, version }, null, 2))
    }
    bump('package.json', '9.9.9')
    for (const path of new Bun.Glob('packages/*/package.json').scanSync({ cwd: root }))
      bump(path, '9.9.9')

    expect(() => checkReleaseVersion(scratch, 'refs/tags/v9.9.9')).toThrow(/packages\/zig/)
    expect(syncReleaseVersion(scratch)).toBe('9.9.9')
    expect(checkReleaseVersion(scratch, 'refs/tags/v9.9.9')).toBe('9.9.9')
  })

  it('keeps the rest of each manifest byte for byte', () => {
    const before = readFileSync(join(root, 'packages/zig/build.zig.zon'), 'utf8')
    const after = readFileSync(join(scratch, 'packages/zig/build.zig.zon'), 'utf8')
    expect(after.replace(/\.version\s*=\s*"[^"]+"/, '')).toBe(before.replace(/\.version\s*=\s*"[^"]+"/, ''))
  })
})
