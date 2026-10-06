/**
 * @fileoverview Craft File System API
 * @description Provides native file system access through the Craft bridge.
 * Works in both browser (via native bridge) and Node.js environments.
 * @module @craft-native/api/fs
 *
 * @example
 * ```typescript
 * import { fs, readBinaryFile, stat, watch } from '@craft-native/api/fs'
 *
 * // Read a text file
 * const content = await fs.readFile('/path/to/file.txt')
 *
 * // Write to a file
 * await fs.writeFile('/path/to/output.txt', 'Hello, World!')
 *
 * // List directory contents
 * const files = await fs.readDir('/path/to/directory')
 *
 * // Watch for changes (returns a Promise<() => void>)
 * const unwatch = await watch('/path/to/watch', (event, filename) => {
 *   console.log(`${event}: ${filename}`)
 * })
 * ```
 */

import { getBridge } from '../bridge/core.js'
import type { CraftFileSystemAPI } from '../types.js'

/**
 * Get the host-injected legacy file-system bridge, or null. The legacy
 * `window.craft.fs` interface is honored when present so existing native
 * hosts keep working — but new code paths route through the unified
 * {@link NativeBridge} (see {@link callBridge}).
 */
function getCraftFs(): CraftFileSystemAPI | null {
  if (typeof window !== 'undefined' && (window as any).craft?.fs) {
    return (window as any).craft.fs
  }
  return null
}

/**
 * Send a request through the unified `NativeBridge`. This replaces the old
 * `window.craft.bridge.call(...)` legacy hook so every API module routes
 * through one transport with consistent timeout/retry/error semantics.
 */
async function callBridge<T = unknown>(method: string, params?: unknown): Promise<T> {
  return getBridge().request<unknown, T>(method, params)
}

/**
 * Validate a file path to prevent directory traversal attacks.
 *
 * Rejects:
 *   - Any `..` segment (including after URL-decoding, since the host bridge may
 *     percent-decode before opening the file)
 *   - Embedded NULs (truncate filenames in C APIs)
 *   - Empty/whitespace-only paths
 *
 * When a `root` is provided, additionally asserts that the resolved absolute
 * path is contained within `root` (best-effort — symlinks are still resolved
 * by the OS at open time).
 */
export function validatePath(path: string, root?: string): void {
  if (typeof path !== 'string' || path.length === 0) {
    throw new Error('Invalid path: must be a non-empty string')
  }

  // Block null bytes (can truncate paths in C APIs)
  if (path.includes('\0')) {
    throw new Error('Invalid path: contains null byte')
  }

  // Decode percent-encoded sequences before splitting so an attacker can't
  // sneak `..` past us as `%2e%2e`.
  let decoded = path
  try {
    decoded = decodeURIComponent(path)
  }
  catch {
    // decodeURIComponent throws on malformed sequences; treat the raw path as
    // suspect rather than failing open.
    throw new Error('Invalid path: malformed percent-encoding')
  }

  // Normalize backslashes to forward slashes and split on / segments.
  const segments = decoded.replace(/\\/g, '/').split('/')
  for (const segment of segments) {
    if (segment === '..') {
      throw new Error(`Path traversal detected: "${path}" contains a ".." segment`)
    }
  }

  if (root) {
    // Best-effort containment check (browser path-resolve is approximate).
    const baseAbs = root.endsWith('/') ? root : `${root}/`
    const resolved = decoded.startsWith('/') ? decoded : `${baseAbs}${decoded}`
    if (!resolved.startsWith(baseAbs) && resolved !== root) {
      throw new Error(`Path escapes root: "${path}" not within "${root}"`)
    }
  }
}

/**
 * Encode a Uint8Array as base64 in chunks. Avoids `String.fromCharCode(...big)`
 * blowing up on large buffers and produces a far more compact wire payload
 * than `Array.from(uint8)` (which JSON-encodes ~5 bytes per byte).
 */
export function uint8ToBase64(bytes: Uint8Array): string {
  const chunks: string[] = []
  const chunkSize = 0x8000
  for (let i = 0; i < bytes.byteLength; i += chunkSize) {
    chunks.push(String.fromCharCode(...bytes.subarray(i, i + chunkSize)))
  }
  if (typeof btoa === 'function') return btoa(chunks.join(''))
  return Buffer.from(bytes).toString('base64')
}

/**
 * Decode a base64 string into a Uint8Array. Mirrors {@link uint8ToBase64}.
 */
export function base64ToUint8(base64: string): Uint8Array {
  if (typeof atob === 'function') {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  }
  return new Uint8Array(Buffer.from(base64, 'base64'))
}

/**
 * File system API implementation.
 * Uses the native Craft bridge for file operations when running in a Craft app,
 * with automatic fallback to Node.js APIs when running in a Node environment.
 *
 * @example
 * ```typescript
 * import { fs } from '@craft-native/api/fs'
 *
 * // Check if a file exists before reading
 * if (await fs.exists('/config.json')) {
 *   const config = JSON.parse(await fs.readFile('/config.json'))
 * }
 * ```
 */
export const fs: CraftFileSystemAPI = {
  async readFile(path: string): Promise<string> {
    validatePath(path)
    const native = getCraftFs()
    if (native) return native.readFile(path)
    if (typeof window !== 'undefined' && (window as any).craft) {
      return callBridge<string>('fs.readFile', { path })
    }
    const { readFile } = await import('node:fs/promises')
    return readFile(path, 'utf-8')
  },

  async writeFile(path: string, content: string): Promise<void> {
    validatePath(path)
    const native = getCraftFs()
    if (native) return native.writeFile(path, content)
    if (typeof window !== 'undefined' && (window as any).craft) {
      await callBridge('fs.writeFile', { path, content })
      return
    }
    const { writeFile } = await import('node:fs/promises')
    return writeFile(path, content, 'utf-8')
  },

  async readDir(path: string): Promise<string[]> {
    validatePath(path)
    // Defensive filter on `.` / `..` regardless of which transport
    // returns the listing. node:fs.readdir already excludes them, but
    // the legacy host bridge (`window.craft.fs.readDir`) is at the host
    // implementation's discretion — and many callers iterate the result
    // and stat each entry, where a stray `..` would silently let them
    // walk above the directory they thought they were enumerating.
    const filter = (xs: string[]) => xs.filter((n) => n !== '.' && n !== '..')
    const native = getCraftFs()
    if (native) return filter(await native.readDir(path))
    if (typeof window !== 'undefined' && (window as any).craft) {
      return filter(await callBridge<string[]>('fs.readDir', { path }))
    }
    const { readdir } = await import('node:fs/promises')
    return filter(await readdir(path))
  },

  async mkdir(path: string): Promise<void> {
    validatePath(path)
    const native = getCraftFs()
    if (native) return native.mkdir(path)
    if (typeof window !== 'undefined' && (window as any).craft) {
      await callBridge('fs.mkdir', { path })
      return
    }
    const { mkdir } = await import('node:fs/promises')
    await mkdir(path, { recursive: true })
  },

  async remove(path: string): Promise<void> {
    validatePath(path)
    const native = getCraftFs()
    if (native) return native.remove(path)
    if (typeof window !== 'undefined' && (window as any).craft) {
      await callBridge('fs.remove', { path })
      return
    }
    const { rm } = await import('node:fs/promises')
    return rm(path, { recursive: true, force: true })
  },

  async exists(path: string): Promise<boolean> {
    validatePath(path)
    const native = getCraftFs()
    if (native) return native.exists(path)
    if (typeof window !== 'undefined' && (window as any).craft) {
      return callBridge<boolean>('fs.exists', { path })
    }
    const { access } = await import('node:fs/promises')
    try {
      await access(path)
      return true
    }
    catch {
      return false
    }
  },
}

/**
 * Read file as binary data (Uint8Array).
 * Use this for non-text files like images, PDFs, or other binary formats.
 */
export async function readBinaryFile(path: string): Promise<Uint8Array> {
  validatePath(path)
  if (typeof window !== 'undefined' && (window as any).craft) {
    // Bridge response carries base64 — converts to Uint8Array on this side.
    // The previous shape `{ data: number[] }` ate ~5x the wire bytes per
    // byte and was JSON.stringify'd by the bridge envelope.
    const response = await callBridge<{ data: string }>('fs.readBinaryFile', { path })
    return base64ToUint8(response.data)
  }
  const { readFile } = await import('node:fs/promises')
  return readFile(path)
}

/**
 * Write binary data to a file.
 * Sends the bytes as base64 (with an `_binary: true` marker) so the wire
 * payload is ~33% overhead instead of the ~5x-10x overhead of JSON-encoded
 * `Array.from(uint8)`.
 */
export async function writeBinaryFile(path: string, data: Uint8Array): Promise<void> {
  validatePath(path)
  if (typeof window !== 'undefined' && (window as any).craft) {
    await callBridge('fs.writeBinaryFile', {
      path,
      _binary: true,
      data: uint8ToBase64(data),
    })
    return
  }
  const { writeFile } = await import('node:fs/promises')
  return writeFile(path, data)
}

/**
 * File statistics information.
 */
export interface FileStats {
  /** File size in bytes */
  size: number
  /** True if this is a regular file */
  isFile: boolean
  /** True if this is a directory */
  isDirectory: boolean
  /** Date when the file was last modified */
  modifiedAt: Date
  /** Date when the file was created */
  createdAt: Date
}

/**
 * Get file or directory statistics.
 */
export async function stat(path: string): Promise<FileStats> {
  validatePath(path)
  if (typeof window !== 'undefined' && (window as any).craft) {
    const response = await callBridge<{
      size: number
      isFile: boolean
      isDirectory: boolean
      modifiedAt: number
      createdAt: number
    }>('fs.stat', { path })
    return {
      size: response.size,
      isFile: response.isFile,
      isDirectory: response.isDirectory,
      modifiedAt: new Date(response.modifiedAt),
      createdAt: new Date(response.createdAt),
    }
  }
  const { stat: nodeStat } = await import('node:fs/promises')
  const stats = await nodeStat(path)
  return {
    size: stats.size,
    isFile: stats.isFile(),
    isDirectory: stats.isDirectory(),
    modifiedAt: stats.mtime,
    createdAt: stats.birthtime,
  }
}

/**
 * Copy a file or directory to a new location.
 */
export async function copy(src: string, dest: string): Promise<void> {
  validatePath(src)
  validatePath(dest)
  if (typeof window !== 'undefined' && (window as any).craft) {
    await callBridge('fs.copy', { src, dest })
    return
  }
  // Node.js fallback. dereference: false stops a symlink under `src` from
  // tricking cp into writing files outside `dest`. verbatimSymlinks: true
  // keeps the link itself intact instead of resolving it relative to `dest`.
  const { cp } = await import('node:fs/promises')
  return cp(src, dest, {
    recursive: true,
    dereference: false,
    verbatimSymlinks: true,
  })
}

/**
 * Move or rename a file or directory.
 */
export async function move(src: string, dest: string): Promise<void> {
  validatePath(src)
  validatePath(dest)
  if (typeof window !== 'undefined' && (window as any).craft) {
    await callBridge('fs.move', { src, dest })
    return
  }
  const { rename } = await import('node:fs/promises')
  return rename(src, dest)
}

/**
 * Watch options. `recursive` recurses into subdirectories — supported by
 * the Craft bridge always, by Node.js's `fs.watch` only on macOS/Windows.
 * Linux falls back to a non-recursive watch and logs a one-time warning.
 */
export interface WatchOptions {
  recursive?: boolean
}

let _watchRecursiveWarned = false

/**
 * Test-only: clear the once-per-process recursive-watch warning flag so
 * tests that exercise the warning path can do so deterministically.
 */
export function _resetWatchWarningForTests(): void {
  _watchRecursiveWarned = false
}

/**
 * Watch a file or directory for changes.
 *
 * Returns a Promise that resolves with an unwatch function once the watcher
 * is fully initialized.
 *
 * Important: the returned unwatch function MUST be called when the watcher
 * is no longer needed. Forgotten watchers leak both the underlying OS handle
 * and the JS-side event listener.
 */
export async function watch(
  path: string,
  callback: (event: string, filename: string) => void,
  options: WatchOptions = {},
): Promise<() => void> {
  validatePath(path)
  const recursive = options.recursive ?? true

  // The desktop bridge's own watch: it names the watch, routes this watch's
  // `craft:fs:change` events to the callback, and unwatches by the same id.
  const native = getCraftFs()
  if (native?.watch) {
    const handle = await native.watch(path, event => callback(event.type, event.path), { recursive })
    return () => {
      void handle.unwatch()
    }
  }

  if (typeof window !== 'undefined' && (window as any).craft) {
    const watchId = typeof globalThis.crypto !== 'undefined' && 'randomUUID' in globalThis.crypto
      ? (globalThis.crypto as Crypto).randomUUID()
      : `${Date.now()}_${performance.now()}`
    await callBridge('fs.watch', { path, watchId, recursive })

    const handler = (event: CustomEvent) => {
      if (event.detail.watchId === watchId) {
        callback(event.detail.eventType, event.detail.filename)
      }
    }
    window.addEventListener('craft:fs:watch' as any, handler)

    return () => {
      window.removeEventListener('craft:fs:watch' as any, handler)
      void callBridge('fs.unwatch', { watchId })
    }
  }

  const nodeFs = await import('node:fs')
  const platform = typeof process !== 'undefined' ? process.platform : ''
  // node:fs.watch supports `recursive` on darwin/win32; on linux it's
  // ignored. Surface a single warning so callers aren't surprised.
  if (recursive && platform === 'linux' && !_watchRecursiveWarned) {
    _watchRecursiveWarned = true
    console.warn(
      '[Craft fs.watch] recursive watching is not supported by node:fs.watch on linux; '
      + 'only direct children of the path will fire events. Use the Craft bridge for true recursion.',
    )
  }
  const watcher = nodeFs.watch(
    path,
    { recursive: recursive && platform !== 'linux' },
    (event: string, filename: string | null) => {
      if (filename) callback(event, filename)
    },
  )
  return () => watcher.close()
}

export default fs
