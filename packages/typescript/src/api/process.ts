/**
 * Craft Process API
 * Provides process management and system information
 */

import { getBridge } from '../bridge/core.js'

/**
 * Send a request through the unified `NativeBridge`. Replaces the legacy
 * `window.craft.bridge.call(...)` hook so process API methods share the
 * same timeout/retry/error semantics as everything else in the SDK.
 */
async function callBridge<T = unknown>(method: string, params?: unknown): Promise<T> {
  return getBridge().request<unknown, T>(method, params)
}

/**
 * Live view of process environment variables. Implemented as a Proxy so that
 * `env.FOO = 'bar'` and `delete env.FOO` actually update `process.env`, and
 * reads always reflect the latest value rather than a snapshot taken at
 * module load time.
 *
 * In non-Node environments (e.g. inside a webview), the proxy targets an
 * empty object — reads return `undefined`, writes are local to the proxy.
 */
const _envBacking: Record<string, string | undefined> = typeof process !== 'undefined'
  ? (process.env as Record<string, string | undefined>)
  : {}

export const env: Record<string, string | undefined> = new Proxy(_envBacking, {
  get(_, key: string) {
    return _envBacking[key]
  },
  set(_, key: string, value) {
    _envBacking[key] = value as string | undefined
    return true
  },
  deleteProperty(_, key: string) {
    delete _envBacking[key]
    return true
  },
  ownKeys() {
    return Reflect.ownKeys(_envBacking)
  },
  getOwnPropertyDescriptor(_, key: string) {
    return Object.getOwnPropertyDescriptor(_envBacking, key)
  },
  has(_, key: string) {
    return key in _envBacking
  },
})

/**
 * Current platform
 */
export type Platform = 'darwin' | 'macos' | 'win32' | 'windows' | 'linux' | 'ios' | 'android' | 'unknown'

/**
 * Get current platform
 */
export function getPlatform(): Platform {
  // Prefer native bridge platform info (most reliable)
  if (typeof globalThis !== 'undefined') {
    const w = globalThis as any
    if (w.craft?._platform) return w.craft._platform
    if (w.__CRAFT_PLATFORM__) return w.__CRAFT_PLATFORM__
  }

  // Fall back to Node.js process.platform
  if (typeof process !== 'undefined' && process.platform) {
    return process.platform as Platform
  }

  // Last resort: user-agent sniffing (unreliable). Guard `navigator` with
  // typeof — a missing global throws ReferenceError before optional
  // chaining can run.
  if (typeof navigator !== 'undefined' && typeof navigator.userAgent === 'string') {
    const ua = navigator.userAgent.toLowerCase()
    // iPhone/iPad checks come BEFORE the broader 'mac' check because
    // iPadOS reports `Macintosh` in its UA string.
    if (ua.includes('iphone') || ua.includes('ipad')) return 'ios'
    if (ua.includes('android')) return 'android'
    if (ua.includes('mac')) return 'darwin'
    if (ua.includes('win')) return 'win32'
    if (ua.includes('linux')) return 'linux'
  }

  return 'unknown'
}

/**
 * Check if running on desktop
 */
export function isDesktop(): boolean {
  const platform = getPlatform()
  return platform === 'darwin' || platform === 'macos' || platform === 'win32' || platform === 'windows' || platform === 'linux'
}

/**
 * Check if running on mobile
 */
export function isMobile(): boolean {
  const platform = getPlatform()
  return platform === 'ios' || platform === 'android'
}

/**
 * Check if running in Craft environment
 */
export function isCraft(): boolean {
  return typeof window !== 'undefined' && typeof window.craft !== 'undefined'
}

/**
 * System information
 */
export interface SystemInfo {
  platform: Platform
  arch: string
  osVersion: string
  hostname: string
  cpuCount: number
  totalMemory: number
  freeMemory: number
  uptime: number
}

/**
 * Get system information
 */
export async function getSystemInfo(): Promise<SystemInfo> {
  if (typeof window !== 'undefined' && window.craft) {
    return callBridge<SystemInfo>('process.getSystemInfo')
  }

  // Node.js fallback
  if (typeof process !== 'undefined') {
    const os = await import('node:os')
    return {
      platform: process.platform as Platform,
      arch: process.arch,
      osVersion: os.release(),
      hostname: os.hostname(),
      cpuCount: os.cpus().length,
      totalMemory: os.totalmem(),
      freeMemory: os.freemem(),
      uptime: os.uptime(),
    }
  }

  // `navigator` is a host global; missing globals throw ReferenceError
  // before optional chaining can run, so guard with `typeof`.
  const cpuCount = typeof navigator !== 'undefined' && typeof navigator.hardwareConcurrency === 'number'
    ? navigator.hardwareConcurrency
    : 1

  return {
    platform: getPlatform(),
    arch: 'unknown',
    osVersion: 'unknown',
    hostname: 'unknown',
    cpuCount,
    totalMemory: 0,
    freeMemory: 0,
    uptime: 0,
  }
}

/**
 * Execute shell command (requires Craft environment)
 */
export interface ExecOptions {
  cwd?: string
  env?: Record<string, string>
  timeout?: number
  maxBuffer?: number
}

export interface ExecResult {
  stdout: string
  stderr: string
  exitCode: number
}

export async function exec(command: string, options?: ExecOptions): Promise<ExecResult> {
  if (typeof window !== 'undefined' && window.craft) {
    return callBridge<ExecResult>('process.exec', { command, ...options })
  }

  // Node.js fallback
  const { exec: nodeExec } = await import('node:child_process')
  const { promisify } = await import('node:util')
  const execPromise = promisify(nodeExec)

  try {
    const { stdout, stderr } = await execPromise(command, {
      cwd: options?.cwd,
      env: options?.env ? { ...process.env, ...options.env } : undefined,
      timeout: options?.timeout,
      maxBuffer: options?.maxBuffer || 1024 * 1024
    })
    return { stdout, stderr, exitCode: 0 }
  }
catch (error: any) {
    return {
      stdout: error.stdout || '',
      stderr: error.stderr || error.message,
      exitCode: error.code || 1
    }
  }
}

/**
 * Spawn a child process
 */
export interface SpawnOptions {
  cwd?: string
  env?: Record<string, string>
  /**
   * Run `command` as a command line through a shell (cmd.exe on Windows,
   * /bin/sh elsewhere) instead of executing it directly.
   *
   * Off by default, as in Node. Without it `command` is a program and `args`
   * are its arguments, so a `;` or `|` inside an argument reaches the program
   * as a plain character rather than as shell syntax.
   *
   * A shell takes one string, so `args` cannot be passed with it — supplying
   * both is refused rather than silently honouring one of them.
   */
  shell?: boolean
}

export class ChildProcess {
  private processId: string | null = null
  private onStdoutHandlers: ((_data: string) => void)[] = []
  private onStderrHandlers: ((_data: string) => void)[] = []
  private onExitHandlers: ((_code: number) => void)[] = []
  // Tracked DOM listeners so we can detach them on exit/kill — without
  // this, every spawn leaks 3 window listeners that pin closures forever.
  private domListeners: Array<{ type: string; handler: EventListener }> = []
  private exited = false

  constructor(
    private command: string,
    private args: string[] = [],
    private options: SpawnOptions = {},
  ) {}

  private addDomListener(type: string, handler: EventListener): void {
    if (typeof window === 'undefined') return
    window.addEventListener(type, handler)
    this.domListeners.push({ type, handler })
  }

  private removeDomListeners(): void {
    if (typeof window === 'undefined') return
    for (const { type, handler } of this.domListeners) {
      window.removeEventListener(type, handler)
    }
    this.domListeners = []
  }

  /** Pid assigned by the native bridge, or null before start(). */
  get pid(): string | null {
    return this.processId
  }

  /**
   * Start the process
   */
  async start(): Promise<void> {
    if (typeof window !== 'undefined' && window.craft) {
      const result = await callBridge<{ pid: string }>('process.spawn', {
        command: this.command,
        args: this.args,
        ...this.options,
      })
      this.processId = result.pid

      const stdoutHandler = ((event: CustomEvent) => {
        if (event.detail.pid === this.processId) {
          this.onStdoutHandlers.forEach(h => h(event.detail.data))
        }
      }) as EventListener
      const stderrHandler = ((event: CustomEvent) => {
        if (event.detail.pid === this.processId) {
          this.onStderrHandlers.forEach(h => h(event.detail.data))
        }
      }) as EventListener
      const exitHandler = ((event: CustomEvent) => {
        if (event.detail.pid === this.processId) {
          this.exited = true
          this.onExitHandlers.forEach(h => h(event.detail.code))
          // Once the process has exited, our listeners can never fire
          // again — release them so the closures are GC-able.
          this.removeDomListeners()
        }
      }) as EventListener

      this.addDomListener('craft:process:stdout', stdoutHandler)
      this.addDomListener('craft:process:stderr', stderrHandler)
      this.addDomListener('craft:process:exit', exitHandler)

      return
    }

    throw new Error('spawn() requires Craft environment')
  }

  /**
   * Write to stdin
   */
  async write(data: string): Promise<void> {
    if (typeof window !== 'undefined' && window.craft && this.processId) {
      await callBridge('process.stdin', { pid: this.processId, data })
    }
  }

  /**
   * Kill the process
   */
  async kill(signal: string = 'SIGTERM'): Promise<void> {
    if (typeof window !== 'undefined' && window.craft && this.processId) {
      await callBridge('process.kill', { pid: this.processId, signal })
      // The native side will still emit a final `exit` event; the exit
      // handler removes listeners from there. Defensive cleanup here too
      // in case the native bridge drops the exit event.
      if (this.exited) this.removeDomListeners()
    }
  }

  /**
   * Listen for stdout data
   */
  onStdout(handler: (data: string) => void): () => void {
    this.onStdoutHandlers.push(handler)
    return () => {
      const idx = this.onStdoutHandlers.indexOf(handler)
      if (idx >= 0) this.onStdoutHandlers.splice(idx, 1)
    }
  }

  /**
   * Listen for stderr data
   */
  onStderr(handler: (data: string) => void): () => void {
    this.onStderrHandlers.push(handler)
    return () => {
      const idx = this.onStderrHandlers.indexOf(handler)
      if (idx >= 0) this.onStderrHandlers.splice(idx, 1)
    }
  }

  /**
   * Listen for exit
   */
  onExit(handler: (code: number) => void): () => void {
    this.onExitHandlers.push(handler)
    return () => {
      const idx = this.onExitHandlers.indexOf(handler)
      if (idx >= 0) this.onExitHandlers.splice(idx, 1)
    }
  }
}

/**
 * Spawn a child process
 */
export function spawn(
  command: string,
  args?: string[],
  options?: SpawnOptions
): ChildProcess {
  return new ChildProcess(command, args, options)
}

/**
 * Get current working directory
 */
export function cwd(): string {
  if (typeof process !== 'undefined') {
    return process.cwd()
  }
  return '/'
}

/**
 * Get home directory
 */
export async function homeDir(): Promise<string> {
  if (typeof window !== 'undefined' && window.craft) {
    return callBridge<string>('process.homeDir')
  }

  if (typeof process !== 'undefined') {
    const os = await import('node:os')
    return os.homedir()
  }

  return '/'
}

/**
 * Get temp directory
 */
export async function tempDir(): Promise<string> {
  if (typeof window !== 'undefined' && window.craft) {
    return callBridge<string>('process.tempDir')
  }

  if (typeof process !== 'undefined') {
    const os = await import('node:os')
    return os.tmpdir()
  }

  return '/tmp'
}

/**
 * Exit the application. Prefers the native bridge's `app.quit()` so the
 * platform can flush state; falls back to `process.exit` in Node-like
 * environments. Accepts a non-zero code on the Node fallback so callers can
 * signal failure to a parent shell.
 */
export function exit(code: number = 0): void {
  if (typeof window !== 'undefined') {
    const app = window.craft?.app as { quit?: (code?: number) => void } | undefined
    if (app && typeof app.quit === 'function') {
      app.quit(code)
      return
    }
  }
  if (typeof process !== 'undefined' && typeof process.exit === 'function') {
    process.exit(code)
  }
}

/**
 * Get command line arguments
 */
export function argv(): string[] {
  if (typeof process !== 'undefined') {
    return process.argv
  }
  return []
}

/**
 * Open URL or file in default application.
 *
 * Uses `child_process.execFile` (no shell) so a target like
 * `https://example.com; rm -rf ~` cannot be reinterpreted by a shell.
 *
 * On Windows we explicitly invoke `cmd.exe /c start "" <target>` rather
 * than calling `start` directly — `start` is a `cmd.exe` builtin, not an
 * executable, so the previous implementation would fail with ENOENT. The
 * empty `""` is the literal `start` window-title argument; `start` would
 * otherwise interpret a quoted path as the title and never open it.
 */
export async function open(target: string): Promise<void> {
  if (typeof window !== 'undefined' && window.craft) {
    await callBridge('process.open', { target })
    return
  }

  const platform = getPlatform()
  const { execFile } = await import('node:child_process')
  const { promisify } = await import('node:util')
  const exec = promisify(execFile)

  switch (platform) {
    case 'darwin':
    case 'macos':
      await exec('open', [target])
      return
    case 'win32':
    case 'windows':
      await exec('cmd.exe', ['/c', 'start', '""', target])
      return
    case 'linux':
      await exec('xdg-open', [target])
      return
    default:
      throw new Error(`Unsupported platform: ${platform}`)
  }
}

const processApi: {
  env: typeof env
  getPlatform: typeof getPlatform
  isDesktop: typeof isDesktop
  isMobile: typeof isMobile
  isCraft: typeof isCraft
  getSystemInfo: typeof getSystemInfo
  exec: typeof exec
  spawn: typeof spawn
  cwd: typeof cwd
  homeDir: typeof homeDir
  tempDir: typeof tempDir
  exit: typeof exit
  argv: typeof argv
  open: typeof open
} = {
  env,
  getPlatform,
  isDesktop,
  isMobile,
  isCraft,
  getSystemInfo,
  exec,
  spawn,
  cwd,
  homeDir,
  tempDir,
  exit,
  argv,
  open,
}

export default processApi
