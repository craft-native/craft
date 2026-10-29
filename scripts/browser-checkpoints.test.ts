import { afterAll, beforeAll, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { chromium, firefox, webkit, type BrowserContext, type Page } from 'playwright'
import type { BrowserPlatform } from '../packages/typescript/src/browser'

// These globals belong only to the disposable test page, not the SDK.
declare global {
  interface Window {
    platform: BrowserPlatform
    releaseCheckpointLock: () => void
    checkpointLockHeld: boolean
    checkpointAbort: AbortController
    checkpointResult?: { value?: unknown, error?: string }
  }
}

const engine = process.env.CRAFT_TEST_BROWSER ?? 'chromium'
if (engine !== 'chromium' && engine !== 'firefox' && engine !== 'webkit') throw new Error(`Unsupported checkpoint browser: ${engine}`)
const browserType = { chromium, firefox, webkit }[engine]
const artifacts = process.env.CRAFT_BROWSER_ARTIFACTS
  ? resolve(process.env.CRAFT_BROWSER_ARTIFACTS)
  : mkdtempSync(join(tmpdir(), 'craft-browser-checkpoints-'))
mkdirSync(artifacts, { recursive: true })
let server: ReturnType<typeof Bun.serve>
let bundleHash: string
const receipts: Record<string, unknown>[] = []

beforeAll(async () => {
  const build = await Bun.build({ entrypoints: [resolve(import.meta.dir, '../packages/typescript/src/browser.ts')], target: 'browser', format: 'esm' })
  if (!build.success) throw new AggregateError(build.logs, 'Cannot bundle maintained browser platform')
  const bundle = await build.outputs[0]!.text()
  bundleHash = new Bun.CryptoHasher('sha256').update(bundle).digest('hex')
  server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === '/platform.js') return new Response(bundle, { headers: { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' } })
      return new Response('<!doctype html><title>Craft checkpoint acceptance</title><main>Disposable checkpoint test</main>', { headers: { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' } })
    },
  })
}, 30_000)

afterAll(async () => {
  server?.stop(true)
  await Bun.write(join(artifacts, 'results.json'), JSON.stringify({ engine, bundleHash, receipts }, null, 2))
  console.log(`Browser checkpoint receipts: ${artifacts}`)
})

async function initialize(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const entry = '/platform.js'
    const { createBrowserPlatform } = await import(entry)
    window.platform = await createBrowserPlatform({ namespace: 'checkpoint-test' })
    if (!window.platform.capabilities.includes('storageCompareAndSet')) throw new Error('Real Web Locks are required; no fallback acceptance')
  })
}

async function open(context: BrowserContext): Promise<Page> {
  const page = await context.newPage()
  await page.goto(server.url.href)
  await initialize(page)
  return page
}

async function reload(page: Page): Promise<void> {
  await page.reload()
  await initialize(page)
}

async function call(page: Page, method: string, args: unknown[]): Promise<unknown> {
  return page.evaluate(({ method, args }) => window.platform.call('Storage', method, args, new AbortController().signal), { method, args })
}

async function hold(page: Page): Promise<void> {
  await page.evaluate(() => {
    window.checkpointLockHeld = false
    void navigator.locks.request('checkpoint-test:storage', () => new Promise<void>((resolve) => {
      window.releaseCheckpointLock = resolve
      window.checkpointLockHeld = true
    }))
  })
  await page.waitForFunction(() => window.checkpointLockHeld)
}

async function queued(page: Page, count: number): Promise<void> {
  await page.waitForFunction(async count => (await navigator.locks.query()).pending?.filter(lock => lock.name === 'checkpoint-test:storage').length === count, count)
}

function scenario(name: string, run: (context: BrowserContext, restart: () => Promise<BrowserContext>) => Promise<void>): void {
  test(name, async () => {
    const profile = mkdtempSync(join(tmpdir(), 'craft-checkpoint-profile-'))
    let context: BrowserContext | undefined
    let part = 0
    const errors: string[] = []
    const versions: string[] = []
    const close = async (): Promise<void> => {
      if (!context) return
      try { await context.tracing.stop({ path: join(artifacts, `${name}-${part++}.zip`) }) }
      finally { await context.close(); context = undefined }
    }
    const launch = async (): Promise<BrowserContext> => {
      await close()
      context = await browserType.launchPersistentContext(profile, { headless: true })
      context.setDefaultTimeout(10_000)
      versions.push(context.browser()!.version())
      context.on('page', page => page.on('pageerror', error => errors.push(error.message)))
      await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
      return context
    }
    try {
      await run(await launch(), launch)
      expect(errors).toEqual([])
      receipts.push({ name, passed: true, versions })
    }
    catch (error) {
      receipts.push({ name, passed: false, versions, error: String(error), pageErrors: errors })
      throw error
    }
    finally {
      try { await close() }
      finally { rmSync(profile, { recursive: true, force: true }) }
    }
  }, 60_000)
}

scenario('acknowledged-save-survives-reload-and-browser-restart', async (context, restart) => {
  const page = await open(context)
  const checkpoint = { generation: 1, payload: 'settler:'.repeat(32_768), units: [{ id: 1, x: 42 }] }
  expect(await call(page, 'set', ['campaign', checkpoint])).toBe(true)
  await reload(page)
  expect(await call(page, 'get', ['campaign'])).toEqual(checkpoint)
  const restored = await open(await restart())
  expect(await call(restored, 'get', ['campaign'])).toEqual(checkpoint)
  expect(await call(restored, 'remove', ['campaign'])).toBe(true)
  await reload(restored)
  expect(await call(restored, 'get', ['campaign'])).toBeNull()
})

scenario('competing-tabs-have-one-create-and-one-cas-winner', async (context) => {
  const [owner, a, b] = await Promise.all([open(context), open(context), open(context)])
  await hold(owner)
  const creates = [call(a, 'setIfAbsent', ['campaign', { generation: 1 }]), call(b, 'setIfAbsent', ['campaign', { generation: 1 }])]
  await queued(owner, 2)
  await owner.evaluate(() => window.releaseCheckpointLock())
  expect((await Promise.all(creates)).sort()).toEqual([false, true])
  await hold(owner)
  const replacements = ['A', 'B'].map((writer, index) => call(index ? b : a, 'compareAndSet', ['campaign', { generation: 1 }, { generation: 2, writer }]))
  await queued(owner, 2)
  await owner.evaluate(() => window.releaseCheckpointLock())
  const results = await Promise.all(replacements)
  expect(results.filter(Boolean)).toHaveLength(1)
  const expected = { generation: 2, writer: results[0] ? 'A' : 'B' }
  await Promise.all([reload(a), reload(b)])
  expect(await call(a, 'get', ['campaign'])).toEqual(expected)
  expect(await call(b, 'get', ['campaign'])).toEqual(expected)
})

scenario('competing-cas-retries-preserve-all-increments', async (context) => {
  const [a, b] = await Promise.all([open(context), open(context)])
  await call(a, 'set', ['counter', 0])
  const increment = (page: Page) => page.evaluate(async () => {
    const signal = new AbortController().signal
    for (let completed = 0, attempts = 0; completed < 20; attempts++) {
      if (attempts > 200) throw new Error('CAS retry budget exhausted')
      const previous = await window.platform.call('Storage', 'get', ['counter'], signal) as number
      if (await window.platform.call('Storage', 'compareAndSet', ['counter', previous, previous + 1], signal)) completed++
    }
  })
  await Promise.all([increment(a), increment(b)])
  await reload(a)
  expect(await call(a, 'get', ['counter'])).toBe(40)
})

scenario('queued-save-captures-data-before-caller-mutation', async (context) => {
  const [owner, writer] = await Promise.all([open(context), open(context)])
  await hold(owner)
  await writer.evaluate(() => {
    const value = { generation: 1, units: [2, 3] }
    const args: unknown[] = ['campaign', value]
    void window.platform.call('Storage', 'set', args, new AbortController().signal).then(value => { window.checkpointResult = { value } })
    value.generation = 2
    value.units.push(99)
    args[0] = 'wrong-key'
  })
  await queued(owner, 1)
  await owner.evaluate(() => window.releaseCheckpointLock())
  await writer.waitForFunction(() => window.checkpointResult?.value === true)
  await reload(writer)
  expect(await call(writer, 'get', ['campaign'])).toEqual({ generation: 1, units: [2, 3] })
  expect(await call(writer, 'get', ['wrong-key'])).toBeNull()
})

for (const interruption of ['reload', 'abort', 'dispose'] as const) {
  scenario(`queued-save-${interruption}-preserves-previous-checkpoint`, async (context) => {
    const [owner, writer] = await Promise.all([open(context), open(context)])
    await call(owner, 'set', ['campaign', { generation: 1 }])
    await hold(owner)
    await writer.evaluate(() => {
      window.checkpointAbort = new AbortController()
      void window.platform.call('Storage', 'set', ['campaign', { generation: 2 }], window.checkpointAbort.signal)
        .then(value => { window.checkpointResult = { value } }, error => { window.checkpointResult = { error: error.name } })
    })
    await queued(owner, 1)
    if (interruption === 'reload') await reload(writer)
    else {
      await writer.evaluate(mode => mode === 'abort' ? window.checkpointAbort.abort() : window.platform.dispose(), interruption)
      await writer.waitForFunction(() => window.checkpointResult?.error === 'AbortError')
    }
    await queued(owner, 0)
    await owner.evaluate(() => window.releaseCheckpointLock())
    expect(await call(owner, 'get', ['campaign'])).toEqual({ generation: 1 })
    await reload(writer)
    expect(await call(writer, 'get', ['campaign'])).toEqual({ generation: 1 })
    expect(await call(writer, 'compareAndSet', ['campaign', { generation: 1 }, { generation: 3 }])).toBe(true)
    await reload(writer)
    expect(await call(writer, 'get', ['campaign'])).toEqual({ generation: 3 })
  })
}

scenario('real-quota-failure-preserves-checkpoint-and-allows-retry', async (context) => {
  const page = await open(context)
  await call(page, 'set', ['campaign', { generation: 1 }])
  const result = await page.evaluate(async () => {
    try {
      await window.platform.call('Storage', 'set', ['campaign', 'x'.repeat(16 * 1024 * 1024)], new AbortController().signal)
      return 'unexpected-success'
    }
    catch (error) { return (error as DOMException).name }
  })
  expect(result).toBe('QuotaExceededError')
  await reload(page)
  expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 1 })
  expect(await call(page, 'compareAndSet', ['campaign', { generation: 1 }, { generation: 2 }])).toBe(true)
  await reload(page)
  expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 2 })
})

scenario('legacy-migration-and-stale-cache-cannot-resurrect-deleted-checkpoints', async (context, restart) => {
  const page = await context.newPage()
  await page.goto(server.url.href)
  await page.evaluate(() => {
    localStorage.setItem('checkpoint-test:account:guest:storage:campaign', JSON.stringify({ generation: 1 }))
    localStorage.setItem('checkpoint-test:account:guest:snapshot:screen', 'keep screen snapshot')
    localStorage.setItem('checkpoint-test:account:guest:credential:name:storage:secret', 'keep credential')
    localStorage.setItem('other-app', 'keep other app')
  })
  await initialize(page)
  expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 1 })
  expect(await call(page, 'compareAndSet', ['campaign', { generation: 1 }, { generation: 2 }])).toBe(true)
  await page.evaluate(() => localStorage.setItem('checkpoint-test:account:guest:storage:campaign', JSON.stringify({ generation: 1 })))
  await reload(page)
  expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 2 })
  expect(await call(page, 'clear', [])).toBe(true)
  await page.evaluate(() => localStorage.setItem('checkpoint-test:account:guest:storage:campaign', JSON.stringify({ generation: 1 })))
  const restored = await open(await restart())
  expect(await call(restored, 'get', ['campaign'])).toBeNull()
  expect(await call(restored, 'keys', [])).toEqual([])
  expect(await restored.evaluate(() => [localStorage.getItem('checkpoint-test:account:guest:snapshot:screen'), localStorage.getItem('other-app'), localStorage.getItem('checkpoint-test:account:guest:credential:name:storage:secret')]))
    .toEqual(['keep screen snapshot', 'keep other app', 'keep credential'])
})

for (const interruption of ['transaction-abort', 'caller-abort', 'dispose'] as const) {
  scenario(`uncommitted-write-${interruption}-rolls-back-checkpoint-and-cache`, async (context) => {
    const page = await open(context)
    await call(page, 'set', ['campaign', { generation: 1 }])
    const result = await page.evaluate(async (mode) => {
      const original = IDBObjectStore.prototype.put
      const controller = new AbortController()
      IDBObjectStore.prototype.put = function (value, key) {
        const request = original.call(this, value, key!)
        // Abort a real transaction after put succeeds but before commit. A
        // request's success must never be mistaken for checkpoint completion.
        if (this.name === 'checkpoints') request.addEventListener('success', () => {
          if (mode === 'transaction-abort') this.transaction.abort()
          else if (mode === 'caller-abort') controller.abort()
          else window.platform.dispose()
        }, { once: true })
        return request
      }
      try {
        await window.platform.call('Storage', 'set', ['campaign', { generation: 2 }], controller.signal)
        return { error: 'unexpected-success', mirror: localStorage.getItem('checkpoint-test:account:guest:storage:campaign') }
      }
      catch (error) { return { error: (error as Error).name, mirror: localStorage.getItem('checkpoint-test:account:guest:storage:campaign') } }
      finally { IDBObjectStore.prototype.put = original }
    }, interruption)
    expect(result).toEqual({ error: 'AbortError', mirror: JSON.stringify({ generation: 1 }) })
    await reload(page)
    expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 1 })
    expect(await call(page, 'compareAndSet', ['campaign', { generation: 1 }, { generation: 3 }])).toBe(true)
  })
}

scenario('account-transition-removes-committed-checkpoints-and-sync-writes-share-transactions', async (context) => {
  const page = await open(context)
  await call(page, 'set', ['campaign', { generation: 1 }])
  await page.evaluate(() => {
    const storage = window.platform.craft.storage as { setSync(key: string, value: unknown): void }
    storage.setSync('campaign', { generation: 2 })
  })
  expect(await call(page, 'get', ['campaign'])).toEqual({ generation: 2 })
  await page.evaluate(() => window.platform.call('SecureStorage', 'set', ['auth.token', 'account-a'], new AbortController().signal))
  expect(await call(page, 'get', ['campaign'])).toBeNull()
  await call(page, 'set', ['campaign', { owner: 'a' }])
  await page.evaluate(() => window.platform.call('SecureStorage', 'remove', ['auth.token'], new AbortController().signal))
  expect(await call(page, 'get', ['campaign'])).toBeNull()
  await page.evaluate(() => window.platform.call('SecureStorage', 'set', ['auth.token', 'account-a'], new AbortController().signal))
  await reload(page)
  expect(await call(page, 'get', ['campaign'])).toBeNull()
})

scenario('missing-transactional-storage-does-not-advertise-atomic-writes', async (context) => {
  const page = await context.newPage()
  await page.goto(server.url.href)
  const result = await page.evaluate(async () => {
    Object.defineProperty(window, 'indexedDB', { configurable: true, value: undefined })
    const entry = '/platform.js'
    const { createBrowserPlatform } = await import(entry)
    window.platform = await createBrowserPlatform({ namespace: 'checkpoint-test' })
    const errors: string[] = []
    for (const method of ['setIfAbsent', 'compareAndSet']) {
      try { await window.platform.call('Storage', method, ['campaign', null, 1], new AbortController().signal) }
      catch (error) { errors.push((error as { code: string }).code) }
    }
    return { capabilities: window.platform.capabilities, errors }
  })
  expect(result.capabilities).not.toContain('storageCompareAndSet')
  expect(result.capabilities).not.toContain('storageSetIfAbsent')
  expect(result.errors).toEqual(['STORAGE_SET_IF_ABSENT_UNSUPPORTED', 'STORAGE_COMPARE_AND_SET_UNSUPPORTED'])
  expect(await call(page, 'get', ['campaign'])).toBeNull()
})
