/**
 * Craft System Tray / Menubar API
 * Comprehensive system tray and menubar app management
 * @module @craft-native/api/tray
 */

import { getBridge } from '../bridge/core.js'

// ============================================================================
// Types
// ============================================================================

/**
 * Menu item configuration
 */
export interface MenuItem {
  /** Unique identifier */
  id?: string
  /** Display label */
  label?: string
  /** Menu item type */
  type?: 'normal' | 'separator' | 'checkbox' | 'radio' | 'submenu'
  /** Checked state (checkbox/radio) */
  checked?: boolean
  /** Enabled state */
  enabled?: boolean
  /** Visible state */
  visible?: boolean
  /** Icon path or SF Symbol name */
  icon?: string
  /** Keyboard shortcut (e.g., 'Cmd+Q', 'Ctrl+Shift+N') */
  shortcut?: string
  /** Action identifier or built-in action */
  action?: 'show' | 'hide' | 'toggle' | 'quit' | string
  /** Submenu items */
  submenu?: MenuItem[]
  /** Tooltip text */
  tooltip?: string
  /** Role (built-in menu item) */
  role?: 'undo' | 'redo' | 'cut' | 'copy' | 'paste' | 'selectAll' | 'delete' | 'minimize' | 'close' | 'quit' | 'toggleFullScreen' | 'hide' | 'hideOthers' | 'unhide' | 'front' | 'zoom' | 'window' | 'help' | 'about' | 'services' | 'recentDocuments' | 'clearRecentDocuments'
}

/**
 * Tray click event
 */
export interface TrayClickEvent {
  /** Mouse button clicked */
  button: 'left' | 'right' | 'middle'
  /** Click timestamp */
  timestamp: number
  /** Double click */
  doubleClick?: boolean
  /** Alt/Option key held */
  altKey?: boolean
  /** Shift key held */
  shiftKey?: boolean
  /** Control key held */
  ctrlKey?: boolean
  /** Command/Meta key held */
  metaKey?: boolean
  /** Click position */
  position?: { x: number; y: number }
  /** Tray bounds */
  bounds?: { x: number; y: number; width: number; height: number }
}

/**
 * Tray configuration options
 */
export interface TrayOptions {
  /** Title/text to display in menubar */
  title?: string
  /** Icon path or template image name */
  icon?: string
  /** Tooltip text */
  tooltip?: string
  /** Menu items */
  menu?: MenuItem[]
  /** Highlight mode on click */
  highlightMode?: 'always' | 'selection' | 'never'
  /** Ignore double click events */
  ignoreDoubleClickEvents?: boolean
}

/**
 * Menubar app configuration
 */
export interface MenubarAppConfig {
  /** Tray title/text */
  title?: string
  /** Tray icon */
  icon?: string
  /** Tooltip */
  tooltip?: string
  /** Menu items */
  menu?: MenuItem[]
  /** Show window on tray click */
  showWindowOnClick?: boolean
  /** Window width when shown */
  windowWidth?: number
  /** Window height when shown */
  windowHeight?: number
  /** Window position relative to tray */
  windowPosition?: 'center' | 'trayCenter' | 'trayBottomCenter' | 'trayBottomLeft' | 'trayBottomRight'
  /** Arrow pointing to tray icon */
  showArrow?: boolean
  /** Vibrancy effect for popup window (macOS) */
  vibrancy?: 'light' | 'dark' | 'titlebar' | 'selection' | 'menu' | 'popover' | 'sidebar'
  /** Hide dock icon (macOS) */
  hideDockIcon?: boolean
  /** Show on all workspaces/spaces */
  showOnAllWorkspaces?: boolean
  /** Activation policy (macOS) */
  activationPolicy?: 'regular' | 'accessory' | 'prohibited'
}

/**
 * Tray event types
 */
export type TrayEventType =
  | 'click'
  | 'right-click'
  | 'double-click'
  | 'mouse-enter'
  | 'mouse-leave'
  | 'mouse-move'
  | 'drop-files'
  | 'drop-text'
  | 'menu-click'
  | 'balloon-click'
  | 'balloon-closed'

/**
 * Tray event data map
 */
export interface TrayEventMap {
  'click': TrayClickEvent
  'right-click': TrayClickEvent
  'double-click': TrayClickEvent
  'mouse-enter': { position: { x: number; y: number } }
  'mouse-leave': void
  'mouse-move': { position: { x: number; y: number } }
  'drop-files': { files: string[] }
  'drop-text': { text: string }
  'menu-click': { menuId: string; action: string }
  'balloon-click': void
  'balloon-closed': void
}

/**
 * Tray event handler
 */
export type TrayEventHandler<T extends TrayEventType> = (_data: TrayEventMap[T]) => void

// ============================================================================
// System Tray Class
// ============================================================================

/**
 * System tray instance
 */
export class SystemTray {
  private _id: string
  private _options: TrayOptions
  private _listeners: Map<string, Set<Function>> = new Map()
  private _menuHandlers: Map<string, Function> = new Map()
  private _destroyed: boolean = false
  // Tracked DOM listeners so we can remove them on destroy() — without
  // this the listener count grew unbounded on each tray construction
  // and multiple trays all received each others' click events.
  private _domListeners: Array<{ type: string; handler: EventListener }> = []

  constructor(id: string, options: TrayOptions = {}) {
    this._id = id
    this._options = options
    this._setupEventListeners()
  }

  /**
   * Get tray ID
   */
  get id(): string {
    return this._id
  }

  /**
   * Check if tray is destroyed
   */
  get isDestroyed(): boolean {
    return this._destroyed
  }

  /**
   * Filter incoming events to those addressed to this tray. The native
   * side may attach `trayId` to `event.detail`; older hosts that don't
   * set it fall through (we still fire — single-tray apps shouldn't
   * regress).
   */
  private _isForThisTray(detail: any): boolean {
    if (!detail) return true
    const id = detail.trayId ?? detail.id
    if (id === undefined || id === null) return true
    return id === this._id
  }

  private _addDomListener(type: string, handler: EventListener): void {
    if (typeof window === 'undefined') return
    window.addEventListener(type, handler)
    this._domListeners.push({ type, handler })
  }

  private _setupEventListeners(): void {
    if (typeof window !== 'undefined') {
      this._addDomListener('craft:tray:click', ((event: CustomEvent) => {
        if (this._isForThisTray(event.detail)) this._emit('click', event.detail)
      }) as EventListener)

      this._addDomListener('craft:tray:rightClick', ((event: CustomEvent) => {
        if (this._isForThisTray(event.detail)) this._emit('right-click', event.detail)
      }) as EventListener)

      this._addDomListener('craft:tray:doubleClick', ((event: CustomEvent) => {
        if (this._isForThisTray(event.detail)) this._emit('double-click', event.detail)
      }) as EventListener)

      this._addDomListener('craft:tray:menuAction', ((event: CustomEvent) => {
        if (!this._isForThisTray(event.detail)) return
        const action = event.detail?.action
        this._emit('menu-click', { menuId: action, action })

        const handler = this._menuHandlers.get(action)
        if (handler) handler()
      }) as EventListener)

      this._addDomListener('craft:tray:dropFiles', ((event: CustomEvent) => {
        if (this._isForThisTray(event.detail)) this._emit('drop-files', { files: event.detail?.files || [] })
      }) as EventListener)

      this._addDomListener('craft:tray:dropText', ((event: CustomEvent) => {
        if (this._isForThisTray(event.detail)) this._emit('drop-text', { text: event.detail?.text || '' })
      }) as EventListener)
    }
  }

  /**
   * Tear down DOM listeners. Idempotent. Always pair with `destroy()` on
   * the manager when constructing trays in tests/long-lived processes.
   */
  protected _teardownDomListeners(): void {
    if (typeof window === 'undefined') return
    for (const { type, handler } of this._domListeners) {
      window.removeEventListener(type, handler)
    }
    this._domListeners = []
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
  on<T extends TrayEventType>(event: T, handler: TrayEventHandler<T>): () => void {
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
  once<T extends TrayEventType>(event: T, handler: TrayEventHandler<T>): () => void {
    const wrapper = (data: TrayEventMap[T]) => {
      this._listeners.get(event)?.delete(wrapper)
      handler(data)
    }
    return this.on(event, wrapper as any)
  }

  /**
   * Remove event handler
   */
  off<T extends TrayEventType>(event: T, handler: TrayEventHandler<T>): void {
    this._listeners.get(event)?.delete(handler)
  }

  // ==========================================================================
  // Tray Control Methods
  // ==========================================================================

  /**
   * Set tray title/text
   */
  async setTitle(title: string): Promise<void> {
    this._options.title = title
    await this._call('setTitle', title)
  }

  /**
   * Get current title
   */
  getTitle(): string {
    return this._options.title || ''
  }

  /**
   * Set tray icon
   */
  async setIcon(icon: string): Promise<void> {
    this._options.icon = icon
    // Native reads `{ icon }`: an SF Symbol name, a Craft icon alias, or a path.
    await this._call('setIcon', JSON.stringify({ icon }))
  }

  /**
   * Set tray tooltip
   */
  async setTooltip(tooltip: string): Promise<void> {
    this._options.tooltip = tooltip
    await this._call('setTooltip', tooltip)
  }

  /**
   * Set or update menu
   */
  async setMenu(items: MenuItem[]): Promise<void> {
    this._options.menu = items

    // Process items to add handlers
    const processItems = (menuItems: MenuItem[]): MenuItem[] => {
      return menuItems.map((item, index) => {
        const processedItem = { ...item }

        // Generate ID if not provided
        if (!processedItem.id && processedItem.label) {
          processedItem.id = `menu_${index}_${Date.now()}`
        }

        // Native routes a click by `action`, not `id`, and gives an item
        // without one no target at all - so a menu built from ids alone
        // rendered, and no click on it ever reached onMenuAction.
        if (!processedItem.action && processedItem.id && processedItem.type !== 'separator') {
          processedItem.action = processedItem.id
        }

        // Process submenu recursively
        if (processedItem.submenu) {
          processedItem.submenu = processItems(processedItem.submenu)
        }

        return processedItem
      })
    }

    const processedItems = processItems(items)
    await this._call('setMenu', JSON.stringify(processedItems))
  }

  /**
   * Update a single menu item
   */
  async updateMenuItem(id: string, updates: Partial<MenuItem>): Promise<void> {
    await this._call('updateMenuItem', JSON.stringify({ id, updates }))
  }

  /**
   * Register a handler for a menu item action
   */
  onMenuAction(actionId: string, handler: () => void): () => void {
    this._menuHandlers.set(actionId, handler)
    return () => {
      this._menuHandlers.delete(actionId)
    }
  }

  /**
   * Show tray icon
   */
  async show(): Promise<void> {
    await this._call('show', '')
  }

  /**
   * Hide tray icon
   */
  async hide(): Promise<void> {
    await this._call('hide', '')
  }

  /**
   * Set highlight mode
   */
  async setHighlightMode(mode: 'always' | 'selection' | 'never'): Promise<void> {
    await this._call('setHighlightMode', mode)
  }

  /**
   * Display balloon notification (Windows)
   */
  async displayBalloon(options: { title: string; content: string; icon?: 'none' | 'info' | 'warning' | 'error'; largeIcon?: boolean; noSound?: boolean; respectQuietTime?: boolean }): Promise<void> {
    await this._call('displayBalloon', JSON.stringify(options))
  }

  /**
   * Remove balloon notification (Windows)
   */
  async removeBalloon(): Promise<void> {
    await this._call('removeBalloon', '')
  }

  /**
   * Get tray bounds (position and size)
   */
  async getBounds(): Promise<{ x: number; y: number; width: number; height: number }> {
    return this._call('getBounds', '')
  }

  /**
   * Destroy the tray
   */
  async destroy(): Promise<void> {
    await this._call('destroy', '')
    this._destroyed = true
    this._listeners.clear()
    this._menuHandlers.clear()
    this._teardownDomListeners()
  }

  // ==========================================================================
  // Convenience Methods
  // ==========================================================================

  /**
   * Show window when tray is clicked
   */
  onClickShowWindow(): () => void {
    return this.on('click', () => {
      if (typeof window !== 'undefined' && (window as any).craft?.window?.show) {
        (window as any).craft.window.show()
      }
    })
  }

  /**
   * Toggle window when tray is clicked
   */
  onClickToggleWindow(): () => void {
    return this.on('click', () => {
      if (typeof window !== 'undefined' && (window as any).craft?.window?.toggle) {
        (window as any).craft.window.toggle()
      }
    })
  }

  // ==========================================================================
  // Helper Methods
  // ==========================================================================

  private async _call<T = void>(action: string, data: string | object): Promise<T> {
    if (typeof window !== 'undefined' && (window as any).webkit?.messageHandlers?.craft) {
      return new Promise((resolve, reject) => {
        try {
          // The native dispatcher reads `t` (target) and `a` (action) and drops
          // anything else without a word: this used to post `type`/`action`/
          // `data`, so setTitle, setIcon and setMenu did nothing on macOS.
          // Same shape as `_post` in the injected craft-bridge.js.
          (window as any).webkit.messageHandlers.craft.postMessage({
            t: 'tray',
            a: action,
            d: typeof data === 'string' ? data : JSON.stringify(data),
          })
          resolve(undefined as T)
        }
catch (error) {
          reject(error)
        }
      })
    }

    const bridge = getBridge()
    return bridge.request(`tray.${action}`, { data })
  }
}

// ============================================================================
// Menubar App Class
// ============================================================================

/**
 * Menubar app with optional popup window
 * Perfect for:
 * - Status bar utilities (Pomodoro timers, CPU monitors)
 * - Quick access tools (clipboard managers, color pickers)
 * - Background services with UI (sync status, VPN controls)
 */
export class MenubarApp {
  private _tray: SystemTray
  private _config: MenubarAppConfig
  private _windowVisible: boolean = false

  constructor(config: MenubarAppConfig = {}) {
    this._config = {
      showWindowOnClick: true,
      windowWidth: 320,
      windowHeight: 400,
      windowPosition: 'trayBottomCenter',
      hideDockIcon: true,
      ...config
    }

    this._tray = new SystemTray('menubar', {
      title: config.title,
      icon: config.icon,
      tooltip: config.tooltip,
      menu: config.menu
    })

    this._setupBehavior()
  }

  /**
   * Get the underlying tray instance
   */
  get tray(): SystemTray {
    return this._tray
  }

  /**
   * Check if popup window is visible
   */
  get isWindowVisible(): boolean {
    return this._windowVisible
  }

  private _setupBehavior(): void {
    // Handle clicks based on config
    if (this._config.showWindowOnClick) {
      this._tray.on('click', () => {
        this.toggleWindow()
      })
    }

    // Hide dock icon if configured
    if (this._config.hideDockIcon) {
      this._hideDockIcon()
    }
  }

  private async _hideDockIcon(): Promise<void> {
    if (typeof window !== 'undefined' && (window as any).craft?.app?.hideDockIcon) {
      await (window as any).craft.app.hideDockIcon()
    }
  }

  /**
   * Show the popup window
   */
  async showWindow(): Promise<void> {
    if (typeof window !== 'undefined' && (window as any).craft?.window?.show) {
      await (window as any).craft.window.show()
      this._windowVisible = true
    }
  }

  /**
   * Hide the popup window
   */
  async hideWindow(): Promise<void> {
    if (typeof window !== 'undefined' && (window as any).craft?.window?.hide) {
      await (window as any).craft.window.hide()
      this._windowVisible = false
    }
  }

  /**
   * Toggle the popup window
   */
  async toggleWindow(): Promise<void> {
    if (this._windowVisible) {
      await this.hideWindow()
    }
else {
      await this.showWindow()
    }
  }

  /**
   * Set tray title
   */
  setTitle(title: string): Promise<void> {
    return this._tray.setTitle(title)
  }

  /**
   * Set tray icon
   */
  setIcon(icon: string): Promise<void> {
    return this._tray.setIcon(icon)
  }

  /**
   * Set menu
   */
  setMenu(items: MenuItem[]): Promise<void> {
    return this._tray.setMenu(items)
  }

  /**
   * Register menu action handler
   */
  onMenuAction(actionId: string, handler: () => void): () => void {
    return this._tray.onMenuAction(actionId, handler)
  }

  /**
   * Quit the app
   */
  async quit(): Promise<void> {
    if (typeof window !== 'undefined' && (window as any).craft?.app?.quit) {
      await (window as any).craft.app.quit()
    }
  }
}

// ============================================================================
// Tray Manager
// ============================================================================

/**
 * Manage system tray instances
 */
class TrayManager {
  private _trays: Map<string, SystemTray> = new Map()
  private _mainTray: SystemTray | null = null

  /**
   * Get or create the main tray
   */
  get main(): SystemTray {
    if (!this._mainTray) {
      this._mainTray = new SystemTray('main')
      this._trays.set('main', this._mainTray)
    }
    return this._mainTray
  }

  /**
   * Create a new tray
   */
  create(id: string, options: TrayOptions = {}): SystemTray {
    const tray = new SystemTray(id, options)
    this._trays.set(id, tray)

    if (!this._mainTray) {
      this._mainTray = tray
    }

    return tray
  }

  /**
   * Get tray by ID
   */
  get(id: string): SystemTray | undefined {
    return this._trays.get(id)
  }

  /**
   * Destroy a tray
   */
  async destroy(id: string): Promise<void> {
    const tray = this._trays.get(id)
    if (tray) {
      await tray.destroy()
      this._trays.delete(id)
      if (this._mainTray?.id === id) {
        this._mainTray = null
      }
    }
  }

  /**
   * Destroy all trays
   */
  async destroyAll(): Promise<void> {
    for (const tray of this._trays.values()) {
      await tray.destroy()
    }
    this._trays.clear()
    this._mainTray = null
  }

  // ==========================================================================
  // Convenience methods for main tray
  // ==========================================================================

  /** Set main tray title */
  setTitle = (title: string): Promise<void> => this.main.setTitle(title)

  /** Set main tray icon */
  setIcon = (icon: string): Promise<void> => this.main.setIcon(icon)

  /** Set main tray tooltip */
  setTooltip = (tooltip: string): Promise<void> => this.main.setTooltip(tooltip)

  /** Set main tray menu */
  setMenu = (items: MenuItem[]): Promise<void> => this.main.setMenu(items)

  /** Register menu action on main tray */
  onMenuAction = (actionId: string, handler: () => void): (() => void) => this.main.onMenuAction(actionId, handler)

  /** Register click handler on main tray */
  onClick = (handler: TrayEventHandler<'click'>): (() => void) => this.main.on('click', handler)

  /** Register right-click handler on main tray */
  onRightClick = (handler: TrayEventHandler<'right-click'>): (() => void) => this.main.on('right-click', handler)

  /** Toggle window on click */
  onClickToggleWindow = (): (() => void) => this.main.onClickToggleWindow()
}

// ============================================================================
// Exports
// ============================================================================

/**
 * Global tray manager instance
 */
export const trayManager: TrayManager = new TrayManager()

/**
 * Alias for convenience
 */
export const tray: TrayManager = trayManager

/**
 * Create a menubar app
 */
export function createMenubarApp(config?: MenubarAppConfig): MenubarApp {
  return new MenubarApp(config)
}

/**
 * Helper to build a menu from items
 */
export function buildMenu(...items: MenuItem[]): MenuItem[] {
  return items
}

/**
 * Create a separator menu item
 */
export function separator(): MenuItem {
  return { type: 'separator' }
}

/**
 * Create a normal menu item
 */
export function menuItem(label: string, options: Omit<MenuItem, 'label' | 'type'> = {}): MenuItem {
  return { label, type: 'normal', ...options }
}

/**
 * Create a checkbox menu item
 */
export function checkbox(label: string, checked: boolean, options: Omit<MenuItem, 'label' | 'type' | 'checked'> = {}): MenuItem {
  return { label, type: 'checkbox', checked, ...options }
}

/**
 * Create a submenu
 */
export function submenu(label: string, items: MenuItem[], options: Omit<MenuItem, 'label' | 'type' | 'submenu'> = {}): MenuItem {
  return { label, type: 'submenu', submenu: items, ...options }
}

export default trayManager
