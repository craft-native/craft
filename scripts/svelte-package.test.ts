import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

test('packed Svelte condition resolves outside the workspace', async () => {
  const root = resolve(import.meta.dir, '..')
  const temp = createTempDir('craft-svelte-package-')
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
}, 30_000)

test('store declarations expose the public Readable contract', () => {
  const root = resolve(import.meta.dir, '..')
  const sdkDir = join(root, 'packages/typescript')
  const temp = createTempDir('craft-svelte-types-')
  const run = (args: string[], cwd = temp) => {
    const result = Bun.spawnSync([process.execPath, ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
    if (result.exitCode !== 0) throw new Error(`${args.join(' ')} failed:\n${result.stdout}\n${result.stderr}`)
  }
  try {
    // Both the workspace Svelte build and the packed consumer resolve the
    // SDK's public declaration entry point. Prepare it in this fixture so a
    // clean run works even when Svelte is the first package suite to run.
    run(['run', 'build'], sdkDir)
    run(['pm', 'pack', '--filename', join(temp, 'core.tgz')], sdkDir)
    writeFileSync(join(temp, 'package.json'), JSON.stringify({
      private: true, type: 'module', dependencies: { 'craft-native': `file:${join(temp, 'core.tgz')}` }, devDependencies: { 'bun-types': '1.4.4' },
    }))
    run(['install'])
    const tsc = join(sdkDir, 'scripts/tsc.ts')
    run([
      tsc, '-p', join(root, 'packages/svelte/tsconfig.json'), '--emitDeclarationOnly',
      '--outDir', join(temp, 'declarations'),
    ])
    // Consumers only need Svelte's public store interface. Inferred subscribe
    // signatures must not leak helper exports from the build-time peer.
    writeFileSync(join(temp, 'store-contract.d.ts'), `
declare module 'svelte/store' {
  export interface Readable<T> {
    subscribe(run: (value: T) => void, invalidate?: (value?: T) => void): () => void
  }
}
`)
    writeFileSync(join(temp, 'consumer.mts'), `
import type { Readable } from 'svelte/store'
import { craft, isReady } from './declarations/stores/craft.js'
import { platform, createPlatformStore } from './declarations/stores/platform.js'
const ready: Readable<boolean> = isReady
const info: Readable<{ platform: string; version: string } | null> = platform
const another: typeof info = createPlatformStore()
const unsubscribe: () => void = craft.subscribe(api => {
  if (api) {
    const result: Promise<{ platform: string; version: string }> = api.getPlatform()
    void result
  }
})
// @ts-expect-error the Craft store is read-only to consumers
craft.set(null)
// @ts-expect-error readiness remains boolean
const wrong: Readable<string> = isReady
void [ready, info, another, unsubscribe, wrong]
`)
    run([
      tsc, 'consumer.mts', 'store-contract.d.ts', '--noEmit', '--strict',
      '--module', 'nodenext', '--moduleResolution', 'nodenext',
      '--target', 'esnext', '--ignoreConfig', '--types', 'bun-types',
    ])
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
}, 60_000)
