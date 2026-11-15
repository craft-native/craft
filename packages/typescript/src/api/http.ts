/**
 * Craft HTTP Client API
 * Provides native HTTP client through the Craft bridge
 * Bypasses CORS restrictions when running in Craft
 */

import type { CraftHttpAPI } from '../types.js'

/**
 * Result of {@link encodeRequestBody}. `kind` lets the caller decide
 * whether to default a `Content-Type: application/json` header.
 */
type EncodedBody =
  | { kind: 'none'; value: undefined }
  | { kind: 'string'; value: string }
  | { kind: 'binary'; value: BodyInit }
  | { kind: 'form'; value: BodyInit }
  | { kind: 'json'; value: string }

/**
 * Translate a user-supplied body into something `fetch()` knows how to
 * send, without losing fidelity. The previous implementation collapsed
 * everything object-shaped through `JSON.stringify`, which produced
 * `"[object FormData]"` for FormData/URLSearchParams/Blob/Uint8Array.
 *
 * The mapping:
 *   - `undefined` / `null`         → `{ kind: 'none' }`
 *   - `string`                     → `{ kind: 'string' }` (no auto C-T)
 *   - `ArrayBuffer` / TypedArray   → `{ kind: 'binary' }`
 *   - `Blob` / `File`              → `{ kind: 'binary' }` (preserves type)
 *   - `FormData`                   → `{ kind: 'form' }` (browser sets boundary)
 *   - `URLSearchParams`            → `{ kind: 'form' }` (forces x-www-form-urlencoded)
 *   - `ReadableStream`             → `{ kind: 'binary' }`
 *   - everything else              → JSON.stringify
 */
export function encodeRequestBody(body: unknown): EncodedBody {
  if (body === undefined || body === null) return { kind: 'none', value: undefined }
  if (typeof body === 'string') return { kind: 'string', value: body }
  // Binary-ish types pass through unchanged.
  if (body instanceof ArrayBuffer) return { kind: 'binary', value: body }
  if (ArrayBuffer.isView(body)) return { kind: 'binary', value: body as ArrayBufferView as BodyInit }
  if (typeof Blob !== 'undefined' && body instanceof Blob) {
    return { kind: 'binary', value: body }
  }
  if (typeof FormData !== 'undefined' && body instanceof FormData) {
    return { kind: 'form', value: body }
  }
  if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
    return { kind: 'form', value: body }
  }
  if (typeof ReadableStream !== 'undefined' && body instanceof ReadableStream) {
    return { kind: 'binary', value: body as unknown as BodyInit }
  }
  // Node's `fetch` (undici) accepts AsyncIterable<Uint8Array> as a body
  // for streaming uploads. Detecting Symbol.asyncIterator covers both
  // user generators and `Readable.toWeb()` outputs without misrouting
  // them through JSON. Browsers will still reject AsyncIterable bodies
  // at the fetch layer, where the error is the runtime's to surface.
  if (
    body !== null
    && typeof body === 'object'
    && (body as { [Symbol.asyncIterator]?: unknown })[Symbol.asyncIterator] !== undefined
  ) {
    return { kind: 'binary', value: body as unknown as BodyInit }
  }
  // Plain object / array → JSON.
  return { kind: 'json', value: JSON.stringify(body) }
}

/**
 * Case-insensitive lookup against an HTTP header object. Returns true when
 * any key with the same lowercased name is present. Does NOT use the
 * `Headers` global directly because callers pass plain objects.
 */
export function hasHeader(headers: Record<string, string>, name: string): boolean {
  const want = name.toLowerCase()
  for (const k of Object.keys(headers)) {
    if (k.toLowerCase() === want) return true
  }
  return false
}

/**
 * HTTP API implementation
 * Uses native HTTP client through the Craft bridge
 */
export const http: CraftHttpAPI = {
  /**
   * Fetch resource (CORS-free in Craft environment)
   */
  async fetch(url: string, options?: RequestInit): Promise<Response> {
    if (typeof window !== 'undefined' && window.craft?.http) {
      return window.craft.http.fetch(url, options)
    }
    // Browser/Node fallback
    return globalThis.fetch(url, options)
  },

  /**
   * Download file with progress tracking. The progress callback is detached
   * (replaced with a no-op) once the underlying bridge promise settles, so
   * a lingering native reference doesn't pin caller closures forever.
   */
  async download(
    url: string,
    destination: string,
    onProgress?: (progress: { loaded: number; total: number }) => void
  ): Promise<void> {
    if (typeof window !== 'undefined' && window.craft?.http) {
      let active: typeof onProgress = onProgress
      const wrapper = onProgress
        ? (p: { loaded: number; total: number }) => active?.(p)
        : undefined
      try {
        return await window.craft.http.download(url, destination, wrapper)
      }
      finally {
        active = undefined // detach
      }
    }
    throw new Error('Download API requires Craft environment')
  },

  /**
   * Upload file with progress tracking. See `download` for the
   * callback-detachment contract.
   */
  async upload(
    url: string,
    filePath: string,
    onProgress?: (progress: { loaded: number; total: number }) => void
  ): Promise<Response> {
    if (typeof window !== 'undefined' && window.craft?.http) {
      let active: typeof onProgress = onProgress
      const wrapper = onProgress
        ? (p: { loaded: number; total: number }) => active?.(p)
        : undefined
      try {
        return await window.craft.http.upload(url, filePath, wrapper)
      }
      finally {
        active = undefined
      }
    }
    throw new Error('Upload API requires Craft environment')
  }
}

/**
 * Extended HTTP client with additional features
 */
export class HttpClient {
  private baseUrl: string
  private defaultHeaders: Record<string, string>
  private timeout: number

  constructor(options: HttpClientOptions = {}) {
    this.baseUrl = options.baseUrl || ''
    this.defaultHeaders = options.headers || {}
    this.timeout = options.timeout || 30000
  }

  /**
   * Make GET request
   */
  async get<T = unknown>(path: string, options?: RequestOptions): Promise<HttpResponse<T>> {
    return this.request<T>('GET', path, options)
  }

  /**
   * Make POST request
   */
  async post<T = unknown>(path: string, body?: unknown, options?: RequestOptions): Promise<HttpResponse<T>> {
    return this.request<T>('POST', path, { ...options, body })
  }

  /**
   * Make PUT request
   */
  async put<T = unknown>(path: string, body?: unknown, options?: RequestOptions): Promise<HttpResponse<T>> {
    return this.request<T>('PUT', path, { ...options, body })
  }

  /**
   * Make PATCH request
   */
  async patch<T = unknown>(path: string, body?: unknown, options?: RequestOptions): Promise<HttpResponse<T>> {
    return this.request<T>('PATCH', path, { ...options, body })
  }

  /**
   * Make DELETE request
   */
  async delete<T = unknown>(path: string, options?: RequestOptions): Promise<HttpResponse<T>> {
    return this.request<T>('DELETE', path, options)
  }

  /**
   * Make HEAD request
   */
  async head(path: string, options?: RequestOptions): Promise<HttpResponse<void>> {
    return this.request<void>('HEAD', path, options)
  }

  /**
   * General request method
   */
  private async request<T>(
    method: string,
    path: string,
    options: RequestOptions = {}
  ): Promise<HttpResponse<T>> {
    const url = this.buildUrl(path, options.params)
    const headers = { ...this.defaultHeaders, ...options.headers }

    // Encode the body once and only set Content-Type for JSON bodies that
    // didn't already have one. The previous version used a case-sensitive
    // `'Content-Type' in headers` check (so a caller-supplied
    // `'content-type'` was missed and a duplicate header appeared) and
    // JSON.stringify'd anything object-shaped — silently turning
    // FormData/URLSearchParams/Uint8Array/Blob into useless
    // `"[object Foo]"` strings.
    const encoded = encodeRequestBody(options.body)
    if (encoded.kind === 'json' && !hasHeader(headers, 'content-type')) {
      headers['Content-Type'] = 'application/json'
    }

    const effectiveTimeout = options.timeout || this.timeout
    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), effectiveTimeout)

    try {
      // Forward the timeout to the native bridge as well — when the request
      // is dispatched through the Craft host, the host has no signal-aware
      // way to short-circuit a hung socket unless we tell it the deadline.
      // The custom `timeoutMs` property is ignored by browsers and
      // `globalThis.fetch` (it's not part of the WHATWG Fetch RequestInit
      // type), so this is purely a Craft-host hint and a no-op everywhere
      // else — no polyfill, no behavior change for non-Craft consumers.
      const response = await http.fetch(url, {
        method,
        headers,
        body: encoded.value as BodyInit | undefined,
        signal: controller.signal,
        ...(typeof options.timeout === 'number' || typeof this.timeout === 'number'
          ? { timeoutMs: effectiveTimeout } as { timeoutMs: number }
          : {}),
      } as RequestInit & { timeoutMs?: number })

      // Parse response. The previous version left `data` undefined for
      // anything that wasn't JSON or text/* and then returned `data as T`,
      // which lied to the type system: an image response would have
      // `data: undefined` typed as `T`. We now branch on Content-Type so
      // every code path produces a defined value (or null when the body
      // is genuinely empty).
      let data: T | null
      const contentType = response.headers.get('content-type') ?? ''

      if (contentType.includes('application/json')) {
        try {
          data = await response.json() as T
        }
        catch {
          // Response body was not valid JSON despite content-type header
          data = (await response.text()) as unknown as T
        }
      }
      else if (contentType.startsWith('text/')) {
        data = (await response.text()) as unknown as T
      }
      else if (
        contentType.includes('octet-stream')
        || contentType.startsWith('image/')
        || contentType.startsWith('audio/')
        || contentType.startsWith('video/')
        || contentType.startsWith('application/')
      ) {
        // Binary — return ArrayBuffer; callers that need a Blob/Uint8Array
        // can wrap. The cast is honest: we genuinely produced bytes.
        data = (await response.arrayBuffer()) as unknown as T
      }
      else if (response.body === null) {
        data = null
      }
      else {
        // Unknown / missing Content-Type. Default to text rather than
        // silently producing `undefined`.
        data = (await response.text()) as unknown as T
      }

      return {
        data: data as T,
        status: response.status,
        statusText: response.statusText,
        headers: Object.fromEntries(response.headers.entries()),
        ok: response.ok,
      }
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        throw new HttpError('Request timeout', 0, 'TIMEOUT')
      }
      throw error
    }
    finally {
      // Always clear the timer, even when fetch throws synchronously (e.g.
      // body-stringify failure). The previous implementation cleared it in
      // both branches of try/catch and missed the synchronous-throw path.
      clearTimeout(timeoutId)
    }
  }

  /**
   * Build URL with query parameters
   */
  private buildUrl(path: string, params?: Record<string, string | number | boolean>): string {
    let url = path.startsWith('http') ? path : `${this.baseUrl}${path}`

    if (params) {
      const searchParams = new URLSearchParams()
      for (const [key, value] of Object.entries(params)) {
        searchParams.append(key, String(value))
      }
      const query = searchParams.toString()
      if (query) {
        url += (url.includes('?') ? '&' : '?') + query
      }
    }

    return url
  }

  /**
   * Set default header
   */
  setHeader(key: string, value: string): void {
    this.defaultHeaders[key] = value
  }

  /**
   * Remove default header
   */
  removeHeader(key: string): void {
    delete this.defaultHeaders[key]
  }

  /**
   * Set bearer token
   */
  setBearerToken(token: string): void {
    this.setHeader('Authorization', `Bearer ${token}`)
  }
}

/**
 * HTTP client options
 */
export interface HttpClientOptions {
  baseUrl?: string
  headers?: Record<string, string>
  timeout?: number
}

/**
 * Request options
 */
export interface RequestOptions {
  headers?: Record<string, string>
  params?: Record<string, string | number | boolean>
  body?: unknown
  timeout?: number
}

/**
 * HTTP response
 */
export interface HttpResponse<T> {
  data: T
  status: number
  statusText: string
  headers: Record<string, string>
  ok: boolean
}

/**
 * HTTP error class
 */
export class HttpError extends Error {
  status: number
  code: string

  constructor(message: string, status: number, code: string = 'HTTP_ERROR') {
    super(message)
    this.name = 'HttpError'
    this.status = status
    this.code = code
  }
}

/**
 * WebSocket client wrapper
 */
export class WebSocketClient {
  private ws: WebSocket | null = null
  private url: string
  private reconnectAttempts: number = 0
  private maxReconnectAttempts: number
  private reconnectDelay: number
  private handlers: Map<string, Set<(data: unknown) => void>> = new Map()
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null

  constructor(url: string, options: WebSocketOptions = {}) {
    this.url = url
    // `??`, not `||`: 0 retries and a 0 ms delay are real choices.
    this.maxReconnectAttempts = options.maxReconnectAttempts ?? 5
    this.reconnectDelay = options.reconnectDelay ?? 1000
  }

  /**
   * Connect to WebSocket server
   */
  connect(): Promise<void> {
    this.cancelReconnect()
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(this.url)
      this.ws = socket

      socket.onopen = () => {
        this.reconnectAttempts = 0
        resolve()
      }

      socket.onerror = (_event) => {
        reject(new Error('WebSocket connection failed'))
      }

      // Only the current socket's close is retried; one disconnect() closed,
      // or one a newer connect() replaced, is not.
      socket.onclose = () => {
        if (this.ws !== socket) return
        this.ws = null
        this.attemptReconnect()
      }

      socket.onmessage = (event: MessageEvent) => this.dispatch(event.data)
    })
  }

  /**
   * Hand a message to its handlers: `{ type, payload }` goes to `type`'s
   * handlers as `payload` (falsy ones included), a typed message without a
   * payload as the whole message, and anything else to `message` handlers.
   */
  private dispatch(raw: unknown): void {
    let type = 'message'
    let value: unknown = raw
    if (typeof raw === 'string') {
      try {
        value = JSON.parse(raw)
      }
      catch {
        value = raw
      }
    }
    if (typeof value === 'object' && value !== null && raw !== value) {
      const message = value as { type?: unknown, payload?: unknown }
      if (typeof message.type === 'string' && message.type) type = message.type
      if ('payload' in message) value = message.payload
    }
    for (const handler of this.handlers.get(type) ?? []) {
      try {
        handler(value)
      }
      catch (error) {
        // One failing handler does not keep the message from the others.
        console.error(`WebSocketClient: a "${type}" handler threw`, error)
      }
    }
  }

  /**
   * Disconnect from WebSocket server. This close is not retried, and a pending
   * retry is cancelled; a later connect() reconnects as configured.
   */
  disconnect(): void {
    this.cancelReconnect()
    this.reconnectAttempts = 0
    const socket = this.ws
    this.ws = null
    socket?.close()
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
  }

  /**
   * Send message
   */
  send(type: string, payload?: unknown): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('WebSocket not connected')
    }
    this.ws.send(JSON.stringify({ type, payload }))
  }

  /**
   * Send raw data
   */
  sendRaw(data: string | ArrayBuffer): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('WebSocket not connected')
    }
    this.ws.send(data)
  }

  /**
   * Subscribe to message type
   */
  on(type: string, handler: (data: unknown) => void): () => void {
    if (!this.handlers.has(type)) {
      this.handlers.set(type, new Set())
    }
    this.handlers.get(type)!.add(handler)

    return () => {
      this.handlers.get(type)?.delete(handler)
    }
  }

  /**
   * Attempt to reconnect
   */
  private attemptReconnect(): void {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      return
    }

    this.reconnectAttempts++
    const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1)

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      // A failed attempt closes, and its close schedules the next one.
      this.connect().catch(() => {})
    }, delay)
  }

  /**
   * Check if connected
   */
  get connected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN
  }
}

/**
 * WebSocket options
 */
export interface WebSocketOptions {
  maxReconnectAttempts?: number
  reconnectDelay?: number
}

/**
 * Create a pre-configured HTTP client
 */
export function createClient(options?: HttpClientOptions): HttpClient {
  return new HttpClient(options)
}

export default http
