import { expect, test } from 'bun:test'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describeDownloadedArchives } from './emulator'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * `sdkmanager` reports `java.util.zip.ZipException: Archive is not a ZIP
 * archive` without saying anything about the bytes it read, so a truncated
 * download, an error page served with a .zip name and a genuinely corrupt
 * archive all look identical afterwards (#451). The leading bytes separate
 * them, and the staging directory is the only record once provisioning fails.
 */
function staging(): { root: string, temp: string } {
  const root = createTempDir('craft-sdk-identity-')
  const temp = join(root, '.temp', 'PackageOperation01')
  mkdirSync(temp, { recursive: true })
  return { root, temp }
}

test('an error page served as an archive is identifiable as markup, not a zip', () => {
  const { root, temp } = staging()
  try {
    writeFileSync(join(temp, 'emulator.zip'), '<!DOCTYPE html>\n<html><body>503</body></html>\n')
    const [found] = describeDownloadedArchives(root)
    expect(found?.looksLike).toBe('markup')
    expect(found?.path).toBe(join('.temp', 'PackageOperation01', 'emulator.zip'))
    expect(found?.leadingHex.startsWith('3c')).toBe(true)
    expect(found?.bytes).toBeGreaterThan(0)
    expect(found?.sha256).toMatch(/^[a-f0-9]{64}$/)
  }
  finally { removeTempDir(root) }
})

test('a real archive, a gzip stream and an empty response are each distinguished', () => {
  const { root, temp } = staging()
  try {
    writeFileSync(join(temp, 'ok.zip'), Buffer.from([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]))
    writeFileSync(join(temp, 'stream.gz'), Buffer.from([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0]))
    writeFileSync(join(temp, 'truncated.zip'), Buffer.alloc(0))
    const kinds = Object.fromEntries(describeDownloadedArchives(root).map(entry => [entry.path.split('/').at(-1), entry.looksLike]))
    expect(kinds['ok.zip']).toBe('zip')
    expect(kinds['stream.gz']).toBe('gzip')
    expect(kinds['truncated.zip']).toBe('empty')
  }
  finally { removeTempDir(root) }
})

test('no staging directory yields no claims, and the limit is honoured', () => {
  const bare = createTempDir('craft-sdk-identity-bare-')
  try { expect(describeDownloadedArchives(bare)).toEqual([]) }
  finally { removeTempDir(bare) }

  const { root, temp } = staging()
  try {
    for (let index = 0; index < 8; index++) writeFileSync(join(temp, `part-${index}.zip`), Buffer.from([0x50, 0x4B]))
    expect(describeDownloadedArchives(root, 3)).toHaveLength(3)
  }
  finally { removeTempDir(root) }
})
