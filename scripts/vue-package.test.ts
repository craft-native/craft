import { expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'

test('packed Vue composables render on the server and expose usable types', () => {
  const root = resolve(import.meta.dir, '..')
  const packageDir = join(root, 'packages/vue')
  const temp = mkdtempSync(join(tmpdir(), 'craft-vue-package-'))
  const run = (args: string[], cwd = temp): void => {
    const result = Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
    expect(`${result.stdout}\n${result.stderr}`).not.toContain('error TS')
    expect(result.exitCode).toBe(0)
  }
  try {
    run([process.execPath, 'run', 'build'], packageDir)
    run([process.execPath, 'pm', 'pack', '--filename', join(temp, 'package.tgz')], packageDir)
    const installed = join(temp, 'node_modules/@craft-native/vue')
    mkdirSync(installed, { recursive: true })
    run(['tar', '-xzf', join(temp, 'package.tgz'), '--strip-components=1', '-C', installed])
    // Supply the actual installed peer, not a mock or a workspace Craft import.
    const require = createRequire(join(packageDir, 'package.json'))
    symlinkSync(dirname(require.resolve('vue/package.json')), join(temp, 'node_modules/vue'), 'junction')
    writeFileSync(join(temp, 'consumer.mjs'), `
import { strict as assert } from 'node:assert'
import { createSSRApp, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import { useCraft, usePlatform } from '@craft-native/vue'
assert.equal(typeof window, 'undefined')
globalThis.setInterval = () => { throw new Error('SSR must not start bridge polling') }
async function render(override) {
  return renderToString(createSSRApp({
    setup() {
      const { craft, isReady } = useCraft()
      const { platform, loading, error } = usePlatform()
      assert.equal(craft.value, null)
      assert.equal(isReady.value, false)
      assert.equal(platform.value, null)
      assert.equal(loading.value, true)
      assert.equal(error.value, null)
      if (override) isReady.value = true
      return () => h('p', { 'data-ready': String(isReady.value) }, '<script>untrusted</script>')
    }
  }))
}
const first = await render(true)
const second = await render(false)
assert.ok(first.includes('data-ready="true"'))
assert.ok(second.includes('data-ready="false"'))
assert.ok(second.includes('&lt;script&gt;untrusted&lt;/script&gt;'))
assert.ok(!second.includes('<script>'))
`)
    run([process.execPath, 'consumer.mjs'])
    writeFileSync(join(temp, 'consumer.mts'), `
import type { Ref } from 'vue'
import { useCraft, usePlatform } from '@craft-native/vue'
const ready: Ref<boolean> = useCraft().isReady
const platform: Ref<{ platform: string; version: string } | null> = usePlatform().platform
// @ts-expect-error readiness is boolean, not text
const wrong: Ref<string> = useCraft().isReady
void [ready, platform, wrong]
`)
    run([
      process.execPath, join(root, 'packages/typescript/scripts/tsc.ts'),
      'consumer.mts', '--noEmit', '--strict', '--module', 'nodenext',
      '--moduleResolution', 'nodenext', '--target', 'esnext', '--ignoreConfig',
    ])
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
}, 60_000)
