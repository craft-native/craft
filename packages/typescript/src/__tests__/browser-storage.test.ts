import { describe, expect, it } from 'bun:test'
import { createBrowserStorage } from '../browser/storage'

function storage(): Storage {
  const data = new Map<string, string>()
  return { get length() { return data.size }, key: index => [...data.keys()][index] ?? null, getItem: key => data.get(key) ?? null, setItem: (key, value) => { data.set(key, String(value)) }, removeItem: key => { data.delete(key) }, clear: () => data.clear() }
}
async function fixture() {
  const saved = storage()
  const changes: string[] = []
  const browser = await createBrowserStorage({ storage: saved, namespace: 'app', tokenKey: 'auth_token', accountKeys: ['auth_user'], hash: async value => `hash-${value}`, changed: name => changes.push(name), lock: null })
  return { saved, browser, changes }
}
describe('browser account persistence', () => {
  it('retains only the current account and shares the configured sign-in key', async () => {
    const { saved, browser, changes } = await fixture()
    await browser.craft.snapshots.set('app', { apiBase: '/api' })
    await browser.call('SecureStorage', 'set', ['auth.token', 'ava'])
    await browser.craft.snapshots.set('today', { user: 'Ava' })
    await browser.call('Storage', 'set', ['draft', { text: 'Private' }])
    expect(saved.getItem('auth_token')).toBe('ava')
    expect(browser.craft.storage.getSync('draft')).toEqual({ text: 'Private' })
    saved.setItem('auth_user', JSON.stringify({ name: 'Ava' }))
    await browser.call('SecureStorage', 'set', ['auth.token', 'ben'])
    expect(saved.getItem('auth_user')).toBeNull()
    expect(browser.craft.snapshots.get('today')).toBeNull()
    expect(browser.craft.storage.getSync('draft')).toBeNull()
    expect(browser.craft.snapshots.get('app')).toEqual({ apiBase: '/api' })
    expect([...Array(saved.length)].map((_, i) => saved.key(i)).join()).not.toContain('hash-ava')
    expect(changes).toContain('session')
  })
  it('blocks stale synchronous reads and writes during a cross-tab transition', async () => {
    const { saved, browser } = await fixture()
    await browser.call('SecureStorage', 'set', ['auth.token', 'ava'])
    await browser.craft.snapshots.set('today', { user: 'Ava' })
    saved.setItem('auth_token', 'ben')
    expect(browser.craft.snapshots.get('today')).toBeNull()
    expect(await browser.craft.snapshots.set('today', { user: 'Stale response' })).toBe(false)
    browser.craft.storage.setSync('draft', 'Stale edit')
    await browser.accountChanged()
    expect(browser.craft.storage.getSync('draft')).toBeNull()
    expect(browser.craft.snapshots.get('today')).toBeNull()
    expect(browser.scope()).toBe('hash-ben')
  })
  it('forgets credentials and snapshots on sign-out without clearing another app', async () => {
    const { saved, browser } = await fixture()
    saved.setItem('other-app', 'keep')
    await browser.call('SecureStorage', 'set', ['auth.token', 'ava'])
    await browser.call('SecureStorage', 'set', ['private-key', 'secret'])
    await browser.craft.snapshots.set('today', { user: 'Ava' })
    await browser.call('SecureStorage', 'clear', [])
    expect(browser.craft.secureStorage.getSync('auth.token')).toBeNull()
    expect(browser.craft.secureStorage.getSync('private-key')).toBeNull()
    expect(browser.craft.snapshots.keys()).toEqual([])
    expect(saved.getItem('other-app')).toBe('keep')
  })
})

function locks() {
  let tail = Promise.resolve()
  return <T>(_name: string, operation: () => T | Promise<T>): Promise<T> => {
    const result = tail.then(operation)
    tail = result.then(() => undefined, () => undefined)
    return result
  }
}
async function atomicFixture() {
  const saved = storage()
  const lock = locks()
  const options = { storage: saved, namespace: 'atomic', tokenKey: 'auth_token', hash: async (value: string) => `hash-${value}`, changed: () => {}, lock }
  const a = await createBrowserStorage(options)
  const b = await createBrowserStorage(options)
  return { saved, a, b, lock }
}

describe('browser atomic account checkpoints', () => {
  it.each([false, true])('retains the native lock through storage publication and rejects errors asynchronously (quota: %s)', async (quota) => {
    const previous = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
    const saved = storage()
    let published = false
    let releasedAfterPublication = false
    let synchronousThrows = 0
    const original = saved.setItem
    saved.setItem = (key, value) => {
      setTimeout(() => { published = true }, 0)
      if (quota) throw new DOMException('Full', 'QuotaExceededError')
      original(key, value)
    }
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { locks: {
      request: (name: string, settings: unknown, callback: () => unknown) => {
        expect(name).toBe('native-lock:storage')
        try {
          return Promise.resolve(callback()).finally(() => { releasedAfterPublication = published })
        }
        catch (error) { synchronousThrows++; return Promise.reject(error) }
      },
    } } })
    try {
      const browser = await createBrowserStorage({ storage: saved, namespace: 'native-lock', tokenKey: 'token', hash: async value => value, changed: () => {} })
      const write = browser.call('Storage', 'set', ['campaign', { tick: 25 }])
      if (quota) await expect(write).rejects.toMatchObject({ name: 'QuotaExceededError' })
      else expect(await write).toBe(true)
      expect(synchronousThrows).toBe(0)
      expect(releasedAfterPublication).toBe(true)
    }
    finally {
      if (previous) Object.defineProperty(globalThis, 'navigator', previous)
      else Reflect.deleteProperty(globalThis, 'navigator')
    }
  })

  it('captures ordinary saves before yielding even without Web Locks', async () => {
    const { browser } = await fixture()
    const state = { tick: 25 }
    const args: unknown[] = ['campaign', state]
    const checkpoint = browser.call('Storage', 'set', args)
    state.tick = 26
    args[0] = 'wrong-key'
    expect(await checkpoint).toBe(true)
    expect(await browser.call('Storage', 'get', ['campaign'])).toEqual({ tick: 25 })
    expect(await browser.call('Storage', 'get', ['wrong-key'])).toBeNull()
  })

  it('rejects invalid checkpoint JSON without replacing the previous save or poisoning retries', async () => {
    const { a } = await atomicFixture()
    await a.call('Storage', 'set', ['campaign', { tick: 25 }])
    const cyclic: { self?: unknown } = {}
    cyclic.self = cyclic
    for (const invalid of [undefined, cyclic, 1n]) {
      for (const method of ['set', 'setIfAbsent', 'compareAndSet']) {
        const args = method === 'compareAndSet' ? ['campaign', { tick: 25 }, invalid] : ['campaign', invalid]
        await expect(a.call('Storage', method, args)).rejects.toThrow()
        expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 25 })
      }
      await expect(a.call('Storage', 'compareAndSet', ['campaign', invalid, { tick: 26 }])).rejects.toThrow()
    }
    expect(await a.call('Storage', 'compareAndSet', ['campaign', { tick: 25 }, { tick: 26 }])).toBe(true)
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 26 })
  })

  it('rechecks account identity after running a caller-provided serializer', async () => {
    const { saved, a } = await atomicFixture()
    await a.call('SecureStorage', 'set', ['auth.token', 'A'])
    const state = { toJSON: () => { saved.setItem('auth_token', 'B'); return { owner: 'A' } } }
    await expect(a.call('Storage', 'set', ['campaign', state])).rejects.toMatchObject({ code: 'STORAGE_SCOPE_CHANGED' })
    expect(saved.getItem('atomic:account:hash-A:storage:campaign')).toBeNull()
    expect(saved.getItem('atomic:account:hash-B:storage:campaign')).toBeNull()
    expect(a.scope()).toBe('hash-B')
  })

  it.each(['set', 'setIfAbsent'])('captures %s checkpoint JSON and its key before waiting for the lock', async (method) => {
    const { saved, a, lock } = await atomicFixture()
    let release!: () => void
    const held = lock('atomic:storage', () => new Promise<void>(resolve => { release = resolve }))
    await Bun.sleep(0)
    const state = { tick: 25, army: [{ units: 3 }] }
    const args: unknown[] = ['campaign', state]
    const checkpoint = a.call('Storage', method, args)
    args[0] = 'wrong-key'
    state.tick = 26
    state.army[0]!.units = 99
    args[1] = { tick: 999 }
    await Bun.sleep(0)
    expect(saved.getItem('atomic:account:guest:storage:campaign')).toBeNull()
    release()
    await held
    expect(await checkpoint).toBe(true)
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 25, army: [{ units: 3 }] })
    expect(await a.call('Storage', 'get', ['wrong-key'])).toBeNull()
  })

  it('captures the expected and replacement CAS values without observing later caller mutations', async () => {
    const { a, lock } = await atomicFixture()
    await a.call('Storage', 'set', ['campaign', { tick: 25 }])
    let release!: () => void
    const held = lock('atomic:storage', () => new Promise<void>(resolve => { release = resolve }))
    await Bun.sleep(0)
    const expected = { tick: 25 }
    const next = { tick: 26, units: [3] }
    const checkpoint = a.call('Storage', 'compareAndSet', ['campaign', expected, next])
    expected.tick = 100
    next.tick = 101
    next.units.push(99)
    release()
    await held
    expect(await checkpoint).toBe(true)
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 26, units: [3] })
  })

  it('compares CAS inputs as their captured JSON representation and runs serializers only once', async () => {
    const { a } = await atomicFixture()
    await a.call('Storage', 'set', ['campaign', { tick: 25 }])
    let expectedCalls = 0
    let nextCalls = 0
    const expected = { toJSON: () => { expectedCalls++; return { tick: 25 } } }
    const next = { toJSON: () => { nextCalls++; return { tick: 26 } } }
    expect(await a.call('Storage', 'compareAndSet', ['campaign', expected, next])).toBe(true)
    expect([expectedCalls, nextCalls]).toEqual([1, 1])
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 26 })
  })

  it('acknowledges ordinary checkpoints only after committing and propagates quota errors', async () => {
    const { saved, a, lock } = await atomicFixture()
    let release!: () => void
    let entered!: () => void
    const started = new Promise<void>(resolve => { entered = resolve })
    const held = lock('atomic:storage', () => new Promise<void>(resolve => { release = resolve; entered() }))
    await started
    let acknowledged = false
    const checkpoint = a.call('Storage', 'set', ['campaign', { tick: 25 }]).then(() => { acknowledged = true })
    await Bun.sleep(0)
    expect(acknowledged).toBe(false)
    expect(saved.getItem('atomic:account:guest:storage:campaign')).toBeNull()
    release(); await Promise.all([held, checkpoint])
    expect(acknowledged).toBe(true)
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 25 })
    saved.setItem = () => { throw new Error('quota exceeded') }
    await expect(a.call('Storage', 'set', ['campaign', { tick: 26 }])).rejects.toThrow('quota exceeded')
    expect(await a.call('Storage', 'get', ['campaign'])).toEqual({ tick: 25 })
  })
  it('advertises atomic support only with a lock primitive and refuses unsupported writes', async () => {
    const { browser } = await fixture()
    expect(browser.atomicStorage).toBe(false)
    await expect(browser.call('Storage', 'setIfAbsent', ['draft', null])).rejects.toMatchObject({ code: 'STORAGE_SET_IF_ABSENT_UNSUPPORTED' })
    await expect(browser.call('Storage', 'compareAndSet', ['draft', null, {}])).rejects.toMatchObject({ code: 'STORAGE_COMPARE_AND_SET_UNSUPPORTED' })
  })
  it('serializes competing creation, preserves stored null, and makes deletion win over CAS', async () => {
    const { a, b } = await atomicFixture()
    expect(a.atomicStorage).toBe(true)
    expect(await Promise.all([a.call('Storage', 'setIfAbsent', ['draft', { id: 'A', feedback: 'latest' }]), b.call('Storage', 'setIfAbsent', ['draft', { id: 'B' }])])).toEqual([true, false])
    expect(await b.call('Storage', 'compareAndSet', ['draft', { feedback: 'latest', id: 'A' }, { id: 'A', done: true }])).toBe(true)
    expect(await b.call('Storage', 'remove', ['draft'])).toBe(true)
    expect(await a.call('Storage', 'compareAndSet', ['draft', { id: 'A', done: true }, { id: 'A' }])).toBe(false)
    expect(await a.call('Storage', 'get', ['draft'])).toBeNull()
    a.craft.storage.setSync('draft', { id: 'C' })
    a.craft.storage.setSync('draft', null)
    expect(a.craft.storage.getSync('draft')).toBeNull()
    expect(await b.call('Storage', 'setIfAbsent', ['draft', { id: 'D' }])).toBe(true)
    expect(await a.call('Storage', 'setIfAbsent', ['draft', null])).toBe(false)
    await b.call('Storage', 'remove', ['draft'])
    expect(await a.call('Storage', 'setIfAbsent', ['draft', null])).toBe(true)
    expect(await b.call('Storage', 'setIfAbsent', ['draft', { id: 'B' }])).toBe(false)
  })
  it('puts synchronous UI writes on the same lock and keeps immediate UI reads', async () => {
    const { a, b } = await atomicFixture()
    a.craft.storage.setSync('draft', { id: 'A' })
    expect(a.craft.storage.getSync('draft')).toEqual({ id: 'A' })
    await b.call('Storage', 'remove', ['draft'])
    expect(await a.call('Storage', 'compareAndSet', ['draft', { id: 'A' }, { id: 'A', done: true }])).toBe(false)
    expect(await a.call('Storage', 'get', ['draft'])).toBeNull()
  })
  it('rejects a queued old-account read instead of retargeting the new namespace', async () => {
    const { saved, a, lock } = await atomicFixture()
    await a.call('SecureStorage', 'set', ['auth.token', 'A'])
    await a.call('Storage', 'set', ['draft', { owner: 'A' }])
    let release!: () => void
    let entered!: () => void
    const started = new Promise<void>(resolve => { entered = resolve })
    const held = lock('atomic:storage', () => new Promise<void>(resolve => { release = resolve; entered() }))
    await started
    const stale = a.call('Storage', 'get', ['draft'])
    saved.setItem('auth_token', 'B')
    const transition = a.accountChanged()
    release()
    await expect(stale).rejects.toMatchObject({ code: 'STORAGE_SCOPE_CHANGED' })
    await Promise.all([held, transition])
    expect(await a.call('Storage', 'get', ['draft'])).toBeNull()
    expect(saved.getItem('atomic:account:hash-B:storage:draft')).toBeNull()
  })
  it('preserves the committed value when an atomic write runs out of storage', async () => {
    const { saved, a } = await atomicFixture()
    await a.call('Storage', 'set', ['draft', { owner: 'A' }])
    const original = saved.setItem
    saved.setItem = () => { throw new Error('quota exceeded') }
    await expect(a.call('Storage', 'compareAndSet', ['draft', { owner: 'A' }, { owner: 'B' }])).rejects.toThrow('quota exceeded')
    saved.setItem = original
    expect(await a.call('Storage', 'get', ['draft'])).toEqual({ owner: 'A' })
  })
  it('rejects stale credential operations and sign-out without touching the next account', async () => {
    const { saved, a, lock } = await atomicFixture()
    await a.call('SecureStorage', 'set', ['auth.token', 'A'])
    await a.call('SecureStorage', 'set', ['private-key', 'A-secret'])
    saved.setItem('atomic:account:hash-B:credential:private-key', 'B-secret')
    let release!: () => void
    let entered!: () => void
    const started = new Promise<void>(resolve => { entered = resolve })
    const held = lock('atomic:storage', () => new Promise<void>(resolve => { release = resolve; entered() }))
    await started
    const stale = [
      ['get', ['private-key']],
      ['set', ['private-key', 'stale-A-secret']],
      ['remove', ['private-key']],
      ['clear', []],
      ['set', ['auth.token', 'stale-A-token']],
      ['remove', ['auth.token']],
    ].map(([method, args]) => a.call('SecureStorage', method as string, args as unknown[])
      .then(() => 'unexpected-success', error => error.code))
    saved.setItem('auth_token', 'B')
    const transition = a.accountChanged()
    release()
    expect(await Promise.all(stale)).toEqual(Array(6).fill('STORAGE_SCOPE_CHANGED'))
    await Promise.all([held, transition])
    expect(saved.getItem('auth_token')).toBe('B')
    expect(await a.call('SecureStorage', 'get', ['private-key'])).toBe('B-secret')
    expect(saved.getItem('atomic:account:hash-B:credential:private-key')).toBe('B-secret')
  })
})
