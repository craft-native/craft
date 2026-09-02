/**
 * Craft Structured Logging
 * JSON-based structured logging with filtering and remote reporting
 */

import { writeFileSync, appendFileSync, existsSync, mkdirSync, readFileSync } from 'fs'
import { dirname } from 'path'
import { hostname as osHostname } from 'os'

// Types
export type LogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal'

export interface LogEntry {
  level: LogLevel
  message: string
  timestamp: string
  context?: Record<string, unknown>
  stack?: string
  tags?: string[]
}

export interface LoggerConfig {
  level?: LogLevel
  format?: 'json' | 'pretty' | 'minimal'
  output?: 'console' | 'file' | 'both' | 'none'
  filePath?: string
  maxFileSize?: number // bytes
  maxFiles?: number
  remote?: {
    url: string
    batchSize?: number
    flushInterval?: number
  }
  /**
   * Field names to redact in logged context. Each entry is matched
   * case-insensitively as a substring of the key — `'password'` matches
   * `password`, `userPassword`, and `oldPassword`. For more precise control
   * use {@link LoggerConfig.redactPatterns} instead.
   */
  redact?: string[]
  /**
   * Regular expressions to match against context keys for redaction. These
   * fire in addition to {@link LoggerConfig.redact}. Use this when you
   * need to redact things like `^auth_` prefixes without redacting `author`.
   */
  redactPatterns?: RegExp[]
  enrichers?: Array<(entry: LogEntry) => LogEntry>
}

// Log level priorities
const LEVEL_PRIORITY: Record<LogLevel, number> = {
  trace: 0,
  debug: 1,
  info: 2,
  warn: 3,
  error: 4,
  fatal: 5,
}

// ANSI colors for pretty printing
const COLORS = {
  reset: '\x1b[0m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  white: '\x1b[37m',
}

const LEVEL_COLORS: Record<LogLevel, string> = {
  trace: COLORS.dim,
  debug: COLORS.cyan,
  info: COLORS.blue,
  warn: COLORS.yellow,
  error: COLORS.red,
  fatal: COLORS.magenta,
}

// Logger class
export class Logger {
  private config: Required<LoggerConfig>
  private context: Record<string, unknown> = {}
  private buffer: LogEntry[] = []
  private flushTimer: NodeJS.Timeout | null = null
  private currentFileSize = 0
  private fileIndex = 0

  constructor(config: LoggerConfig = {}) {
    this.config = {
      level: 'info',
      format: 'pretty',
      output: 'console',
      filePath: './logs/app.log',
      maxFileSize: 10 * 1024 * 1024, // 10MB
      maxFiles: 5,
      remote: undefined as any,
      redact: ['password', 'passwd', 'token', 'secret', 'apikey', 'api_key', 'authorization', 'cookie', 'set-cookie', 'bearer'],
      redactPatterns: [],
      enrichers: [],
      ...config,
    }

    if (this.config.output === 'file' || this.config.output === 'both') {
      this.initFileLogging()
    }

    if (this.config.remote) {
      this.startRemoteFlush()
    }
  }

  private initFileLogging(): void {
    const dir = dirname(this.config.filePath)
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
    }
  }

  private startRemoteFlush(): void {
    if (this.config.remote) {
      const interval = this.config.remote.flushInterval || 5000
      this.flushTimer = setInterval(() => this.flushRemote(), interval)
    }
  }

  /**
   * Create a child logger with additional context
   */
  child(context: Record<string, unknown>): Logger {
    const child = new Logger(this.config)
    child.context = { ...this.context, ...context }
    return child
  }

  /**
   * Add context to all log entries
   */
  withContext(context: Record<string, unknown>): this {
    this.context = { ...this.context, ...context }
    return this
  }

  /**
   * Log methods
   */
  trace(message: string, context?: Record<string, unknown>): void {
    this.log('trace', message, context)
  }

  debug(message: string, context?: Record<string, unknown>): void {
    this.log('debug', message, context)
  }

  info(message: string, context?: Record<string, unknown>): void {
    this.log('info', message, context)
  }

  warn(message: string, context?: Record<string, unknown>): void {
    this.log('warn', message, context)
  }

  error(message: string, context?: Record<string, unknown>): void {
    this.log('error', message, context)
  }

  fatal(message: string, context?: Record<string, unknown>): void {
    this.log('fatal', message, context)
  }

  /**
   * Log with error object
   */
  errorWithStack(message: string, error: Error, context?: Record<string, unknown>): void {
    this.log('error', message, {
      ...context,
      error: {
        name: error.name,
        message: error.message,
        stack: error.stack,
      },
    })
  }

  /**
   * Main log method
   */
  private log(level: LogLevel, message: string, context?: Record<string, unknown>): void {
    // Check if level is enabled
    if (LEVEL_PRIORITY[level] < LEVEL_PRIORITY[this.config.level]) {
      return
    }

    let entry: LogEntry = {
      level,
      message,
      timestamp: new Date().toISOString(),
      context: { ...this.context, ...context },
    }

    // Apply enrichers
    for (const enricher of this.config.enrichers) {
      entry = enricher(entry)
    }

    // Redact sensitive fields
    if (entry.context) {
      entry.context = this.redactSensitive(entry.context)
    }

    // Output
    this.output(entry)

    // Buffer for remote
    if (this.config.remote) {
      this.buffer.push(entry)
      if (this.buffer.length >= (this.config.remote.batchSize || 100)) {
        this.flushRemote()
      }
    }
  }

  /**
   * Output log entry
   */
  private output(entry: LogEntry): void {
    const formatted = this.format(entry)

    if (this.config.output === 'console' || this.config.output === 'both') {
      this.outputConsole(entry, formatted)
    }

    if (this.config.output === 'file' || this.config.output === 'both') {
      this.outputFile(entry)
    }
  }

  /**
   * Output to console. When running inside a Craft webview we ALSO mirror
   * the message through `window.craft.bridge.call('log.write', …)` so the
   * native log facility (and tools like `Console.app` / `journalctl`)
   * receives the entry — webview console output is otherwise stuck behind
   * a devtools connection that production users don't have open.
   */
  private outputConsole(entry: LogEntry, formatted: string): void {
    const color = LEVEL_COLORS[entry.level]
    const output = this.config.format === 'pretty' ? `${color}${formatted}${COLORS.reset}` : formatted

    switch (entry.level) {
      case 'error':
      case 'fatal':
        console.error(output)
        break
      case 'warn':
        console.warn(output)
        break
      default:
        console.log(output)
    }

    // Best-effort native forwarding. We use the bridge's batching API so a
    // log-heavy code path doesn't fire one bridge call per line — `addToBatch`
    // coalesces into a single envelope on the next tick.
    if (typeof window !== 'undefined') {
      const w = window as unknown as {
        craft?: {
          bridge?: {
            addToBatch?: (m: string, p?: unknown) => void
            call?: (m: string, p?: unknown) => unknown
          }
        }
      }
      const bridge = w.craft?.bridge
      if (bridge) {
        try {
          if (typeof bridge.addToBatch === 'function') {
            bridge.addToBatch('log.write', { level: entry.level, message: formatted, timestamp: entry.timestamp })
          }
          else if (typeof bridge.call === 'function') {
            void bridge.call('log.write', { level: entry.level, message: formatted, timestamp: entry.timestamp })
          }
        }
        catch {
          // Native logger optional; never crash the host on a log forwarding failure.
        }
      }
    }
  }

  /**
   * Output to file
   */
  private outputFile(entry: LogEntry): void {
    const line = JSON.stringify(entry) + '\n'
    const lineSize = Buffer.byteLength(line)

    // Check if rotation needed
    if (this.currentFileSize + lineSize > this.config.maxFileSize) {
      this.rotateFile()
    }

    appendFileSync(this.config.filePath, line)
    this.currentFileSize += lineSize
  }

  /**
   * Rotate log file
   */
  private rotateFile(): void {
    this.fileIndex = (this.fileIndex + 1) % this.config.maxFiles

    // Rename current file
    const rotatedPath = this.config.filePath.replace(/\.log$/, `.${this.fileIndex}.log`)
    if (existsSync(this.config.filePath)) {
      const content = readFileSync(this.config.filePath)
      writeFileSync(rotatedPath, content)
      writeFileSync(this.config.filePath, '')
    }

    this.currentFileSize = 0
  }

  /**
   * Format log entry
   */
  private format(entry: LogEntry): string {
    switch (this.config.format) {
      case 'json':
        return JSON.stringify(entry)

      case 'minimal':
        return `[${entry.level.toUpperCase()}] ${entry.message}`

      case 'pretty':
      default:
        const time = entry.timestamp.split('T')[1].split('.')[0]
        const level = entry.level.toUpperCase().padEnd(5)
        let output = `${COLORS.dim}${time}${COLORS.reset} ${level} ${entry.message}`

        if (entry.context && Object.keys(entry.context).length > 0) {
          output += ` ${COLORS.dim}${JSON.stringify(entry.context)}${COLORS.reset}`
        }

        return output
    }
  }

  /**
   * Redact sensitive fields. A field is redacted if its name (lowercased)
   * substring-matches one of `config.redact`, OR if its name (untouched)
   * matches one of `config.redactPatterns`. Nested objects recurse.
   */
  private redactSensitive(obj: Record<string, unknown>): Record<string, unknown> {
    const result: Record<string, unknown> = {}
    const patterns = this.config.redactPatterns ?? []
    // `redact` is non-optional in the merged config but a consumer can
    // still pass `redact: undefined` (or `null as any`) which would crash
    // the `.some` call below. Guard once.
    const redactList = this.config.redact ?? []

    for (const [key, value] of Object.entries(obj)) {
      const lowerKey = key.toLowerCase()
      const shouldRedact
        = redactList.some(field => lowerKey.includes(field.toLowerCase()))
          || patterns.some(re => re.test(key))

      if (shouldRedact) {
        result[key] = '[REDACTED]'
      }
      else if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
        result[key] = this.redactSensitive(value as Record<string, unknown>)
      }
      else {
        result[key] = value
      }
    }

    return result
  }

  /**
   * Flush logs to remote endpoint
   */
  private async flushRemote(): Promise<void> {
    if (!this.config.remote || this.buffer.length === 0) return

    const entries = [...this.buffer]
    this.buffer = []

    try {
      await fetch(this.config.remote.url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ logs: entries }),
      })
    }
catch (error) {
      // Re-add failed entries
      this.buffer.unshift(...entries)
      console.error('[Logger] Failed to flush to remote:', error)
    }
  }

  /**
   * Flush and close logger
   */
  async close(): Promise<void> {
    if (this.flushTimer) {
      clearInterval(this.flushTimer)
    }
    await this.flushRemote()
  }

  /**
   * Set log level
   */
  setLevel(level: LogLevel): void {
    this.config.level = level
  }

  /**
   * Get current log level
   */
  getLevel(): LogLevel {
    return this.config.level
  }
}

// Standard enrichers
export const enrichers = {
  /**
   * Add process info
   */
  processInfo: (entry: LogEntry): LogEntry => ({
    ...entry,
    context: {
      ...entry.context,
      pid: process.pid,
      memory: Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
    },
  }),

  /**
   * Add hostname
   */
  hostname: (entry: LogEntry): LogEntry => ({
    ...entry,
    context: {
      ...entry.context,
      hostname: osHostname(),
    },
  }),

  /**
   * Add environment
   */
  environment: (entry: LogEntry): LogEntry => ({
    ...entry,
    context: {
      ...entry.context,
      env: process.env.NODE_ENV || 'development',
    },
  }),

  /**
   * Add request ID (for HTTP contexts)
   */
  requestId:
    (getId: () => string | undefined) =>
    (entry: LogEntry): LogEntry => {
      const requestId = getId()
      if (requestId) {
        return {
          ...entry,
          context: { ...entry.context, requestId },
        }
      }
      return entry
    },
}

// Create default logger
let defaultLogger: Logger | null = null

export function getLogger(config?: LoggerConfig): Logger {
  if (!defaultLogger) {
    defaultLogger = new Logger(config)
  }
  return defaultLogger
}

export function setDefaultLogger(logger: Logger): void {
  defaultLogger = logger
}

// Convenience functions using default logger
export const log = {
  trace: (message: string, context?: Record<string, unknown>): void => getLogger().trace(message, context),
  debug: (message: string, context?: Record<string, unknown>): void => getLogger().debug(message, context),
  info: (message: string, context?: Record<string, unknown>): void => getLogger().info(message, context),
  warn: (message: string, context?: Record<string, unknown>): void => getLogger().warn(message, context),
  error: (message: string, context?: Record<string, unknown>): void => getLogger().error(message, context),
  fatal: (message: string, context?: Record<string, unknown>): void => getLogger().fatal(message, context),
}

export default Logger
