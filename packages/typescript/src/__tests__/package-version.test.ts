import { expect, test } from 'bun:test'
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

test('relocated ESM and CJS bundles retain their build-time SDK version', async () => {
  const packageRoot = resolve(import.meta.dir, '../..')
  const temp = mkdtempSync(join(tmpdir(), 'craft-version-package-'))
  try {
    const source = join(temp, 'source')
    mkdirSync(source)
    cpSync(join(packageRoot, 'src'), join(source, 'src'), { recursive: true })
    writeFileSync(join(source, 'package.json'), JSON.stringify({ name: 'craft-native', version: '7.8.9', type: 'module' }))
    symlinkSync(join(packageRoot, 'node_modules'), join(source, 'node_modules'), 'dir')
    for (const format of ['esm', 'cjs'] as const) {
      const result = await Bun.build({
        root: source,
        entrypoints: [join(source, 'src/index.ts')],
        outdir: join(temp, format),
        naming: format === 'cjs' ? 'sdk.cjs' : 'sdk.mjs',
        format,
        target: format === 'cjs' ? 'node' : 'bun',
      })
      expect(result.success).toBe(true)
    }
    // Neither installed bundle may read the now-absent build checkout.
    rmSync(source, { recursive: true, force: true })
    const native = join(temp, 'native')
    writeFileSync(native, '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "craft version $CRAFT_TEST_VERSION"; fi\n')
    chmodSync(native, 0o755)
    for (const format of ['esm', 'cjs'] as const) {
      const bundle = join(temp, format, format === 'cjs' ? 'sdk.cjs' : 'sdk.mjs')
      const consumer = join(temp, format === 'cjs' ? 'consumer.cjs' : 'consumer.mjs')
      const load = format === 'cjs' ? `const sdk = require(${JSON.stringify(bundle)})` : `import * as sdk from ${JSON.stringify(bundle)}`
      writeFileSync(consumer, `${load}\nsdk.createApp({ url: 'https://example.test', craftPath: ${JSON.stringify(native)}, quiet: true }).show().catch(error => { console.error(error); process.exitCode = 1 })\n`)
      for (const nativeVersion of ['7.8.9', '7.8.10']) {
        const result = Bun.spawnSync([format === 'cjs' ? 'node' : process.execPath, consumer], {
          cwd: temp,
          env: { ...process.env, CRAFT_TEST_VERSION: nativeVersion },
          stdout: 'pipe', stderr: 'pipe',
        })
        expect(result.exitCode).toBe(0)
        const stderr = result.stderr.toString()
        if (nativeVersion === '7.8.9') expect(stderr).not.toContain('version mismatch')
        else expect(stderr).toContain('SDK=7.8.9, native=7.8.10')
      }
      const runtimePaths = readFileSync(bundle, 'utf8').split('\n')
        .filter(line => !line.trimStart().startsWith('//') && line.includes(source))
      expect(runtimePaths).toEqual([])
    }
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
}, 60_000)
