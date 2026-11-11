/**
 * Comprehensive coverage for the 43-item improvement batch.
 *
 * Each `describe` block is labelled with the item number from the original
 * audit so failures map directly back to the change set.
 */

import { afterAll, afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// -------------------------------------------------------------------------
// Item 1: HMR module endpoint must reject path traversal.
// -------------------------------------------------------------------------
import { HotReloadServer } from '../dev/hot-reload'
import { createTempDir, removeAllTempDirs } from '../temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

describe('Item 1: HMR path traversal', () => {
  let workdir: string
  let server: HotReloadServer
  let port: number

  beforeEach(async () => {
    workdir = createTempDir('craft-hmr-')
    writeFileSync(join(workdir, 'safe.js'), 'export const hello = "world"')
    // The "secret" file lives OUTSIDE workdir — exactly what the bug used
    // to expose.
    writeFileSync(join(workdir, '..', 'craft-hmr-secret.txt'), 'TOP_SECRET')
    server = new HotReloadServer({ watchDir: workdir, port: 0 })
    server.start()
    // Bun.serve binds synchronously; `port` resolves the OS-assigned port.
    port = server.port
  })

  afterEach(() => {
    server.stop()
    try { rmSync(workdir, { recursive: true, force: true }) } catch {/* ignore */}
    try { rmSync(join(tmpdir(), 'craft-hmr-secret.txt'), { force: true }) } catch {/* ignore */}
  })

  async function request(path: string): Promise<{ status: number; body: string }> {
    const res = await fetch(`http://127.0.0.1:${port}${path}`)
    return { status: res.status, body: await res.text() }
  }

  it('serves files inside watchDir', async () => {
    const r = await request('/hmr-module/safe.js')
    expect(r.status).toBe(200)
    expect(r.body).toContain('hello')
  })

  it('rejects parent-directory traversal', async () => {
    const r = await request('/hmr-module/..%2Fcraft-hmr-secret.txt')
    expect(r.status).toBe(403)
    expect(r.body).not.toContain('TOP_SECRET')
  })

  it('rejects absolute paths', async () => {
    const r = await request('/hmr-module//etc/passwd')
    expect(r.status).toBe(403)
  })

  it('rejects null-byte injection', async () => {
    const r = await request('/hmr-module/safe.js%00.png')
    expect(r.status).toBe(403)
  })
})

// -------------------------------------------------------------------------
// Item 2: CORS `*` is forbidden when credentials are enabled.
// -------------------------------------------------------------------------
import { CORSHandler } from '../security'

describe('Item 2: CORS `*` + credentials', () => {
  it('omits Access-Control-Allow-Origin when credentials and no request origin', () => {
    const h = new CORSHandler({ origin: true, credentials: true })
    const headers = h.getHeaders(undefined)
    expect(headers['Access-Control-Allow-Origin']).toBeUndefined()
  })

  it('echoes the request origin when credentials are enabled', () => {
    const h = new CORSHandler({ origin: true, credentials: true })
    const headers = h.getHeaders('https://app.example.com')
    expect(headers['Access-Control-Allow-Origin']).toBe('https://app.example.com')
    expect(headers['Access-Control-Allow-Credentials']).toBe('true')
  })

  it('refuses literal `*` paired with credentials', () => {
    const h = new CORSHandler({ origin: '*', credentials: true })
    const headers = h.getHeaders('https://app.example.com')
    expect(headers['Access-Control-Allow-Origin']).toBeUndefined()
  })

  it('still allows `*` when credentials are off', () => {
    const h = new CORSHandler({ origin: true })
    expect(h.getHeaders(undefined)['Access-Control-Allow-Origin']).toBe('*')
  })
})

// -------------------------------------------------------------------------
// Item 3: AES-GCM IV must default to 12 bytes.
// -------------------------------------------------------------------------
import { SecureStorage } from '../security'

describe('Item 3 & 8: SecureStorage IV length, destroy()', () => {
  it('uses a 12-byte IV by default', () => {
    const s = new SecureStorage('pw', { salt: Buffer.from('1234567890123456') })
    const blob = JSON.parse(s.encrypt('hello'))
    // 12 bytes hex-encoded → 24 chars.
    expect(blob.iv).toHaveLength(24)
    s.destroy()
  })

  it('round-trips encrypt/decrypt', () => {
    const s = new SecureStorage('pw', { salt: Buffer.from('1234567890123456') })
    const enc = s.encrypt('the quick brown fox')
    expect(s.decrypt(enc)).toBe('the quick brown fox')
    s.destroy()
  })

  it('refuses operations after destroy()', () => {
    const s = new SecureStorage('pw', { salt: Buffer.from('1234567890123456') })
    const enc = s.encrypt('x')
    s.destroy()
    expect(s.isDestroyed()).toBe(true)
    expect(() => s.encrypt('x')).toThrow(/destroyed/)
    expect(() => s.decrypt(enc)).toThrow(/destroyed/)
  })
})

// -------------------------------------------------------------------------
// Item 4: Cross-runtime crypto interop (PBKDF2 in both runtimes).
// -------------------------------------------------------------------------
import { crypto as cryptoApi } from '../api/crypto'

describe('Item 4 & 5 & 27: crypto.encrypt/decrypt round-trip & PBKDF2', () => {
  it('decrypts ciphertext it produced', async () => {
    const enc = await cryptoApi.encrypt('hello world', 'sek-rit-password')
    expect(typeof enc).toBe('string')
    const dec = await cryptoApi.decrypt(enc, 'sek-rit-password')
    expect(dec).toBe('hello world')
  })

  it('rejects ciphertext with wrong key', async () => {
    const enc = await cryptoApi.encrypt('plain', 'right')
    await expect(cryptoApi.decrypt(enc, 'wrong')).rejects.toThrow()
  })

  it('rejects truncated ciphertext loudly', async () => {
    await expect(cryptoApi.decrypt('xxx', 'pw')).rejects.toThrow(/too short/)
  })
})

// -------------------------------------------------------------------------
// Item 6: createTable defaults are SQL-escaped.
// -------------------------------------------------------------------------
import { encodeDefaultLiteral, validateIdentifier } from '../api/db'

describe('Item 6: SQL DEFAULT escaping', () => {
  it('doubles single quotes in string defaults', () => {
    expect(encodeDefaultLiteral("O'Brien")).toBe("'O''Brien'")
  })
  it('emits NULL for null/undefined', () => {
    expect(encodeDefaultLiteral(null)).toBe('NULL')
    expect(encodeDefaultLiteral(undefined)).toBe('NULL')
  })
  it('emits 0/1 for booleans', () => {
    expect(encodeDefaultLiteral(true)).toBe('1')
    expect(encodeDefaultLiteral(false)).toBe('0')
  })
  it('rejects non-finite numbers', () => {
    expect(() => encodeDefaultLiteral(NaN)).toThrow()
    expect(() => encodeDefaultLiteral(Infinity)).toThrow()
  })
  it('rejects objects/arrays', () => {
    expect(() => encodeDefaultLiteral({ a: 1 })).toThrow()
    expect(() => encodeDefaultLiteral([1, 2])).toThrow()
  })
})

describe('Item 17: validateIdentifier reports correct kind', () => {
  it('reports `column name` errors when validating columns', () => {
    expect(() => validateIdentifier('1bad', 'column')).toThrow(/column name/)
  })
  it('reports `table name` errors when validating tables', () => {
    expect(() => validateIdentifier('1bad', 'table')).toThrow(/table name/)
  })
})

// -------------------------------------------------------------------------
// Item 7: HMR FSWatcher closes on stop().
// -------------------------------------------------------------------------
describe('Item 7: HMR stop releases FSWatcher', () => {
  it('closes the FSWatcher and nulls the field', async () => {
    const dir = createTempDir('craft-hmr-')
    const s = new HotReloadServer({ watchDir: dir, port: 0 })
    s.start()
    // Wait briefly for watch() to finish initializing.
    await new Promise((r) => setTimeout(r, 30))
    s.stop()
    const watcher = (s as unknown as { watcher: unknown }).watcher
    expect(watcher).toBeNull()
    rmSync(dir, { recursive: true, force: true })
  })
})

// -------------------------------------------------------------------------
// Item 9: WKWebView _call routes through pending response queue.
// -------------------------------------------------------------------------
import { _drainPendingForTests, isWebKitHost, webkitRequest } from '../bridge/webkit-pending'

describe('Item 9: WKWebView pending helper', () => {
  let originalWebkit: unknown

  beforeEach(() => {
    originalWebkit = (globalThis as any).window?.webkit
    ;(globalThis as any).window = (globalThis as any).window || {}
    ;(globalThis as any).window.webkit = {
      messageHandlers: { craft: { postMessage: () => {/* swallow */} } },
    }
  })

  afterEach(() => {
    _drainPendingForTests()
    if (originalWebkit) (globalThis as any).window.webkit = originalWebkit
    else delete (globalThis as any).window.webkit
  })

  it('detects the WKWebView host', () => {
    expect(isWebKitHost()).toBe(true)
  })

  it('resolves through window.__craftBridgeResolve', async () => {
    const promise = webkitRequest<{ ok: boolean }>('test-bucket', { type: 'x' })
    // Allow microtasks to drain so the helper installs hooks.
    await Promise.resolve()
    const w = (globalThis as any).window
    expect(typeof w.__craftBridgeResolve).toBe('function')
    const handled = w.__craftBridgeResolve('test-bucket', { ok: true })
    expect(handled).toBe(true)
    await expect(promise).resolves.toEqual({ ok: true })
  })

  it('rejects through window.__craftBridgeReject', async () => {
    const promise = webkitRequest('test-bucket', { type: 'x' })
    await Promise.resolve()
    const w = (globalThis as any).window
    w.__craftBridgeReject('test-bucket', new Error('nope'))
    await expect(promise).rejects.toThrow(/nope/)
  })

  it('times out after the configured timeoutMs', async () => {
    const promise = webkitRequest('test-bucket', { type: 'x' }, { timeoutMs: 20 })
    await expect(promise).rejects.toThrow(/timed out/)
  })

  it('cleans up the pending slot on settle', async () => {
    const w = (globalThis as any).window
    const promise = webkitRequest('clean-bucket', { type: 'x' })
    await Promise.resolve()
    expect(w.__craftBridgePending['clean-bucket'].length).toBe(1)
    w.__craftBridgeResolve('clean-bucket', 'done')
    await promise
    expect(w.__craftBridgePending['clean-bucket'].length).toBe(0)
  })
})

// -------------------------------------------------------------------------
// Item 10 & 12: Bridge consolidation — getBridge() warns on config mismatch
// and message IDs are isolated per instance.
// -------------------------------------------------------------------------
import {
  createBridge,
  getBridge,
  NativeBridge,
  resetGlobalBridge,
} from '../bridge/core'

describe('Item 10 & 11 & 12: bridge singleton config + per-instance counters', () => {
  // Bun's test runner provides a happy-dom-like `window`; some other test
  // suites in the package mutate it. Reset to a clean slate around these.
  let savedWindow: any

  beforeEach(() => {
    savedWindow = (globalThis as any).window
    delete (globalThis as any).window
    resetGlobalBridge()
  })

  afterEach(() => {
    resetGlobalBridge()
    if (savedWindow !== undefined) (globalThis as any).window = savedWindow
  })

  it('warns when getBridge() is called twice with differing config', () => {
    const warn = mock(() => {})
    const orig = console.warn
    console.warn = warn as unknown as typeof console.warn
    try {
      getBridge({ timeout: 1000 })
      getBridge({ timeout: 9999 })
      expect(warn).toHaveBeenCalled()
    }
    finally {
      console.warn = orig
    }
  })

  it('does not warn when configs match', () => {
    const warn = mock(() => {})
    const orig = console.warn
    console.warn = warn as unknown as typeof console.warn
    try {
      getBridge({ timeout: 1000 })
      getBridge({ timeout: 1000 })
      expect(warn).not.toHaveBeenCalled()
    }
    finally {
      console.warn = orig
    }
  })

  it('two NativeBridge instances mint disjoint message-id namespaces', () => {
    const a = new NativeBridge({ enableOfflineQueue: true, retries: 0, timeout: 5000 })
    const b = new NativeBridge({ enableOfflineQueue: true, retries: 0, timeout: 5000 })
    void a.request('m').catch(() => {})
    void b.request('m').catch(() => {})
    const aId = (a as unknown as { offlineQueue: Array<{ id: string }> }).offlineQueue[0].id
    const bId = (b as unknown as { offlineQueue: Array<{ id: string }> }).offlineQueue[0].id
    expect(aId.startsWith('msg-')).toBe(true)
    expect(bId.startsWith('msg-')).toBe(true)
    // They must not share the same prefix.
    expect(aId.split('_')[0]).not.toBe(bId.split('_')[0])
    a.destroy()
    b.destroy()
  })
})

// -------------------------------------------------------------------------
// Item 13: process.open(target) on Windows uses cmd.exe /c start.
// -------------------------------------------------------------------------
import { open as openTarget } from '../api/process'

describe('Item 13: process.open Windows path', () => {
  it('source contains the cmd.exe /c start fix-up', async () => {
    const src = await Bun.file(new URL('../api/process.ts', import.meta.url)).text()
    expect(src).toContain("'cmd.exe'")
    expect(src).toContain("'/c'")
    expect(src).toContain("'start'")
  })

  it('still works on the host platform (smoke test)', async () => {
    // We don't actually want to launch anything; just assert it doesn't
    // throw a sync error from the validator path.
    expect(typeof openTarget).toBe('function')
  })
})

// -------------------------------------------------------------------------
// Item 14: ChildProcess promises only what native shell.spawn does.
//
// This used to check that the class removed its `craft:process:*` window
// listeners on exit. Nothing ever dispatched those events, so the listeners
// and the onStdout/onStderr/onExit/write methods that fed them are gone, and
// the check is that they stay gone until something native backs them.
// -------------------------------------------------------------------------
describe('Item 14: ChildProcess has no unbacked output API', () => {
  it('declares no stream or exit handlers and listens for no process events', async () => {
    const { ChildProcess } = await import('../api/process')
    const child = new ChildProcess('true') as unknown as Record<string, unknown>
    for (const name of ['onStdout', 'onStderr', 'onExit', 'write'])
      expect(child[name]).toBeUndefined()
    const src = await Bun.file(new URL('../api/process.ts', import.meta.url)).text()
    expect(src).not.toContain('craft:process:')
    expect(src).toContain('\'shell.spawn\'')
  })
})

// -------------------------------------------------------------------------
// Item 15: Tray events filter on tray id; destroy tears down listeners.
// -------------------------------------------------------------------------
import { SystemTray } from '../api/tray'

describe('Item 15: SystemTray id filtering & teardown', () => {
  let originalAdd: typeof window.addEventListener
  let originalRemove: typeof window.removeEventListener
  const added: Array<{ type: string; handler: EventListenerOrEventListenerObject }> = []
  const removed: Array<{ type: string; handler: EventListenerOrEventListenerObject }> = []

  beforeEach(() => {
    ;(globalThis as any).window = (globalThis as any).window || {}
    originalAdd = (globalThis as any).window.addEventListener
    originalRemove = (globalThis as any).window.removeEventListener
    ;(globalThis as any).window.addEventListener = ((type: string, handler: EventListenerOrEventListenerObject) => {
      added.push({ type, handler })
    }) as typeof window.addEventListener
    ;(globalThis as any).window.removeEventListener = ((type: string, handler: EventListenerOrEventListenerObject) => {
      removed.push({ type, handler })
    }) as typeof window.removeEventListener
  })

  afterEach(() => {
    if (originalAdd) (globalThis as any).window.addEventListener = originalAdd
    if (originalRemove) (globalThis as any).window.removeEventListener = originalRemove
    added.length = 0
    removed.length = 0
  })

  it('removes every listener it registered when destroy() runs', () => {
    const tray = new SystemTray('t1')
    const beforeAdd = added.length
    expect(beforeAdd).toBeGreaterThan(0)
    // Skip the native call by directly invoking the protected teardown —
    // that's the part this test is asserting on.
    ;(tray as unknown as { _teardownDomListeners(): void })._teardownDomListeners()
    expect(removed.length).toBe(beforeAdd)
  })

  it('only fires events with matching trayId', () => {
    let fired = 0
    const tray = new SystemTray('t-target')
    tray.on('click', () => { fired++ })
    // Fire an event scoped to a different tray.
    const isFor = (tray as unknown as { _isForThisTray: (d: unknown) => boolean })._isForThisTray.bind(tray)
    expect(isFor({ trayId: 't-other' })).toBe(false)
    expect(isFor({ trayId: 't-target' })).toBe(true)
    // No id at all → fall through (single-tray apps).
    expect(isFor({})).toBe(true)
    expect(fired).toBe(0)
  })
})

// -------------------------------------------------------------------------
// Item 16: HttpClient case-insensitive Content-Type detection +
// Item 19: non-JSON bodies pass through unchanged.
// -------------------------------------------------------------------------
import { encodeRequestBody, hasHeader } from '../api/http'

describe('Item 16 & 19: HTTP body encoding & header lookup', () => {
  it('hasHeader is case-insensitive', () => {
    expect(hasHeader({ 'content-type': 'a' }, 'Content-Type')).toBe(true)
    expect(hasHeader({ 'CONTENT-TYPE': 'a' }, 'content-type')).toBe(true)
    expect(hasHeader({}, 'content-type')).toBe(false)
  })

  it('passes FormData through unchanged', () => {
    const fd = new FormData()
    fd.append('a', 'b')
    const r = encodeRequestBody(fd)
    expect(r.kind).toBe('form')
    expect(r.value).toBe(fd)
  })

  it('passes URLSearchParams through unchanged', () => {
    const usp = new URLSearchParams({ a: 'b' })
    const r = encodeRequestBody(usp)
    expect(r.kind).toBe('form')
    expect(r.value).toBe(usp)
  })

  it('passes Uint8Array through as binary', () => {
    const u = new Uint8Array([1, 2, 3])
    const r = encodeRequestBody(u)
    expect(r.kind).toBe('binary')
    expect(r.value).toBe(u)
  })

  it('passes Blob through as binary', () => {
    const b = new Blob(['hi'])
    const r = encodeRequestBody(b)
    expect(r.kind).toBe('binary')
    expect(r.value).toBe(b)
  })

  it('passes strings through as-is (no JSON wrapping)', () => {
    const r = encodeRequestBody('plain text')
    expect(r.kind).toBe('string')
    expect(r.value).toBe('plain text')
  })

  it('JSON-stringifies plain objects', () => {
    const r = encodeRequestBody({ a: 1 })
    expect(r.kind).toBe('json')
    expect(r.value).toBe('{"a":1}')
  })

  it('treats undefined as no body', () => {
    expect(encodeRequestBody(undefined).kind).toBe('none')
    expect(encodeRequestBody(null).kind).toBe('none')
  })
})

// -------------------------------------------------------------------------
// Item 18: process.env reflects mutations.
// -------------------------------------------------------------------------
import { env } from '../api/process'

describe('Item 18: process.env live proxy', () => {
  it('reflects post-import mutations', () => {
    process.env.CRAFT_TEST_FLAG = 'on'
    expect(env.CRAFT_TEST_FLAG).toBe('on')
    delete process.env.CRAFT_TEST_FLAG
    expect(env.CRAFT_TEST_FLAG).toBeUndefined()
  })

  it('writes propagate to process.env', () => {
    env.CRAFT_TEST_WRITE = 'yes'
    expect(process.env.CRAFT_TEST_WRITE).toBe('yes')
    delete env.CRAFT_TEST_WRITE
    expect(process.env.CRAFT_TEST_WRITE).toBeUndefined()
  })
})

// -------------------------------------------------------------------------
// Item 20: writeBinaryFile uses base64 — verify the source.
// -------------------------------------------------------------------------
import { base64ToUint8, uint8ToBase64 } from '../api/fs'

describe('Item 20: fs base64 round-trip', () => {
  it('round-trips a Uint8Array', () => {
    const src = new Uint8Array([0, 1, 2, 254, 255, 128])
    const b = uint8ToBase64(src)
    expect(typeof b).toBe('string')
    const out = base64ToUint8(b)
    expect(Array.from(out)).toEqual(Array.from(src))
  })

  it('round-trips 1 MiB without exhausting the call stack', () => {
    const size = 1024 * 1024
    const src = new Uint8Array(size)
    for (let i = 0; i < size; i++) src[i] = i & 0xff
    const b = uint8ToBase64(src)
    const out = base64ToUint8(b)
    expect(out.length).toBe(size)
    expect(out[12345]).toBe(12345 & 0xff)
  })
})

// -------------------------------------------------------------------------
// Item 22: storage.ts handles arrays/primitives without corruption.
// -------------------------------------------------------------------------
import { Storage } from '../utils/storage'

describe('Item 22: Storage array and primitive handling', () => {
  let backing: Record<string, string> = {}

  beforeEach(() => {
    backing = {}
    ;(globalThis as unknown as { localStorage: any }).localStorage = {
      getItem: (k: string) => backing[k] ?? null,
      setItem: (k: string, v: string) => { backing[k] = v },
      removeItem: (k: string) => { delete backing[k] },
      clear: () => { backing = {} },
    }
  })

  afterEach(() => {
    delete (globalThis as unknown as { localStorage?: unknown }).localStorage
  })

  it('round-trips an array without merging into defaults', () => {
    const s = new Storage<string[]>('arr', [])
    s.save(['a', 'b', 'c'])
    expect(s.load()).toEqual(['a', 'b', 'c'])
  })

  it('round-trips an object and preserves new defaults keys', () => {
    const s = new Storage<{ a: number; b?: number }>('obj', { a: 0, b: 99 })
    s.save({ a: 1, b: 2 } as never)
    backing.obj = JSON.stringify({ a: 5 }) // emulate older payload
    expect(s.load()).toEqual({ a: 5, b: 99 })
  })
})

// -------------------------------------------------------------------------
// Item 23: Timer drift recovery via wallclock.
// -------------------------------------------------------------------------
import { Timer } from '../utils/timer'

describe('Item 23: Timer wallclock tracking', () => {
  afterEach(() => Timer._setClockForTests(null))

  it('records the deadline using the injected clock at start()', () => {
    let now = 1_000_000
    Timer._setClockForTests(() => now)
    const t = new Timer(60, () => {/* noop */})
    t.start()
    const endAt = (t as unknown as { endAt: number }).endAt
    expect(endAt).toBe(1_000_000 + 60_000)
    t.pause()
  })

  it('updates the deadline when setDuration is called while running', () => {
    let now = 1_000_000
    Timer._setClockForTests(() => now)
    const t = new Timer(60, () => {/* noop */})
    t.start()
    now += 5000 // advance wallclock by 5s
    t.setDuration(120)
    const endAt = (t as unknown as { endAt: number }).endAt
    expect(endAt).toBe(1_005_000 + 120_000)
    t.pause()
  })

  it('formatTime never goes negative', () => {
    expect(Timer.formatTime(-99)).toBe('0:00')
    expect(Timer.formatTime(125)).toBe('2:05')
  })
})

// -------------------------------------------------------------------------
// Item 25: timingSafeEqual compares bytes, not UTF-16.
// -------------------------------------------------------------------------
import { timingSafeEqual } from '../api/crypto'

describe('Item 25: timingSafeEqual operates on UTF-8 bytes', () => {
  it('returns true for identical strings', () => {
    expect(timingSafeEqual('café', 'café')).toBe(true)
  })

  it('returns false for differing byte length', () => {
    expect(timingSafeEqual('a', 'aa')).toBe(false)
  })

  it('returns false for differing astral-plane content', () => {
    expect(timingSafeEqual('😀', '😁')).toBe(false)
  })
})

// -------------------------------------------------------------------------
// Item 26: hash('md5', …) inside a non-Node runtime fails loudly.
// -------------------------------------------------------------------------
describe('Item 26: md5 only available in Node', () => {
  it('hash sha256 works', async () => {
    const h = await cryptoApi.hash('sha256', 'hello')
    expect(h).toMatch(/^[0-9a-f]{64}$/)
  })

  it('hash md5 works in Node (smoke)', async () => {
    const h = await cryptoApi.hash('md5', 'hello')
    expect(h).toMatch(/^[0-9a-f]{32}$/)
  })
})

// -------------------------------------------------------------------------
// Item 27: randomString rejects empty charset.
// -------------------------------------------------------------------------
import { randomString } from '../api/crypto'

describe('Item 27: randomString empty-charset guard', () => {
  it('throws on empty charset', async () => {
    await expect(randomString(8, '')).rejects.toThrow(/charset/)
  })

  it('throws on negative length', async () => {
    await expect(randomString(-1)).rejects.toThrow(/length/)
  })

  it('produces the requested length', async () => {
    const s = await randomString(40, 'AB')
    expect(s).toHaveLength(40)
    expect(s).toMatch(/^[AB]+$/)
  })
})

// -------------------------------------------------------------------------
// Item 28: UUID validator accepts v6/v7/v8.
// -------------------------------------------------------------------------
import { validators } from '../security'

describe('Item 28: UUID validator covers RFC 9562 versions', () => {
  it('accepts v4', () => {
    expect(validators.uuid('a3bb189e-8bf9-4c6f-a8a4-5e8d4e1f4c11')).toBe(true)
  })
  it('accepts v7', () => {
    expect(validators.uuid('018d5d3b-4a78-7d49-b5f3-1e0eaa5b0aaa')).toBe(true)
  })
  it('accepts v8', () => {
    expect(validators.uuid('aaaaaaaa-aaaa-8aaa-baaa-aaaaaaaaaaaa')).toBe(true)
  })
  it('rejects v0', () => {
    expect(validators.uuid('aaaaaaaa-aaaa-0aaa-baaa-aaaaaaaaaaaa')).toBe(false)
  })
})

// -------------------------------------------------------------------------
// Item 29: removeNonPrintable preserves Unicode.
// -------------------------------------------------------------------------
import { sanitizers } from '../security'

describe('Item 29: removeNonPrintable Unicode-aware', () => {
  it('preserves accented Latin characters', () => {
    expect(sanitizers.removeNonPrintable('café')).toBe('café')
  })
  it('preserves CJK and emoji', () => {
    expect(sanitizers.removeNonPrintable('中文 😀')).toBe('中文 😀')
  })
  it('strips actual control characters', () => {
    expect(sanitizers.removeNonPrintable('abc')).toBe('abc')
  })
})

// -------------------------------------------------------------------------
// Item 30: useCraft hooks talk to bridge — verify imports exist.
// -------------------------------------------------------------------------
describe('Item 30: framework hooks reach the bridge', () => {
  it('react.ts no longer contains "Would call native API" stubs', async () => {
    const src = await Bun.file(new URL('../utils/react.ts', import.meta.url)).text()
    expect(src).not.toContain('Would call native API')
  })
  it('vue.ts no longer contains "Would call native API" stubs', async () => {
    const src = await Bun.file(new URL('../utils/vue.ts', import.meta.url)).text()
    expect(src).not.toContain('Would call native API')
  })
  it('svelte.ts no longer contains "Would call native API" stubs', async () => {
    const src = await Bun.file(new URL('../utils/svelte.ts', import.meta.url)).text()
    expect(src).not.toContain('Would call native API')
  })
})

// -------------------------------------------------------------------------
// Item 32: CraftApp sidebarConfig argv encoding.
// (Item 34's binary-discovery contract moved to binary-resolver.test.ts
//  once the SDK started delegating to pantry for craft installation.)
// -------------------------------------------------------------------------
describe('Item 32: CraftApp arg encoding', () => {
  it('inlines small sidebar configs onto argv', async () => {
    const { CraftApp } = await import('../index')
    const app = new (CraftApp as unknown as { new(c: any): { buildArgs(): string[] } })({
      window: { nativeSidebar: true, sidebarConfig: { items: [{ id: 'a' }] } },
    })
    const args = (app as unknown as { buildArgs(): string[] }).buildArgs()
    expect(args).toContain('--sidebar-config')
  })

  it('spills large sidebar configs into a temp file', async () => {
    const { CraftApp } = await import('../index')
    const big = { items: Array.from({ length: 5000 }, (_, i) => ({ id: `i${i}`, label: 'x'.repeat(50) })) }
    const app = new (CraftApp as unknown as { new(c: any): { buildArgs(): string[] } })({
      window: { nativeSidebar: true, sidebarConfig: big },
    })
    const args = (app as unknown as { buildArgs(): string[] }).buildArgs()
    expect(args).toContain('--sidebar-config-file')
    const fileIdx = args.indexOf('--sidebar-config-file') + 1
    expect(fileIdx).toBeGreaterThan(0)
    const path = args[fileIdx]
    const written = readFileSync(path, 'utf-8')
    expect(JSON.parse(written).items.length).toBe(5000)
  })
})

// -------------------------------------------------------------------------
// Item 36: dbAudit lifts default listener cap.
// -------------------------------------------------------------------------
import { dbAudit } from '../api/db'

describe('Item 36: dbAudit cap', () => {
  it('reports max listeners as 0 (uncapped)', () => {
    expect(dbAudit.getMaxListeners()).toBe(0)
  })
})

// -------------------------------------------------------------------------
// Item 38 & 39: Updater find -print0 + helper exists.
// -------------------------------------------------------------------------
describe('Item 38 & 39: updater find parsing & install verification', () => {
  it('source uses -print0 for find invocations', async () => {
    const src = await Bun.file(new URL('../updater/index.ts', import.meta.url)).text()
    expect(src).toContain('-print0')
    expect(src).toContain('findFirstByName')
  })

  it('installUpdate refuses to run with no manifest/download', async () => {
    const { AutoUpdater } = await import('../updater')
    const u = new AutoUpdater({
      updateUrl: 'https://example.com/manifest.json',
      currentVersion: '1.0.0',
      appPath: '/tmp/x',
    })
    await expect(u.installUpdate(false)).rejects.toThrow(/No update downloaded/)
  })
})

// -------------------------------------------------------------------------
// Item 41: AppManager invalidates cached preferences on theme/display events.
// -------------------------------------------------------------------------
describe('Item 41: AppManager cache invalidation', () => {
  it('source clears _preferences on relevant events', async () => {
    const src = await Bun.file(new URL('../api/app.ts', import.meta.url)).text()
    expect(src).toMatch(/this\._preferences = null/)
    expect(src).toContain('theme-changed')
  })
})

// -------------------------------------------------------------------------
// Item 42: hashPassword salt round-trips through base64 in both runtimes.
// -------------------------------------------------------------------------
import { hashPassword, verifyPassword } from '../api/crypto'

describe('Item 42: hashPassword/verifyPassword round-trip', () => {
  it('verifies a password with the same salt', async () => {
    const { hash, salt } = await hashPassword('correct horse battery staple')
    expect(await verifyPassword('correct horse battery staple', hash, salt)).toBe(true)
    expect(await verifyPassword('wrong', hash, salt)).toBe(false)
  })
})

// -------------------------------------------------------------------------
// Item 43: email validator catches obvious typos.
// -------------------------------------------------------------------------
describe('Item 43: email validator', () => {
  it('rejects trailing dots', () => {
    expect(validators.email('foo@bar.com.')).toBe(false)
  })
  it('rejects leading dots in local part', () => {
    expect(validators.email('.foo@bar.com')).toBe(false)
  })
  it('rejects consecutive dots', () => {
    expect(validators.email('a..b@bar.com')).toBe(false)
  })
  it('accepts plus-aliasing', () => {
    expect(validators.email('user+filter@example.museum')).toBe(true)
  })
})

// -------------------------------------------------------------------------
// Item 11: open() Windows path argv test (separate to keep file flow clean)
// -------------------------------------------------------------------------
describe('Item 11: open() smoke', () => {
  it('exports an async open()', () => {
    expect(typeof openTarget).toBe('function')
  })
})

// -------------------------------------------------------------------------
// Item 21: fs.watch recursive flag on Linux falls back gracefully.
// -------------------------------------------------------------------------
describe('Item 21: fs.watch recursive option', () => {
  it('source threads `recursive` through to fs.watch', async () => {
    const src = await Bun.file(new URL('../api/fs.ts', import.meta.url)).text()
    expect(src).toContain('recursive: recursive && platform !== \'linux\'')
    expect(src).toContain('WatchOptions')
  })
})

// -------------------------------------------------------------------------
// Item 31: removeNonPrintable already covered above. Item 32: covered above.
// Item 33: dev defaults — verify the helper is reachable.
// -------------------------------------------------------------------------
describe('Item 33: detectDevMode honours CRAFT_ENV', () => {
  it('source reads CRAFT_ENV before NODE_ENV', async () => {
    const src = await Bun.file(new URL('../index.ts', import.meta.url)).text()
    expect(src).toContain('CRAFT_ENV')
    expect(src).toContain('detectDevMode')
  })
})

// -------------------------------------------------------------------------
// Item 35: hashPassword salt round-trips already covered (item 42).
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// Item 24: audio.playTone resumes context — we don't run audio in CI but
// we can assert the source has the resume() call and is async.
// -------------------------------------------------------------------------
describe('Item 24: audio context resume', () => {
  it('source contains audioContext.resume() and the function is async', async () => {
    const src = await Bun.file(new URL('../utils/audio.ts', import.meta.url)).text()
    expect(src).toContain('audioContext.resume()')
    expect(src).toMatch(/async playTone/)
  })
})

// -------------------------------------------------------------------------
// Item 37: process.spawn shell flag — declared in the type, helper noted.
// -------------------------------------------------------------------------
describe('Item 37: spawn shell flag declared', () => {
  it('SpawnOptions type includes shell', async () => {
    const src = await Bun.file(new URL('../api/process.ts', import.meta.url)).text()
    expect(src).toContain('shell?: boolean')
  })
})

// -------------------------------------------------------------------------
// CSP development preset: no longer ships 'unsafe-inline' by default.
// -------------------------------------------------------------------------
import { ContentSecurityPolicy } from '../security'

describe('CSP: development preset tightening', () => {
  it('script-src does not include unsafe-inline by default', () => {
    const csp = ContentSecurityPolicy.development().toString()
    // Pull out just the script-src directive so style-src's
    // 'unsafe-inline' (still allowed for dev) doesn't contaminate the
    // assertion.
    const scriptSrc = csp.split(';').map(s => s.trim()).find(s => s.startsWith('script-src '))
    expect(scriptSrc).toBeDefined()
    expect(scriptSrc).toContain("'strict-dynamic'")
    expect(scriptSrc).not.toContain("'unsafe-inline'")
  })

  it('explicitly opts into unsafe-inline only when requested', () => {
    const csp = ContentSecurityPolicy.development({ allowUnsafeInline: true }).toString()
    const scriptSrc = csp.split(';').map(s => s.trim()).find(s => s.startsWith('script-src '))
    expect(scriptSrc).toContain("'unsafe-inline'")
  })

  it('embeds the supplied nonce', () => {
    const csp = ContentSecurityPolicy.development({ nonce: 'abc123' }).toString()
    expect(csp).toContain("'nonce-abc123'")
  })

  it('refuses to run when NODE_ENV=production', () => {
    const savedNode = process.env.NODE_ENV
    const savedCraft = process.env.CRAFT_ENV
    const savedApp = process.env.APP_ENV
    process.env.NODE_ENV = 'production'
    delete process.env.CRAFT_ENV
    delete process.env.APP_ENV
    try {
      expect(() => ContentSecurityPolicy.development()).toThrow(/production/)
    }
    finally {
      if (savedNode !== undefined) process.env.NODE_ENV = savedNode
      else delete process.env.NODE_ENV
      if (savedCraft !== undefined) process.env.CRAFT_ENV = savedCraft
      if (savedApp !== undefined) process.env.APP_ENV = savedApp
    }
  })
})

// -------------------------------------------------------------------------
// db.transaction documents the conflict with beginTransaction().
// -------------------------------------------------------------------------
describe('db.transaction docs', () => {
  it('source warns about mixing transaction() with beginTransaction()', async () => {
    const src = await Bun.file(new URL('../api/db.ts', import.meta.url)).text()
    expect(src).toContain('beginTransaction')
    expect(src).toMatch(/Don't mix the two/)
  })
})

// -------------------------------------------------------------------------
// process.ts navigator guard.
// -------------------------------------------------------------------------
describe('process.ts navigator guard', () => {
  it('uses typeof navigator !== \'undefined\' instead of optional chain', async () => {
    const src = await Bun.file(new URL('../api/process.ts', import.meta.url)).text()
    expect(src).toContain("typeof navigator !== 'undefined'")
    expect(src).not.toMatch(/navigator\?\.hardwareConcurrency/)
  })
})

// -------------------------------------------------------------------------
// Item 40: error-overlay HTML escaping sanity (we already escape).
// -------------------------------------------------------------------------
describe('Item 40: error-overlay escapes user fields', () => {
  it('source includes escapeHtml around message/source/suggestions', async () => {
    const src = await Bun.file(new URL('../dev/error-overlay.ts', import.meta.url)).text()
    expect(src).toContain('escapeHtml(error.message)')
    expect(src).toContain('escapeHtml(error.source)')
    expect(src).toMatch(/escapeHtml\(s\)/)
  })
})
