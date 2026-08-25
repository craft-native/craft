/**
 * Craft - Build desktop apps with web languages
 * TypeScript SDK powered by Bun
 */

import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { craftBinaryNotFoundMessage, resolveCraftBinary } from './binary-resolver.js'
import type { AppConfig, WindowOptions } from './types.js'

const execFileAsync = promisify(execFile)

/** Tracks whether we've already warned about a binary/SDK version mismatch so each process logs once. */
let versionMismatchWarned = false

/**
 * Read the SDK's own version from `package.json`. Falls back to `'unknown'`
 * when not running from the source tree (the import-meta.dir path may not
 * resolve in some bundler edge cases).
 */
function getSdkVersion(): string {
  try {
    const pkgPath = join(import.meta.dir, '..', 'package.json')
    return JSON.parse(readFileSync(pkgPath, 'utf-8')).version ?? 'unknown'
  }
  catch {
    return 'unknown'
  }
}

/**
 * Probe the native binary for its `--version`, compare it to the SDK
 * version, and warn (once) when they don't match. Best-effort: a binary
 * that doesn't support `--version` is silently ignored.
 */
async function probeBinaryVersion(craftPath: string): Promise<void> {
  if (versionMismatchWarned) return
  try {
    const { stdout } = await execFileAsync(craftPath, ['--version'], { timeout: 2000 })
    const nativeVersion = parseCraftVersionOutput(stdout)
    const sdkVersion = getSdkVersion()
    if (sdkVersion !== 'unknown' && nativeVersion && nativeVersion !== sdkVersion) {
      versionMismatchWarned = true
      console.warn(
        `⚠️  Craft binary/SDK version mismatch: SDK=${sdkVersion}, native=${nativeVersion}.\n`
        + '   This is usually fine across patch releases but may produce surprising behavior across minors.',
      )
    }
  }
  catch {
    // Binary may not implement --version, or may be slow; don't block startup.
  }
}

export function parseCraftVersionOutput(output: string): string {
  const firstLine = output.trim().split(/\r?\n/, 1)[0] ?? ''
  return firstLine.replace(/^craft version\s+/i, '').replace(/^v/, '').trim()
}

// Export packaging API
export { packageApp, pack, type PackageConfig, type PackageResult } from './package.js'

// Export binary resolution. Craft ships through the pantry registry, and this is
// the single source of truth for finding the native binary (PATH, or CRAFT_BIN
// for local builds). Anything that spawns craft itself — the stx desktop
// package, for instance — must resolve it the same way rather than probing paths
// of its own.
export { craftBinaryNotFoundMessage, resolveCraftBinary } from './binary-resolver.js'

// Export utilities
export * from './utils/index.js'

// Export API modules
export * from './api/index.js'

// Namespace export so consumers can also do `import { components } from '....js'`
// and reach every symbol from `./components` without name clashes against the
// API surface. The flat (selective) re-exports below are kept for backwards
// compatibility, but new code should prefer `components.X` to avoid surprises
// when new exports are added on either side.
export * as components from './components/index.js'

// Export component abstractions (React Native-style primitives)
// Use explicit exports to avoid conflicts with names from './api/index.js':
// Excluded duplicates: Sidebar, createSidebar, SidebarItem, SidebarSection,
// SidebarConfig, TouchBarItem, TableColumn, Platform
export {
  // Sidebar (component variants, aliased to avoid conflict with api/sidebar)
  createTahoeSidebar,
  createArcSidebar,
  createOrbStackSidebar,
  sidebarItem,
  sidebarSection,
  sidebarSeparator,
  tahoeStyle,
  arcStyle,
  orbstackStyle,

  // Native UI Components
  createSplitView,
  SplitViewInstance,
  createFileBrowser,
  FileBrowserInstance,
  createOutlineView,
  OutlineViewInstance,
  createTableView,
  TableViewInstance,
  showQuickLook,
  hideQuickLook,
  canQuickLook,
  showColorPicker,
  showFontPicker,
  showDatePicker,
  createProgress,
  ProgressInstance,
  setToolbar,
  updateToolbarItem,
  setToolbarVisible,
  setTouchBar,
  updateTouchBarItem,

  // Animated & StyleSheet
  StyleSheet,
  Animated,
} from './components/index.js'
export type {
  // Sidebar types (excluding duplicates with api)
  ContextMenuItem,
  SidebarStyle,
  SidebarPosition,
  SidebarHeaderConfig,
  SidebarFooterConfig,
  SidebarEventType,
  SidebarEventMap,
  SidebarEventHandler,

  // Native component types (excluding duplicates with api)
  ComponentProps,
  ComponentInstance,
  SplitViewOrientation,
  SplitViewDividerStyle,
  SplitViewConfig,
  FileBrowserConfig,
  FileBrowserSelection,
  OutlineItem,
  OutlineViewConfig,
  TableRow,
  TableViewConfig,
  QuickLookConfig,
  ColorPickerConfig,
  FontPickerConfig,
  FontResult,
  DatePickerConfig,
  ProgressConfig,
  ToolbarItem,
  ToolbarConfig,
  TouchBarConfig,

  // Style types
  FlexStyle,
  LayoutStyle,
  SpacingStyle,
  BorderStyle,
  ColorStyle,
  ShadowStyle,
  TransformStyle,
  ViewStyle,
  TextStyleProps,
  TextStyle,
  ImageStyleProps,
  ImageStyle,

  // Component props
  BaseProps,
  ViewProps,
  TextProps,
  ImageSource,
  ImageProps,
  ScrollViewProps,
  PressableProps,
  TextInputProps,
  FlatListProps,

  // Events
  LayoutEvent,
  ScrollEvent,
} from './components/index.js'

// Export styling utilities (Headwind CSS integration + Sidebar styles)
export * from './styles/headwind.js'
export * from './styles/index.js'

// Export framework-specific optimizations
export * from './optimizations/index.js'

// Export auto-updater (delta/differential update support)
export * as updater from './updater/index.js'

// Also export the updater surface top-level. An app that self-updates needs the
// class and the manifest builder by name; reaching them only through the
// namespace left them untyped for anything re-exporting this package.
export { AutoUpdater, generateUpdateManifest } from './updater/index.js'
export type {
  UpdateInfo as UpdateManifest,
  UpdateProgress,
  UpdaterConfig,
  UpdaterEvent,
  PlatformUpdate,
} from './updater/index.js'

/**
 * Decide whether to enable dev defaults (hot-reload + devtools). The
 * previous default keyed exclusively off `NODE_ENV === 'development'`,
 * which Bun scripts and packaged CLIs almost never set; the result was
 * that you had to opt into devtools manually even when running from
 * source. The order of precedence is:
 *
 *   1. `CRAFT_ENV` env var, if set (`development`/`production` win).
 *   2. `NODE_ENV` env var, if set.
 *   3. Heuristic: enabled when not running inside a packaged binary
 *      (i.e. `process.pkg` / `import.meta.main` are absent or true).
 *      Keeps "just clone and run" working out of the box.
 */
function detectDevMode(): boolean {
  if (typeof process === 'undefined') return false
  const craftEnv = (process.env.CRAFT_ENV || '').toLowerCase()
  if (craftEnv === 'development' || craftEnv === 'dev') return true
  if (craftEnv === 'production' || craftEnv === 'prod') return false
  const nodeEnv = (process.env.NODE_ENV || '').toLowerCase()
  if (nodeEnv === 'development' || nodeEnv === 'dev') return true
  if (nodeEnv === 'production' || nodeEnv === 'prod') return false
  // Packaged-binary heuristic. `process.pkg` (pkg/Bun-compile),
  // `process.isPackaged` (Electron) → not dev. Otherwise default to dev.
  const proc = process as unknown as { pkg?: unknown; isPackaged?: boolean }
  if (proc.pkg || proc.isPackaged) return false
  return true
}

export class CraftApp {
  private process?: ChildProcess
  private config: AppConfig

  constructor(config: AppConfig = {}) {
    // Validate window dimensions
    if (config.window?.width !== undefined && (config.window.width < 100 || config.window.width > 10000)) {
      throw new Error(`Invalid window width: ${config.window.width}. Must be between 100 and 10000 pixels.`)
    }
    if (config.window?.height !== undefined && (config.window.height < 100 || config.window.height > 10000)) {
      throw new Error(`Invalid window height: ${config.window.height}. Must be between 100 and 10000 pixels.`)
    }

    // Validate that either html or url is provided, not both
    if (config.html && config.url) {
      console.warn('⚠️  Both html and url provided. URL will take precedence.')
    }

    this.config = {
      ...config,
      window: {
        title: 'Craft App',
        width: 800,
        height: 600,
        resizable: true,
        frameless: false,
        transparent: false,
        alwaysOnTop: false,
        fullscreen: false,
        hotReload: detectDevMode(),
        devTools: detectDevMode(),
        systemTray: false,
        ...config.window,
      },
    }
  }

  /**
   * Create and show a window with HTML content
   */
  async show(html?: string): Promise<void> {
    if (html) {
      this.config.html = html
    }

    // Validate that we have something to show (unless it's menubar-only mode)
    if (!this.config.window?.menubarOnly && !this.config.html && !this.config.url) {
      throw new Error(
        'No content to display. Provide either html or url:\n' +
        '  show(html, options) or loadURL(url, options)'
      )
    }

    const args = this.buildArgs()
    const craftPath = await this.findCraftBinary()

    // Probe the binary's reported version and warn if the SDK and native
    // halves drift. Fire-and-forget — the warning isn't load-bearing and
    // shouldn't gate startup.
    void probeBinaryVersion(craftPath)

    this.process = spawn(craftPath, args, {
      stdio: this.config.quiet ? 'ignore' : 'inherit',
    })

    return new Promise((resolve, reject) => {
      this.process?.on('error', (error: Error & { code?: string }) => {
        if (error.code === 'ENOENT') {
          // Single canonical message — we no longer probe a matrix of
          // "we tried these locations" since pantry is the install
          // surface of record.
          reject(new Error(craftBinaryNotFoundMessage(craftPath)))
          return
        }
        if (error.code === 'EACCES') {
          reject(new Error(
            `❌ Failed to start Craft process: ${error.message}\n\n`
            + `Permission denied on the binary at ${craftPath}.\n`
            + 'Re-run `pantry install craft` to restore correct permissions, '
            + `or chmod +x the file directly.`,
          ))
          return
        }
        reject(new Error(
          `❌ Failed to start Craft process: ${error.message}\n\n`
          + 'For troubleshooting, visit:\n'
          + '  https://github.com/home-lang/craft/issues',
        ))
      })

      this.process?.on('exit', (code) => {
        if (code === 0 || code === null) {
          resolve()
        }
        else {
          reject(new Error(
            `❌ Craft process exited with code ${code}\n\n` +
            'This may indicate:\n' +
            '  • Invalid window configuration\n' +
            '  • Malformed HTML content\n' +
            '  • System resource constraints\n\n' +
            'Check the console output above for more details.'
          ))
        }
      })
    })
  }

  /**
   * Load a URL in the window
   */
  async loadURL(url: string): Promise<void> {
    this.config.url = url
    return this.show()
  }

  /**
   * Close the window
   */
  close(): void {
    if (this.process) {
      this.process.kill()
    }
  }

  private buildArgs(): string[] {
    const args: string[] = []
    const { window, html, url, appName } = this.config

    // Before the window options: this names the *app*, not the window, and
    // the two are independent — a note-taking app is "Notes" in the menu bar
    // whatever the open document has put in the title bar.
    if (appName)
      args.push('--app-name', appName)

    // Menubar-only mode doesn't need content
    if (!window?.menubarOnly) {
      // URL takes precedence over HTML
      if (url) {
        args.push('--url', url)
      }
      else if (html) {
        args.push('--html', html)
      }
    }

    // Window options
    if (window?.title)
      args.push('--title', window.title)
    if (window?.width)
      args.push('--width', String(window.width))
    if (window?.height)
      args.push('--height', String(window.height))
    if (window?.x !== undefined)
      args.push('--x', String(window.x))
    if (window?.y !== undefined)
      args.push('--y', String(window.y))

    // Boolean flags
    if (window?.frameless)
      args.push('--frameless')
    if (window?.transparent)
      args.push('--transparent')
    if (window?.alwaysOnTop)
      args.push('--always-on-top')
    if (window?.fullscreen)
      args.push('--fullscreen')
    if (!window?.resizable)
      args.push('--no-resize')
    if (window?.darkMode)
      args.push('--dark')
    if (window?.hotReload)
      args.push('--hot-reload')
    // Both directions. The binary defaults DevTools *off* and used to have no
    // flag that turned them on, so pushing only the negative meant the SDK's
    // `devTools: true` — which is what dev mode sets — silently did nothing.
    if (window?.devTools === false)
      args.push('--no-devtools')
    else if (window?.devTools === true)
      args.push('--dev-tools')
    if (window?.systemTray)
      args.push('--system-tray')
    if (window?.hideDockIcon)
      args.push('--hide-dock-icon')
    if (window?.menubarOnly)
      args.push('--menubar-only')
    if (window?.titlebarHidden)
      args.push('--titlebar-hidden')
    if (window?.headless)
      args.push('--headless')
    if (window?.webSidebarMaterial) {
      args.push('--web-sidebar-material')
      if (window?.webSidebarWidth)
        args.push('--web-sidebar-width', String(window.webSidebarWidth))
      if (window?.webSidebarMaterialOpacity !== undefined)
        args.push('--web-sidebar-material-opacity', String(window.webSidebarMaterialOpacity))
    }
    if (window?.icon)
      args.push('--icon', window.icon)
    // After the geometry flags, and independent of them: those are what the
    // window opens at until there is a saved frame, which then wins.
    if (window?.frameAutosave)
      args.push('--frame-autosave', window.frameAutosave)

    if (window?.nativeSidebar) {
      args.push('--native-sidebar')
      if (window?.sidebarWidth)
        args.push('--sidebar-width', String(window.sidebarWidth))
      const sidebarConfig = window?.sidebarConfig
        ? {
            ...window.sidebarConfig,
            variant: window.sidebarConfig.variant ?? window.sidebarVariant,
            material: window.sidebarConfig.material ?? window.sidebarMaterial,
            backgroundEffect: window.sidebarConfig.backgroundEffect ?? window.sidebarBackgroundEffect,
            allowsVibrancy: window.sidebarConfig.allowsVibrancy ?? window.sidebarAllowsVibrancy,
          }
        : undefined
      if (sidebarConfig?.variant === 'desktop') {
        sidebarConfig.material = sidebarConfig.material ?? 'sidebar'
        sidebarConfig.backgroundEffect = sidebarConfig.backgroundEffect ?? 'vibrancy'
        sidebarConfig.allowsVibrancy = sidebarConfig.allowsVibrancy ?? true
      }
      if (sidebarConfig) {
        // sidebarConfig used to be JSON-stringified onto argv directly,
        // which (a) hits OS argv length limits on macOS/Linux, (b) breaks
        // on cmd.exe when the config contains newlines, and (c) leaks the
        // entire config to anyone running `ps`. Inline tiny configs that
        // are clearly safe (≤ 4 KiB, no newlines) and spill larger ones
        // into a temp file via `--sidebar-config-file <path>`.
        let json: string
        try {
          json = JSON.stringify(sidebarConfig)
        }
        catch (e) {
          throw new Error(`Failed to serialize sidebarConfig: ${(e as Error).message}`)
        }
        // macOS ARG_MAX is 1 MiB; Linux is 128 KiB+ on every modern kernel.
        // The native craft binary only implements the inline `--sidebar-config`
        // flag (it does NOT recognise `--sidebar-config-file`), so falling
        // back to a file write makes Craft drop our config and render its
        // built-in Finder placeholder instead. Bumping the inline ceiling
        // to 256 KiB lets every realistic dashboard config (~10–20 KiB)
        // round-trip; only a config with embedded newlines (which the OS
        // chokes on for argv) drops to the file path.
        const inlineLimit = 256 * 1024
        const safeForArgv = json.length <= inlineLimit && !json.includes('\n') && !json.includes('\r')
        if (safeForArgv) {
          args.push('--sidebar-config', json)
        }
        else {
          const dir = mkdtempSync(join(tmpdir(), 'craft-sidebar-'))
          const path = join(dir, 'sidebar-config.json')
          writeFileSync(path, json, 'utf-8')
          args.push('--sidebar-config-file', path)
        }
      }
    }

    if (this.config.quiet)
      args.push('--quiet')

    return args
  }

  /**
   * Resolve the `craft` binary to spawn.
   *
   * Craft ships through the pantry registry (`pantry install craft`),
   * so once pantry is set up the binary is on PATH and we just spawn
   * `'craft'`. The two escape hatches are `config.craftPath` (per-app
   * pin) and the `CRAFT_BIN` env var (test/dev override). Anything
   * else is delegated to PATH lookup; the error path on the spawn
   * itself surfaces a pantry-pointing message via
   * {@link craftBinaryNotFoundMessage}.
   */
  private async findCraftBinary(): Promise<string> {
    return resolveCraftBinary(this.config.craftPath)
  }
}

/**
 * Create a new Craft app instance
 */
export function createApp(config?: AppConfig): CraftApp {
  return new CraftApp(config)
}

/**
 * Quick helper to show a window with HTML
 */
export async function show(html: string, options?: WindowOptions): Promise<void> {
  const app = new CraftApp({ html, window: options })
  return app.show()
}

/**
 * Quick helper to load a URL
 */
export async function loadURL(url: string, options?: WindowOptions): Promise<void> {
  const app = new CraftApp({ url, window: options })
  return app.show()
}

// Export types explicitly, excluding names already exported by './api'
// Excluded duplicates: SidebarItem, SidebarSection, SidebarConfig, SidebarSelectEvent,
// TrayClickEvent, MenuItem, AppInfo, NotificationOptions, DeviceInfo,
// PermissionStatus, ShareOptions, DisplayInfo
export type {
  WindowOptions,
  CraftSidebarAPI,
  AppConfig,
  CraftTrayAPI,
  CraftWindowAPI,
  CraftAppAPI,
  CraftBridgeAPI,
  Permission,
  HapticType,
  CameraOptions,
  PhotoPickerOptions,
  CraftMobileAPI,
  CraftFileSystemAPI,
  CraftDatabaseAPI,
  CraftHttpAPI,
  CraftCryptoAPI,
  CraftCapabilities,
  CapabilityNamespace,
  CapabilityNamespaceStatus,
  CapabilityAction,
  CraftPreferencesAPI,
  CraftPreferencesInfo,
  CraftSettingsAPI,
  PreferenceValue,
  CraftEventType,
  CraftEventMap,
  CraftEventHandler,
  CraftEventEmitter,
  IOSConfig,
  AndroidConfig,
  MacOSConfig,
  WindowsConfig,
  LinuxConfig,
  CraftAppConfig,
} from './types.js'
