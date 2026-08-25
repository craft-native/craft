/**
 * Craft Platform Support Matrix
 *
 * This file defines types for the desktop TypeScript SDK (craft-native).
 * For mobile bridge types (window.craft injected at runtime), see types/craft.d.ts.
 *
 * Feature              | macOS | Linux | Windows | iOS | Android
 * ---------------------|-------|-------|---------|-----|--------
 * Window Management    |   ✓   |   ✓   |    ✓    |  -  |    -
 * System Tray          |   ✓   |   ✓   |    ✓    |  -  |    -
 * Native Sidebar       |   ✓   |   -   |    -    |  -  |    -
 * Touch Bar            |   ✓   |   -   |    -    |  -  |    -
 * Toolbar              |   ✓   |   ✓   |    ✓    |  -  |    -
 * File System          |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Database (SQLite)    |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * HTTP Client          |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Crypto               |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Notifications        |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Clipboard            |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Dialogs (File/Alert) |   ✓   |   ✓   |    ✓    |  -  |    -
 * App Lifecycle        |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Keyboard Shortcuts   |   ✓   |   ✓   |    ✓    |  -  |    -
 * Process/Exec         |   ✓   |   ✓   |    ✓    |  -  |    -
 * Hot Reload           |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * Camera/Microphone    |   ✓   |   ✓   |    ✓    |  ✓  |    ✓
 * GPU Acceleration     |   ✓   |   ✓   |    ✓    |  -  |    -
 * Stage Manager        |   ✓   |   -   |    -    |  -  |    -
 * Handoff/Continuity   |   ✓   |   -   |    -    |  -  |    -
 * Spotlight            |   ✓   |   -   |    -    |  -  |    -
 * Jump List            |   -   |   -   |    ✓    |  -  |    -
 * Taskbar Progress     |   -   |   -   |    ✓    |  -  |    -
 * Windows Hello        |   -   |   -   |    ✓    |  -  |    -
 * Toast Notifications  |   -   |   -   |    ✓    |  -  |    -
 * Biometrics           |   -   |   -   |    -    |  ✓  |    ✓
 * Haptic Feedback      |   -   |   -   |    -    |  ✓  |    ✓
 * Secure Storage       |   -   |   -   |    -    |  ✓  |    ✓
 * Location             |   -   |   -   |    -    |  ✓  |    ✓
 * Share Sheet          |   -   |   -   |    -    |  ✓  |    ✓
 * CarPlay              |   -   |   -   |    -    |  ✓  |    -
 * Live Activities      |   -   |   -   |    -    |  ✓  |    -
 * SharePlay            |   -   |   -   |    -    |  ✓  |    -
 * StoreKit (IAP)       |   -   |   -   |    -    |  ✓  |    -
 * Material You         |   -   |   -   |    -    |  -  |    ✓
 * Play Billing (IAP)   |   -   |   -   |    -    |  -  |    ✓
 * Work Manager         |   -   |   -   |    -    |  -  |    ✓
 * Predictive Back      |   -   |   -   |    -    |  -  |    ✓
 *
 * Mobile-only bridge APIs (window.craft, defined in types/craft.d.ts):
 *   AR (ARKit/ARCore), ML (Core ML/ML Kit), Deep Links, OTA Updates,
 *   Widgets, Auth Persistence, Contacts, Calendar, Health/Fitness,
 *   Watch Connectivity, Siri/Assistant, Background Tasks, PDF Viewer
 */

export interface WindowOptions {
  /**
   * Window title
   */
  title?: string

  /**
   * Build the window without ever putting it on screen (macOS).
   *
   * The page loads and runs JavaScript exactly as it would visibly, and it
   * remains capturable — a snapshot taken after script has mutated the DOM
   * reflects the mutation.
   *
   * **It does not animate.** An unshown window does not drive the compositor,
   * so `requestAnimationFrame` stops after one frame and page timers fall to
   * roughly 1Hz. Anything that advances itself — CSS or canvas animation, a
   * charting library redrawing on rAF, "wait until the spinner stops" — sees
   * the first frame forever. Drive the page with explicit calls and take
   * readiness from load completion, not from a polling loop inside the page.
   *
   * Contradicts `menubarOnly`, which has no window to hide; passing both is an
   * error rather than a silent no-op.
   */
  headless?: boolean

  /**
   * Remember this window's size and position across launches, under this name
   * (macOS).
   *
   * `width`/`height`/`x`/`y` become **first-launch defaults**: they are what
   * the window opens at until there is a saved frame to restore, and the saved
   * frame wins from then on. Without this the window forgets its geometry
   * every launch, and an app that wants the standard behaviour has to wire
   * `onResize`/`onMove` to its own storage and reimplement what AppKit does in
   * one call.
   *
   * The name is the key AppKit stores under, so it must be stable across
   * launches and distinct per window.
   */
  frameAutosave?: string

  /**
   * Window width in pixels
   * @default 800
   */
  width?: number

  /**
   * Window height in pixels
   * @default 600
   */
  height?: number

  /**
   * X position of window
   */
  x?: number

  /**
   * Y position of window
   */
  y?: number

  /**
   * Whether window is resizable
   * @default true
   */
  resizable?: boolean

  /**
   * Whether window is frameless
   * @default false
   */
  frameless?: boolean

  /**
   * Whether window has transparency
   * @default false
   */
  transparent?: boolean

  /**
   * Whether window is always on top
   * @default false
   */
  alwaysOnTop?: boolean

  /**
   * Whether window starts in fullscreen
   * @default false
   */
  fullscreen?: boolean

  /**
   * Enable dark mode
   */
  darkMode?: boolean

  /**
   * Enable hot reload for development
   * @default false
   */
  hotReload?: boolean

  /**
   * Enable developer tools
   * @default false in production, true in development
   */
  devTools?: boolean

  /**
   * Enable system tray icon
   * @default false
   */
  systemTray?: boolean

  /**
   * Hide dock icon (menubar-only mode, macOS)
   * @default false
   */
  hideDockIcon?: boolean

  /**
   * Menubar-only mode (no window, only system tray)
   * @default false
   */
  menubarOnly?: boolean

  /**
   * Hide the titlebar (content extends to window edge)
   * @default false
   */
  titlebarHidden?: boolean

  /**
   * Draw native macOS sidebar material behind a web-rendered sidebar.
   * Useful for apps whose sidebar is authored in HTML/STX but should sit over
   * real AppKit vibrancy in transparent titlebar windows.
   *
   * The window title is hidden in this mode: the host draws its own
   * sidebar/back/forward row into the titlebar, where AppKit would otherwise
   * print the title underneath it.
   * @default false
   */
  webSidebarMaterial?: boolean

  /**
   * Width of the native material backdrop behind a web-rendered sidebar.
   * Only used when webSidebarMaterial is true.
   * @default 286
   */
  webSidebarWidth?: number

  /**
   * White/dark native tint opacity over the sidebar material.
   * Higher values reduce desktop bleed-through while keeping subtle vibrancy.
   * @default 0.78
   */
  webSidebarMaterialOpacity?: number

  /**
   * Use native macOS sidebar (Finder-style with vibrancy)
   * Creates a split view with NSOutlineView sidebar and WebView content
   * @default false
   */
  nativeSidebar?: boolean

  /**
   * Width of the native sidebar in pixels
   * Only used when nativeSidebar is true
   * @default 220
   */
  sidebarWidth?: number

  /**
   * Native sidebar visual variant.
   * The desktop variant enables a translucent sidebar material by default.
   */
  sidebarVariant?: SidebarVariant

  /**
   * Native material used for the sidebar.
   */
  sidebarMaterial?: SidebarMaterial

  /**
   * Native sidebar background treatment.
   */
  sidebarBackgroundEffect?: SidebarBackgroundEffect

  /**
   * Whether the native sidebar should allow background vibrancy.
   */
  sidebarAllowsVibrancy?: boolean

  /**
   * Sidebar configuration (sections and items)
   * Only used when nativeSidebar is true
   */
  sidebarConfig?: SidebarConfig

  /**
   * Path to a dock icon image (PNG, JPG, or ICNS).
   * On macOS, the file is loaded with `[NSImage initWithContentsOfFile:]`
   * and applied via `[NSApp setApplicationIconImage:]` before the first
   * window appears. Other platforms ignore this option for now.
   *
   * @example "/path/to/resources/assets/images/app-icon.png"
   */
  icon?: string
}

// ============================================================================
// Native Sidebar Configuration Types
// ============================================================================

export type SidebarVariant = 'tahoe' | 'vibrancy' | 'solid' | 'transparent' | 'workspace' | 'desktop'

export type SidebarMaterial = 'auto' | 'sidebar' | 'hud' | 'popover' | 'content'

export type SidebarBackgroundEffect = 'none' | 'vibrancy' | 'shimmer'

/**
 * Sidebar item configuration
 */
export interface SidebarItem {
  /**
   * Unique identifier for the item
   */
  id: string

  /**
   * Display label
   */
  label: string

  /**
   * SF Symbol name (macOS) or icon path
   * @example "house.fill", "folder", "star.fill"
   */
  icon?: string

  /**
   * Badge text (e.g., unread count)
   */
  badge?: string | number

  /**
   * Tint color for the icon (hex color)
   * Useful for tag colors
   * @example "#ff0000"
   */
  tintColor?: string

  /**
   * Whether this item is currently selected
   */
  selected?: boolean

  /**
   * Whether this item is disabled
   */
  disabled?: boolean

  /**
   * Nested items (for expandable sections)
   */
  children?: SidebarItem[]

  /**
   * URL or path associated with this item
   */
  url?: string

  /**
   * Custom data to pass to event handlers
   */
  data?: Record<string, unknown>
}

/**
 * Sidebar section configuration
 */
export interface SidebarSection {
  /**
   * Unique identifier for the section
   */
  id: string

  /**
   * Section header text
   */
  title: string

  /**
   * Whether section is collapsible
   * @default true
   */
  collapsible?: boolean

  /**
   * Whether section is initially collapsed
   * @default false
   */
  collapsed?: boolean

  /**
   * Items in this section
   */
  items: SidebarItem[]
}

/**
 * Complete sidebar configuration
 */
export interface SidebarConfig {
  /**
   * Visual style variant shared with STX web sidebars
   */
  variant?: SidebarVariant

  /**
   * Native material used for the sidebar
   */
  material?: SidebarMaterial

  /**
   * Native background effect
   */
  backgroundEffect?: SidebarBackgroundEffect

  /**
   * Let the desktop background show through the sidebar material
   */
  allowsVibrancy?: boolean

  /**
   * Light-mode tint opacity over sidebar material.
   * Higher values reduce desktop bleed-through.
   */
  materialOpacity?: number

  /**
   * Dark-mode tint opacity over sidebar material.
   * Higher values reduce desktop bleed-through.
   */
  materialDarkOpacity?: number

  /**
   * Sections to display in the sidebar
   */
  sections: SidebarSection[]

  /**
   * Minimum sidebar width
   * @default 180
   */
  minWidth?: number

  /**
   * Maximum sidebar width
   * @default 320
   */
  maxWidth?: number

  /**
   * Whether sidebar can be collapsed
   * @default true
   */
  canCollapse?: boolean

  /**
   * Search placeholder text (shows search field if provided)
   */
  searchPlaceholder?: string

  /**
   * Header content (optional custom header)
   */
  header?: {
    title?: string
    subtitle?: string
  }
}

/**
 * Sidebar selection event
 */
export interface SidebarSelectEvent {
  /**
   * ID of the selected item
   */
  itemId: string

  /**
   * ID of the section containing the item
   */
  sectionId: string

  /**
   * The full item configuration
   */
  item: SidebarItem

  /**
   * Custom data from the item
   */
  data?: Record<string, unknown>
}

/**
 * Sidebar API (available as window.craft.sidebar in WebView)
 */
export interface CraftSidebarAPI {
  /**
   * Update sidebar configuration
   * @param config - New sidebar configuration
   */
  setConfig(config: SidebarConfig): Promise<void>

  /**
   * Update a specific section
   * @param sectionId - Section ID to update
   * @param section - New section configuration
   */
  updateSection(sectionId: string, section: Partial<SidebarSection>): Promise<void>

  /**
   * Update a specific item
   * @param itemId - Item ID to update
   * @param item - New item configuration
   */
  updateItem(itemId: string, item: Partial<SidebarItem>): Promise<void>

  /**
   * Add an item to a section
   * @param sectionId - Section to add to
   * @param item - Item to add
   * @param index - Optional index to insert at
   */
  addItem(sectionId: string, item: SidebarItem, index?: number): Promise<void>

  /**
   * Remove an item
   * @param itemId - Item ID to remove
   */
  removeItem(itemId: string): Promise<void>

  /**
   * Select an item programmatically
   * @param itemId - Item ID to select
   */
  selectItem(itemId: string): Promise<void>

  /**
   * Get the currently selected item ID
   */
  getSelectedItem(): Promise<string | null>

  /**
   * Set badge for an item
   * @param itemId - Item ID
   * @param badge - Badge text or number (null to remove)
   */
  setBadge(itemId: string, badge: string | number | null): Promise<void>

  /**
   * Expand a section
   * @param sectionId - Section ID to expand
   */
  expandSection(sectionId: string): Promise<void>

  /**
   * Collapse a section
   * @param sectionId - Section ID to collapse
   */
  collapseSection(sectionId: string): Promise<void>

  /**
   * Toggle section expanded state
   * @param sectionId - Section ID to toggle
   */
  toggleSection(sectionId: string): Promise<void>

  /**
   * Register selection change handler
   * @param callback - Function called when selection changes
   * @returns Unsubscribe function
   */
  onSelect(callback: (event: SidebarSelectEvent) => void): () => void

  /**
   * Register search handler
   * @param callback - Function called when search text changes
   * @returns Unsubscribe function
   */
  onSearch(callback: (query: string) => void): () => void

  /**
   * Register context menu handler
   * @param callback - Function called on right-click
   * @returns Unsubscribe function
   */
  onContextMenu(callback: (event: SidebarSelectEvent) => void): () => void
}

export interface AppConfig {
  /**
   * HTML content to display
   */
  html?: string

  /**
   * URL to load
   */
  url?: string

  /**
   * Window options
   */
  window?: WindowOptions

  /**
   * The name macOS shows for the app: the App menu title, and the
   * "About X" / "Hide X" / "Quit X" items.
   *
   * Without it those read the executable's name, so every app launched
   * through the shared `craft` binary calls itself "craft" in the menu bar.
   * A packaged `.app` gets this from `CFBundleName` instead; this is what
   * gives a dev-mode app its identity back without a packaging step.
   *
   * Not the name `ps` and Activity Monitor show — that comes from the
   * executable and cannot be changed from inside the process.
   */
  appName?: string

  /**
   * Path to Craft binary (auto-detected if not provided)
   */
  craftPath?: string

  /**
   * Suppress all non-error output from the native binary.
   * When true, the binary runs with --quiet and stdio is piped.
   * @default false
   */
  quiet?: boolean
}


// ============================================================================
// Craft Bridge API Type Definitions
// These types describe the JavaScript API available in the WebView
// ============================================================================

/**
 * Craft System Tray API (available as window.craft.tray in WebView)
 */
export interface CraftTrayAPI {
    /**
     * Update the system tray title/text
     * Updates in real-time (60fps max)
     * @param title - Text to show in menubar (max 20 chars recommended)
     */
    setTitle(title: string): Promise<void>

    /**
     * Set tooltip text for the tray icon
     * @param tooltip - Tooltip text (shows on hover)
     */
    setTooltip(tooltip: string): Promise<void>

    /**
     * Register a click handler for tray icon clicks
     * @param callback - Function to call when tray icon is clicked
     * @returns Function to unregister the handler
     */
    onClick(callback: (event: TrayClickEvent) => void): () => void

    /**
     * Convenience: toggle window visibility on tray click
     * @returns Function to unregister the handler
     */
    onClickToggleWindow(): () => void

    /**
     * Set a context menu for the tray icon
     * @param items - Menu item definitions
     */
    setMenu(items: MenuItem[]): Promise<void>
}

/**
 * Craft Window Control API (available as window.craft.window in WebView)
 */
export interface CraftWindowAPI {
    /**
     * Show the window
     */
    show(): Promise<void>

    /**
     * Hide the window
     */
    hide(): Promise<void>

    /**
     * Toggle window visibility
     */
    toggle(): Promise<void>

    /**
     * Minimize the window
     */
    minimize(): Promise<void>

    /**
     * Close the window
     */
    close(): Promise<void>
}

/**
 * Craft App Control API (available as window.craft.app in WebView)
 */
export interface CraftAppAPI {
    /**
     * Hide the dock icon (menubar-only mode, macOS)
     */
    hideDockIcon(): Promise<void>

    /**
     * Show the dock icon (normal mode, macOS)
     */
    showDockIcon(): Promise<void>

    /**
     * Quit the application
     */
    quit(): Promise<void>

    /**
     * Send a native system notification
     * @param options - Notification configuration
     */
    notify(options: NotificationOptions): Promise<void>

    /**
     * Get application information
     */
    getInfo(): Promise<AppInfo>
}

/**
 * Tray click event details
 */
export interface TrayClickEvent {
    /**
     * Which mouse button was clicked
     */
    button: 'left' | 'right' | 'middle'

    /**
     * Timestamp of the click
     */
    timestamp: number

    /**
     * Keyboard modifiers held during click
     */
    modifiers: {
        command?: boolean
        shift?: boolean
        option?: boolean
        control?: boolean
    }
}

/**
 * Menu item configuration
 */
export interface MenuItem {
    /**
     * Unique identifier for the menu item
     */
    id?: string

    /**
     * Label text to display
     */
    label?: string

    /**
     * Menu item type
     */
    type?: 'normal' | 'separator' | 'checkbox' | 'radio'

    /**
     * Whether the item is checked (for checkbox/radio types)
     */
    checked?: boolean

    /**
     * Whether the item is enabled
     */
    enabled?: boolean

    /**
     * Action to perform when clicked (built-in or custom)
     */
    action?: 'show' | 'hide' | 'toggle' | 'quit' | string

    /**
     * Keyboard shortcut (e.g., 'Cmd+Q')
     */
    shortcut?: string

    /**
     * Submenu items
     */
    submenu?: MenuItem[]
}

/**
 * Application information
 */
export interface AppInfo {
    /**
     * Application name
     */
    name: string

    /**
     * Application version
     */
    version: string

    /**
     * Platform (macos, linux, windows)
     */
    platform: string
}

/**
 * Notification options
 */
export interface NotificationOptions {
    /**
     * Notification title (required)
     */
    title: string

    /**
     * Notification body text
     */
    body?: string

    /**
     * Icon path or data URL
     */
    icon?: string

    /**
     * Sound to play
     * - "default" - System default sound
     * - "Glass" - Glass sound (macOS)
     * - "Ping" - Ping sound (macOS)
     * - Or any system sound name
     */
    sound?: string

    /**
     * Action buttons (platform dependent)
     */
    actions?: Array<{
        action: string
        title: string
    }>

    /**
     * Notification tag (for grouping/replacing)
     */
    tag?: string

    /**
     * Auto-close timeout in milliseconds
     */
    timeout?: number
}

// ============================================================================
// Mobile Platform APIs
// ============================================================================

/**
 * Device information (mobile platforms)
 */
export interface DeviceInfo {
  /**
   * Platform (ios, android)
   */
  platform: 'ios' | 'android'

  /**
   * OS version
   */
  osVersion: string

  /**
   * Device model
   */
  model: string

  /**
   * Screen width in points
   */
  screenWidth: number

  /**
   * Screen height in points
   */
  screenHeight: number

  /**
   * Device pixel ratio
   */
  scaleFactor: number

  /**
   * Whether device is a tablet
   */
  isTablet: boolean

  /**
   * Safe area insets
   */
  safeAreaInsets: {
    top: number
    bottom: number
    left: number
    right: number
  }
}

/**
 * Permission types
 */
export type Permission =
  | 'camera'
  | 'microphone'
  | 'location'
  | 'photos'
  | 'notifications'
  | 'contacts'
  | 'calendar'
  | 'reminders'

/**
 * Permission status
 */
export type PermissionStatus = 'granted' | 'denied' | 'notDetermined' | 'restricted'

/**
 * Haptic feedback types
 */
export type HapticType =
  | 'selection'
  | 'impact-light'
  | 'impact-medium'
  | 'impact-heavy'
  | 'notification-success'
  | 'notification-warning'
  | 'notification-error'

/**
 * Camera options
 */
export interface CameraOptions {
  /**
   * Camera type (front or back)
   */
  type?: 'front' | 'back'

  /**
   * Media type to capture
   */
  mediaType?: 'photo' | 'video'

  /**
   * Maximum video duration in seconds
   */
  maxDuration?: number

  /**
   * Video quality
   */
  quality?: 'low' | 'medium' | 'high'
}

/**
 * Photo picker options
 */
export interface PhotoPickerOptions {
  /**
   * Maximum number of selections
   */
  maxSelections?: number

  /**
   * Media types to show
   */
  mediaType?: 'photo' | 'video' | 'all'
}

/**
 * Share options
 */
export interface ShareOptions {
  /**
   * Text to share
   */
  text?: string

  /**
   * URL to share
   */
  url?: string

  /**
   * Title (Android only)
   */
  title?: string

  /**
   * Dialog title (Android only)
   */
  dialogTitle?: string
}

/**
 * Craft Mobile API (device-specific features)
 */
export interface CraftMobileAPI {
  /**
   * Get device information
   */
  getDeviceInfo(): Promise<DeviceInfo>

  /**
   * Request permission
   * @param permission - Permission type to request
   */
  requestPermission(permission: Permission): Promise<PermissionStatus>

  /**
   * Check permission status
   * @param permission - Permission type to check
   */
  checkPermission(permission: Permission): Promise<PermissionStatus>

  /**
   * Trigger haptic feedback
   * @param type - Haptic feedback type
   */
  haptic(type: HapticType): Promise<void>

  /**
   * Vibrate device
   * @param duration - Duration in milliseconds
   */
  vibrate(duration: number): Promise<void>

  /**
   * Show native toast (Android) or banner (iOS)
   * @param message - Message to display
   * @param duration - Duration in milliseconds (optional)
   */
  toast(message: string, duration?: number): Promise<void>

  /**
   * Open camera to capture photo/video
   * @param options - Camera configuration
   */
  openCamera(options?: CameraOptions): Promise<string>

  /**
   * Open photo picker
   * @param options - Picker configuration
   */
  pickPhoto(options?: PhotoPickerOptions): Promise<string[]>

  /**
   * Share content via system share sheet
   * @param options - Share configuration
   */
  share(options: ShareOptions): Promise<void>

  /**
   * Set orientation lock
   * @param orientation - Orientation to lock to
   */
  setOrientation(orientation: 'portrait' | 'landscape' | 'any'): Promise<void>

  /**
   * Set status bar style (iOS)
   * @param style - Status bar style
   */
  setStatusBarStyle(style: 'light' | 'dark' | 'default'): Promise<void>

  /**
   * Open app settings
   */
  openSettings(): Promise<void>

  /**
   * Check if biometric auth is available
   */
  isBiometricAvailable(): Promise<boolean>

  /**
   * Authenticate with biometrics
   * @param reason - Reason shown to user (iOS)
   */
  authenticateBiometric(reason: string): Promise<boolean>

  /**
   * Store data securely (keychain/keystore)
   * @param key - Storage key
   * @param value - Value to store
   */
  secureStore(key: string, value: string): Promise<void>

  /**
   * Retrieve data from secure storage
   * @param key - Storage key
   */
  secureRetrieve(key: string): Promise<string | null>

  /**
   * Delete data from secure storage
   * @param key - Storage key
   */
  secureDelete(key: string): Promise<void>
}

/**
 * Craft Desktop Bridge API (available as window.craft in desktop WebView)
 *
 * This interface covers the desktop platforms (macOS, Linux, Windows).
 * For the mobile bridge API (iOS/Android), see types/craft.d.ts which
 * defines the CraftBridge interface with additional mobile-only features
 * such as AR, ML, deep links, OTA updates, widgets, and auth persistence.
 */
export interface CraftBridgeAPI {
  /**
   * Trackpad gesture phases (desktop only).
   *
   * Present in every Craft window, but dormant on a host that does not emit —
   * so its presence is not a promise that swipes will arrive. See
   * `api/gestures`.
   */
  gestures?: import('./api/gestures.js').GesturesAPI

  /**
   * System tray control (desktop only)
   */
  tray?: CraftTrayAPI

  /**
   * Window control (desktop)
   */
  window?: CraftWindowAPI

  /**
   * Application control
   */
  app: CraftAppAPI

  /**
   * Mobile-specific APIs (mobile only)
   */
  mobile?: CraftMobileAPI

  /**
   * File system APIs
   */
  fs?: CraftFileSystemAPI

  /**
   * Database APIs
   */
  db?: CraftDatabaseAPI

  /**
   * HTTP client APIs
   */
  http?: CraftHttpAPI

  /**
   * Native sidebar APIs (macOS)
   */
  sidebar?: CraftSidebarAPI

  /**
   * Crypto APIs
   */
  crypto?: CraftCryptoAPI

  /**
   * Do Not Disturb / Focus (macOS)
   */
  focus?: CraftFocusAPI

  /**
   * Screen-sharing and screen-recording detection (macOS)
   */
  screenSharing?: CraftScreenSharingAPI

  /**
   * System-wide hotkeys (macOS).
   *
   * Absent in effect on Linux and Windows: the calls exist, and every
   * registration is refused, because Craft has no implementation there and a
   * shortcut that can never fire is worse than one that was never accepted.
   */
  shortcuts?: CraftGlobalShortcutsAPI

  /**
   * A small scalar preference store (macOS: CFPreferences).
   */
  prefs?: CraftPreferencesAPI

  /**
   * The Cmd+, convention: where the App menu's Settings… item arrives.
   */
  settings?: CraftSettingsAPI
}

/**
 * The only value types `craft.prefs` stores.
 *
 * Anything else is refused in the page, before it can reach native. That is
 * deliberate rather than a limitation dodged: the preferences API raises an
 * Objective-C exception for a value that is not a property-list type, and Zig
 * cannot catch one — so refusing containers here is what makes that crash
 * unreachable. Serialise structure yourself:
 * `prefs.set(k, JSON.stringify(v))`.
 */
export type PreferenceValue = string | number | boolean

export interface CraftPreferencesInfo {
  /**
   * The preferences domain in use — the bundle identifier inside a packaged
   * `.app`, the executable's name otherwise.
   */
  domain: string
  /** The key prefix craft namespaces its own preferences under. */
  prefix: string
  /** How many keys the app currently has stored. */
  count: number
  /** A copy-pasteable command that prints the domain. */
  readCommand: string
}

/**
 * A small preference store over the platform's own mechanism, so `defaults
 * read` and a native settings pane both see what the app wrote.
 *
 * macOS only. Values are stored as native property-list types under a reserved
 * key prefix, so clearing craft's preferences cannot disturb the AppKit and
 * WebKit keys that share the same domain.
 */
export interface CraftPreferencesAPI {
  /**
   * Read a preference.
   *
   * `fallback` is returned when the key is absent — and also when what is
   * stored is of a different type from the fallback, which is how a value left
   * behind by an older build of the app degrades to the default rather than to
   * a surprise. Call `get(key)` with no fallback to read whatever is stored.
   *
   * Rejects with `code: 'PREFS_FOREIGN_VALUE'` if something outside craft
   * wrote a value craft cannot represent, rather than coercing it away.
   */
  get: <T extends PreferenceValue>(key: string, fallback?: T) => Promise<T | undefined>
  /**
   * Write a preference. Resolves once the value is on disk, not merely once
   * the message was posted.
   *
   * Rejects with `code: 'PREFS_UNSUPPORTED_VALUE'` for anything that is not a
   * string, number or boolean; `'PREFS_NON_FINITE'` for NaN or Infinity;
   * `'PREFS_VALUE_TOO_LARGE'` past 8 KiB; `'PREFS_BAD_KEY'` for a key outside
   * `/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/`.
   */
  set: (key: string, value: PreferenceValue) => Promise<void>
  /** Remove a preference. Resolves to whether it was there to begin with. */
  delete: (key: string) => Promise<boolean>
  /**
   * Remove every preference this app has set, and nothing else. Resolves to
   * how many were removed.
   */
  clear: () => Promise<number>
  /** Every key this app has set, sorted. */
  keys: () => Promise<string[]>
  /**
   * Which domain the preferences are actually landing in.
   *
   * Worth having: an unbundled dev-mode binary writes to a domain named after
   * the executable while a packaged `.app` writes to its bundle identifier, so
   * preferences set during development can appear to vanish once the app is
   * packaged.
   */
  info: () => Promise<CraftPreferencesInfo>
}

/**
 * The Cmd+, convention.
 *
 * craft's default App menu ships a `Settings…` item, and this is where its
 * click arrives. An app that replaces the whole menu bar with
 * `craft.menu.set()` loses the default item, and can declare
 * `{ id: 'settings', role: 'settings', label: 'Settings…', shortcut: 'cmd+,' }`
 * to get it back — the same handler answers either way.
 */
export interface CraftSettingsAPI {
  /** Subscribe to Settings being opened. Returns an unsubscribe function. */
  onOpen: (handler: (event: { source: string }) => void) => () => void
  /**
   * Open settings from the app's own UI — a gear button, say — so it lands in
   * the same handler as Cmd+, rather than needing a second code path. Purely
   * page-local; nothing crosses the bridge.
   */
  open: (source?: string) => Promise<void>
}


/** A global hotkey, as `craft.shortcuts.list()` reports it. */
export interface GlobalShortcut {
  /** The id the app registered it under. */
  id: string
  /**
   * Craft's canonical spelling of the combination — `Cmd+Delete`, whatever
   * the app originally wrote — so it can be passed straight back to
   * `register()`.
   */
  accelerator: string
  /** The key alone, canonically named. */
  key: string
  /** False while `disable()` has the key released back to the system. */
  enabled: boolean
}

/** Why a registration was refused. */
export interface GlobalShortcutError {
  /** The id from the payload that failed, or `''` if it had none. */
  id: string
  /** Craft's error code, e.g. `NATIVE_CALL_FAILED`, `INVALID_PARAMETER`. */
  code: string
  message: string
}

/**
 * System-wide hotkeys: they fire whether or not the app is frontmost.
 *
 * Accelerators are `+`-separated and case-insensitive — `'Cmd+Shift+H'`. The
 * last component is the key, everything before it a modifier (`Cmd`/`Command`/
 * `Meta`, `Ctrl`/`Control`, `Alt`/`Option`, `Shift`, or `CmdOrCtrl` for the
 * platform's own). Keys are named by position on the keyboard, not by the
 * character they produce, so a binding survives a layout change.
 *
 * At least one of Command, Control or Option is required, except on the
 * function keys: a bare global hotkey on `H` would mean no application on the
 * system ever saw the user type an h again.
 */
export interface CraftGlobalShortcutsAPI {
  /**
   * Reserve a combination system-wide. Registering an `id` twice replaces the
   * first binding.
   *
   * The promise resolves once the message is posted, **not** once the key is
   * reserved — so a combination that belongs to another app or to the system
   * resolves here and reports on {@link CraftGlobalShortcutsAPI.onError}.
   */
  register: (id: string, accelerator: string) => Promise<void>
  /** Give the key back to the system and forget the shortcut. */
  unregister: (id: string) => Promise<void>
  /** The same, for every shortcut this app holds. */
  unregisterAll: () => Promise<void>
  /**
   * Stop firing *and release the key*, so other apps can use it again. The
   * shortcut stays listed. Holding a reservation while dropping the event
   * would make the combination dead in every other app for as long as Craft
   * ran.
   */
  disable: (id: string) => Promise<void>
  /**
   * Take the key back. Can fail if something else claimed it while it was
   * released, which reports on {@link CraftGlobalShortcutsAPI.onError}.
   */
  enable: (id: string) => Promise<void>
  /** Whether the id is known — enabled or not. */
  isRegistered: (id: string) => Promise<boolean>
  list: () => Promise<GlobalShortcut[]>
  /** Every press of a registered, enabled shortcut. Returns an unsubscribe. */
  on: (handler: (event: { id: string, accelerator: string }) => void) => () => void
  /**
   * Where every fire-and-forget call reports its failure — `register`,
   * `enable`, `disable`, `unregister`. (`isRegistered` and `list` are
   * requests and reject their own promise instead.) Returns an unsubscribe.
   */
  onError: (handler: (error: GlobalShortcutError) => void) => () => void
}

/**
 * Focus / Do Not Disturb authorization state, mirroring
 * `INFocusStatusAuthorizationStatus`. `unsupported` is Craft's own value for
 * platforms and OS versions where the framework isn't present at all.
 */
export type FocusAuthorization = 'notDetermined' | 'restricted' | 'denied' | 'authorized' | 'unsupported'

export interface FocusStatus {
  /** False when the Focus framework isn't available on this platform. */
  supported: boolean
  /**
   * Whether the user is currently in *any* Focus. `null` means the system
   * declined to answer — almost always because authorization hasn't been
   * granted, which is not the same as "not focused".
   */
  isFocused: boolean | null
  authorization: FocusAuthorization
}

export interface FocusShortcutOptions {
  /** Shortcut to run when turning Focus on. */
  onShortcut?: string
  /** Shortcut to run when turning Focus off. */
  offShortcut?: string
  /** Defaults to `auto`. */
  strategy?: FocusStrategy
}

/**
 * How a shortcut is run.
 *
 * `cli` execs `/usr/bin/shortcuts` and reports the shortcut's real exit status.
 * `url` opens `shortcuts://run-shortcut`, the only route the App Sandbox
 * permits — but it is fire-and-forget: LaunchServices confirms it handed the
 * URL over, never that the shortcut ran. `auto` picks `url` under sandbox and
 * `cli` everywhere else, so a real status is used wherever one exists.
 */
export type FocusStrategy = 'auto' | 'cli' | 'url'

export interface FocusResult {
  ok: boolean
  strategy?: 'shortcut' | 'url'
  /** Exit status of the Shortcuts CLI. Absent for the `url` strategy. */
  exitCode?: number
  /**
   * `url` strategy only: the request reached Shortcuts. Not a claim that the
   * shortcut ran — no such signal is available on this route.
   */
  dispatched?: boolean
  shortcut?: string
  error?: string
}

/**
 * Do Not Disturb / Focus.
 *
 * Reading is public API (`INFocusStatusCenter`). Writing is not available to
 * third-party apps — `setEnabled` runs a user-created Shortcut containing the
 * *Set Focus* action, which is the only path macOS sanctions.
 */
export interface CraftFocusAPI {
  getStatus(): Promise<FocusStatus>
  /** Present the system permission prompt for Focus status. */
  requestAuthorization(): Promise<FocusAuthorization>
  setEnabled(enabled: boolean, options?: FocusShortcutOptions): Promise<FocusResult>
  /** Run any shortcut by name — for per-mode or timed Focus flows. */
  runShortcut(name: string): Promise<FocusResult>
  /** Every shortcut installed for the current user. */
  listShortcuts(): Promise<string[]>
}

/** Which signal produced a detection. */
export type ScreenSharingKind = 'system' | 'remote' | 'conference' | 'recording'

export interface ScreenSharingSource {
  /** Owning application, as the window server reports it. */
  app: string
  /** Window title that matched. Empty when the owner alone was the signal. */
  window: string
  kind: ScreenSharingKind
}

export interface ScreenSharingState {
  /** True when any signal fired. */
  sharing: boolean
  signals: {
    /** macOS Screen Sharing / Apple Remote Desktop has the session. */
    systemScreenShare: boolean
    /** The session is being driven from somewhere other than this console. */
    remoteSession: boolean
    /** A conferencing app is showing its live sharing control. */
    conferenceSharing: boolean
    /** A recorder is capturing the screen. */
    screenRecording: boolean
  }
  sources: ScreenSharingSource[]
}

/**
 * Screen-sharing detection. Matches the sharing *indicator* a conferencing app
 * shows while a share is live, never the mere presence of the app — see
 * `screen_sharing.zig` for the signal table.
 */
export interface CraftScreenSharingAPI {
  getState(): Promise<ScreenSharingState>
  /**
   * Start polling. Emits `craft:screenSharing:change` whenever the resolved
   * state differs, including once immediately. Interval is clamped to
   * 250ms–60s.
   */
  watch(intervalMs?: number): Promise<{ ok: boolean, intervalMs: number }>
  unwatch(): Promise<{ ok: boolean }>
  /** Subscribe to state changes. Returns an unsubscribe function. */
  onChange(cb: (state: ScreenSharingState) => void): () => void
}

/**
 * File system API
 */
export interface CraftFileSystemAPI {
  /**
   * Read file contents
   * @param path - File path
   */
  readFile(path: string): Promise<string>

  /**
   * Write file contents
   * @param path - File path
   * @param content - File content
   */
  writeFile(path: string, content: string): Promise<void>

  /**
   * Read directory contents
   * @param path - Directory path
   */
  readDir(path: string): Promise<string[]>

  /**
   * Create directory
   * @param path - Directory path
   */
  mkdir(path: string): Promise<void>

  /**
   * Remove file or directory
   * @param path - Path to remove
   */
  remove(path: string): Promise<void>

  /**
   * Check if path exists
   * @param path - Path to check
   */
  exists(path: string): Promise<boolean>
}

/**
 * Database API (SQLite)
 */
export interface CraftDatabaseAPI {
  /**
   * Execute SQL query
   * @param sql - SQL query
   * @param params - Query parameters
   */
  execute(sql: string, params?: unknown[]): Promise<void>

  /**
   * Query database
   * @param sql - SQL query
   * @param params - Query parameters
   */
  query(sql: string, params?: unknown[]): Promise<unknown[]>

  /**
   * Begin transaction
   */
  beginTransaction(): Promise<void>

  /**
   * Commit transaction
   */
  commit(): Promise<void>

  /**
   * Rollback transaction
   */
  rollback(): Promise<void>
}

/**
 * HTTP client API
 */
export interface CraftHttpAPI {
  /**
   * Fetch resource
   * @param url - URL to fetch
   * @param options - Fetch options
   */
  fetch(url: string, options?: RequestInit): Promise<Response>

  /**
   * Download file with progress
   * @param url - URL to download
   * @param destination - Download destination path
   * @param onProgress - Progress callback
   */
  download(
    url: string,
    destination: string,
    onProgress?: (progress: { loaded: number, total: number }) => void
  ): Promise<void>

  /**
   * Upload file with progress
   * @param url - Upload URL
   * @param filePath - File to upload
   * @param onProgress - Progress callback
   */
  upload(
    url: string,
    filePath: string,
    onProgress?: (progress: { loaded: number, total: number }) => void
  ): Promise<Response>
}

/**
 * Crypto API
 */
export interface CraftCryptoAPI {
  /**
   * Generate random bytes
   * @param size - Number of bytes
   */
  randomBytes(size: number): Promise<Uint8Array>

  /**
   * Hash data
   * @param algorithm - Hash algorithm
   * @param data - Data to hash
   */
  hash(algorithm: 'sha256' | 'sha512' | 'md5', data: string): Promise<string>

  /**
   * Encrypt data
   * @param data - Data to encrypt
   * @param key - Encryption key
   */
  encrypt(data: string, key: string): Promise<string>

  /**
   * Decrypt data
   * @param encryptedData - Data to decrypt
   * @param key - Decryption key
   */
  decrypt(encryptedData: string, key: string): Promise<string>
}

// ============================================================================
// Event Emitter Pattern
// ============================================================================

/**
 * Event types for craft.on() and craft.off()
 */
export type CraftEventType =
  | 'window:focus'
  | 'window:blur'
  | 'window:resize'
  | 'window:move'
  | 'window:close'
  | 'window:minimize'
  | 'window:maximize'
  | 'window:fullscreen'
  | 'app:activate'
  | 'app:deactivate'
  | 'app:beforeQuit'
  | 'app:willQuit'
  | 'tray:click'
  | 'tray:rightClick'
  | 'tray:doubleClick'
  | 'menu:click'
  | 'shortcut:triggered'
  | 'deeplink:open'
  | 'file:drop'
  | 'theme:change'
  | 'network:online'
  | 'network:offline'
  | 'battery:low'
  | 'battery:charging'
  | 'idle:active'
  | 'idle:idle'
  | 'display:added'
  | 'display:removed'
  | 'display:changed'

/**
 * Event data map for typed event handlers
 */
export interface CraftEventMap {
  'window:focus': void
  'window:blur': void
  'window:resize': { width: number; height: number }
  'window:move': { x: number; y: number }
  'window:close': void
  'window:minimize': void
  'window:maximize': void
  'window:fullscreen': { isFullscreen: boolean }
  'app:activate': void
  'app:deactivate': void
  'app:beforeQuit': { preventDefault: () => void }
  'app:willQuit': void
  'tray:click': TrayClickEvent
  'tray:rightClick': TrayClickEvent
  'tray:doubleClick': TrayClickEvent
  'menu:click': { menuId: string; itemId: string }
  'shortcut:triggered': { shortcut: string }
  'deeplink:open': { url: string }
  'file:drop': { files: string[] }
  'theme:change': { theme: 'light' | 'dark' | 'system' }
  'network:online': void
  'network:offline': void
  'battery:low': { level: number }
  'battery:charging': { isCharging: boolean }
  'idle:active': void
  'idle:idle': { idleTime: number }
  'display:added': DisplayInfo
  'display:removed': { id: string }
  'display:changed': DisplayInfo
}

/**
 * Event handler type
 */
export type CraftEventHandler<T extends CraftEventType> = (_data: CraftEventMap[T]) => void

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
  /** Whether this is the primary display */
  isPrimary: boolean
  /** Display bounds */
  bounds: { x: number; y: number; width: number; height: number }
  /** Work area bounds (excluding taskbar/dock) */
  workArea: { x: number; y: number; width: number; height: number }
}

/**
 * Event emitter API
 */
export interface CraftEventEmitter {
  /**
   * Register an event handler
   * @param event - Event type
   * @param handler - Event handler function
   * @returns Unsubscribe function
   */
  on<T extends CraftEventType>(event: T, handler: CraftEventHandler<T>): () => void

  /**
   * Register a one-time event handler
   * @param event - Event type
   * @param handler - Event handler function
   * @returns Unsubscribe function
   */
  once<T extends CraftEventType>(event: T, handler: CraftEventHandler<T>): () => void

  /**
   * Remove an event handler
   * @param event - Event type
   * @param handler - Event handler function
   */
  off<T extends CraftEventType>(event: T, handler: CraftEventHandler<T>): void

  /**
   * Remove all handlers for an event
   * @param event - Event type
   */
  removeAllListeners(event?: CraftEventType): void

  /**
   * Emit an event (internal use)
   * @param event - Event type
   * @param data - Event data
   */
  emit<T extends CraftEventType>(event: T, data: CraftEventMap[T]): void
}

// ============================================================================
// Mobile Platform Configurations
// ============================================================================

/**
 * iOS-specific configuration
 */
export interface IOSConfig {
  /** Bundle identifier */
  bundleId: string
  /** App name */
  appName: string
  /** Version string */
  version: string
  /** Build number */
  buildNumber: string
  /** Minimum iOS version */
  minimumOSVersion?: string
  /** Device families (1=iPhone, 2=iPad) */
  deviceFamily?: (1 | 2)[]
  /** Supported orientations */
  orientations?: ('portrait' | 'portraitUpsideDown' | 'landscapeLeft' | 'landscapeRight')[]
  /** Status bar style */
  statusBarStyle?: 'default' | 'lightContent' | 'darkContent'
  /** Hide status bar */
  statusBarHidden?: boolean
  /** Requires full screen */
  requiresFullScreen?: boolean
  /** Background modes */
  backgroundModes?: ('audio' | 'location' | 'fetch' | 'remote-notification' | 'processing')[]
  /** URL schemes */
  urlSchemes?: string[]
  /** Associated domains (for universal links) */
  associatedDomains?: string[]
  /** App Transport Security settings */
  ats?: {
    allowsArbitraryLoads?: boolean
    allowsArbitraryLoadsForMedia?: boolean
    allowsArbitraryLoadsInWebContent?: boolean
    exceptionDomains?: Record<string, {
      includesSubdomains?: boolean
      allowsInsecureHTTPLoads?: boolean
    }>
  }
  /** Privacy usage descriptions */
  privacyDescriptions?: {
    camera?: string
    microphone?: string
    photoLibrary?: string
    location?: string
    locationAlways?: string
    contacts?: string
    calendars?: string
    reminders?: string
    healthShare?: string
    healthUpdate?: string
    motion?: string
    bluetooth?: string
    faceId?: string
    speechRecognition?: string
    tracking?: string
  }
  /** Capabilities */
  capabilities?: {
    pushNotifications?: boolean
    appGroups?: string[]
    iCloud?: { containers?: string[] }
    healthKit?: boolean
    homeKit?: boolean
    siriKit?: boolean
    carPlay?: boolean
    accessWifi?: boolean
    nfc?: boolean
  }
  /**
   * Custom entitlements as plist key/value pairs. Values must be one of the
   * primitive plist types — booleans, strings, numbers, or arrays of those.
   * Anything richer (e.g. nested dicts) needs a manual `.entitlements`
   * file referenced via {@link AppleSigningOptions.entitlementsPath}.
   */
  entitlements?: Record<string, boolean | string | number | Array<string | number>>
}

/**
 * Android-specific configuration
 */
export interface AndroidConfig {
  /** Package name */
  packageName: string
  /** App name */
  appName: string
  /** Version name */
  versionName: string
  /** Version code */
  versionCode: number
  /** Minimum SDK version */
  minSdkVersion?: number
  /** Target SDK version */
  targetSdkVersion?: number
  /** Compile SDK version */
  compileSdkVersion?: number
  /** Supported screen sizes */
  screenSizes?: ('small' | 'normal' | 'large' | 'xlarge')[]
  /** Screen orientations */
  orientations?: ('portrait' | 'landscape' | 'sensor')[]
  /** Permissions */
  permissions?: string[]
  /** Features */
  features?: Array<{ name: string; required?: boolean }>
  /** Intent filters */
  intentFilters?: Array<{
    action: string
    category?: string[]
    data?: { scheme?: string; host?: string; pathPrefix?: string }
  }>
  /** Deep links */
  deepLinks?: Array<{
    scheme: string
    host: string
    pathPrefix?: string
  }>
  /** Gradle config */
  gradle?: {
    buildToolsVersion?: string
    ndkVersion?: string
    kotlinVersion?: string
    dependencies?: string[]
    plugins?: string[]
  }
  /** ProGuard rules */
  proguardRules?: string[]
  /** Signing config */
  signing?: {
    keyAlias: string
    keyPassword?: string
    storeFile: string
    storePassword?: string
  }
  /** Adaptive icon */
  adaptiveIcon?: {
    foreground: string
    background: string
    monochromeIcon?: string
  }
  /** Splash screen */
  splashScreen?: {
    backgroundColor: string
    icon: string
    iconWidth?: number
  }
}

/**
 * macOS-specific configuration
 */
export interface MacOSConfig {
  /** Bundle identifier */
  bundleId: string
  /** App name */
  appName: string
  /** Version */
  version: string
  /** Build number */
  buildNumber: string
  /** Minimum macOS version */
  minimumOSVersion?: string
  /** App category */
  category?: string
  /** Copyright */
  copyright?: string
  /** Sandbox enabled */
  sandbox?: boolean
  /** Hardened runtime */
  hardenedRuntime?: boolean
  /** Code signing identity */
  signingIdentity?: string
  /** Provisioning profile */
  provisioningProfile?: string
  /** Entitlements */
  entitlements?: {
    'com.apple.security.app-sandbox'?: boolean
    'com.apple.security.network.client'?: boolean
    'com.apple.security.network.server'?: boolean
    'com.apple.security.files.user-selected.read-only'?: boolean
    'com.apple.security.files.user-selected.read-write'?: boolean
    'com.apple.security.files.downloads.read-only'?: boolean
    'com.apple.security.files.downloads.read-write'?: boolean
    'com.apple.security.device.camera'?: boolean
    'com.apple.security.device.microphone'?: boolean
    'com.apple.security.device.usb'?: boolean
    'com.apple.security.device.bluetooth'?: boolean
    'com.apple.security.personal-information.location'?: boolean
    'com.apple.security.personal-information.addressbook'?: boolean
    'com.apple.security.personal-information.calendars'?: boolean
    'com.apple.security.automation.apple-events'?: boolean
    [key: string]: boolean | string | string[] | undefined
  }
  /** URL schemes */
  urlSchemes?: string[]
  /** File type associations */
  fileAssociations?: Array<{
    extension: string
    name: string
    role: 'Editor' | 'Viewer' | 'Shell' | 'None'
    icon?: string
  }>
  /** DMG options */
  dmg?: {
    title?: string
    icon?: string
    background?: string
    windowWidth?: number
    windowHeight?: number
    iconSize?: number
    contents?: Array<{ x: number; y: number; type: 'file' | 'link'; path: string }>
  }
  /** Notarization */
  notarization?: {
    appleId: string
    teamId: string
    password?: string
  }
}

/**
 * Windows-specific configuration
 */
export interface WindowsConfig {
  /** Application ID */
  appId: string
  /** App name */
  appName: string
  /** Version */
  version: string
  /** Publisher name */
  publisher: string
  /** Publisher display name */
  publisherDisplayName: string
  /** Description */
  description?: string
  /** App icon */
  icon?: string
  /** Request elevation */
  requestedExecutionLevel?: 'asInvoker' | 'highestAvailable' | 'requireAdministrator'
  /** File associations */
  fileAssociations?: Array<{
    extension: string
    name: string
    description?: string
    icon?: string
  }>
  /** Protocol handlers */
  protocols?: Array<{
    name: string
    schemes: string[]
  }>
  /** NSIS installer options */
  nsis?: {
    oneClick?: boolean
    perMachine?: boolean
    allowElevation?: boolean
    allowToChangeInstallationDirectory?: boolean
    installerIcon?: string
    uninstallerIcon?: string
    installerHeaderIcon?: string
    createDesktopShortcut?: boolean | 'always'
    createStartMenuShortcut?: boolean
    shortcutName?: string
    include?: string
    license?: string
  }
  /** MSI installer options */
  msi?: {
    oneClick?: boolean
    perMachine?: boolean
    upgradeCode?: string
  }
  /** MSIX package options */
  msix?: {
    identityName?: string
    applicationId?: string
    publisher?: string
    publisherDisplayName?: string
    certificateFile?: string
    certificatePassword?: string
  }
  /** Code signing */
  signing?: {
    certificateFile?: string
    certificatePassword?: string
    certificateSubjectName?: string
    certificateSha1?: string
    signingHashAlgorithms?: ('sha1' | 'sha256')[]
    timestampServer?: string
  }
}

/**
 * Linux-specific configuration
 */
export interface LinuxConfig {
  /** App name */
  appName: string
  /** Executable name */
  executableName: string
  /** Version */
  version: string
  /** Description */
  description?: string
  /** Maintainer */
  maintainer?: string
  /** Vendor */
  vendor?: string
  /** Homepage */
  homepage?: string
  /** Category */
  category?: string
  /** Icon */
  icon?: string | Record<string, string>
  /** Desktop file */
  desktop?: {
    Name?: string
    GenericName?: string
    Comment?: string
    Exec?: string
    Icon?: string
    Terminal?: boolean
    Type?: string
    Categories?: string[]
    MimeType?: string[]
    StartupWMClass?: string
    Keywords?: string[]
  }
  /** Deb package options */
  deb?: {
    depends?: string[]
    recommends?: string[]
    section?: string
    priority?: string
    scripts?: {
      preinst?: string
      postinst?: string
      prerm?: string
      postrm?: string
    }
  }
  /** RPM package options */
  rpm?: {
    requires?: string[]
    license?: string
    group?: string
    scripts?: {
      pre?: string
      post?: string
      preun?: string
      postun?: string
    }
  }
  /** AppImage options */
  appImage?: {
    license?: string
    category?: string
  }
  /** Flatpak options */
  flatpak?: {
    appId: string
    branch?: string
    runtime?: string
    runtimeVersion?: string
    sdk?: string
    permissions?: string[]
    modules?: any[]
  }
  /** Snap options */
  snap?: {
    name: string
    grade?: 'stable' | 'devel'
    confinement?: 'strict' | 'classic' | 'devmode'
    base?: string
    plugs?: string[]
    slots?: string[]
  }
}

/**
 * Complete app configuration with platform-specific options
 */
export interface CraftAppConfig extends AppConfig {
  /** iOS configuration */
  ios?: IOSConfig
  /** Android configuration */
  android?: AndroidConfig
  /** macOS configuration */
  macos?: MacOSConfig
  /** Windows configuration */
  windows?: WindowsConfig
  /** Linux configuration */
  linux?: LinuxConfig
}

/**
 * Augment the Window interface to include the Craft bridge
 */
declare global {
  interface Window {
    /**
     * Craft native bridge API (auto-injected)
     */
    craft?: CraftBridgeAPI & CraftEventEmitter
  }
}
