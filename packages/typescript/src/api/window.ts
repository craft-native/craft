/**
 * Craft Window API
 * Comprehensive window management for desktop applications
 * @module @craft-native/api/window
 */

import { getBridge } from '../bridge/core.js'
import { isWebKitHost, webkitRequest } from '../bridge/webkit-pending.js'

// ============================================================================
// Types
// ============================================================================

/**
 * Window position on screen
 */
export interface WindowPosition {
  x: number
  y: number
}

/**
 * Window size dimensions
 */
export interface WindowSize {
  width: number
  height: number
}

/**
 * Window bounds (position + size)
 */
export interface WindowBounds {
  x: number
  y: number
  width: number
  height: number
}

/**
 * Window state information
 */
export interface WindowState {
  /** Whether window is visible */
  isVisible: boolean
  /** Whether window is minimized */
  isMinimized: boolean
  /** Whether window is maximized */
  isMaximized: boolean
  /** Whether window is fullscreen */
  isFullscreen: boolean
  /** Whether window is focused */
  isFocused: boolean
  /** Whether window is always on top */
  isAlwaysOnTop: boolean
  /** Current window bounds */
  bounds: WindowBounds
}

/**
 * Window creation options
 */
export interface WindowCreateOptions {
  /** Window title */
  title?: string
  /** Window width */
  width?: number
  /** Window height */
  height?: number
  /** X position (undefined = center) */
  x?: number
  /** Y position (undefined = center) */
  y?: number
  /** Minimum width */
  minWidth?: number
  /** Minimum height */
  minHeight?: number
  /** Maximum width */
  maxWidth?: number
  /** Maximum height */
  maxHeight?: number
  /** Whether window is resizable */
  resizable?: boolean
  /** Whether window is movable */
  movable?: boolean
  /** Whether window is minimizable */
  minimizable?: boolean
  /** Whether window is maximizable */
  maximizable?: boolean
  /** Whether window is closable */
  closable?: boolean
  /** Whether window is focusable */
  focusable?: boolean
  /** Whether window is always on top */
  alwaysOnTop?: boolean
  /** Whether window is fullscreen */
  fullscreen?: boolean
  /** Whether window is frameless */
  frameless?: boolean
  /** Whether window has transparency */
  transparent?: boolean
  /** Background color (for transparent windows) */
  backgroundColor?: string
  /** Whether to show in taskbar */
  skipTaskbar?: boolean
  /** Whether titlebar is hidden */
  titlebarHidden?: boolean
  /** Draw native macOS sidebar material behind a web-rendered sidebar */
  webSidebarMaterial?: boolean
  /** Width of the native material backdrop behind a web-rendered sidebar */
  webSidebarWidth?: number
  /** White/dark tint opacity over the native material backdrop */
  webSidebarMaterialOpacity?: number
  /** Titlebar style (macOS) */
  titlebarStyle?: 'default' | 'hidden' | 'hiddenInset' | 'customButtonsOnHover'
  /** Vibrancy effect (macOS) */
  vibrancy?: 'appearance-based' | 'light' | 'dark' | 'titlebar' | 'selection' | 'menu' | 'popover' | 'sidebar' | 'header' | 'sheet' | 'window' | 'hud' | 'fullscreen-ui' | 'tooltip' | 'content' | 'under-window' | 'under-page'
  /** Background material (Windows 11) */
  backgroundMaterial?: 'auto' | 'none' | 'mica' | 'acrylic' | 'tabbed'
  /** Parent window ID */
  parent?: string
  /** Whether this is a modal window */
  modal?: boolean
  /** HTML content to load */
  html?: string
  /** URL to load */
  url?: string
}

/**
 * Window event types
 */
export type WindowEventType =
  | 'show'
  | 'hide'
  | 'focus'
  | 'blur'
  | 'minimize'
  | 'maximize'
  | 'unmaximize'
  | 'restore'
  | 'resize'
  | 'move'
  | 'close'
  | 'closed'
  | 'enter-fullscreen'
  | 'leave-fullscreen'
  | 'ready-to-show'

/**
 * Window event data map
 */
export interface WindowEventMap {
  'show': void
  'hide': void
  'focus': void
  'blur': void
  'minimize': void
  'maximize': void
  'unmaximize': void
  'restore': void
  'resize': WindowSize
  'move': WindowPosition
  'close': { preventDefault: () => void }
  'closed': void
  'enter-fullscreen': void
  'leave-fullscreen': void
  'ready-to-show': void
}

/**
 * Window event handler
 */
export type WindowEventHandler<T extends WindowEventType> = (_data: WindowEventMap[T]) => void

// ============================================================================
// Window Class
// ============================================================================

/**
 * Window instance for managing a single window
 */
export class Window {
  private _id: string
  private _listeners: Map<string, Set<Function>> = new Map()
  private _closed: boolean = false
  private _domListeners: Array<{ type: string; handler: EventListener }> = []

  constructor(id: string) {
    this._id = id
    this._setupEventListeners()
  }

  /**
   * Get window ID
   */
  get id(): string {
    return this._id
  }

  /**
   * Check if window is closed
   */
  get isClosed(): boolean {
    return this._closed
  }

  private _setupEventListeners(): void {
    if (typeof window !== 'undefined') {
      const eventTypes: WindowEventType[] = [
        'show', 'hide', 'focus', 'blur', 'minimize', 'maximize',
        'unmaximize', 'restore', 'resize', 'move', 'close', 'closed',
        'enter-fullscreen', 'leave-fullscreen', 'ready-to-show'
      ]

      eventTypes.forEach(type => {
        const handler = ((event: CustomEvent) => {
          if (event.detail?.windowId === this._id || !event.detail?.windowId) {
            this._emit(type, event.detail?.data)
          }
        }) as EventListener
        const eventName = `craft:window:${type}`
        globalThis.window.addEventListener(eventName, handler)
        this._domListeners.push({ type: eventName, handler })
      })
    }
  }

  private _cleanupEventListeners(): void {
    if (typeof window !== 'undefined') {
      for (const { type, handler } of this._domListeners) {
        globalThis.window.removeEventListener(type, handler)
      }
      this._domListeners = []
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
  on<T extends WindowEventType>(event: T, handler: WindowEventHandler<T>): () => void {
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
  once<T extends WindowEventType>(event: T, handler: WindowEventHandler<T>): () => void {
    const wrapper = (data: WindowEventMap[T]) => {
      this._listeners.get(event)?.delete(wrapper)
      handler(data)
    }
    return this.on(event, wrapper as any)
  }

  /**
   * Remove an event handler
   */
  off<T extends WindowEventType>(event: T, handler: WindowEventHandler<T>): void {
    this._listeners.get(event)?.delete(handler)
  }

  // ==========================================================================
  // Window Control Methods
  // ==========================================================================

  /**
   * Show the window
   */
  async show(): Promise<void> {
    await this._call('show')
  }

  /**
   * Hide the window
   */
  async hide(): Promise<void> {
    await this._call('hide')
  }

  /**
   * Toggle window visibility
   */
  async toggle(): Promise<void> {
    await this._call('toggle')
  }

  /**
   * Focus the window
   */
  async focus(): Promise<void> {
    await this._call('focus')
  }

  /**
   * Blur the window (remove focus)
   */
  async blur(): Promise<void> {
    await this._call('blur')
  }

  /**
   * Minimize the window
   */
  async minimize(): Promise<void> {
    await this._call('minimize')
  }

  /**
   * Maximize the window
   */
  async maximize(): Promise<void> {
    await this._call('maximize')
  }

  /**
   * Unmaximize the window
   */
  async unmaximize(): Promise<void> {
    await this._call('unmaximize')
  }

  /**
   * Restore the window from minimized/maximized state
   */
  async restore(): Promise<void> {
    await this._call('restore')
  }

  /**
   * Close the window
   */
  async close(): Promise<void> {
    await this._call('close')
    this._closed = true
    this._cleanupEventListeners()
  }

  /**
   * Destroy the window (force close without events)
   */
  async destroy(): Promise<void> {
    await this._call('destroy')
    this._closed = true
    this._cleanupEventListeners()
  }

  /**
   * Enter fullscreen mode
   */
  async setFullscreen(fullscreen: boolean = true): Promise<void> {
    await this._call('setFullscreen', { fullscreen })
  }

  /**
   * Toggle fullscreen mode
   */
  async toggleFullscreen(): Promise<void> {
    await this._call('toggleFullscreen')
  }

  // ==========================================================================
  // Window Properties
  // ==========================================================================

  /**
   * Set window title
   */
  async setTitle(title: string): Promise<void> {
    await this._call('setTitle', { title })
  }

  /**
   * Get window title
   */
  async getTitle(): Promise<string> {
    return this._call('getTitle')
  }

  /**
   * Set window size
   */
  async setSize(width: number, height: number, animate?: boolean): Promise<void> {
    await this._call('setSize', { width, height, animate })
  }

  /**
   * Get window size
   */
  async getSize(): Promise<WindowSize> {
    return this._call('getSize')
  }

  /**
   * Set minimum window size
   */
  async setMinimumSize(width: number, height: number): Promise<void> {
    await this._call('setMinimumSize', { width, height })
  }

  /**
   * Set maximum window size
   */
  async setMaximumSize(width: number, height: number): Promise<void> {
    await this._call('setMaximumSize', { width, height })
  }

  /**
   * Set window position
   */
  async setPosition(x: number, y: number, animate?: boolean): Promise<void> {
    await this._call('setPosition', { x, y, animate })
  }

  /**
   * Move window by a relative screen delta.
   */
  async moveBy(dx: number, dy: number): Promise<void> {
    await this._call('moveBy', { dx, dy })
  }

  /**
   * Get window position
   */
  async getPosition(): Promise<WindowPosition> {
    return this._call('getPosition')
  }

  /**
   * Set window bounds (position and size)
   */
  async setBounds(bounds: Partial<WindowBounds>, animate?: boolean): Promise<void> {
    await this._call('setBounds', { ...bounds, animate })
  }

  /**
   * Get window bounds
   */
  async getBounds(): Promise<WindowBounds> {
    return this._call('getBounds')
  }

  /**
   * Center window on screen
   */
  async center(): Promise<void> {
    await this._call('center')
  }

  /**
   * Set always on top
   */
  async setAlwaysOnTop(alwaysOnTop: boolean, level?: 'normal' | 'floating' | 'modal-panel' | 'main-menu' | 'status' | 'pop-up-menu' | 'screen-saver'): Promise<void> {
    await this._call('setAlwaysOnTop', { alwaysOnTop, level })
  }

  /**
   * Check if window is always on top
   */
  async isAlwaysOnTop(): Promise<boolean> {
    return this._call('isAlwaysOnTop')
  }

  /**
   * Set window resizable
   */
  async setResizable(resizable: boolean): Promise<void> {
    await this._call('setResizable', { resizable })
  }

  /**
   * Check if window is resizable
   */
  async isResizable(): Promise<boolean> {
    return this._call('isResizable')
  }

  /**
   * Set window movable
   */
  async setMovable(movable: boolean): Promise<void> {
    await this._call('setMovable', { movable })
  }

  /**
   * Start moving the native window from the current pointer event.
   */
  async startDrag(): Promise<void> {
    await this._call('startDrag')
  }

  /**
   * Check if window is movable
   */
  async isMovable(): Promise<boolean> {
    return this._call('isMovable')
  }

  /**
   * Set minimum window size
   */
  async setMinSize(width: number, height: number): Promise<void> {
    await this._call('setMinSize', { width, height })
  }

  /**
   * Set maximum window size
   */
  async setMaxSize(width: number, height: number): Promise<void> {
    await this._call('setMaxSize', { width, height })
  }

  /**
   * Set window opacity
   */
  async setOpacity(opacity: number): Promise<void> {
    await this._call('setOpacity', { opacity: Math.max(0, Math.min(1, opacity)) })
  }

  /**
   * Get window opacity
   */
  async getOpacity(): Promise<number> {
    return this._call('getOpacity')
  }

  /**
   * Set background color
   */
  async setBackgroundColor(color: string): Promise<void> {
    await this._call('setBackgroundColor', { color })
  }

  /**
   * Get window state
   */
  async getState(): Promise<WindowState> {
    return this._call('getState')
  }

  // ==========================================================================
  // macOS Specific
  // ==========================================================================

  /**
   * Set vibrancy effect (macOS)
   */
  async setVibrancy(vibrancy: WindowCreateOptions['vibrancy'] | null): Promise<void> {
    await this._call('setVibrancy', { vibrancy })
  }

  /**
   * Where the platform's window buttons are — read, not written.
   *
   * There was a `setTrafficLightPosition` here, and a `trafficLightPosition`
   * window option beside it. Neither ever moved anything: the host has no
   * handler for the call, and AppKit re-lays out the standard window buttons
   * after any one-shot `setFrameOrigin:`, which is why `macos.zig` leaves them
   * where the window server puts them and says so at length.
   *
   * What a layout actually needs is the opposite direction — where they *are*,
   * which the host measures and publishes on every window:
   *
   *   window.craft.windowControls        { style, x, y, width, height, ... }
   *   --craft-window-controls-width      the room to leave, in CSS
   *
   * See `CraftWindowControls`, and `docs/features/window-management.md`.
   */
  get windowControls(): import('../types.js').CraftWindowControls | undefined {
    return (globalThis as { craft?: { windowControls?: import('../types.js').CraftWindowControls } })
      .craft?.windowControls
  }

  /**
   * Set window level (macOS)
   */
  async setWindowLevel(level: number): Promise<void> {
    await this._call('setWindowLevel', { level })
  }

  /**
   * Enable/disable window shadow (macOS)
   */
  async setHasShadow(hasShadow: boolean): Promise<void> {
    await this._call('setHasShadow', { hasShadow })
  }

  // ==========================================================================
  // Windows Specific
  // ==========================================================================

  /**
   * Set background material (Windows 11)
   */
  async setBackgroundMaterial(material: WindowCreateOptions['backgroundMaterial']): Promise<void> {
    await this._call('setBackgroundMaterial', { material })
  }

  /**
   * Flash window in taskbar (Windows)
   */
  async flashFrame(flash: boolean): Promise<void> {
    await this._call('flashFrame', { flash })
  }

  /**
   * Set taskbar overlay icon (Windows)
   */
  async setOverlayIcon(icon: string | null, description?: string): Promise<void> {
    await this._call('setOverlayIcon', { icon, description })
  }

  // ==========================================================================
  // Content
  // ==========================================================================

  /**
   * Load HTML content
   */
  async loadHTML(html: string): Promise<void> {
    await this._call('loadHTML', { html })
  }

  /**
   * Load URL
   */
  async loadURL(url: string): Promise<void> {
    await this._call('loadURL', { url })
  }

  /**
   * Reload content
   */
  async reload(): Promise<void> {
    await this._call('reload')
  }

  /**
   * Execute JavaScript in window
   */
  async executeJavaScript<T = unknown>(code: string): Promise<T> {
    return this._call('executeJavaScript', { code })
  }

  // ==========================================================================
  // Helper Methods
  // ==========================================================================

  private async _call<T = void>(action: string, data?: Record<string, any>): Promise<T> {
    if (isWebKitHost()) {
      // Route via the unified WKWebView pending queue so getters actually
      // receive their native response instead of resolving with `undefined`
      // (the previous implementation silently broke `getTitle()`,
      // `getSize()`, `getBounds()`, `getState()`, etc.).
      return webkitRequest<T>(`window.${action}`, {
        type: 'window',
        action,
        windowId: this._id,
        data,
      })
    }

    // Fallback to unified NativeBridge.
    const bridge = getBridge()
    return bridge.request(`window.${action}`, { windowId: this._id, ...data })
  }
}

// ============================================================================
// Window Manager
// ============================================================================

/**
 * Window manager for creating and managing multiple windows
 */
class WindowManager {
  private _windows: Map<string, Window> = new Map()
  private _currentWindow: Window | null = null
  private _idCounter: number = 0

  constructor() {
    // Initialize current window if in WebView context
    if (typeof globalThis.window !== 'undefined') {
      this._currentWindow = new Window('main')
      this._windows.set('main', this._currentWindow)
    }
  }

  /**
   * Get current window (the window this code is running in)
   */
  get current(): Window {
    if (!this._currentWindow) {
      this._currentWindow = new Window('main')
      this._windows.set('main', this._currentWindow)
    }
    return this._currentWindow
  }

  /**
   * Get all windows
   */
  get all(): Window[] {
    return Array.from(this._windows.values())
  }

  /**
   * Get window by ID
   */
  get(id: string): Window | undefined {
    return this._windows.get(id)
  }

  /**
   * Create a new window
   */
  async create(options: WindowCreateOptions = {}): Promise<Window> {
    const id = `window_${++this._idCounter}_${Date.now()}`

    const bridge = getBridge()
    await bridge.request('window.create', { id, ...options })

    const win = new Window(id)
    this._windows.set(id, win)

    return win
  }

  /**
   * Get focused window
   */
  async getFocused(): Promise<Window | null> {
    const bridge = getBridge()
    const id = await bridge.request<void, string | null>('window.getFocused')
    return id ? this._windows.get(id) || null : null
  }

  // ==========================================================================
  // Convenience methods for current window
  // ==========================================================================

  /** Show current window */
  show = (): Promise<void> => this.current.show()

  /** Hide current window */
  hide = (): Promise<void> => this.current.hide()

  /** Toggle current window visibility */
  toggle = (): Promise<void> => this.current.toggle()

  /** Minimize current window */
  minimize = (): Promise<void> => this.current.minimize()

  /** Maximize current window */
  maximize = (): Promise<void> => this.current.maximize()

  /** Close current window */
  close = (): Promise<void> => this.current.close()

  /** Focus current window */
  focus = (): Promise<void> => this.current.focus()

  /** Center current window */
  center = (): Promise<void> => this.current.center()

  /** Set current window fullscreen */
  setFullscreen = (fullscreen?: boolean): Promise<void> => this.current.setFullscreen(fullscreen)

  /** Toggle current window fullscreen */
  toggleFullscreen = (): Promise<void> => this.current.toggleFullscreen()

  /** Set current window title */
  setTitle = (title: string): Promise<void> => this.current.setTitle(title)

  /** Set current window size */
  setSize = (width: number, height: number, animate?: boolean): Promise<void> => this.current.setSize(width, height, animate)

  /** Set current window position */
  setPosition = (x: number, y: number, animate?: boolean): Promise<void> => this.current.setPosition(x, y, animate)

  /** Move current window by a relative screen delta */
  moveBy = (dx: number, dy: number): Promise<void> => this.current.moveBy(dx, dy)

  /** Set current window bounds */
  setBounds = (bounds: Partial<WindowBounds>, animate?: boolean): Promise<void> => this.current.setBounds(bounds, animate)

  /** Set current window always on top */
  setAlwaysOnTop = (alwaysOnTop: boolean): Promise<void> => this.current.setAlwaysOnTop(alwaysOnTop)

  /** Set current window opacity */
  setOpacity = (opacity: number): Promise<void> => this.current.setOpacity(opacity)

  /** Set current window background color */
  setBackgroundColor = (color: string): Promise<void> => this.current.setBackgroundColor(color)

  /** Set current window vibrancy (macOS) */
  setVibrancy = (vibrancy: WindowCreateOptions['vibrancy'] | null): Promise<void> => this.current.setVibrancy(vibrancy)

  /** Set current window resizable */
  setResizable = (resizable: boolean): Promise<void> => this.current.setResizable(resizable)

  /** Start moving current window from a native pointer event */
  startDrag = (): Promise<void> => this.current.startDrag()

  /** Get current window state */
  getState = (): Promise<WindowState> => this.current.getState()

  /** Register event handler on current window */
  on = <T extends WindowEventType>(event: T, handler: WindowEventHandler<T>): (() => void) => this.current.on(event, handler)

  /** Register one-time event handler on current window */
  once = <T extends WindowEventType>(event: T, handler: WindowEventHandler<T>): (() => void) => this.current.once(event, handler)
}

// ============================================================================
// Exports
// ============================================================================

/**
 * Global window manager instance
 */
export const windowManager: WindowManager = new WindowManager()

/**
 * Alias for convenience - manage the current window and child windows.
 */
export const win: WindowManager = windowManager

/**
 * Documentation-friendly alias for the window manager.
 */
export const window: WindowManager = windowManager

/**
 * Create a new native window.
 */
export function createWindow(_options?: WindowCreateOptions): Promise<Window>
export function createWindow(_html: string, _options?: WindowCreateOptions): Promise<Window>
export function createWindow(
  htmlOrOptions: string | WindowCreateOptions = {},
  options: WindowCreateOptions = {},
): Promise<Window> {
  const windowOptions = typeof htmlOrOptions === 'string'
    ? { ...options, html: htmlOrOptions }
    : htmlOrOptions

  return windowManager.create(windowOptions)
}

export default windowManager
