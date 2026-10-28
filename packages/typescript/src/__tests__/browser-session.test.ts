import { describe, expect, it } from 'bun:test'
import { createBrowserPlatform } from '../browser'
import { createBrowserStorage } from '../browser/storage'

function memoryStorage(): Storage {
  const data = new Map<string, string>()
  return { get length() { return data.size }, key: index => [...data.keys()][index] ?? null, getItem: key => data.get(key) ?? null, setItem: (key, value) => { data.set(key, String(value)) }, removeItem: key => { data.delete(key) }, clear: () => data.clear() }
}

type Platform = Awaited<ReturnType<typeof createBrowserPlatform>>

/** A held exclusive Web Lock, including the browser's queued-abort semantics. */
function heldWebLocks() {
  type Work = (lock: { name: string, mode: 'exclusive' }) => unknown
  let held = true
  let entered!: () => void
  const requested = new Promise<void>(resolve => { entered = resolve })
  const queue: { cancelled: () => boolean, run: () => void }[] = []
  const drain = (): void => {
    if (held) return
    const next = queue.shift()
    if (!next) return
    if (next.cancelled()) { drain(); return }
    held = true
    next.run()
  }
  return {
    requested,
    release() { held = false; drain() },
    request(name: string, optionsOrWork: LockOptions | Work, work?: Work): Promise<unknown> {
      const options = typeof optionsOrWork === 'function' ? {} : optionsOrWork
      const operation = typeof optionsOrWork === 'function' ? optionsOrWork : work!
      entered()
      return new Promise((resolve, reject) => {
        let cancelled = false
        let acquired = false
        const abort = (): void => {
          if (acquired) return
          cancelled = true
          reject(options.signal?.reason ?? new DOMException('Aborted', 'AbortError'))
        }
        if (options.signal?.aborted) { abort(); return }
        options.signal?.addEventListener('abort', abort, { once: true })
        queue.push({
          cancelled: () => cancelled,
          run() {
            acquired = true
            options.signal?.removeEventListener('abort', abort)
            Promise.resolve().then(() => operation({ name, mode: 'exclusive' })).then(resolve, reject).finally(() => { held = false; drain() })
          },
        })
        drain()
      })
    },
  }
}

async function withPlatform(run: (platform: Platform, saved: Storage) => Promise<void>, extra: Record<string, unknown> = {}, options: Parameters<typeof createBrowserPlatform>[0] = {}) {
  const saved = memoryStorage()
  const previous = new Map<string, PropertyDescriptor | undefined>()
  const globals: Record<string, unknown> = {
    localStorage: saved,
    window: { addEventListener() {}, removeEventListener() {} },
    location: { origin: 'https://fixture.invalid', href: 'https://fixture.invalid/m' },
    navigator: { language: 'en', userAgent: 'Fixture' },
    ...extra,
  }
  for (const [key, value] of Object.entries(globals)) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  let platform: Platform | undefined
  try {
    platform = await createBrowserPlatform({ namespace: 'fixture', tokenKey: 'auth_token', ...options })
    await run(platform, saved)
  }
  finally {
    platform?.dispose()
    for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else Reflect.deleteProperty(globalThis, key) }
  }
}

describe('browser host session', () => {
  it('the public platform saves the captured checkpoint while the simulation keeps mutating', async () => {
    const locks = heldWebLocks()
    await withPlatform(async (platform, saved) => {
      const state = { tick: 25, units: [{ id: 'settler', x: 2 }] }
      const args: unknown[] = ['checkpoint', state]
      const write = platform.call('Storage', 'set', args, new AbortController().signal)
      args[0] = 'other-checkpoint'
      state.tick = 26
      state.units[0]!.x = 9
      try {
        await locks.requested
        expect(saved.getItem('fixture:account:guest:storage:checkpoint')).toBeNull()
      }
      finally { locks.release() }
      expect(await write).toBe(true)
      expect(JSON.parse(saved.getItem('fixture:account:guest:storage:checkpoint')!)).toEqual({ tick: 25, units: [{ id: 'settler', x: 2 }] })
      expect(saved.getItem('fixture:account:guest:storage:other-checkpoint')).toBeNull()
    }, { navigator: { language: 'en', userAgent: 'Fixture', locks } })
  })

  it('the Web Locks fixture cancels a queued request without running its callback', async () => {
    const locks = heldWebLocks()
    const controller = new AbortController()
    let ran = false
    const queued = locks.request('control', { signal: controller.signal }, () => { ran = true })
    controller.abort()
    await expect(queued).rejects.toMatchObject({ name: 'AbortError' })
    locks.release()
    await Bun.sleep(0)
    expect(ran).toBe(false)
  })

  for (const cancellation of ['caller', 'dispose'] as const) {
    for (const method of ['get', 'set', 'setIfAbsent', 'compareAndSet', 'remove', 'clear'] as const) {
      it(`cancels queued Storage.${method} on ${cancellation} cancellation without changing the previous save`, async () => {
        const locks = heldWebLocks()
        await withPlatform(async (platform, saved) => {
          const address = 'fixture:account:guest:storage:checkpoint'
          saved.setItem(address, JSON.stringify({ tick: 24 }))
          const controller = new AbortController()
          let settled = false
          const args = method === 'clear' ? []
            : method === 'compareAndSet' ? ['checkpoint', { tick: 24 }, { tick: 25 }]
              : method === 'set' || method === 'setIfAbsent' ? ['checkpoint', { tick: 25 }] : ['checkpoint']
          const write = platform.call('Storage', method, args, controller.signal)
            .then(value => ({ value }), error => ({ error }))
            .then(result => { settled = true; return result })
          try {
            await locks.requested
            if (cancellation === 'caller') controller.abort()
            else platform.dispose()
            await Bun.sleep(0)
            expect(settled).toBe(true)
          }
          finally { locks.release() }
          expect(await write).toMatchObject({ error: { name: 'AbortError' } })
          expect(JSON.parse(saved.getItem(address)!)).toEqual({ tick: 24 })
        }, { navigator: { language: 'en', userAgent: 'Fixture', locks } })
      })
    }
  }

  it('cancels a caller waiting for account cleanup without cancelling the cleanup', async () => {
    const locks = heldWebLocks()
    await withPlatform(async (platform, saved) => {
      const oldAddress = 'fixture:account:guest:storage:checkpoint'
      saved.setItem(oldAddress, JSON.stringify({ tick: 24 }))
      saved.setItem('auth_token', 'new-account')
      const controller = new AbortController()
      let settled = false
      const waiting = platform.call('Storage', 'set', ['checkpoint', { tick: 25 }], controller.signal)
        .then(value => ({ value }), error => ({ error }))
        .then(result => { settled = true; return result })
      try {
        await locks.requested
        controller.abort()
        await Bun.sleep(0)
        expect(settled).toBe(true)
      }
      finally { locks.release() }
      expect(await waiting).toMatchObject({ error: { name: 'AbortError' } })
      await Bun.sleep(0)
      expect(saved.getItem(oldAddress)).toBeNull()
      expect((platform.craft.storage as { getSync: (key: string) => unknown }).getSync('checkpoint')).toBeNull()
    }, { navigator: { language: 'en', userAgent: 'Fixture', locks } })
  })

  it('reports each sign-in, account switch and sign-out once, with the previous token', async () => {
    await withPlatform(async (platform) => {
      const signal = new AbortController().signal
      const messages: unknown[] = []
      const heard: unknown[] = []
      platform.emit((type, payload) => { if (type === 'SESSION_CHANGED') messages.push(payload) })
      const session = platform.craft.session as { key: string, token: () => string | null, onChange: (cb: (t: string | null, p: string | null) => void) => () => void }
      expect(session.key).toBe('auth.token')
      expect(session.token()).toBeNull()
      const stop = session.onChange((token, previous) => heard.push([token, previous, session.token()]))
      await platform.call('SecureStorage', 'set', ['auth.token', 'ava'], signal)
      await platform.call('SecureStorage', 'set', ['auth.token', 'ava'], signal)
      await platform.call('SecureStorage', 'set', ['private-key', 'not-a-session'], signal)
      await platform.call('SecureStorage', 'set', ['auth.token', 'ben'], signal)
      await platform.call('SecureStorage', 'remove', ['auth.token'], signal)
      stop()
      await platform.call('SecureStorage', 'set', ['auth.token', 'cy'], signal)
      expect(heard).toEqual([['ava', null, 'ava'], ['ben', 'ava', 'ben'], [null, 'ben', null]])
      expect(messages).toEqual([
        { key: 'auth.token', token: 'ava', previous: null },
        { key: 'auth.token', token: 'ben', previous: 'ava' },
        { key: 'auth.token', token: null, previous: 'ben' },
        { key: 'auth.token', token: 'cy', previous: null },
      ])
    })
  })

  it('follows a configured token key', async () => {
    await withPlatform(async (platform, saved) => {
      const signal = new AbortController().signal
      const heard: unknown[] = []
      ;(platform.craft.session as any).onChange((token: string | null) => heard.push(token))
      await platform.call('SecureStorage', 'set', ['auth.token', 'ignored'], signal)
      await platform.call('SecureStorage', 'set', ['hq.session', 'ava'], signal)
      expect(saved.getItem('auth_token')).toBe('ava')
      expect((platform.craft.session as any).token()).toBe('ava')
      expect(heard).toEqual(['ava'])
    }, {}, { sessionTokenKey: 'hq.session' })
  })
})

describe('browser storage session callback', () => {
  it('reports a cross-tab change once storage moved to the new account', async () => {
    const saved = memoryStorage()
    const heard: unknown[] = []
    const browser = await createBrowserStorage({
      storage: saved, namespace: 'app', tokenKey: 'auth_token', hash: async value => `hash-${value}`, changed: () => {}, lock: null,
      sessionChanged: (token, previous) => heard.push([token, previous, browser.scope()]),
    })
    saved.setItem('auth_token', 'ava')
    await browser.accountChanged()
    saved.setItem('auth_token', 'ben')
    saved.setItem('auth_token', 'cy')
    await Promise.all([browser.accountChanged(), browser.accountChanged()])
    expect(heard).toEqual([['ava', null, 'hash-ava'], ['cy', 'ava', 'hash-cy']])
  })
})
