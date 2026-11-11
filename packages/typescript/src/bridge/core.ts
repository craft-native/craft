/**
 * Craft Native Bridge Core
 * Bidirectional async communication, message queue, and type-safe protocols
 */

import { EventEmitter } from 'events'
import { secureUUID } from './ids.js'

// Ambient types for native bridges injected by the host. These globals are
// defined by WKWebView (iOS), Android WebView, Electron's contextBridge, and
// the WinRT `chrome.webview` object respectively. We don't import them — they
// just need to be known so we don't cast through `any` in the send path.
interface WkWebKitGlobal {
  messageHandlers?: {
    craft?: { postMessage(message: unknown): void }
  }
}
interface AndroidWebViewGlobal {
  postMessage(message: string): void
}
interface CraftIPCGlobal {
  send(channel: string, message: unknown): void
}
declare global {
  // eslint-disable-next-line vars-on-top
  interface Window {
    webkit?: WkWebKitGlobal
    CraftBridge?: AndroidWebViewGlobal
    craftIPC?: CraftIPCGlobal
  }
}

/**
 * Bridge error codes returned by the native layer.
 * Used in BridgeMessage.error.code field.
 */
export const BridgeErrorCodes = {
  /** Generic/unknown error */
  UNKNOWN: -1,
  /** Operation timed out waiting for native response */
  TIMEOUT: -2,
  /** Offline queue full, cannot enqueue more requests */
  QUEUE_FULL: -3,
  /** Binary transfer not enabled */
  BINARY_DISABLED: -4,
  /** Expected binary response but got non-binary */
  EXPECTED_BINARY: -5,
  /** Bridge destroyed while requests were pending */
  BRIDGE_DESTROYED: -6,
  /** Bridge in-flight request limit exceeded (backpressure) */
  BUSY: -7,
  /** Native side speaks an incompatible bridge protocol version */
  PROTOCOL_MISMATCH: -8,
  /** Bridge transitioned from connected to disconnected with requests in flight */
  DISCONNECTED: -9,
  /**
   * The native side received the request and refused or failed it. Not
   * retried: asking again gets the same answer. `data.nativeCode` carries
   * the bridge's own string code when it sent one.
   */
  NATIVE_ERROR: -10,
} as const

export type BridgeErrorCode = typeof BridgeErrorCodes[keyof typeof BridgeErrorCodes]

/**
 * Bridge wire-protocol version. Bumped when the message envelope changes in a
 * backwards-incompatible way. Native and SDK must agree, or the bridge will
 * reject the handshake with PROTOCOL_MISMATCH.
 */
export const BRIDGE_PROTOCOL_VERSION = 1

// Types
export interface BridgeMessage<T = unknown> {
  id: string
  type: 'request' | 'response' | 'event' | 'stream'
  method?: string
  params?: T
  result?: unknown
  error?: { code: number; message: string; data?: unknown }
  streamId?: string
  streamEvent?: 'data' | 'end' | 'error'
}

export interface BridgeConfig {
  timeout?: number
  retries?: number
  retryDelay?: number
  queueSize?: number
  batchSize?: number
  batchDelay?: number
  enableOfflineQueue?: boolean
  enableBinaryTransfer?: boolean
  /**
   * Maximum number of in-flight requests before new requests are rejected
   * with `BridgeErrorCodes.BUSY`. Prevents user code from DOSing the native
   * layer with tight loops. Defaults to 10_000.
   */
  maxConcurrentRequests?: number
  /**
   * Origin to use when the bridge falls back to `window.parent.postMessage`
   * (i.e. Craft is running inside a host iframe rather than a native
   * webview). Defaults to `null`, which **disables** the postMessage path
   * entirely — `'*'` was the old default and leaks bridge traffic to any
   * cross-origin parent. Set this to your host page's exact origin
   * (e.g. `'https://app.example.com'`) when embedding.
   */
  parentOrigin?: string | null
}

export interface StreamController<T> {
  onData(callback: (data: T) => void): void
  onEnd(callback: () => void): void
  onError(callback: (error: Error) => void): void
  cancel(): void
}

/**
 * Build a unique message ID. Each {@link NativeBridge} owns its own counter
 * (`#counter`) and a per-instance secret (`prefix`) derived from
 * {@link secureUUID}, so two bridges in the same process produce IDs from
 * fully-disjoint namespaces — there is no longer a module-level counter
 * that could leak state across bridges (e.g. between tests after a
 * `resetGlobalBridge()` call).
 */
function buildMessageId(prefix: string, counter: number): string {
  return `${prefix}_${Date.now().toString(36)}_${counter.toString(36)}`
}

// Native Bridge Core
export class NativeBridge extends EventEmitter {
  private config: Required<BridgeConfig>
  private pendingRequests = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: NodeJS.Timeout }>()
  private offlineQueue: BridgeMessage[] = []
  private connected = false
  private streams = new Map<string, { onData: (data: unknown) => void; onEnd: () => void; onError: (error: Error) => void }>()
  private batchBuffer: BridgeMessage[] = []
  private batchTimer: NodeJS.Timeout | null = null
  private destroyed = false
  // Per-instance ID prefix so two bridges in the same process can never
  // produce the same message ID even if they happen to construct on the
  // same millisecond. Derived from a secure UUID's first 8 hex chars
  // (32 bits of entropy, plenty for collision resistance across the
  // typically-tiny number of bridges in a session).
  private readonly idPrefix: string = `msg-${secureUUID().slice(0, 8)}`
  // Per-instance message counter, seeded with a random offset so attackers
  // can't predict outstanding ids by counting from zero.
  private idCounter: number = Math.floor(Math.random() * 1e9)
  private nextMessageId(): string {
    if (this.idCounter >= Number.MAX_SAFE_INTEGER - 1) {
      this.idCounter = Math.floor(Math.random() * 1e9)
    }
    this.idCounter++
    return buildMessageId(this.idPrefix, this.idCounter)
  }
  // Track DOM listeners so destroy() can remove them. Without this, tests
  // that construct/destroy NativeBridge in a loop accumulate craft-ready
  // and message listeners and exhaust the runtime's listener cap.
  // eslint-disable-next-line pickier/no-unused-vars
  private boundHandleMessage: ((event: MessageEvent | CustomEvent) => void) | null = null
  private craftReadyHandler: (() => void) | null = null

  constructor(config: BridgeConfig = {}) {
    super()
    // The default EventEmitter cap is 10. Real apps subscribe to many
    // bridge channels (`menu.click`, `component.event`, lifecycle, …)
    // plus internal ones; the cap fires "MaxListenersExceeded" warnings
    // long before there's a real leak. 100 is generous-but-bounded so a
    // genuine listener leak still surfaces.
    this.setMaxListeners(100)
    this.config = {
      timeout: 30000,
      retries: 3,
      retryDelay: 1000,
      queueSize: 1000,
      batchSize: 10,
      batchDelay: 50,
      enableOfflineQueue: true,
      enableBinaryTransfer: true,
      maxConcurrentRequests: 10000,
      parentOrigin: null,
      ...config,
    }
    this.setupBridge()
  }

  private setupBridge(): void {
    if (typeof window === 'undefined') return

    // Listen for messages from native. Bind once and store the reference so
    // destroy() can remove the listener cleanly.
    this.boundHandleMessage = this.handleMessage.bind(this)
    window.addEventListener('message', this.boundHandleMessage)
    window.addEventListener('craft-bridge-message' as any, this.boundHandleMessage)

    // Auto-connect when the host fires `craft:ready`. Without this, every
    // request sat in `offlineQueue` because nothing called setConnected().
    // Hosts that wire up the bridge synchronously (e.g. before the
    // injected JS dispatches craft:ready) can also detect the runtime
    // immediately via `window.craft`.
    if (window.craft) {
      // The runtime is already there — flip on the next microtask so
      // subscribers to `'connected'` have a chance to register first.
      Promise.resolve().then(() => this.setConnected(true))
    }
    else {
      this.craftReadyHandler = () => {
        if (this.craftReadyHandler) {
          window.removeEventListener('craft:ready' as any, this.craftReadyHandler)
          this.craftReadyHandler = null
        }
        this.setConnected(true)
      }
      // `once: true` is also defensive — if `craft:ready` fires twice we
      // still only flip once. The handler also self-removes on first run
      // so we don't depend on `once` semantics that older webviews lack.
      window.addEventListener('craft:ready' as any, this.craftReadyHandler, { once: true })
    }
  }

  private teardownBridgeListeners(): void {
    if (typeof window === 'undefined') return
    if (this.boundHandleMessage) {
      window.removeEventListener('message', this.boundHandleMessage)
      window.removeEventListener('craft-bridge-message' as any, this.boundHandleMessage)
      this.boundHandleMessage = null
    }
    if (this.craftReadyHandler) {
      window.removeEventListener('craft:ready' as any, this.craftReadyHandler)
      this.craftReadyHandler = null
    }
  }

  private handleMessage(event: MessageEvent | CustomEvent): void {
    let data: BridgeMessage
    try {
      data = 'detail' in event ? event.detail : typeof event.data === 'string' ? JSON.parse(event.data) : event.data
    }
catch (err) {
      console.warn('[Craft Bridge] Failed to parse message:', err)
      return
    }

    if (!data || !data.id) return

    // Drop responses whose id wasn't minted by THIS bridge instance. Without
    // this guard, a third-party script that can fire `craft-bridge-message`
    // events (anything on the same page, in dev) could resolve any
    // outstanding request by guessing the id. Stream/event ids aren't
    // generated by us in the same way, so they're left unrestricted.
    if (data.type === 'response' && !this.isOwnId(data.id)) {
      return
    }

    switch (data.type) {
      case 'response':
        this.handleResponse(data)
        break
      case 'event':
        this.handleEvent(data)
        break
      case 'stream':
        this.handleStream(data)
        break
    }
  }

  /** True when the given id starts with this bridge's per-instance prefix. */
  private isOwnId(id: string): boolean {
    return typeof id === 'string' && id.startsWith(`${this.idPrefix}_`)
  }

  private handleResponse(message: BridgeMessage): void {
    const pending = this.pendingRequests.get(message.id)
    if (!pending) return

    clearTimeout(pending.timeout)
    this.pendingRequests.delete(message.id)

    if (message.error) {
      pending.reject(new BridgeError(message.error.message, message.error.code, message.error.data))
    }
else {
      pending.resolve(message.result)
    }
  }

  private handleEvent(message: BridgeMessage): void {
    if (message.method) {
      this.emit(message.method, message.params)
    }
  }

  private handleStream(message: BridgeMessage): void {
    if (!message.streamId) return
    const stream = this.streams.get(message.streamId)
    if (!stream) return

    switch (message.streamEvent) {
      case 'data':
        stream.onData(message.result)
        break
      case 'end':
        stream.onEnd()
        this.streams.delete(message.streamId)
        break
      case 'error':
        stream.onError(new Error(message.error?.message || 'Stream error'))
        this.streams.delete(message.streamId)
        break
    }
  }

  /**
   * Send a request to native and wait for response
   */
  async request<T = unknown, R = unknown>(method: string, params?: T, options?: { timeout?: number }): Promise<R> {
    return this.requestWithRetry(method, params, this.config.retries, options?.timeout)
  }

  private async requestWithRetry<T, R>(method: string, params: T | undefined, retriesLeft: number, timeout?: number): Promise<R> {
    try {
      return await this.sendRequest<T, R>(method, params, timeout)
    }
catch (error) {
      if (retriesLeft > 0 && this.isRetryableError(error)) {
        await this.delay(this.config.retryDelay)
        return this.requestWithRetry(method, params, retriesLeft - 1, timeout)
      }
      throw error
    }
  }

  private isRetryableError(error: unknown): boolean {
    if (error instanceof BridgeError) {
      // Network errors, timeouts are retryable
      return error.code === BridgeErrorCodes.UNKNOWN || error.code === BridgeErrorCodes.TIMEOUT
    }
    return false
  }

  private async sendRequest<T, R>(method: string, params?: T, timeout?: number): Promise<R> {
    if (this.destroyed) {
      throw new BridgeError('Bridge destroyed', BridgeErrorCodes.BRIDGE_DESTROYED)
    }
    if (this.pendingRequests.size >= this.config.maxConcurrentRequests) {
      throw new BridgeError(
        `Bridge busy: ${this.pendingRequests.size} in-flight requests exceeds maxConcurrentRequests=${this.config.maxConcurrentRequests}`,
        BridgeErrorCodes.BUSY
      )
    }

    const effectiveTimeout = timeout ?? this.config.timeout
    const message: BridgeMessage<T> = {
      id: this.nextMessageId(),
      type: 'request',
      method,
      params,
    }

    if (!this.connected && this.config.enableOfflineQueue) {
      if (this.offlineQueue.length >= this.config.queueSize) {
        throw new BridgeError('Offline queue full', BridgeErrorCodes.QUEUE_FULL)
      }
      this.offlineQueue.push(message)
      // Return a promise that will be resolved when connected. Mirror the
      // online timeout so requests that never connect are rejected rather
      // than leaking forever — and remove from offlineQueue too so a late
      // reconnect doesn't deliver to a dead request.
      return new Promise((resolve, reject) => {
        this.pendingRequests.set(message.id, {
          resolve: resolve as (value: unknown) => void,
          reject,
          timeout: setTimeout(() => {
            this.pendingRequests.delete(message.id)
            const idx = this.offlineQueue.findIndex(m => m.id === message.id)
            if (idx >= 0) this.offlineQueue.splice(idx, 1)
            reject(new BridgeError('Request timeout (offline)', BridgeErrorCodes.TIMEOUT))
          }, effectiveTimeout),
        })
      })
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingRequests.delete(message.id)
        reject(new BridgeError('Request timeout', BridgeErrorCodes.TIMEOUT))
      }, effectiveTimeout)

      this.pendingRequests.set(message.id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timeout: timer,
      })

      // Fail fast when no transport is wired (plain `bun build` / Vite dev
      // without a Craft host). Otherwise the caller waits the full timeout
      // for a request that was never delivered.
      if (!this.send(message)) {
        clearTimeout(timer)
        this.pendingRequests.delete(message.id)
        reject(new BridgeError(
          'No bridge transport available — not running inside a Craft host',
          BridgeErrorCodes.UNKNOWN,
        ))
      }
    })
  }

  /**
   * Negotiate the wire-protocol version with the native layer. Throws
   * BridgeError(PROTOCOL_MISMATCH) if the native side reports a version we
   * don't speak.
   *
   * This is **opt-in** — you must call it explicitly, and only against a
   * host of your own that answers a `_handshake` request. Craft's own
   * webview hosts do not: inside one, requests go through
   * `window.craft.invoke`, which takes `namespace.action` names, and this
   * call is rejected immediately instead of negotiating anything. Use
   * `window.craft.capabilities` to ask a Craft host what it serves.
   */
  async handshake(): Promise<{ nativeVersion: number }> {
    const result = await this.request<{ sdkVersion: number }, { version: number }>(
      '_handshake',
      { sdkVersion: BRIDGE_PROTOCOL_VERSION }
    )
    if (result?.version !== BRIDGE_PROTOCOL_VERSION) {
      throw new BridgeError(
        `Bridge protocol mismatch: SDK speaks v${BRIDGE_PROTOCOL_VERSION}, native speaks v${result?.version ?? 'unknown'}`,
        BridgeErrorCodes.PROTOCOL_MISMATCH
      )
    }
    return { nativeVersion: result.version }
  }

  /**
   * Send a fire-and-forget message (no response expected)
   */
  notify<T = unknown>(method: string, params?: T): void {
    const message: BridgeMessage<T> = {
      id: this.nextMessageId(),
      type: 'request',
      method,
      params,
    }
    this.send(message)
  }

  /**
   * Create a stream for receiving multiple responses.
   *
   * @param method - native method name
   * @param params - method params
   * @param options.bufferLimit - max events buffered before consumer registers
   *   `onData`. Once exceeded the stream is failed with `BUFFER_OVERFLOW`
   *   instead of growing indefinitely. Defaults to 1000.
   */
  stream<T = unknown>(
    method: string,
    params?: unknown,
    options?: { bufferLimit?: number },
  ): StreamController<T> {
    const bufferLimit = options?.bufferLimit ?? 1000
    const streamId = this.nextMessageId()
    const message: BridgeMessage = {
      id: this.nextMessageId(),
      type: 'request',
      method,
      params,
      streamId,
    }

    // Buffer events received before the consumer registers callbacks, so we
    // don't silently drop them (previous implementation used no-op stubs).
    const pendingData: T[] = []
    let ended = false
    let pendingError: Error | undefined
    let cancelled = false
    // eslint-disable-next-line pickier/no-unused-vars
    let dataCallback: ((data: T) => void) | null = null
    let endCallback: (() => void) | null = null
    // eslint-disable-next-line pickier/no-unused-vars
    let errorCallback: ((error: Error) => void) | null = null

    const controller: StreamController<T> = {
      onData: (cb) => {
        dataCallback = cb
        // Flush any buffered events. Honor the `ended` and `pendingError`
        // flags AFTER the buffer drains so consumers see the full event
        // history before the terminal signal — otherwise a fast end can
        // race the buffered data and the consumer thinks the stream
        // finished empty.
        while (pendingData.length > 0) {
          cb(pendingData.shift() as T)
        }
      },
      onEnd: (cb) => {
        endCallback = cb
        if (ended) cb()
      },
      onError: (cb) => {
        errorCallback = cb
        if (pendingError) cb(pendingError)
      },
      cancel: () => {
        // Idempotent: a second cancel() must not delete a stream that's
        // already gone or fire a duplicate `_cancelStream` to native.
        if (cancelled) return
        cancelled = true
        if (!this.streams.has(streamId)) return
        this.streams.delete(streamId)
        this.send({
          id: this.nextMessageId(),
          type: 'request',
          method: '_cancelStream',
          params: { streamId },
        })
      },
    }

    this.streams.set(streamId, {
      onData: (data) => {
        if (dataCallback) {
          dataCallback(data as T)
          return
        }
        if (pendingData.length >= bufferLimit) {
          // Don't grow forever — fail the stream instead. Set pendingError
          // so a late onError handler still sees it.
          const overflow = new BridgeError(
            `Stream buffer overflow: ${pendingData.length} events buffered with no consumer (limit=${bufferLimit})`,
            BridgeErrorCodes.BUSY,
          )
          pendingError = overflow
          if (errorCallback) errorCallback(overflow)
          this.streams.delete(streamId)
          // Tell the native side to stop producing — without this, the
          // peer keeps sending events into the dropped stream forever.
          this.send({
            id: this.nextMessageId(),
            type: 'request',
            method: '_cancelStream',
            params: { streamId },
          })
          return
        }
        pendingData.push(data as T)
      },
      onEnd: () => {
        ended = true
        if (endCallback) endCallback()
      },
      onError: (error) => {
        pendingError = error
        if (errorCallback) errorCallback(error)
      },
    })

    this.send(message)
    return controller
  }

  /**
   * Send binary data to native
   */
  async sendBinary(method: string, data: ArrayBuffer | Uint8Array): Promise<void> {
    if (!this.config.enableBinaryTransfer) {
      throw new BridgeError('Binary transfer not enabled', BridgeErrorCodes.BINARY_DISABLED)
    }

    const base64 = this.arrayBufferToBase64(data instanceof ArrayBuffer ? new Uint8Array(data) : data)
    await this.request(method, { _binary: true, data: base64 })
  }

  /**
   * Receive binary data from native
   */
  async receiveBinary(method: string, params?: unknown): Promise<ArrayBuffer> {
    if (!this.config.enableBinaryTransfer) {
      throw new BridgeError('Binary transfer not enabled', BridgeErrorCodes.BINARY_DISABLED)
    }

    const result = await this.request<unknown, { _binary: boolean; data: string }>(method, params)
    if (result._binary) {
      return this.base64ToArrayBuffer(result.data)
    }
    throw new BridgeError('Expected binary response', BridgeErrorCodes.EXPECTED_BINARY)
  }

  /**
   * Batch multiple requests
   */
  async batch<T extends Array<{ method: string; params?: unknown }>>(
    requests: T
  ): Promise<Array<{ result?: unknown; error?: { code: number; message: string } }>> {
    return this.request('_batch', { requests })
  }

  /**
   * Add request to batch buffer (auto-flushed)
   */
  addToBatch<T = unknown>(method: string, params?: T): void {
    this.batchBuffer.push({
      id: this.nextMessageId(),
      type: 'request',
      method,
      params,
    })

    if (this.batchBuffer.length >= this.config.batchSize) {
      this.flushBatch()
    }
else if (!this.batchTimer) {
      this.batchTimer = setTimeout(() => this.flushBatch(), this.config.batchDelay)
    }
  }

  private flushBatch(): void {
    if (this.batchTimer) {
      clearTimeout(this.batchTimer)
      this.batchTimer = null
    }

    // Drop any buffered work if destroy() ran between schedule and flush — the
    // bridge is gone, the native side won't reply, and emitting would resurrect
    // listeners we just torn down.
    if (this.destroyed) {
      this.batchBuffer = []
      return
    }

    if (this.batchBuffer.length === 0) return

    const batch = this.batchBuffer
    this.batchBuffer = []

    // If we lost connection between scheduling the batch and flushing it,
    // re-queue the messages onto the offline queue (when enabled) instead
    // of dropping them on the floor of `send()` — otherwise the
    // fire-and-forget `addToBatch()` path silently loses every request
    // sent during a transient disconnect.
    if (!this.connected) {
      if (this.config.enableOfflineQueue) {
        for (const msg of batch) {
          if (this.offlineQueue.length >= this.config.queueSize) break
          this.offlineQueue.push(msg)
        }
      }
      return
    }

    // Match the shape used by `batch()` above so the native side has a single
    // batch envelope format to parse. Previously `{ messages }` and `{ requests }`
    // diverged and the buffered path silently broke on the native side.
    this.send({
      id: this.nextMessageId(),
      type: 'request',
      method: '_batch',
      params: { requests: batch },
    })
  }

  /**
   * Set connection status. Emits `'connected'` / `'disconnected'`. On
   * disconnect, every outstanding pending request is rejected with
   * `BridgeErrorCodes.DISCONNECTED` immediately — previously they sat
   * until `timeout` (default 30s) expired, hanging the calling app.
   */
  setConnected(connected: boolean): void {
    const wasConnected = this.connected
    this.connected = connected

    if (connected && !wasConnected) {
      this.emit('connected')
      this.flushOfflineQueue()
    }
    else if (!connected && wasConnected) {
      this.emit('disconnected')
      // Reject pending requests so callers can retry/back off rather than
      // wait for the per-request timeout to fire.
      for (const [id, pending] of this.pendingRequests) {
        clearTimeout(pending.timeout)
        pending.reject(new BridgeError('Bridge disconnected', BridgeErrorCodes.DISCONNECTED))
        this.pendingRequests.delete(id)
      }
    }
  }

  private flushOfflineQueue(): void {
    const queue = this.offlineQueue
    this.offlineQueue = []
    for (const message of queue) {
      this.send(message)
    }
  }

  /**
   * Dispatch a message to whichever native transport is available. Returns
   * `true` when the message was handed off to a transport, `false` when no
   * transport could be found — the caller (only `sendRequest` cares) can
   * use that to fail fast instead of waiting for the request timeout.
   */
  private send(message: BridgeMessage): boolean {
    let json: string
    try {
      json = JSON.stringify(message)
    }
    catch (e) {
      // The most common cause is a circular params payload. Reject the
      // matching pending request synchronously so the caller doesn't
      // wait the full timeout for a message we never managed to send.
      this.failPendingForMessage(message, new BridgeError(
        `Failed to serialize bridge message: ${(e as Error).message}`,
        BridgeErrorCodes.UNKNOWN,
        { originalError: String(e) },
      ))
      return false
    }

    try {
      if (typeof window !== 'undefined') {
        // Craft's own page bridge. Every Craft webview has it, and it is the
        // only thing the native dispatcher answers, so a request goes
        // through it whenever it is there.
        if (message.type === 'request' && this.sendThroughInjectedBridge(message)) {
          return true
        }

        // iOS WKWebView
        if (window.webkit?.messageHandlers?.craft) {
          window.webkit.messageHandlers.craft.postMessage(message)
          return true
        }

        // Android WebView
        if (window.CraftBridge) {
          window.CraftBridge.postMessage(json)
          return true
        }

        // Electron IPC
        if (window.craftIPC) {
          window.craftIPC.send('bridge-message', message)
          return true
        }

        // Generic postMessage. Only enabled when the host explicitly opts in
        // via `BridgeConfig.parentOrigin`; previously this used `'*'`, which
        // broadcasts every native call to whatever cross-origin frame is
        // hosting Craft.
        if (window.parent !== window && this.config.parentOrigin) {
          window.parent.postMessage(message, this.config.parentOrigin)
          return true
        }
      }

      // Node.js (for testing)
      if (typeof process !== 'undefined' && typeof (process as { send?: (m: unknown) => void }).send === 'function') {
        ;(process as { send: (m: unknown) => void }).send(message)
        return true
      }

      return false
    }
    catch (e) {
      // postMessage can throw DataCloneError on un-cloneable values even
      // when JSON.stringify would have succeeded (e.g. functions, DOM
      // nodes). Fail the matching pending entry rather than letting the
      // exception escape into the caller's microtask.
      this.failPendingForMessage(message, new BridgeError(
        `Bridge transport rejected the message: ${(e as Error).message}`,
        BridgeErrorCodes.UNKNOWN,
      ))
      return false
    }
  }

  /**
   * Hand a request to `window.craft.invoke`, the dispatcher that
   * `craft-bridge.js` injects into every Craft webview, and settle the
   * pending entry with what native answers.
   *
   * This is the only path by which `request()` reaches native code. The
   * `{id, type: 'request', method, params}` envelope this class builds is not
   * something any Craft host parses: posted raw to the `craft` message
   * handler it was dropped, and every `request()` waited out its timeout and
   * its retries. The method name is used as written, `namespace.action`, so
   * it has to be one the native bridge serves (`fs.readFile`,
   * `shell.openUrl`, `dialog.openFile`); one it does not serve is rejected
   * with `NATIVE_ERROR` straight away.
   *
   * Returns false when the injected bridge is not present, so the older
   * transports below still get their turn in a host that provides one.
   */
  private sendThroughInjectedBridge(message: BridgeMessage): boolean {
    const injected = (window as { craft?: { invoke?: (method: string, params?: unknown) => Promise<unknown> } }).craft
    if (!injected || typeof injected.invoke !== 'function' || typeof message.method !== 'string') return false

    let call: Promise<unknown>
    try {
      call = Promise.resolve(injected.invoke(message.method, message.params))
    }
    catch (e) {
      call = Promise.reject(e)
    }
    call.then(
      result => this.handleResponse({ id: message.id, type: 'response', result }),
      (error: unknown) => {
        const detail = (error ?? {}) as { code?: unknown, message?: unknown }
        const text = typeof detail.message === 'string' && detail.message.length > 0
          ? detail.message
          : `Native bridge refused ${message.method}`
        this.handleResponse({
          id: message.id,
          type: 'response',
          error: {
            code: BridgeErrorCodes.NATIVE_ERROR,
            message: text,
            data: { nativeCode: typeof detail.code === 'string' ? detail.code : undefined, method: message.method },
          },
        })
      },
    )
    return true
  }

  /**
   * Reject the pending entry corresponding to `message.id` with `error`,
   * if any. Used by `send()` when serialization or transport throws so
   * the caller's promise rejects immediately.
   */
  private failPendingForMessage(message: BridgeMessage, error: BridgeError): void {
    const pending = this.pendingRequests.get(message.id)
    if (!pending) return
    clearTimeout(pending.timeout)
    this.pendingRequests.delete(message.id)
    pending.reject(error)
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  private arrayBufferToBase64(buffer: Uint8Array): string {
    const chunks: string[] = []
    const chunkSize = 8192
    for (let i = 0; i < buffer.byteLength; i += chunkSize) {
      chunks.push(String.fromCharCode(...buffer.subarray(i, i + chunkSize)))
    }
    return btoa(chunks.join(''))
  }

  private base64ToArrayBuffer(base64: string): ArrayBuffer {
    const binary = atob(base64)
    const buffer = new ArrayBuffer(binary.length)
    const bytes = new Uint8Array(buffer)
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i)
    }
    return buffer
  }

  /**
   * Destroy the bridge. Idempotent.
   */
  destroy(): void {
    if (this.destroyed) return
    this.destroyed = true

    // Clear all pending requests
    for (const [, pending] of this.pendingRequests) {
      clearTimeout(pending.timeout)
      pending.reject(new BridgeError('Bridge destroyed', BridgeErrorCodes.BRIDGE_DESTROYED))
    }
    this.pendingRequests.clear()
    this.streams.clear()
    this.offlineQueue = []
    this.batchBuffer = []
    if (this.batchTimer) {
      clearTimeout(this.batchTimer)
      this.batchTimer = null
    }
    this.teardownBridgeListeners()
    this.removeAllListeners()
  }
}

// Bridge Error
export class BridgeError extends Error {
  code: number
  data?: unknown

  constructor(message: string, code: number, data?: unknown) {
    super(message)
    this.name = 'BridgeError'
    this.code = code
    this.data = data
  }
}

// Type-safe Bridge Protocol Generator
export interface BridgeMethod<P = void, R = void> {
  method: string
  params: P
  result: R
}

export type InferParams<T> = T extends BridgeMethod<infer P, unknown> ? P : never
export type InferResult<T> = T extends BridgeMethod<unknown, infer R> ? R : never

export function createTypedBridge<T extends Record<string, BridgeMethod<any, any>>>(bridge: NativeBridge) {
  return new Proxy(
    {},
    {
      get(_, method: string) {
        return (params?: unknown) => bridge.request(method, params)
      },
    }
  ) as {
    [K in keyof T]: (params: InferParams<T[K]>) => Promise<InferResult<T[K]>>
  }
}

// There is deliberately no menu class here. The application menu bar is a
// fire-and-forget action bridge (`menu` / `setAppMenu`), not a request/response
// method, and it is reached through the injected `window.craft.menu` — see
// packages/zig/src/js/craft-bridge.js and its types in
// packages/zig/types/craft-bridge.d.ts. A `NativeMenus` class used to sit here
// calling `bridge.request('menu.setApplicationMenu')`, a transport no zig
// handler serves; nothing noticed because `bridge/core` is not re-exported from
// the package index, so it was unreachable through the public API either way.

// Native Dialogs
export interface OpenDialogOptions {
  title?: string
  defaultPath?: string
  buttonLabel?: string
  filters?: Array<{ name: string; extensions: string[] }>
  properties?: Array<'openFile' | 'openDirectory' | 'multiSelections' | 'showHiddenFiles' | 'createDirectory' | 'promptToCreate' | 'noResolveAliases' | 'treatPackageAsDirectory' | 'dontAddToRecent'>
  message?: string
}

export interface SaveDialogOptions {
  title?: string
  defaultPath?: string
  buttonLabel?: string
  filters?: Array<{ name: string; extensions: string[] }>
  properties?: Array<'showHiddenFiles' | 'createDirectory' | 'showOverwriteConfirmation' | 'dontAddToRecent'>
  message?: string
  nameFieldLabel?: string
  showsTagField?: boolean
}

export interface MessageBoxOptions {
  type?: 'none' | 'info' | 'error' | 'question' | 'warning'
  buttons?: string[]
  defaultId?: number
  cancelId?: number
  title?: string
  message: string
  detail?: string
  checkboxLabel?: string
  checkboxChecked?: boolean
  icon?: string
}

export class NativeDialogs {
  constructor(private bridge: NativeBridge) {}

  /**
   * Show open file dialog
   */
  async showOpenDialog(options: OpenDialogOptions = {}): Promise<{ canceled: boolean; filePaths: string[] }> {
    return this.bridge.request('dialog.showOpenDialog', options)
  }

  /**
   * Show save file dialog
   */
  async showSaveDialog(options: SaveDialogOptions = {}): Promise<{ canceled: boolean; filePath?: string }> {
    return this.bridge.request('dialog.showSaveDialog', options)
  }

  /**
   * Show message box
   */
  async showMessageBox(options: MessageBoxOptions): Promise<{ response: number; checkboxChecked?: boolean }> {
    return this.bridge.request('dialog.showMessageBox', options)
  }

  /**
   * Show error box
   */
  async showErrorBox(title: string, content: string): Promise<void> {
    await this.bridge.request('dialog.showErrorBox', { title, content })
  }

  /**
   * Show color picker
   */
  async showColorPicker(options?: { defaultColor?: string; title?: string }): Promise<string | null> {
    return this.bridge.request('dialog.showColorPicker', options || {})
  }

  /**
   * Show font picker
   */
  async showFontPicker(options?: { defaultFont?: { family: string; size: number }; title?: string }): Promise<{ family: string; size: number } | null> {
    return this.bridge.request('dialog.showFontPicker', options || {})
  }
}

// Native Component Bridge
export interface NativeComponent {
  id: string
  type: string
  props: Record<string, unknown>
}

export class NativeComponentBridge {
  private components = new Map<string, NativeComponent>()

  constructor(private bridge: NativeBridge) {
    this.bridge.on('component.event', this.handleComponentEvent.bind(this))
  }

  private handleComponentEvent(event: { componentId: string; eventType: string; data: unknown }): void {
    const component = this.components.get(event.componentId)
    if (component) {
      this.bridge.emit(`component:${event.componentId}:${event.eventType}`, event.data)
    }
  }

  /**
   * Create a native sidebar
   */
  async createSidebar(config: {
    width?: number
    minWidth?: number
    maxWidth?: number
    position?: 'left' | 'right'
    collapsible?: boolean
    collapsed?: boolean
    variant?: 'tahoe' | 'vibrancy' | 'solid' | 'transparent' | 'workspace' | 'desktop'
    material?: 'auto' | 'sidebar' | 'hud' | 'popover' | 'content'
    backgroundEffect?: 'none' | 'vibrancy' | 'shimmer'
    allowsVibrancy?: boolean
    materialOpacity?: number
    materialDarkOpacity?: number
    sections?: Array<{
      id: string
      label?: string
      title?: string
      items?: Array<{
        id: string
        label: string
        icon?: string
        href?: string
        badge?: string | number
      }>
    }>
  }): Promise<string> {
    const id = await this.bridge.request<typeof config, string>('component.createSidebar', config)
    this.components.set(id, { id, type: 'sidebar', props: config })
    return id
  }

  /**
   * Create a native file browser
   */
  async createFileBrowser(config: {
    rootPath?: string
    showHidden?: boolean
    selectionMode?: 'single' | 'multiple'
    fileFilter?: Array<{ name: string; extensions: string[] }>
  }): Promise<string> {
    const id = await this.bridge.request<typeof config, string>('component.createFileBrowser', config)
    this.components.set(id, { id, type: 'fileBrowser', props: config })
    return id
  }

  /**
   * Create a native split view
   */
  async createSplitView(config: {
    orientation?: 'horizontal' | 'vertical'
    dividerStyle?: 'thin' | 'thick' | 'paneSplitter'
    initialPosition?: number
    minPositions?: [number, number]
  }): Promise<string> {
    const id = await this.bridge.request<typeof config, string>('component.createSplitView', config)
    this.components.set(id, { id, type: 'splitView', props: config })
    return id
  }

  /**
   * Update component props
   */
  async updateComponent(componentId: string, props: Record<string, unknown>): Promise<void> {
    const component = this.components.get(componentId)
    if (component) {
      component.props = { ...component.props, ...props }
    }
    await this.bridge.request('component.update', { componentId, props })
  }

  /**
   * Destroy component
   */
  async destroyComponent(componentId: string): Promise<void> {
    this.components.delete(componentId)
    await this.bridge.request('component.destroy', { componentId })
  }

  /**
   * Listen for component events
   */
  onComponentEvent(componentId: string, eventType: string, callback: (data: unknown) => void): () => void {
    const eventName = `component:${componentId}:${eventType}`
    this.bridge.on(eventName, callback)
    return () => this.bridge.off(eventName, callback)
  }

  /**
   * Get selection from file browser
   */
  async getFileBrowserSelection(componentId: string): Promise<string[]> {
    return this.bridge.request('component.getFileBrowserSelection', { componentId })
  }
}

// Global bridge instance
let globalBridge: NativeBridge | null = null
let globalBridgeConfig: BridgeConfig | null = null

/**
 * Get the process-wide singleton bridge, constructing it on first call.
 *
 * **Caveats for multi-window apps:**
 *   - The first caller's `config` wins; later calls receive the existing
 *     instance regardless of the config they pass — and we now log a
 *     `console.warn` when a follow-up caller passes a config that differs
 *     from the original (so silently-discarded configs are at least
 *     visible during development).
 *   - Calling `destroy()` on the returned bridge tears down state for
 *     every consumer, not just the caller.
 *
 * If your app opens more than one window or test harness, prefer
 * {@link createBridge} to create independent instances and pass them
 * explicitly to the components that need them.
 */
export function getBridge(config?: BridgeConfig): NativeBridge {
  if (!globalBridge) {
    globalBridge = new NativeBridge(config)
    globalBridgeConfig = config ?? null
    return globalBridge
  }
  if (config && globalBridgeConfig && !shallowConfigEqual(config, globalBridgeConfig)) {
    console.warn(
      '[Craft Bridge] getBridge() ignored a follow-up config that differs from the '
      + 'original — the singleton was already constructed. Use createBridge() for '
      + 'independent instances, or call resetGlobalBridge() first.',
    )
  }
  else if (config && !globalBridgeConfig) {
    console.warn(
      '[Craft Bridge] getBridge() ignored a follow-up config — singleton already '
      + 'exists with no recorded config. Use createBridge() for independent instances.',
    )
  }
  return globalBridge
}

function shallowConfigEqual(a: BridgeConfig, b: BridgeConfig): boolean {
  const keys = new Set<keyof BridgeConfig>([
    ...(Object.keys(a) as Array<keyof BridgeConfig>),
    ...(Object.keys(b) as Array<keyof BridgeConfig>),
  ])
  for (const k of keys) {
    if (a[k] !== b[k]) return false
  }
  return true
}

/**
 * Create an independent bridge instance. Use this in multi-window apps and
 * tests where the singleton from {@link getBridge} would cause two callers
 * to share state.
 */
export function createBridge(config?: BridgeConfig): NativeBridge {
  return new NativeBridge(config)
}

/**
 * Reset the global bridge. Intended for tests that need to start from a
 * known state — call `destroy()` on the previous instance first if you
 * created any pending work.
 */
export function resetGlobalBridge(): void {
  globalBridge = null
  globalBridgeConfig = null
}

// Export convenience instances
export function getDialogs(): NativeDialogs {
  return new NativeDialogs(getBridge())
}

export function getComponents(): NativeComponentBridge {
  return new NativeComponentBridge(getBridge())
}

const bridgeCore: {
  NativeBridge: typeof NativeBridge
  BridgeError: typeof BridgeError
  BridgeErrorCodes: typeof BridgeErrorCodes
  createTypedBridge: typeof createTypedBridge
  NativeDialogs: typeof NativeDialogs
  NativeComponentBridge: typeof NativeComponentBridge
  getBridge: typeof getBridge
  createBridge: typeof createBridge
  getDialogs: typeof getDialogs
  getComponents: typeof getComponents
} = {
  NativeBridge,
  BridgeError,
  BridgeErrorCodes,
  createTypedBridge,
  NativeDialogs,
  NativeComponentBridge,
  getBridge,
  createBridge,
  getDialogs,
  getComponents,
}

export default bridgeCore
