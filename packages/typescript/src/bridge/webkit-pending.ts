/**
 * Shared WKWebView pending-response helper.
 *
 * The legacy WKWebView path uses `webkit.messageHandlers.craft.postMessage`,
 * which is one-way — the native side calls back into the page via
 * `window.__craftBridgeResolve(action, payload)` (or `__craftBridgeReject`).
 *
 * Before this helper, every API module (`api/dialog.ts`, `api/clipboard.ts`)
 * re-implemented the same `__craftBridgePending` queue and a number of others
 * (`api/window.ts`, `api/app.ts`) skipped it entirely and resolved with
 * `undefined`. Centralizing it here means:
 *
 *   - one place to enforce a default timeout (callers that "just call once"
 *     can't leak closures forever),
 *   - one place to expose the `__craftBridgeResolve`/`__craftBridgeReject`
 *     globals the native side needs (the legacy native bridge looks for these
 *     names, so they have to be declared on `window`),
 *   - one place to swap the implementation later without touching every API.
 */

const DEFAULT_TIMEOUT_MS = 30_000

interface PendingEntry<T> {
  resolve: (value: T) => void
  reject: (reason: unknown) => void
}

interface CraftBridgePendingHost {
  __craftBridgePending?: Record<string, Array<PendingEntry<any>>>
  __craftBridgeResolve?: (bucket: string, payload: unknown) => boolean
  __craftBridgeReject?: (bucket: string, error: unknown) => boolean
}

function host(): CraftBridgePendingHost | null {
  if (typeof window === 'undefined') return null
  return window as unknown as CraftBridgePendingHost
}

/**
 * Install the native-callable hooks (`window.__craftBridgeResolve` and
 * `window.__craftBridgeReject`) once. Idempotent — safe to call from every
 * helper that needs them.
 */
function ensureGlobalHooks(): void {
  const w = host()
  if (!w) return
  w.__craftBridgePending = w.__craftBridgePending || {}
  if (!w.__craftBridgeResolve) {
    w.__craftBridgeResolve = (bucket: string, payload: unknown) => {
      const list = w.__craftBridgePending![bucket]
      if (!list || list.length === 0) return false
      const entry = list.shift()!
      entry.resolve(payload)
      return true
    }
  }
  if (!w.__craftBridgeReject) {
    w.__craftBridgeReject = (bucket: string, error: unknown) => {
      const list = w.__craftBridgePending![bucket]
      if (!list || list.length === 0) return false
      const entry = list.shift()!
      entry.reject(error instanceof Error ? error : new Error(String(error)))
      return true
    }
  }
}

/**
 * Returns true when the page is running inside a WKWebView with a registered
 * `craft` message handler.
 */
export function isWebKitHost(): boolean {
  return typeof window !== 'undefined' && !!window.webkit?.messageHandlers?.craft
}

/** Desktop window handles use the injected Craft envelope on both WebKit and WebView2. */
export function isDesktopWebViewHost(): boolean {
  if (isWebKitHost()) return true
  if (typeof window === 'undefined') return false
  const host = window as Window & { chrome?: { webview?: { postMessage?: (message: unknown) => void } } }
  return typeof host.chrome?.webview?.postMessage === 'function'
}

/**
 * Send a fire-and-forget message into the WKWebView host. Returns true if
 * the message was delivered, false otherwise.
 */
export function postWebKit(message: unknown): boolean {
  if (!isWebKitHost()) return false
  window.webkit!.messageHandlers!.craft!.postMessage(message)
  return true
}

/**
 * Send a request via the WKWebView host and wait for the native side to
 * resolve it through `window.__craftBridgeResolve(bucket, payload)`. The
 * returned promise:
 *
 *   - rejects with `Error('No WKWebView host')` if the page isn't running
 *     inside a webview,
 *   - rejects with a timeout error after `timeoutMs` if the native side
 *     never replies (default 30s — match the bridge core's default),
 *   - cleans up its slot in the pending queue on settle / cancel so it can
 *     never leak the resolver closure.
 */
export function webkitRequest<T>(
  bucket: string,
  message: unknown,
  options: { timeoutMs?: number } = {},
): Promise<T> {
  if (!isWebKitHost()) {
    return Promise.reject(new Error('No WKWebView host'))
  }
  ensureGlobalHooks()
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const w = host()!
  return new Promise<T>((resolve, reject) => {
    let settled = false
    const list = (w.__craftBridgePending![bucket] = w.__craftBridgePending![bucket] || [])
    let timer: ReturnType<typeof setTimeout>
    const entry: PendingEntry<T> = {
      resolve: (v: T) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        const idx = list.indexOf(entry)
        if (idx >= 0) list.splice(idx, 1)
        resolve(v)
      },
      reject: (e: unknown) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        const idx = list.indexOf(entry)
        if (idx >= 0) list.splice(idx, 1)
        reject(e)
      },
    }
    list.push(entry)
    timer = setTimeout(() => {
      entry.reject(new Error(`[WKWebView] ${bucket} timed out after ${timeoutMs}ms`))
    }, timeoutMs)
    try {
      window.webkit!.messageHandlers!.craft!.postMessage(message)
    }
    catch (e) {
      entry.reject(e)
    }
  })
}

/**
 * Test helper: drain every queued promise and reject them with the given
 * error. Used by the test suite to assert that we don't leak closures.
 */
export function _drainPendingForTests(error: Error = new Error('drain')): number {
  const w = host()
  if (!w?.__craftBridgePending) return 0
  let count = 0
  for (const bucket of Object.keys(w.__craftBridgePending)) {
    const list = w.__craftBridgePending[bucket]
    while (list.length > 0) {
      const entry = list.shift()!
      entry.reject(error)
      count++
    }
  }
  return count
}
