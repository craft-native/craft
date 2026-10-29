import { createCheckpointStore } from './checkpoints'

export interface BrowserStorageOptions {
  storage: Storage
  namespace: string
  tokenKey: string
  /**
   * The secure-storage name screens read the sign-in token under
   * (`craft.secureStorage.getSync('auth.token')`), stored at `tokenKey`.
   * Default `auth.token`.
   */
  sessionTokenKey?: string
  /** Existing website identity keys to forget whenever its token changes. */
  accountKeys?: string[]
  hash: (value: string) => Promise<string>
  changed: (name: string) => void
  /**
   * The sign-in token changed (a sign-in, a sign-out, another account), here
   * or in another tab: called once the new account's storage is in place.
   */
  sessionChanged?: (token: string | null, previous: string | null) => void
  /** A host lock primitive; honor signal cancellation while queued, as native Web Locks do. */
  lock?: (<T>(name: string, operation: () => T | Promise<T>, options?: { signal?: AbortSignal }) => Promise<T>) | null
}

export interface BrowserStorage {
  atomicStorage: boolean
  craft: {
    storage: { getSync: (key: string) => unknown, setSync: (key: string, value: unknown) => void }
    secureStorage: { getSync: (key: string) => string | null }
    snapshots: { get: (name: string) => unknown, set: (name: string, value: unknown) => Promise<boolean>, clear: (keep?: string[]) => Promise<boolean>, keys: () => string[] }
  }
  call: (module: string, method: string, args: unknown[], signal?: AbortSignal) => Promise<unknown>
  accountChanged: () => Promise<void>
  scope: () => string
}

/** Stop a caller's wait while required identity cleanup continues independently. */
async function waitForAccount<T>(operation: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return operation
  let abort!: () => void
  try {
    // eslint-disable-next-line no-unused-vars
    return await Promise.race([operation, new Promise<T>((resolve, reject) => {
      abort = () => reject(signal.reason)
      if (signal.aborted) abort()
      else signal.addEventListener('abort', abort, { once: true })
    })])
  }
  finally { signal.removeEventListener('abort', abort) }
}

/** Browser persistence has browser security semantics; it does not claim to be a Keychain. */
export async function createBrowserStorage(options: BrowserStorageOptions): Promise<BrowserStorage> {
  const { storage, namespace, tokenKey, changed } = options
  const sessionTokenKey = options.sessionTokenKey || 'auth.token'
  const prefix = `${namespace}:`
  const lock = options.lock === null ? undefined : options.lock ?? (typeof navigator !== 'undefined' && typeof navigator.locks?.request === 'function'
    ? <T>(name: string, operation: () => T | Promise<T>, settings?: { signal?: AbortSignal }) => navigator.locks.request(name, settings ?? {}, async () => {
        try { return await operation() }
        finally {
          // Firefox publishes localStorage snapshots at the end of a task.
          // Keep ownership through that boundary before another tab can read.
          // An async callback also delivers storage exceptions as rejections,
          // instead of reporting a synchronous Web Lock callback exception.
          await new Promise<void>(resolve => setTimeout(resolve, 0))
        }
      })
    : undefined)
  const exclusive = <T>(operation: () => T | Promise<T>, signal?: AbortSignal): Promise<T> => {
    const guarded = (): T | Promise<T> => { signal?.throwIfAborted(); return operation() }
    signal?.throwIfAborted()
    return lock ? lock(`${namespace}:storage`, guarded, { signal }) : Promise.resolve().then(guarded)
  }
  // Custom storage/lock adapters own their coherence contract. Real browser
  // checkpoints require transactional persistence as well as admission locks.
  const checkpoints = options.lock === undefined && lock && typeof indexedDB !== 'undefined'
    ? createCheckpointStore(storage, namespace) : null
  const atomicStorage = !!lock && (!!checkpoints || typeof options.lock === 'function')
  const checkpoint = <T>(operation: (store: Storage) => T, signal?: AbortSignal): Promise<T> => checkpoints
    ? checkpoints(operation, signal) : Promise.resolve().then(() => { signal?.throwIfAborted(); return operation(storage) })
  const scopeChanged = (): Error => Object.assign(new Error('The storage account changed'), { code: 'STORAGE_SCOPE_CHANGED' })
  const pending = new Map<string, { json: string | null }>()
  let token = storage.getItem(tokenKey)
  let reported = token
  let scope = token ? await options.hash(token) : 'guest'
  let transitioning = false
  let revision = 0
  let transition: Promise<void> | null = null
  const available = (): boolean => !transitioning && storage.getItem(tokenKey) === token
  const key = (name: string): string => `${prefix}account:${scope}:${name}`
  const snapshotKey = (name: string): string => name === 'app' ? `${prefix}app` : key(`snapshot:${name}`)
  const keys = (base: string, source: Storage = storage): string[] => Array.from({ length: source.length }, (_, index) => source.key(index)).filter((value): value is string => value !== null && value.startsWith(base))
  const parse = (value: string | null): unknown => {
    if (value === null) return null
    try { return JSON.parse(value) }
    catch { throw Object.assign(new Error('Stored value is not valid JSON'), { code: 'STORAGE_CORRUPT' }) }
  }
  const encode = (value: unknown): string => {
    const json = JSON.stringify(value)
    if (json === undefined) throw Object.assign(new Error('Storage requires JSON values'), { code: 'INVALID_ARGUMENT' })
    return json
  }
  const capture = () => ({ token, scope, revision })
  const requireScope = (captured: ReturnType<typeof capture>): void => {
    if (!available() || captured.token !== token || captured.scope !== scope || captured.revision !== revision) throw scopeChanged()
  }
  const read = (name: string): unknown => {
    if (!available()) return null
    const address = key(`storage:${name}`)
    const waiting = pending.get(address)
    return parse(waiting ? waiting.json : storage.getItem(address))
  }
  const setSync = (name: string, value: unknown): void => {
    if (!available()) return
    const captured = capture()
    const address = key(`storage:${name}`)
    const json = value === null || value === undefined ? null : encode(value)
    const write = (source: Storage): void => { if (json === null) source.removeItem(address); else source.setItem(address, json) }
    if (!lock) { write(storage); return }
    const entry = { json }
    pending.set(address, entry)
    void exclusive(() => checkpoint(source => { requireScope(captured); write(source) }))
      .catch(error => { if (error.code !== 'STORAGE_SCOPE_CHANGED') console.error('Browser storage write failed', error) })
      .finally(() => { if (pending.get(address) === entry) pending.delete(address) })
  }
  const accountChanged = async (): Promise<void> => {
    const next = storage.getItem(tokenKey)
    if (next === token) { await transition; return }
    const previous = scope
    const current = ++revision
    transitioning = true
    // Remove only the previous account's data. An account change must never
    // expose its retained first frame to the next person, even in another tab.
    token = next
    pending.clear()
    transition = (async () => {
      await exclusive(async () => {
        if (checkpoints) await checkpoint(source => { for (const name of keys(`${prefix}account:${previous}:`, source)) source.removeItem(name) })
        for (const name of keys(`${prefix}account:${previous}:`)) storage.removeItem(name)
        for (const name of options.accountKeys ?? []) { if (name !== tokenKey) storage.removeItem(name) }
      })
      const nextScope = next ? await options.hash(next) : 'guest'
      if (current !== revision) return
      scope = nextScope
      transitioning = false
      changed('session')
      // Against the token last reported, so a superseded transition (two
      // quick writes) still reads as one change from what listeners saw.
      const before = reported
      reported = next
      if (before !== next) options.sessionChanged?.(next, before)
    })()
    await transition
  }
  const secureKey = (name: string): string => name === sessionTokenKey ? tokenKey : key(`credential:${name}`)
  return {
    atomicStorage,
    scope: () => scope,
    accountChanged,
    craft: {
      storage: { getSync: read, setSync },
      secureStorage: { getSync: name => name === sessionTokenKey || available() ? storage.getItem(secureKey(name)) : null },
      snapshots: {
        get: (name) => {
          if (!available() && name !== 'app') return null
          const value = storage.getItem(snapshotKey(name))
          if (value === null) return null
          try { return JSON.parse(value) } catch { return value }
        },
        async set(name, value) { if (name !== 'app' && !available()) return false; storage.setItem(snapshotKey(name), typeof value === 'string' ? value : JSON.stringify(value)); changed(name); return true },
        async clear(keep = []) { if (!available()) return false; for (const name of keys(key('snapshot:'))) { const label = name.slice(key('snapshot:').length); if (!keep.includes(label)) { storage.removeItem(name); changed(label) } } if (!keep.includes('app')) storage.removeItem(snapshotKey('app')); return true },
        keys: () => available() ? keys(key('snapshot:')).map(name => name.slice(key('snapshot:').length)) : [],
      },
    },
    async call(module, method, args, signal) {
      signal?.throwIfAborted()
      const captured = capture()
      const wasAvailable = available()
      const name = String(args[0] ?? '')
      // Match a native bridge's JSON message boundary: capture the save at
      // invocation, not after account cleanup or another tab's lock releases.
      // The caller can keep advancing its simulation while this write waits.
      let json: string | undefined
      let expected: unknown
      if (wasAvailable && module === 'Storage') {
        if (method === 'set' || (method === 'setIfAbsent' && atomicStorage)) json = encode(args[1])
        if (method === 'compareAndSet' && atomicStorage) {
          expected = parse(encode(args[1]))
          json = encode(args[2])
        }
      }
      await waitForAccount(accountChanged(), signal)
      if (module === 'Storage') {
        if (!wasAvailable) throw scopeChanged()
        return exclusive(() => checkpoint(source => {
          requireScope(captured)
          const address = `${prefix}account:${captured.scope}:storage:${name}`
          if (method === 'get') return parse(source.getItem(address))
          if (method === 'set') { source.setItem(address, json!); return true }
          if (method === 'remove') { source.removeItem(address); return true }
          if (method === 'keys') return keys(key('storage:'), source).map(item => item.slice(key('storage:').length))
          if (method === 'clear') { for (const item of keys(key('storage:'), source)) source.removeItem(item); return true }
          if (method === 'compareAndSet' || method === 'setIfAbsent') {
            if (!atomicStorage) throw Object.assign(new Error('Atomic browser storage requires transactional persistence and Web Locks'), { code: method === 'setIfAbsent' ? 'STORAGE_SET_IF_ABSENT_UNSUPPORTED' : 'STORAGE_COMPARE_AND_SET_UNSUPPORTED' })
            const raw = source.getItem(address)
            if (method === 'setIfAbsent') {
              if (raw !== null) return false
              source.setItem(address, json!)
              return true
            }
            if (raw === null || !jsonEqual(parse(raw), expected)) return false
            source.setItem(address, json!)
            return true
          }
          throw Object.assign(new Error(`Unsupported browser storage operation ${method}`), { code: 'UNSUPPORTED' })
        }, signal), signal)
      }
      if (module === 'SecureStorage') {
        if (!wasAvailable) throw scopeChanged()
        const result = await exclusive(() => {
          requireScope(captured)
          const address = name === sessionTokenKey ? tokenKey : `${prefix}account:${captured.scope}:credential:${name}`
          if (method === 'get') return storage.getItem(address)
          if (method === 'set') { storage.setItem(address, String(args[1])); return true }
          if (method === 'remove') { storage.removeItem(address); return true }
          if (method === 'clear') {
            for (const item of keys(`${prefix}account:${captured.scope}:credential:`)) storage.removeItem(item)
            storage.removeItem(tokenKey)
            return true
          }
          throw Object.assign(new Error(`Unsupported browser storage operation ${module}.${method}`), { code: 'UNSUPPORTED' })
        }, signal)
        // Account cleanup takes the same lock. Start it only after releasing
        // this operation's lock, while stale queued calls already fail scope.
        if (method === 'clear' || (name === sessionTokenKey && (method === 'set' || method === 'remove')))
          await accountChanged()
        return result
      }
      throw Object.assign(new Error(`Unsupported browser storage operation ${module}.${method}`), { code: 'UNSUPPORTED' })
    },
  }
}

/** JSON value equality: object order is irrelevant, array order and types are not. */
function jsonEqual(left: unknown, right: unknown): boolean {
  if (left === right) return true
  if (Array.isArray(left) || Array.isArray(right))
    return Array.isArray(left) && Array.isArray(right) && left.length === right.length && left.every((value, index) => jsonEqual(value, right[index]))
  if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object') return false
  const a = left as Record<string, unknown>
  const b = right as Record<string, unknown>
  return Object.keys(a).length === Object.keys(b).length && Object.keys(a).every(key => Object.prototype.hasOwnProperty.call(b, key) && jsonEqual(a[key], b[key]))
}
