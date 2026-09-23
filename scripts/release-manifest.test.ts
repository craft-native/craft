import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createReleaseManifest, verifyReleaseManifest } from './release-manifest'

const identity = { repository: 'craft-native/craft', tag: 'v0.0.93', commit: 'a'.repeat(40) }
const names = ['craft-darwin-arm64.zip', 'craft-darwin-x64.zip', 'craft-linux-x64.zip', 'craft-windows-x64.zip']

function withArchives(check: (dir: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), 'craft-manifest-'))
  try {
    for (const name of names) writeFileSync(join(dir, name), `bytes for ${name}`)
    check(dir)
  }
  finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('includes every platform and additional future archives with exact byte hashes', () => {
  withArchives((dir) => {
    writeFileSync(join(dir, 'craft-linux-arm64.zip'), 'abc')
    const manifest = createReleaseManifest(identity, dir)
    expect(manifest.assets).toHaveLength(5)
    expect(manifest.assets.find(asset => asset.name === 'craft-linux-arm64.zip')).toEqual({ name: 'craft-linux-arm64.zip', size: 3, sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' })
    expect(() => verifyReleaseManifest(manifest, manifest)).not.toThrow()
  })
})

test('rejects the macOS-only manifest shape that shipped in v0.0.92', () => {
  withArchives((dir) => {
    const expected = createReleaseManifest(identity, dir)
    expect(() => verifyReleaseManifest({ ...expected, assets: expected.assets.slice(0, 2) }, expected)).toThrow('asset set mismatch')
  })
})

test('requires Windows and rejects empty archives', () => {
  withArchives((dir) => {
    rmSync(join(dir, 'craft-windows-x64.zip'))
    expect(() => createReleaseManifest(identity, dir)).toThrow('craft-windows-x64.zip')
    writeFileSync(join(dir, 'craft-windows-x64.zip'), '')
    expect(() => createReleaseManifest(identity, dir)).toThrow('empty')
  })
})

test('rejects changed bytes, duplicate assets, unexpected names and stale identity', () => {
  withArchives((dir) => {
    const expected = createReleaseManifest(identity, dir)
    for (const key of ['schemaVersion', 'repository', 'tag', 'commit'])
      expect(() => verifyReleaseManifest({ ...expected, [key]: 'wrong' }, expected)).toThrow('mismatch')
    const duplicate = structuredClone(expected)
    duplicate.assets[1] = duplicate.assets[0]
    expect(() => verifyReleaseManifest(duplicate, expected)).toThrow('duplicate')
    for (const changed of [{ name: 'craft-unknown.zip' }, { size: 1 }, { sha256: '0'.repeat(64) }]) {
      const manifest = structuredClone(expected)
      Object.assign(manifest.assets[0], changed)
      expect(() => verifyReleaseManifest(manifest, expected)).toThrow()
    }
    writeFileSync(join(dir, names[0]), 'tampered')
    expect(() => verifyReleaseManifest(expected, createReleaseManifest(identity, dir))).toThrow('SHA-256 mismatch')
  })
})
