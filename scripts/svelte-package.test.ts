import { expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

test('packed Svelte condition resolves outside the workspace', async () => {
  const root = resolve(import.meta.dir, '..')
  const temp = mkdtempSync(join(tmpdir(), 'craft-svelte-package-'))
  try {
    const packed = Bun.spawnSync([
      process.execPath, 'pm', 'pack', '--filename', join(temp, 'package.tgz'),
    ], { cwd: join(root, 'packages/svelte'), stdout: 'pipe', stderr: 'pipe' })
    expect(packed.exitCode).toBe(0)
    const installed = join(temp, 'node_modules/@craft-native/svelte')
    mkdirSync(installed, { recursive: true })
    const extracted = Bun.spawnSync([
      'tar', '-xzf', join(temp, 'package.tgz'), '--strip-components=1', '-C', installed,
    ], { stdout: 'pipe', stderr: 'pipe' })
    expect(extracted.exitCode).toBe(0)
    writeFileSync(join(temp, 'consumer.ts'), "export * from '@craft-native/svelte'\n")
    const bundled = await Bun.build({
      entrypoints: [join(temp, 'consumer.ts')],
      conditions: ['svelte'],
      external: ['svelte', 'svelte/*', 'craft-native'],
      target: 'browser',
    })
    expect(bundled.logs.filter(log => log.level === 'error')).toEqual([])
    expect(bundled.success).toBe(true)
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
})
