/**
 * Craft App API
 * Application lifecycle, configuration, and system integration
 * @module @craft-native/api/app
 */

import { getBridge } from '../bridge/core.js'
import { isWebKitHost, webkitRequest } from '../bridge/webkit-pending.js'

// ============================================================================
// Types
// ============================================================================

/**
 * Application information
 */
export interface AppInfo {
  /** App name */
  name: string
  /** App version */
  version: string
  /** Bundle identifier */
  bundleId?: string
  /** Build number */
  buildNumber?: string
  /** Platform */
  platform: 'macos' | 'windows' | 'linux' | 'ios' | 'android'
  /** Architecture */
  arch: 'x64' | 'arm64' | 'x86' | 'arm'
  /** App path */
  appPath: string
  /** User data path */
  userDataPath: string
  /** Executable path */
  executablePath: string
  /** Resources path */
  resourcesPath: string
  /** Temp path */
  tempPath: string
  /** Logs path */
  logsPath: string
  /** Is packaged app */
  isPackaged: boolean
  /** Is development mode */
  isDevelopment: boolean
}

/**
 * System preferences
 */
export interface SystemPreferences {
  /** Dark mode enabled */
  isDarkMode: boolean
  /** Accent color */
  accentColor: string
  /** Reduced motion */
  reducedMotion: boolean
  /** Reduced transparency */
  reducedTransparency: boolean
  /** High contrast */
  highContrast: boolean
  /** System font */
  systemFont: string
  /** System locale */
  locale: string
  /** System timezone */
  timezone: string
}

/**
 * Display information
 */
export interface DisplayInfo {
  /** Display ID */
  id: string
  /** Display name */
  name: string
  /** Width in pixels */
  width: number
  /** Height in pixels */
  height: number
  /** Scale factor */
  scaleFactor: number
  /** Is primary display */
  isPrimary: boolean
  /** Display bounds */
  bounds: { x: number; y: number; width: number; height: number }
  /** Work area (excluding taskbar/dock) */
  workArea: { x: number; y: number; width: number; height: number }
  /** Refresh rate */
  refreshRate?: number
  /** Color depth */
  colorDepth?: number
  /** Is touchscreen */
  touchSupport?: boolean
}

/**
 * Badge options (dock/taskbar)
 */
export interface BadgeOptions {
  /** Badge text/number */
  badge: string | number | null
  /** Badge color (optional) */
  color?: string
}

/**
 * Notification options
 */
export interface NotificationOptions {
  /** Notification title */
  title: string
  /** Notification body */
  body?: string
  /** Notification subtitle (macOS) */
  subtitle?: string
  /** Icon path */
  icon?: string
  /** Sound to play */
  sound?: string | 'default' | 'none'
  /** Action buttons */
  actions?: Array<{ action: string; title: string; icon?: string }>
  /** Close button text */
  closeButtonText?: string
  /** Has reply field */
  hasReply?: boolean
  /** Reply placeholder */
  replyPlaceholder?: string
  /** Timeout type */
  timeoutType?: 'default' | 'never'
  /** Urgency (Linux) */
  urgency?: 'low' | 'normal' | 'critical'
  /** Silent */
  silent?: boolean
  /** Tag for grouping/replacing */
  tag?: string
}

/**
 * App event types
 */
export type AppEventType =
  | 'ready'
  | 'activate'
  | 'deactivate'
  | 'will-quit'
  | 'quit'
  | 'before-quit'
  | 'window-all-closed'
  | 'open-file'
  | 'open-url'
  | 'theme-changed'
  | 'accent-color-changed'
  | 'display-added'
  | 'display-removed'
  | 'display-metrics-changed'
  | 'power-suspend'
  | 'power-resume'
  | 'power-on-ac'
  | 'power-on-battery'
  | 'lock-screen'
  | 'unlock-screen'
  | 'user-did-become-active'
  | 'user-did-resign-active'

/**
 * App event data map
 */
export interface AppEventMap {
  'ready': void
  'activate': { hasVisibleWindows: boolean }
  'deactivate': void
  'will-quit': { preventDefault: () => void }
  'quit': void
  'before-quit': { preventDefault: () => void }
  'window-all-closed': void
  'open-file': { path: string }
  'open-url': { url: string }
  'theme-changed': { theme: 'light' | 'dark' }
  'accent-color-changed': { color: string }
  'display-added': DisplayInfo
  'display-removed': { id: string }
  'display-metrics-changed': { display: DisplayInfo; changedMetrics: string[] }
  'power-suspend': void
  'power-resume': void
  'power-on-ac': void
  'power-on-battery': void
  'lock-screen': void
  'unlock-screen': void
  'user-did-become-active': void
  'user-did-resign-active': void
}

/**
 * App event handler
 */
export type AppEventHandler<T extends AppEventType> = (_data: AppEventMap[T]) => void

/**
 * Global shortcut handler
 */
export type ShortcutHandler = () => void

// ============================================================================
// App Manager Class
// ============================================================================

/**
 * Application manager for lifecycle and system integration
 */
class AppManager {
  private _listeners: Map<string, Set<Function>> = new Map()
  private _shortcuts: Map<string, ShortcutHandler> = new Map()
  private _info: AppInfo | null = null
  private _preferences: SystemPreferences | null = null
  private _domListeners: Array<{ type: string; handler: EventListener }> = []
  private _mediaQuery: MediaQueryList | null = null
  private _mediaQueryHandler: ((_event: MediaQueryListEvent) => void) | null = null

  constructor() {
    this._setupEventListeners()
  }

  private _addDomListener(type: string, handler: EventListener): void {
    if (typeof window === 'undefined') return
    window.addEventListener(type, handler)
    this._domListeners.push({ type, handler })
  }

  /**
   * Tear down DOM listeners. Intended for tests that construct/destroy
   * the manager and for advanced multi-window setups; the singleton
   * `appManager` is normally process-lived.
   */
  destroy(): void {
    if (typeof window !== 'undefined') {
      for (const { type, handler } of this._domListeners) {
        window.removeEventListener(type, handler)
      }
      this._domListeners = []
      if (this._mediaQuery && this._mediaQueryHandler) {
        this._mediaQuery.removeEventListener('change', this._mediaQueryHandler)
        this._mediaQuery = null
        this._mediaQueryHandler = null
      }
    }
    this._listeners.clear()
    this._shortcuts.clear()
    this._info = null
    this._preferences = null
  }

  private _setupEventListeners(): void {
    if (typeof window !== 'undefined') {
      // System events
      const events: AppEventType[] = [
        'ready', 'activate', 'deactivate', 'will-quit', 'quit', 'before-quit',
        'window-all-closed', 'open-file', 'open-url', 'theme-changed',
        'accent-color-changed', 'display-added', 'display-removed',
        'display-metrics-changed', 'power-suspend', 'power-resume',
        'power-on-ac', 'power-on-battery', 'lock-screen', 'unlock-screen',
        'user-did-become-active', 'user-did-resign-active',
      ]

      events.forEach(event => {
        const handler = ((e: CustomEvent) => {
          // Invalidate caches that the event has just made stale.
          // `_preferences` snapshots theme/accent/reduced-motion/locale,
          // so any of these events must clear it to avoid serving stale
          // values from `getSystemPreferences()`. `_info` snapshots
          // immutable bundle metadata, so it's preserved.
          if (
            event === 'theme-changed'
            || event === 'accent-color-changed'
            || event === 'display-added'
            || event === 'display-removed'
            || event === 'display-metrics-changed'
          ) {
            this._preferences = null
          }
          this._emit(event, e.detail)
        }) as EventListener
        this._addDomListener(`craft:app:${event}`, handler)
      })

      // Global shortcut events
      const shortcutHandler = ((e: CustomEvent) => {
        const accelerator = e.detail?.accelerator
        const handler = this._shortcuts.get(accelerator)
        if (handler) handler()
      }) as EventListener
      this._addDomListener('craft:shortcut', shortcutHandler)

      // Theme change detection via media query
      if (window.matchMedia) {
        this._mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
        this._mediaQueryHandler = (e: MediaQueryListEvent) => {
          this._preferences = null
          this._emit('theme-changed', { theme: e.matches ? 'dark' : 'light' })
        }
        this._mediaQuery.addEventListener('change', this._mediaQueryHandler)
      }
    }
  }

  private _emit(event: string, data?: any): void {
    const listeners = this._listeners.get(event)
    if (listeners) {
      listeners.forEach(fn => fn(data))
    }
  }

  /**
   * Register an event handler
   */
  on<T extends AppEventType>(event: T, handler: AppEventHandler<T>): () => void {
    if (!this._listeners.has(event)) {
      this._listeners.set(event, new Set())
    }
    this._listeners.get(event)!.add(handler)

    return () => {
      this._listeners.get(event)?.delete(handler)
    }
  }

  /**
   * Register a one-time event handler
   */
  once<T extends AppEventType>(event: T, handler: AppEventHandler<T>): () => void {
    const wrapper = (data: AppEventMap[T]) => {
      this._listeners.get(event)?.delete(wrapper)
      handler(data)
    }
    return this.on(event, wrapper as any)
  }

  /**
   * Remove event handler
   */
  off<T extends AppEventType>(event: T, handler: AppEventHandler<T>): void {
    this._listeners.get(event)?.delete(handler)
  }

  // ==========================================================================
  // App Lifecycle
  // ==========================================================================

  /**
   * Quit the application
   */
  async quit(): Promise<void> {
    await this._call('quit')
  }

  /**
   * Exit with code
   */
  async exit(code: number = 0): Promise<void> {
    await this._call('exit', { code })
  }

  /**
   * Relaunch the application
   */
  async relaunch(options?: { args?: string[]; execPath?: string }): Promise<void> {
    await this._call('relaunch', options)
  }

  /**
   * Hide the application (macOS)
   */
  async hide(): Promise<void> {
    await this._call('hide')
  }

  /**
   * Show the application (macOS)
   */
  async show(): Promise<void> {
    await this._call('show')
  }

  /**
   * Focus the application
   */
  async focus(): Promise<void> {
    await this._call('focus')
  }

  // ==========================================================================
  // Dock Icon (macOS)
  // ==========================================================================

  /**
   * Hide dock icon (macOS)
   */
  async hideDockIcon(): Promise<void> {
    await this._call('hideDockIcon')
  }

  /**
   * Show dock icon (macOS)
   */
  async showDockIcon(): Promise<void> {
    await this._call('showDockIcon')
  }

  /**
   * Set dock icon badge
   */
  async setBadge(badge: string | number | null): Promise<void> {
    await this._call('setBadge', { badge: badge?.toString() ?? '' })
  }

  /**
   * Get dock icon badge
   */
  async getBadge(): Promise<string> {
    return this._call('getBadge')
  }

  /**
   * Bounce dock icon (macOS)
   */
  async bounce(type: 'critical' | 'informational' = 'informational'): Promise<number> {
    return this._call('bounce', { type })
  }

  /**
   * Cancel dock icon bounce (macOS)
   */
  async cancelBounce(id: number): Promise<void> {
    await this._call('cancelBounce', { id })
  }

  /**
   * Set dock icon
   */
  async setDockIcon(icon: string): Promise<void> {
    await this._call('setDockIcon', { icon })
  }

  // ==========================================================================
  // App Information
  // ==========================================================================

  /**
   * Get application information
   */
  async getInfo(): Promise<AppInfo> {
    if (!this._info) {
      this._info = await this._call<AppInfo>('getInfo')
    }
    return this._info
  }

  /**
   * Get app name
   */
  async getName(): Promise<string> {
    const info = await this.getInfo()
    return info.name
  }

  /**
   * Get app version
   */
  async getVersion(): Promise<string> {
    const info = await this.getInfo()
    return info.version
  }

  /**
   * Get app path
   */
  async getAppPath(): Promise<string> {
    const info = await this.getInfo()
    return info.appPath
  }

  /**
   * Get path to special directory
   */
  async getPath(name: 'home' | 'appData' | 'userData' | 'temp' | 'exe' | 'desktop' | 'documents' | 'downloads' | 'music' | 'pictures' | 'videos' | 'logs'): Promise<string> {
    return this._call('getPath', { name })
  }

  // ==========================================================================
  // System Preferences
  // ==========================================================================

  /**
   * Get system preferences
   */
  async getSystemPreferences(): Promise<SystemPreferences> {
    if (!this._preferences) {
      this._preferences = await this._call<SystemPreferences>('getSystemPreferences')
    }
    return this._preferences
  }

  /**
   * Check if dark mode is enabled
   */
  async isDarkMode(): Promise<boolean> {
    // Try browser API first
    if (typeof window !== 'undefined' && window.matchMedia) {
      return window.matchMedia('(prefers-color-scheme: dark)').matches
    }
    const prefs = await this.getSystemPreferences()
    return prefs.isDarkMode
  }

  /**
   * Get accent color
   */
  async getAccentColor(): Promise<string> {
    const prefs = await this.getSystemPreferences()
    return prefs.accentColor
  }

  /**
   * Check if reduced motion is enabled
   */
  async isReducedMotion(): Promise<boolean> {
    if (typeof window !== 'undefined' && window.matchMedia) {
      return window.matchMedia('(prefers-reduced-motion: reduce)').matches
    }
    const prefs = await this.getSystemPreferences()
    return prefs.reducedMotion
  }

  /**
   * Get system locale
   */
  async getLocale(): Promise<string> {
    if (typeof navigator !== 'undefined') {
      return navigator.language || 'en-US'
    }
    const prefs = await this.getSystemPreferences()
    return prefs.locale
  }

  // ==========================================================================
  // Display
  // ==========================================================================

  /**
   * Get all displays
   */
  async getDisplays(): Promise<DisplayInfo[]> {
    return this._call('getDisplays')
  }

  /**
   * Get primary display
   */
  async getPrimaryDisplay(): Promise<DisplayInfo> {
    return this._call('getPrimaryDisplay')
  }

  /**
   * Get display at point
   */
  async getDisplayAtPoint(x: number, y: number): Promise<DisplayInfo | null> {
    return this._call('getDisplayAtPoint', { x, y })
  }

  // ==========================================================================
  // Notifications
  // ==========================================================================

  /**
   * Send a notification
   */
  async notify(options: NotificationOptions): Promise<void> {
    await this._call('notify', options)
  }

  /**
   * Check if notifications are supported
   */
  async isNotificationSupported(): Promise<boolean> {
    if (typeof Notification !== 'undefined') {
      return Notification.permission !== 'denied'
    }
    return this._call('isNotificationSupported')
  }

  // ==========================================================================
  // Global Shortcuts
  // ==========================================================================

  /**
   * Register a global shortcut
   */
  async registerShortcut(accelerator: string, handler: ShortcutHandler): Promise<boolean> {
    this._shortcuts.set(accelerator, handler)
    return this._call('registerShortcut', { accelerator })
  }

  /**
   * Unregister a global shortcut
   */
  async unregisterShortcut(accelerator: string): Promise<void> {
    this._shortcuts.delete(accelerator)
    await this._call('unregisterShortcut', { accelerator })
  }

  /**
   * Unregister all global shortcuts
   */
  async unregisterAllShortcuts(): Promise<void> {
    this._shortcuts.clear()
    await this._call('unregisterAllShortcuts')
  }

  /**
   * Check if a shortcut is registered
   */
  async isShortcutRegistered(accelerator: string): Promise<boolean> {
    return this._call('isShortcutRegistered', { accelerator })
  }

  // ==========================================================================
  // Appearance
  // ==========================================================================

  /**
   * Set the app appearance on native hosts.
   */
  async setAppearance(appearance: 'light' | 'dark' | 'system'): Promise<void> {
    await this._call('setAppearance', { appearance })
  }

  /**
   * Get the current effective Light/Dark appearance.
   */
  async getAppearance(): Promise<'light' | 'dark'> {
    return this._call('getAppearance')
  }

  // ==========================================================================
  // Power Management
  // ==========================================================================

  /**
   * Start power save blocker
   */
  async startPowerSaveBlocker(type: 'prevent-app-suspension' | 'prevent-display-sleep'): Promise<number> {
    return this._call('startPowerSaveBlocker', { type })
  }

  /**
   * Stop power save blocker
   */
  async stopPowerSaveBlocker(id: number): Promise<void> {
    await this._call('stopPowerSaveBlocker', { id })
  }

  /**
   * Check if power save blocker is active
   */
  async isPowerSaveBlockerActive(id: number): Promise<boolean> {
    return this._call('isPowerSaveBlockerActive', { id })
  }

  /**
   * Get system idle time
   */
  async getIdleTime(): Promise<number> {
    return this._call('getIdleTime')
  }

  // ==========================================================================
  // Login Items (macOS/Windows)
  // ==========================================================================

  /**
   * Start the app when the user logs in, or stop doing so (macOS 13+).
   *
   * Served by `autoLaunch` (`SMAppService.mainAppService`), which registers the
   * running app bundle. It cannot open the app hidden or with other arguments,
   * and registers only this app, so `openAsHidden`, `path` and `args` are
   * refused rather than ignored. Rejects when macOS declines, for example
   * for a binary that is not inside an app bundle, or before macOS 13.
   */
  async setLoginItemSettings(options: { openAtLogin: boolean, openAsHidden?: boolean, path?: string, args?: string[] }): Promise<void> {
    if (options.openAsHidden || options.path !== undefined || options.args !== undefined)
      throw new Error('setLoginItemSettings supports only openAtLogin: SMAppService registers this app as it is, with no hidden launch, path or arguments')
    const action = options.openAtLogin ? 'enable' : 'disable'
    const result = await this._autoLaunch<{ ok?: boolean, reason?: string }>(action)
    if (!result?.ok)
      throw new Error(`macOS did not ${options.openAtLogin ? 'register' : 'unregister'} the login item${result?.reason ? `: ${result.reason}` : ''}`)
  }

  /**
   * Whether the app starts at login (macOS 13+), from `autoLaunch`.
   *
   * `openAsHidden`, `wasOpenedAtLogin` and `wasOpenedAsHidden` are always
   * false: SMAppService has no hidden launch and does not say how this launch
   * began.
   */
  async getLoginItemSettings(): Promise<{ openAtLogin: boolean, openAsHidden: boolean, wasOpenedAtLogin: boolean, wasOpenedAsHidden: boolean }> {
    const result = await this._autoLaunch<{ value?: boolean }>('isEnabled')
    return { openAtLogin: !!result?.value, openAsHidden: false, wasOpenedAtLogin: false, wasOpenedAsHidden: false }
  }

  // #588: these were sent as `app` actions, which native never served, so in
  // a WebKit host their promise never settled. Login items live on `autoLaunch`.
  private async _autoLaunch<T>(action: 'enable' | 'disable' | 'isEnabled'): Promise<T> {
    if (isWebKitHost())
      return webkitRequest<T>(`autoLaunch.${action}`, { type: 'autoLaunch', action })
    return getBridge().request(`autoLaunch.${action}`) as Promise<T>
  }

  // ==========================================================================
  // Helper Methods
  // ==========================================================================

  private async _call<T = void>(action: string, data?: Record<string, any>): Promise<T> {
    if (isWebKitHost()) {
      // Route via the unified WKWebView pending queue so getters
      // (`getInfo`, `getDisplays`, `getBadge`, `getAppearance`, …) actually
      // receive their native response instead of resolving with `undefined`.
      return webkitRequest<T>(`app.${action}`, {
        type: 'app',
        action,
        data,
      })
    }

    const bridge = getBridge()
    return bridge.request(`app.${action}`, data)
  }
}

// ============================================================================
// Exports
// ============================================================================

/**
 * Global app manager instance
 */
export const appManager: AppManager = new AppManager()

/**
 * Alias for convenience
 */
export const app: AppManager = appManager

// Re-export common functionality directly
export const quit = (): Promise<void> => appManager.quit()
export const hide = (): Promise<void> => appManager.hide()
export const show = (): Promise<void> => appManager.show()
export const focus = (): Promise<void> => appManager.focus()
export const hideDockIcon = (): Promise<void> => appManager.hideDockIcon()
export const showDockIcon = (): Promise<void> => appManager.showDockIcon()
export const setBadge = (badge: string | number | null): Promise<void> => appManager.setBadge(badge)
export const getInfo = (): Promise<AppInfo> => appManager.getInfo()
export const getVersion = (): Promise<string> => appManager.getVersion()
export const getName = (): Promise<string> => appManager.getName()
export const getPath = (name: Parameters<typeof appManager.getPath>[0]): Promise<string> => appManager.getPath(name)
export const isDarkMode = (): Promise<boolean> => appManager.isDarkMode()
export const getLocale = (): Promise<string> => appManager.getLocale()
export const notify = (options: NotificationOptions): Promise<void> => appManager.notify(options)
export const registerShortcut = (accelerator: string, handler: ShortcutHandler): Promise<boolean> => appManager.registerShortcut(accelerator, handler)
export const unregisterShortcut = (accelerator: string): Promise<void> => appManager.unregisterShortcut(accelerator)

export default appManager
