/**
 * localStorage is a synchronous UI mirror, not an atomic cross-process store.
 * WebKit can grant a Web Lock before another process's storage cache updates.
 * Keep the acknowledged checkpoint in one IndexedDB read/write transaction.
 */
export function createCheckpointStore(mirror: Storage, namespace: string) {
  const prefix = `${namespace}:account:`
  const owned = (key: string): boolean => {
    if (!key.startsWith(prefix)) return false
    const scoped = key.slice(prefix.length)
    const separator = scoped.indexOf(':')
    return separator !== -1 && scoped.slice(separator + 1).startsWith('storage:')
  }
  const mirrorKeys = (): string[] => Array.from({ length: mirror.length }, (_, i) => mirror.key(i)).filter((key): key is string => key !== null && owned(key))

  return async <T>(operation: (storage: Storage) => T, signal?: AbortSignal): Promise<T> => {
    signal?.throwIfAborted()
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(`${namespace}:checkpoints`, 1)
      let abandoned = false
      const abort = (): void => { abandoned = true; reject(signal?.reason) }
      signal?.addEventListener('abort', abort, { once: true })
      request.onupgradeneeded = () => { request.result.createObjectStore('checkpoints') }
      request.onerror = () => { signal?.removeEventListener('abort', abort); reject(request.error) }
      request.onblocked = () => { abandoned = true; signal?.removeEventListener('abort', abort); reject(new DOMException('Checkpoint database upgrade is blocked', 'InvalidStateError')) }
      request.onsuccess = () => {
        signal?.removeEventListener('abort', abort)
        if (abandoned || signal?.aborted) { request.result.close(); reject(signal?.reason); return }
        resolve(request.result)
      }
    })
    try {
      // Commit legacy import before touching its UI mirror. If the first new
      // save is interrupted, recovery must import neither its partial cache nor
      // a deleted checkpoint from an old page's stale cache.
      await new Promise<void>((resolve, reject) => {
        const transaction = db.transaction('checkpoints', 'readwrite')
        const store = transaction.objectStore('checkpoints')
        const request = store.get('state')
        let failure: unknown
        request.onsuccess = () => {
          if (request.result !== undefined) return
          try { store.put(mirrorKeys().map(key => [key, mirror.getItem(key)!]), 'state') }
          catch (error) { failure = error; transaction.abort() }
        }
        transaction.oncomplete = () => resolve()
        transaction.onabort = () => reject(failure ?? transaction.error)
      })
      signal?.throwIfAborted()
      return await new Promise<T>((resolve, reject) => {
        const transaction = db.transaction('checkpoints', 'readwrite')
        const store = transaction.objectStore('checkpoints')
        let result: T
        let failure: unknown
        const before = new Map<string, string | null>()
        const abort = (): void => {
          failure = signal?.reason
          try { transaction.abort() } catch { /* A completed transaction cannot be undone. */ }
        }
        signal?.addEventListener('abort', abort, { once: true })
        transaction.oncomplete = () => { signal?.removeEventListener('abort', abort); resolve(result) }
        transaction.onabort = () => {
          signal?.removeEventListener('abort', abort)
          // A failed checkpoint must not leave a successful-looking local UI
          // mirror. The database remains authoritative if cache repair fails.
          for (const [key, value] of before) {
            try { if (value === null) mirror.removeItem(key); else mirror.setItem(key, value) } catch { /* Storage can become unavailable during rollback. */ }
          }
          reject(failure ?? transaction.error ?? new DOMException('Checkpoint transaction aborted', 'AbortError'))
        }
        const request = store.get('state')
        request.onsuccess = () => {
          try {
            signal?.throwIfAborted()
            const values = new Map(request.result as [string, string][])
            let dirty = false
            const storage: Storage = {
              get length() { return values.size },
              key: index => [...values.keys()][index] ?? null,
              getItem: key => values.get(key) ?? null,
              setItem(key, value) { values.set(key, String(value)); dirty = true },
              removeItem(key) { dirty = values.delete(key) || dirty },
              clear() { dirty = values.size > 0 || dirty; values.clear() },
            }
            result = operation(storage)
            signal?.throwIfAborted()
            for (const key of new Set([...mirrorKeys(), ...values.keys()])) {
              const previous = mirror.getItem(key)
              const next = values.get(key) ?? null
              if (previous === next) continue
              before.set(key, previous)
              if (next === null) mirror.removeItem(key)
              else mirror.setItem(key, next)
            }
            // Quota/cache failures above abort before acknowledging a new
            // checkpoint. Await transaction completion, never just put.success.
            if (dirty) store.put([...values], 'state')
          }
          catch (error) { failure = error; transaction.abort() }
        }
      })
    }
    finally { db.close() }
  }
}
