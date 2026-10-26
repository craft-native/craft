import { expect, test } from 'bun:test'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { packageApp } from '../package'
import { createTempDir, removeTempDir } from '../temp-dir'

test('standalone app packaging refuses missing notarization credentials', async () => {
  const work = createTempDir('craft-notary-contract-')
  try {
    const binary = join(work, 'Example')
    writeFileSync(binary, '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    const results = await packageApp({
      name: 'Example', version: '1.0.0', binaryPath: binary,
      platforms: ['macos'], outDir: join(work, 'dist'),
      macos: { dmg: false, notarize: true },
    })
    expect(results.some(result => result.success)).toBe(false)
    expect(results.find(result => result.format === 'app (notarize)')?.error).toContain('Notarization requires')
  }
  finally {
    removeTempDir(work)
  }
})
