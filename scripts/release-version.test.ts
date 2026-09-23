import { expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { checkReleaseVersion, validateReleaseVersion } from './release-version'

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
  const temp = mkdtempSync(join(tmpdir(), 'craft-release-version-'))
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
