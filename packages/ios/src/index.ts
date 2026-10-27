import { gzipSync } from 'node:zlib'
import { iosPermissionMask, iosPermissions, renderPermissionSource, verifyInstalledProfile, verifyRuntimeProfile, withAppRuntime, writeInstalledProfile } from './runtime-profile.js'
/**
 * Craft iOS Builder
 *
 * Generates native iOS apps from web content using WKWebView.
 */

import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'

/** Store large native source assets compressed; the host decodes each once on demand. */
export function compressNativeSources(target: string): void {
  if (statSync(target).isDirectory()) {
    for (const entry of readdirSync(target)) compressNativeSources(join(target, entry))
    return
  }
  if (!/\.(?:js|json)$/.test(target)) return
  const bytes = readFileSync(target)
  if (bytes.length < 1024 || (bytes[0] === 0x1f && bytes[1] === 0x8b)) return
  const packed = gzipSync(bytes, { level: 9 })
  if (packed.length < bytes.length) writeFileSync(target, packed)
}
import { dirname, extname, join, resolve, sep } from 'node:path'
import { $ } from 'bun'
import { appShortcutsSwift, type CraftAppShortcut } from './app-shortcuts.js'

/** Package custom fonts and their licenses; removed fonts cannot linger in the app. */
export function syncNativeFonts(fonts: CraftConfig['nativeFonts'], output: string): string[] {
  const destination = join(output, 'NativeFonts')
  const names = new Set<string>()
  const files = Object.entries(fonts ?? {}).map(([family, entry]) => {
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(family))
      throw new Error(`Invalid native font PostScript name: ${family}`)
    if (names.has(family.toLowerCase())) throw new Error(`Duplicate native font name: ${family}`)
    names.add(family.toLowerCase())
    if ([entry.src, entry.license].some(file => file && resolve(file).startsWith(resolve(destination) + sep)))
      throw new Error('Native font sources must be outside the generated NativeFonts directory')
    const extension = extname(entry.src).toLowerCase()
    if (!['.ttf', '.otf'].includes(extension) || !existsSync(entry.src) || !statSync(entry.src).isFile())
      throw new Error(`Native font ${family} must reference an existing TTF or OTF file: ${entry.src}`)
    if (entry.license && (!existsSync(entry.license) || !statSync(entry.license).isFile()))
      throw new Error(`Native font license not found: ${entry.license}`)
    return { family, ...entry, filename: `${family}${extension}` }
  })
  rmSync(destination, { recursive: true, force: true })
  if (!files.length) return []
  mkdirSync(destination, { recursive: true })
  for (const file of files) {
    cpSync(file.src, join(destination, file.filename))
    if (file.license) cpSync(file.license, join(destination, `${file.family}.LICENSE.txt`))
  }
  return files.map(file => `NativeFonts/${file.filename}`)
}

const TEMPLATES_DIR = join(dirname(import.meta.dir), 'templates')

/** This package's version, which the app names in its user agent (`Craft/<version>`). */
export function resolveCraftVersion(startDir: string = import.meta.dir): string {
  let directory = resolve(startDir)
  while (true) {
    try {
      const packageJSON = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')) as {
        name?: unknown
        version?: unknown
      }
      // `craft-native` bundles this builder under its own dist and publishes
      // in lockstep, so its version is this builder's version too. Without
      // it an app built through craft-native reported Craft 0.0.0.
      if ((packageJSON.name === '@craft-native/ios' || packageJSON.name === 'craft-native') && typeof packageJSON.version === 'string' && packageJSON.version.length > 0)
        return packageJSON.version
    }
    catch {
      // Keep walking: bundled builds put the module below the package root.
    }
    const parent = dirname(directory)
    if (parent === directory) break
    directory = parent
  }
  return '0.0.0'
}

const CRAFT_VERSION = resolveCraftVersion()

export type CraftAppearance = 'light' | 'dark' | 'system'

/** A declared command Craft runs after the native project has been generated. */
export interface CraftPostGenerateHook {
  command: string
  args?: string[]
}

export interface CraftTabBarConfig {
  selection?: {
    /** The selected tab indicator's corner radius in points; omitted keeps a capsule. */
    cornerRadius?: number
    /** The selected tab indicator fill as #RRGGBB. */
    color?: string
  }
}

export interface CraftConfig {
  appShortcuts?: CraftAppShortcut[]
  /** Bundled font files keyed by their PostScript font name, used as native fontFamily. */
  nativeFonts?: Record<string, { src: string, license?: string }>

  appName: string
  bundleId: string
  /** Opt in to UIKit + JavaScriptCore instead of the default WebView. */
  renderer?: 'web' | 'native'
  version?: string
  buildNumber?: string
  darkMode?: boolean
  /**
   * Which interface style the app draws in. `system` follows the phone's
   * Light/Dark setting (and the page's `prefers-color-scheme` with it); `light`
   * and `dark` pin one. Unset keeps the older `darkMode` switch.
   */
  appearance?: CraftAppearance
  /** Static native tab-bar styling applied before the page's own tabBar.set call. */
  tabBar?: CraftTabBarConfig
  /** Runs from the generated project root after `craft ios build` writes it. */
  postGenerate?: CraftPostGenerateHook
  backgroundColor?: string
  /** The launch and webview background while the phone is in Dark Mode. */
  backgroundColorDark?: string
  /** Edge-swipe back and forward through the page's history, pushState entries included. */
  swipeNavigation?: boolean
  enableSpeechRecognition?: boolean
  enableHaptics?: boolean
  enableShare?: boolean
  enableCamera?: boolean
  enableBiometric?: boolean
  enablePushNotifications?: boolean
  enableSecureStorage?: boolean
  enableGeolocation?: boolean
  enableClipboard?: boolean
  enableContacts?: boolean
  enableCalendar?: boolean
  enableLocalNotifications?: boolean
  enableInAppPurchase?: boolean
  enableKeepAwake?: boolean
  enableOrientationLock?: boolean
  enableDeepLinks?: boolean
  enableQRScanner?: boolean
  /** Reach devices on the local network (a Mac on the same Wi-Fi); iOS asks first. */
  enableLocalNetwork?: boolean
  enableFilePicker?: boolean
  enableFileDownload?: boolean
  enableSocialAuth?: boolean
  /** Native passkeys; requires a matching `webcredentials:` associated domain. */
  enablePasskeys?: boolean
  enableAudioRecording?: boolean
  enableVideoRecording?: boolean
  enableMotionSensors?: boolean
  enableLocalDatabase?: boolean
  enableBluetooth?: boolean
  enableNFC?: boolean
  enableHealthKit?: boolean
  /** Native Apple Wallet pass presentation and lookup for native screens. */
  enableWallet?: boolean
  enableLiveActivities?: boolean
  enableWatchApp?: boolean
  enableBackgroundLocation?: boolean
  enableBackgroundTasks?: boolean
  enableScreenCapture?: boolean
  enablePDFViewer?: boolean
  enableAR?: boolean
  enableMLKit?: boolean
  /**
   * Show and control what the Music app is playing (`craft.music`, through
   * MPMusicPlayerController.systemMusicPlayer). Only Apple Music: iOS gives
   * no app the controls of another player such as Spotify. iOS asks the
   * person for media library access the first time the page calls
   * `craft.music.requestAuthorization()`, never at launch.
   */
  enableAppleMusic?: boolean
  /**
   * Read a Bluetooth heart-rate strap, or a watch broadcasting its heart rate
   * (the standard Heart Rate Service), through `craft.heartRate`: scan,
   * connect, live readings with RR intervals, and a recording kept natively.
   * Adds the `bluetooth-central` background mode, so readings keep coming
   * during a workout with the screen locked. iOS asks for Bluetooth the first
   * time the page scans or connects.
   */
  enableHeartRate?: boolean
  /**
   * Keep playing sound with the screen locked or the app in the background:
   * a sleep soundscape, a meditation timer's ambience. Adds the `audio`
   * background mode. iOS keeps the app running only while it plays, and App
   * Review expects audible content, so turn it on only for an app that plays
   * some (Web Audio on native screens and in the web view, which use the
   * playback session).
   */
  enableBackgroundAudio?: boolean
  /**
   * Schedule structured workouts onto the paired Apple Watch through
   * `craft.scheduledWorkouts` (WorkoutKit's WorkoutScheduler, iOS 17+): each
   * appears in the watch's Workout app on its day, with its steps, goals and
   * alerts. Compiles CraftScheduledWorkouts.swift with the
   * `CRAFT_SCHEDULED_WORKOUTS` condition, so an app without it never links
   * WorkoutKit; below iOS 17 it is weak-linked and answers unsupported. iOS
   * asks the person the first time the page calls
   * `craft.scheduledWorkouts.requestAuthorization()`, never at launch.
   */
  enableScheduledWorkouts?: boolean
  /**
   * Purpose strings in the app's own words, by Info.plist key
   * (`{ NSAppleMusicUsageDescription: 'Shows the song playing during a workout.' }`).
   * Each replaces the generic sentence Craft writes for that key.
   */
  usageDescriptions?: Record<string, string>
  /**
   * The app's site. With `renderer: "web"` it is the page the web view loads.
   * With `renderer: "native"` and `nativeScreens` there is no web view: its
   * path is the path the app starts on (`/` when unset), and a path no native
   * screen draws (`craft.navigation.open('/terms')`, or a link to this host)
   * opens in the in-app browser against its origin. Native screens read it as
   * `__stxNativeBridge.appURL`.
   */
  devServerURL?: string
  iosVersion?: string
  watchosVersion?: string
  teamId?: string
  urlSchemes?: string[]
  trustedOrigins?: string[]
  /**
   * The domains the app's web view treats as its own (WKAppBoundDomains, at
   * most 10). Service workers only run in an iOS web view on these, so a site
   * that works offline in Safari works offline in the app. Unset, they are the
   * hosts of `trustedOrigins` and the dev server: the origins the bridge is
   * already injected into, and once any are declared iOS keeps script
   * injection to them. `[]` declares none.
   */
  appBoundDomains?: string[]
  /**
   * Also refuse to load anything but the app-bound domains in the web view
   * (WKWebViewConfiguration.limitsNavigationsToAppBoundDomains). Off by
   * default: links elsewhere already open in Safari. WebKit applies the limit
   * to the main frame only, so embedded players and maps in cross-origin
   * iframes (YouTube, Vimeo) keep loading with it on (checked in the iOS 26
   * simulator); WebKit only declines to inject user scripts into them, which
   * the bridge never does.
   */
  limitNavigationsToAppBoundDomains?: boolean
  /**
   * Universal links and shared web credentials
   * (`com.apple.developer.associated-domains`). A bare host such as
   * `hq.training` is written as `applinks:hq.training`; an entry with its own
   * service (`webcredentials:`, `applinks:…?mode=developer`) is kept as given.
   * A universal link reaches the page the way a custom-scheme link does, as
   * `craftDeepLink`.
   */
  associatedDomains?: string[]
  /**
   * iOS's scheduled background refresh (BGAppRefreshTask). When enabled the
   * page gets `craftBackgroundRefresh` and answers with
   * `craft.background.complete(ok)`. The identifier defaults to
   * `<bundleId>.refresh` and is declared in BGTaskSchedulerPermittedIdentifiers,
   * with the `fetch` background mode.
   */
  backgroundRefresh?: CraftBackgroundRefresh
  appGroups?: string[]
  appIconPath?: string
  /**
   * The logo the launch screen shows on `backgroundColor`, and that stays on
   * screen until the page says it is ready (`splash.hide()`), so the app goes
   * from launch to content without a blank web view in between. PNG, PDF or
   * SVG, drawn at its own size in points: give an SVG the width and height it
   * should have on screen.
   */
  splashImagePath?: string
  /** The splash logo in Dark Mode, on `backgroundColorDark`. The light one if unset. */
  splashImagePathDark?: string
  /**
   * Whether the app uses encryption beyond the exempt kinds (HTTPS, the
   * system's own). Written as `ITSAppUsesNonExemptEncryption`, so App Store
   * Connect does not ask the export-compliance question on every build.
   * Default false: a WebView app that talks HTTPS is exempt.
   */
  usesNonExemptEncryption?: boolean
  privacy?: CraftPrivacyManifest
  /** Press-and-hold link previews, as in Safari. Default false. */
  allowsLinkPreview?: boolean
  /**
   * WebKit's bar above the keyboard for a form field (previous, next, Done),
   * which no native app's keyboard has. Default false: hidden. A page can
   * change it with `craft.chrome.setKeyboardAccessory()`.
   */
  keyboardAccessory?: boolean
  /** Pinch and double-tap zoom off, and the page's viewport pinned at scale 1. Default true. */
  disableZoom?: boolean
  /**
   * The longest the launch splash stays up, in seconds, when the page neither
   * hides it (`splash.hide()`) nor paints. Default 3.
   */
  splashMaxSeconds?: number
  /**
   * How long the app's own page may take to answer, in seconds, before the
   * load counts as unreachable and the bundled page stands in. Default 10.
   */
  requestTimeoutSeconds?: number
  orientations?: Array<'portrait' | 'landscape-left' | 'landscape-right' | 'portrait-upside-down'>
  deviceFamilies?: Array<'iphone' | 'ipad'>
  /**
   * App paths drawn as native stx screens, each to the screen in the native
   * bundle that draws it, e.g. `{ "/m": "Today", "/m/calendar": "Calendar" }`.
   * A segment may be a parameter (`/m/workout/:id`) and the last one `*`.
   * Needs `nativeBundle`.
   *
   * With `renderer: "web"` (hybrid) every other path stays in the web view,
   * and a path whose screen is missing or throws falls back to it.
   *
   * With `renderer: "native"` the app is all native, with the same tabs and
   * path routing and no web view at all: every tab id and the start path (the
   * path of `devServerURL`) must be a native screen's, and any other path
   * opens in the in-app browser on the app's site.
   */
  nativeScreens?: Record<string, string>
  /**
   * The bundle `stx native compile --format bundle` wrote, copied to
   * `dist/native-screen.js`; or a directory of route bundles (stx's
   * `routesDir`: `<Screen>.js` and `__app.js`), copied to
   * `dist/native-screens/`, so each screen evaluates only its own file.
   */
  nativeBundle?: string
  /**
   * The bundle route of a screen-less script that runs once for the app's
   * whole life, beside the screens (Stacks names it `__app`). It hears the
   * app's events (`craftNotificationResponse`, `craftNotificationReceived`,
   * `craftSilentPush`, `craftBackgroundRefresh`, `craftShortcut`,
   * `craftSiriShortcut`) as `CRAFT_EVENT` messages instead of the page, every
   * `APP_STATE`, and can open paths with `craft.navigation.open`. Needs
   * `nativeScreens` or `renderer: "native"`, and the native bundle.
   */
  nativeApp?: string
  /**
   * Where native screens run their JavaScript. `"main"` (the default) runs it
   * on the main thread; `"background"` gives screens a serial thread of their
   * own, so a screen's script, its timers and its renders never hold the
   * main thread while it scrolls or animates. UIKit still runs on main: the
   * shell hands each render to it, and a pushed screen waits for its first
   * render (at most 0.3 s) so it never slides in empty.
   */
  nativeScriptThread?: 'main' | 'background'
  /**
   * The native tab bar, shown from the first frame, before the page loads.
   * The page's own `tabBar.set` replaces it later. Each `id` is the tab's
   * root path, as the page's tab links name it.
   */
  tabs?: CraftTab[]
  /**
   * Hybrid: web-storage keys the page writes (localStorage or
   * sessionStorage) that native screens need, mirrored into the Keychain
   * under the name given, e.g. `{ "auth_token": "auth.token" }` for
   * `craft.secureStorage.getSync('auth.token')`. Turns on secure storage.
   */
  shareStorage?: Record<string, string>
  /**
   * The secure-storage key the signed-in account's token lives under
   * (default `auth.token`). `craft.session` follows it: a change of it, made
   * by any native screen or by the page through a `shareStorage` key, is
   * `SESSION_CHANGED { key, token, previous }` on every native screen and a
   * `craftsession` event on the page.
   */
  sessionTokenKey?: string
  /**
   * Crash and error reporting to bughq (CraftCrashReporter.swift): crashes
   * and hangs (signal handlers, NSException, MetricKit), uncaught JavaScript
   * errors in native screens and the app script, and what the page sends
   * through `craft.crashReporter`. Queued on disk and sent when online.
   */
  crashReporting?: CraftCrashReporting
}

export interface CraftCrashReporting {
  /** The bughq project's public ingest key. Ships in the app; it is not a secret. */
  key: string
  /** The bughq host. Default https://bughq.org. */
  host?: string
  /** Default `production`. */
  environment?: string
  /** The release every event names. Default `<version>+<build>`, e.g. `1.0.0+41`. */
  release?: string
  /** One session per launch, for crash-free sessions per release. Default on. */
  sessions?: boolean
}

export interface CraftTab {
  /** The tab's root path; comes back to the page in `craftTabSelect`. */
  id: string
  title: string
  /** An SF Symbol name. */
  symbol?: string
  /** Native selected-tab icon overrides; retained pushed screens keep their owning tab's policy. */
  selectedSymbol?: string
  selectedIconTint?: string
  /** False suppresses the legacy pulse while selected; omission uses the legacy policy. */
  selectedIconPulse?: boolean
}

/** `/a//b/?q#h` → `/a/b`, the way the shell and the page compare paths. Null for a relative path. */
export function normalizeNativePath(raw: string): string | null {
  if (typeof raw !== 'string') return null
  let path = raw
  const cut = path.search(/[?#]/)
  if (cut >= 0) path = path.slice(0, cut)
  if (!path.startsWith('/')) return null
  path = path.replace(/\/{2,}/g, '/')
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  return path
}

export interface NativePathMatch {
  path: string
  screen: string
  params: Record<string, string>
}

function routeSegments(path: string): string[] {
  return path === '/' ? [] : path.slice(1).split('/')
}

/**
 * The native screen for a path, by the rules the shell (`CraftHybridRoutes`)
 * and the page script apply: static segments win over `:params`, which win
 * over a trailing `*`; query items become params under the path's own.
 */
export function matchNativePath(nativeScreens: Record<string, string> | undefined, raw: string): NativePathMatch | null {
  const path = normalizeNativePath(raw)
  if (path === null) return null
  const routes = Object.entries(nativeScreens ?? {})
    .map(([pattern, screen]) => ({ pattern: normalizeNativePath(pattern), screen }))
    .filter((route): route is { pattern: string, screen: string } => route.pattern !== null && !!route.screen)
    .map(route => ({ ...route, segments: routeSegments(route.pattern) }))
  const wild = (segments: string[]) => (segments.at(-1) === '*' ? 1 : 0)
  const fixed = (segments: string[]) => segments.filter(s => s !== '*' && !s.startsWith(':')).length
  routes.sort((a, b) => (wild(a.segments) - wild(b.segments))
    || (fixed(b.segments) - fixed(a.segments))
    || (b.segments.length - a.segments.length)
    || (a.pattern < b.pattern ? -1 : a.pattern > b.pattern ? 1 : 0))
  const decode = (value: string) => {
    try {
      return decodeURIComponent(value)
    }
    catch {
      return value
    }
  }
  const parts = routeSegments(path)
  for (const route of routes) {
    const params: Record<string, string> = {}
    let matched = true
    for (let i = 0; i < route.segments.length; i++) {
      const segment = route.segments[i]!
      if (segment === '*') {
        params['*'] = parts.slice(i).join('/')
        break
      }
      if (i >= parts.length) { matched = false; break }
      if (segment.startsWith(':')) {
        if (!parts[i]) { matched = false; break }
        params[segment.slice(1)] = decode(parts[i]!)
      }
      else if (segment !== parts[i]) { matched = false; break }
    }
    if (!matched) continue
    if (route.segments.at(-1) !== '*' && route.segments.length !== parts.length) continue
    const query = raw.indexOf('?')
    if (query >= 0) {
      for (const item of raw.slice(query + 1).split('#')[0]!.split('&')) {
        if (!item) continue
        const [rawKey = '', ...rest] = item.split('=')
        const key = decode(rawKey)
        if (!key || key in params) continue
        params[key] = decode(rest.join('=').replace(/\+/g, ' '))
      }
    }
    return { path, screen: route.screen, params }
  }
  return null
}

/** Whether a config mixes native screens into its web page. */
export function isHybrid(config: Pick<CraftConfig, 'renderer' | 'nativeScreens'>): boolean {
  return (config.renderer ?? 'web') === 'web' && Object.keys(config.nativeScreens ?? {}).length > 0
}

/** Whether a config is an all-native app with routes: `renderer: "native"` and `nativeScreens`, tabs and paths with no web view. */
export function hasNativeRoutes(config: Pick<CraftConfig, 'renderer' | 'nativeScreens'>): boolean {
  return config.renderer === 'native' && Object.keys(config.nativeScreens ?? {}).length > 0
}

/** Whether a config draws any native screen, and so needs `dist/native-screen.js`. */
export function usesNativeBundle(config: Pick<CraftConfig, 'renderer' | 'nativeScreens'>): boolean {
  return config.renderer === 'native' || Object.keys(config.nativeScreens ?? {}).length > 0
}

/**
 * The path the app starts on: the path of `devServerURL` (with its query),
 * `/` when there is none. The shell reads it the same way
 * (`CraftHybridRoutes.appPath`).
 */
export function nativeStartPath(config: Pick<CraftConfig, 'devServerURL'>): string {
  if (!config.devServerURL) return '/'
  try {
    const url = new URL(config.devServerURL)
    return `${url.pathname || '/'}${url.search}`
  }
  catch {
    return '/'
  }
}

/** What is wrong with a config's hybrid and tab settings, one sentence each. */
export function hybridConfigProblems(config: Pick<CraftConfig, 'renderer' | 'nativeScreens' | 'tabs' | 'shareStorage' | 'devServerURL' | 'nativeApp' | 'nativeScriptThread'>): string[] {
  const problems: string[] = []
  const screens = Object.entries(config.nativeScreens ?? {})
  for (const [pattern, screen] of screens) {
    if (normalizeNativePath(pattern) !== pattern || /[?#]/.test(pattern))
      problems.push(`nativeScreens path "${pattern}" must be an absolute path with no query, hash or trailing slash.`)
    if (routeSegments(normalizeNativePath(pattern) ?? '/').slice(0, -1).includes('*'))
      problems.push(`nativeScreens path "${pattern}" may only end in *.`)
    if (typeof screen !== 'string' || !/^[A-Za-z_$][\w$-]*$/.test(screen))
      problems.push(`nativeScreens screen "${String(screen)}" for "${pattern}" must be a screen name from the native bundle.`)
  }
  const ids = new Set<string>()
  for (const tab of config.tabs ?? []) {
    if (!tab || typeof tab.id !== 'string' || !tab.id || typeof tab.title !== 'string' || !tab.title)
      problems.push('Each tab needs an id (its root path) and a title.')
    else if (ids.has(tab.id))
      problems.push(`Tab "${tab.id}" is listed twice.`)
    else ids.add(tab.id)
  }
  for (const [key, target] of Object.entries(config.shareStorage ?? {})) {
    if (!key || typeof target !== 'string' || !target)
      problems.push(`shareStorage "${key}" needs the Keychain key native screens read it under.`)
  }
  // All native: there is no web view for a path to fall back to, so every
  // tab and the start path must be drawn by a native screen.
  if (hasNativeRoutes(config)) {
    for (const id of ids) {
      if (!matchNativePath(config.nativeScreens, id))
        problems.push(`Tab "${id}" is not a nativeScreens path; with renderer: "native" every tab must be a native screen.`)
    }
    const start = nativeStartPath(config)
    if (!matchNativePath(config.nativeScreens, start))
      problems.push(`The start path "${start}" (from devServerURL) is not a nativeScreens path; with renderer: "native" the app must start on a native screen.`)
  }
  if (config.nativeApp !== undefined) {
    if (typeof config.nativeApp !== 'string' || !/^[A-Za-z_$][\w$-]*$/.test(config.nativeApp))
      problems.push(`nativeApp "${String(config.nativeApp)}" must be a route name from the native bundle.`)
    else if (!usesNativeBundle(config))
      problems.push('nativeApp runs in the native bundle; it needs nativeScreens or renderer: "native".')
  }
  if (config.nativeScriptThread !== undefined && config.nativeScriptThread !== 'main' && config.nativeScriptThread !== 'background')
    problems.push(`nativeScriptThread "${String(config.nativeScriptThread)}" must be "main" or "background".`)
  return problems
}

/**
 * The builder installs a directory of route bundles (stx's `routesDir`) as
 * well as the one-file bundle, and the app runs each screen from its own
 * route's file. Stacks asks for route bundles only when this is true.
 */
export const nativeRouteBundles = true

/**
 * The app evaluates stx's shared runtime (`__runtime.js`, stx's
 * `sharedRuntime`) in each screen's context before the route's own file.
 * Stacks asks stx for it only when this is true: a route file built so
 * refuses to run without it.
 */
export const nativeRouteRuntime = true

/**
 * The app gives a screen its messages a language at a time (stx's
 * `messages`, `native-screens/__messages/`): read when the screen first
 * looks inside them (`__stxNativeReadMessages`). Stacks leaves the languages
 * out of the screens' code only when this is true.
 */
export const nativeMessages = true

/**
 * Copy the compiled native bundle where the app loads it from: one file to
 * `dist/native-screen.js`, a directory of route bundles to
 * `dist/native-screens/`. Whichever it is replaces the other, because the
 * app prefers a route's own file and would run a stale one.
 */
function installNativeBundle(source: string, output: string): void {
  if (!existsSync(source)) throw new Error(`Native bundle not found: ${source}`)
  const single = join(output, 'dist', 'native-screen.js')
  const routes = join(output, 'dist', 'native-screens')
  mkdirSync(dirname(single), { recursive: true })
  if (statSync(source).isDirectory()) {
    if (!readdirSync(source).some(name => name.endsWith('.js'))) throw new Error(`Native route bundles not found in ${source}`)
    if (resolve(source) !== resolve(routes)) {
      rmSync(routes, { recursive: true, force: true })
      cpSync(source, routes, { recursive: true })
    }
    compressNativeSources(routes)
    rmSync(single, { force: true })
    return
  }
  if (resolve(source) !== resolve(single)) cpSync(source, single)
  compressNativeSources(single)
  rmSync(routes, { recursive: true, force: true })
}

/** Whether the generated project carries native screens, in either layout. */
function hasInstalledNativeBundle(output: string): boolean {
  return existsSync(join(output, 'dist', 'native-screen.js')) || existsSync(join(output, 'dist', 'native-screens'))
}

export interface CraftBackgroundRefresh {
  enabled: boolean
  /** The BGTaskScheduler identifier. Default `<bundleId>.refresh`. */
  identifier?: string
  /** The soonest iOS may run it again, in minutes. Default 15. */
  minimumIntervalMinutes?: number
}

export interface CraftPrivacyDataType {
  type: string
  linked?: boolean
  tracking?: boolean
  purposes: string[]
}

export interface CraftPrivacyAccessedApiType {
  type: string
  reasons: string[]
}

export interface CraftPrivacyManifest {
  tracking?: boolean
  trackingDomains?: string[]
  collectedDataTypes?: CraftPrivacyDataType[]
  accessedApiTypes?: CraftPrivacyAccessedApiType[]
}

export interface InitOptions {
  name: string
  bundleId?: string
  teamId?: string
  output: string
  config?: Partial<CraftConfig>
  /**
   * Where the Zig runtime archives live, overriding `CRAFT_IOS_RUNTIME`.
   *
   * `null` means "no runtime, whatever the environment says" — the shape
   * `AppConfig.craftPath` has for `CRAFT_BIN`, and the reason it exists here
   * is the same: a caller that does not opt in should not be steered by an
   * ambient variable. Without it this package's own tests inherited whatever
   * the developer's shell exported, and went from 12 passing to 8 passing and
   * 4 failing when `CRAFT_IOS_RUNTIME` happened to be set.
   *
   * Omitted (`undefined`) keeps the environment lookup, which is what the
   * monorepo dev loop uses.
   */
  runtimeDir?: string | null
  /** Explicit Craft Zig source package for a per-app runtime build (or CRAFT_IOS_RUNTIME_SOURCE). */
  runtimeSource?: string | null
}

export interface BuildOptions {
  htmlPath?: string
  /** JavaScript bundle emitted by `stx native compile Screen.stx --format bundle`. */
  nativeBundlePath?: string
  devServer?: string
  output: string
  generateProject?: boolean
  /**
   * Where to re-read the Zig runtime archives from, overriding
   * `CRAFT_IOS_RUNTIME`. Same meaning as `InitOptions.runtimeDir`; `null`
   * leaves whatever `init` installed exactly as it is.
   */
  runtimeDir?: string | null
  /** Rebuild the installed runtime from this source using the app's current feature flags. */
  runtimeSource?: string | null
}

/**
 * Run the app's declared generator hook without invoking a shell.
 *
 * A hook gets the generated project as its cwd and explicit metadata so a
 * patch can target the right platform and phase without guessing from paths.
 */
export function runPostGenerateHook(
  hook: CraftPostGenerateHook | undefined,
  output: string,
  phase: 'build' = 'build',
): void {
  if (!hook) return
  if (typeof hook.command !== 'string' || !hook.command.trim())
    throw new Error('iOS postGenerate.command must be a non-empty executable')
  if (hook.args !== undefined && (!Array.isArray(hook.args) || hook.args.some(argument => typeof argument !== 'string')))
    throw new Error('iOS postGenerate.args must be an array of strings')

  const command = [hook.command, ...(hook.args ?? [])]
  let result: ReturnType<typeof Bun.spawnSync>
  try {
    result = Bun.spawnSync(command, {
      cwd: output,
      env: { ...process.env, CRAFT_PROJECT_ROOT: output, CRAFT_PLATFORM: 'ios', CRAFT_GENERATE_PHASE: phase },
      stdout: 'inherit',
      stderr: 'pipe',
    })
  }
  catch (error) {
    throw new Error(`iOS postGenerate hook could not start in ${output}: ${hook.command}`, { cause: error })
  }
  if (result.exitCode !== 0) {
    const stderr = result.stderr?.toString().trim()
    throw new Error(`iOS postGenerate hook failed in ${output} with exit code ${result.exitCode}${stderr ? `: ${stderr}` : ''}`)
  }
}

export interface OpenOptions {
  output: string
}

export interface RunOptions {
  simulator: boolean
  output: string
}

const DEFAULT_CONFIG: Omit<CraftConfig, 'appName' | 'bundleId'> = {
  renderer: 'web',
  version: '1.0.0',
  buildNumber: '1',
  darkMode: true,
  backgroundColor: '#0b1712',
  enableSpeechRecognition: false,
  enableHaptics: false,
  enableShare: false,
  enableCamera: false,
  enableBiometric: false,
  enablePushNotifications: false,
  enableSecureStorage: false,
  enableGeolocation: false,
  enableClipboard: false,
  enableContacts: false,
  enableCalendar: false,
  enableLocalNotifications: false,
  enableInAppPurchase: false,
  enableKeepAwake: false,
  enableOrientationLock: false,
  enableDeepLinks: false,
  enableQRScanner: false,
  enableLocalNetwork: false,
  enableFilePicker: false,
  enableFileDownload: false,
  enableSocialAuth: false,
  enablePasskeys: false,
  enableAudioRecording: false,
  enableVideoRecording: false,
  enableMotionSensors: false,
  enableLocalDatabase: false,
  enableBluetooth: false,
  enableNFC: false,
  enableHealthKit: false,
  enableWallet: false,
  enableLiveActivities: false,
  enableWatchApp: false,
  enableBackgroundLocation: false,
  enableBackgroundTasks: false,
  enableScreenCapture: false,
  enablePDFViewer: false,
  enableAR: false,
  enableMLKit: false,
  enableAppleMusic: false,
  enableHeartRate: false,
  enableScheduledWorkouts: false,
  iosVersion: '16.0',
  watchosVersion: '9.0',
  teamId: '',
  trustedOrigins: [],
  associatedDomains: [],
  appGroups: [],
  orientations: ['portrait'],
  deviceFamilies: ['iphone', 'ipad'],
}

export function renderDeviceFamilies(config: CraftConfig): string {
  const values = new Set((config.deviceFamilies?.length ? config.deviceFamilies : ['iphone', 'ipad'])
    .map(family => family === 'ipad' ? '2' : '1'))
  return [...values].join(',')
}

function xmlEscape(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(/\u0027/g, '&apos;')
}

function plistString(key: string, value: string): string {
  return `    <key>${key}</key>\n    <string>${xmlEscape(value)}</string>`
}

/** `appearance` when set, otherwise what the older `darkMode` switch pinned. */
export function resolveAppearance(config: Pick<CraftConfig, 'appearance' | 'darkMode'>): CraftAppearance {
  if (config.appearance) return config.appearance
  return config.darkMode === false ? 'light' : 'dark'
}

/**
 * The Info.plist interface style and the status bar that reads on it.
 *
 * The status bar used to be `LightContent` whatever the app looked like:
 * white text that vanished on a light page. It now follows the appearance —
 * dark text on a light app, light on a dark one, and the system's choice when
 * the app follows the system.
 */
export function renderAppearance(config: Pick<CraftConfig, 'appearance' | 'darkMode'>): { interfaceStyle: string, statusBarStyle: string } {
  const appearance = resolveAppearance(config)
  if (appearance === 'system') return { interfaceStyle: 'Automatic', statusBarStyle: 'UIStatusBarStyleDefault' }
  if (appearance === 'light') return { interfaceStyle: 'Light', statusBarStyle: 'UIStatusBarStyleDarkContent' }
  return { interfaceStyle: 'Dark', statusBarStyle: 'UIStatusBarStyleLightContent' }
}

export function renderUsageDescriptions(config: CraftConfig): string {
  const entries: Array<[boolean | undefined, string, string]> = [
    [config.enableSpeechRecognition, 'NSSpeechRecognitionUsageDescription', `${config.appName} uses speech recognition for voice input.`],
    [config.enableSpeechRecognition || config.enableAudioRecording || config.enableVideoRecording, 'NSMicrophoneUsageDescription', `${config.appName} uses the microphone to record audio.`],
    [config.enableCamera || config.enableVideoRecording || config.enableQRScanner || config.enableAR, 'NSCameraUsageDescription', `${config.appName} uses the camera for photos, video, scanning, and augmented reality.`],
    [config.enableCamera || config.enableVideoRecording, 'NSPhotoLibraryUsageDescription', `${config.appName} lets you choose photos and videos from your library.`],
    [config.enableGeolocation || config.enableBackgroundLocation, 'NSLocationWhenInUseUsageDescription', `${config.appName} uses your location while you record an activity.`],
    [config.enableBackgroundLocation, 'NSLocationAlwaysAndWhenInUseUsageDescription', `${config.appName} continues recording your route when the screen is locked or the app is in the background.`],
    [config.enableContacts, 'NSContactsUsageDescription', `${config.appName} accesses contacts only when you choose a contact feature.`],
    [config.enableCalendar, 'NSCalendarsUsageDescription', `${config.appName} accesses your calendar only when you choose a calendar feature.`],
    [config.enableBluetooth || config.enableHeartRate, 'NSBluetoothAlwaysUsageDescription', config.enableHeartRate
      ? `${config.appName} connects to your heart-rate monitor over Bluetooth to show and record your heart rate during a workout.`
      : `${config.appName} uses Bluetooth to connect to nearby devices.`],
    [config.enableMotionSensors, 'NSMotionUsageDescription', `${config.appName} uses motion data for activity features.`],
    [config.enableNFC, 'NFCReaderUsageDescription', `${config.appName} reads NFC tags when you start a scan.`],
    [config.enableLocalNetwork, 'NSLocalNetworkUsageDescription', `${config.appName} connects to your own devices on this network.`],
    [config.enableHealthKit, 'NSHealthShareUsageDescription', `${config.appName} reads health data you choose to share.`],
    [config.enableHealthKit, 'NSHealthUpdateUsageDescription', `${config.appName} writes health data only with your permission.`],
    [config.enableBiometric, 'NSFaceIDUsageDescription', `${config.appName} uses Face ID to protect your account.`],
    [config.enableAppleMusic, 'NSAppleMusicUsageDescription', `${config.appName} shows and controls the music playing in the Music app.`],
  ]
  const own = config.usageDescriptions ?? {}

  return entries
    .map(([enabled, key, value]): [string, string] | null => {
      const custom = own[key]?.trim()
      if (custom) return [key, custom]
      if (enabled) return [key, value]
      return null
    })
    .filter((entry): entry is [string, string] => entry !== null)
    .map(([key, value]) => plistString(key, value))
    .join('\n')
}

export function renderOrientations(config: CraftConfig): string {
  const names: Record<NonNullable<CraftConfig['orientations']>[number], string> = {
    portrait: 'UIInterfaceOrientationPortrait',
    'landscape-left': 'UIInterfaceOrientationLandscapeLeft',
    'landscape-right': 'UIInterfaceOrientationLandscapeRight',
    'portrait-upside-down': 'UIInterfaceOrientationPortraitUpsideDown',
  }
  // Annotated, not inferred: the `['portrait']` fallback widens to string[]
  // on its own, which then cannot index `names`.
  const values: NonNullable<CraftConfig['orientations']> = config.orientations?.length ? config.orientations : ['portrait']
  return values.map(value => `        <string>${names[value]}</string>`).join('\n')
}

/** WKAppBoundDomains: the configured domains plus the dev server's host, at most 10. */
export function renderAppBoundDomains(config: CraftConfig): string {
  const hostOf = (value: string): string | null => {
    try {
      const url = new URL(value)
      return url.protocol === 'https:' || url.protocol === 'http:' ? url.hostname.toLowerCase() : null
    }
    catch {
      return null
    }
  }
  const domains = config.appBoundDomains !== undefined
    ? config.appBoundDomains.map(value => value.trim().toLowerCase()).filter(Boolean)
    : (config.trustedOrigins ?? []).map(hostOf).filter((host): host is string => !!host)
  if (!domains.length) return ''
  const devHost = config.devServerURL ? hostOf(config.devServerURL) : null
  if (devHost) domains.push(devHost)
  const unique = [...new Set(domains)].slice(0, 10)
  return `    <key>WKAppBoundDomains</key>\n    <array>\n${plistArray(unique)}\n    </array>`
}

export function renderUrlTypes(config: CraftConfig): string {
  const schemes = [...new Set(config.urlSchemes?.map(value => value.trim()).filter(Boolean) ?? [])]
  if (!schemes.length) return ''

  return `    <key>CFBundleURLTypes</key>\n    <array>\n        <dict>\n            <key>CFBundleURLSchemes</key>\n            <array>\n${schemes.map(value => `                <string>${xmlEscape(value)}</string>`).join('\n')}\n            </array>\n        </dict>\n    </array>`
}

function plistArray(values: string[], indent = 2): string {
  const padding = '    '.repeat(indent)
  return values.map(value => `${padding}<string>${xmlEscape(value)}</string>`).join('\n')
}

export function renderBackgroundModes(config: CraftConfig): string {
  const modes = new Set<string>()
  if (config.backgroundRefresh?.enabled) modes.add('fetch')
  if (config.enableBackgroundLocation) modes.add('location')
  if (config.enableBackgroundTasks) modes.add('processing')
  if (config.enablePushNotifications) modes.add('remote-notification')
  // A strap's readings keep arriving with the screen locked mid-workout.
  if (config.enableHeartRate) modes.add('bluetooth-central')
  // A soundscape keeps playing with the screen locked (a sleep timer).
  if (config.enableBackgroundAudio) modes.add('audio')
  if (!modes.size) return ''

  return `    <key>UIBackgroundModes</key>\n    <array>\n${plistArray([...modes])}\n    </array>`
}

/** The background refresh task's identifier, or null when it is off. */
export function backgroundRefreshIdentifier(config: Pick<CraftConfig, 'backgroundRefresh' | 'bundleId'>): string | null {
  if (!config.backgroundRefresh?.enabled) return null
  return config.backgroundRefresh.identifier?.trim() || `${config.bundleId}.refresh`
}

/** BGTaskSchedulerPermittedIdentifiers: iOS runs no task it does not list. */
export function renderBackgroundTaskIdentifiers(config: Pick<CraftConfig, 'backgroundRefresh' | 'bundleId'>): string {
  const identifier = backgroundRefreshIdentifier(config)
  if (!identifier) return ''
  return `    <key>BGTaskSchedulerPermittedIdentifiers</key>\n    <array>\n${plistArray([identifier])}\n    </array>`
}

/**
 * The associated-domains entitlement's entries. Each needs a service prefix,
 * and a bare host (the easy thing to write) used to be signed as it was and
 * then matched nothing, so universal links silently never opened the app.
 */
export function associatedDomainEntries(domains: string[] | undefined): string[] {
  return [...new Set((domains ?? [])
    .map(value => value.trim())
    .filter(Boolean)
    .map(value => /^[a-z]+:/i.test(value) ? value : `applinks:${value}`))]
}

export function renderEntitlements(config: CraftConfig): string {
  const entries: string[] = []
  const associatedDomains = associatedDomainEntries(config.associatedDomains)
  if (associatedDomains.length) {
    entries.push(`    <key>com.apple.developer.associated-domains</key>\n    <array>\n${plistArray(associatedDomains)}\n    </array>`)
  }
  if (config.appGroups?.length) {
    entries.push(`    <key>com.apple.security.application-groups</key>\n    <array>\n${plistArray(config.appGroups)}\n    </array>`)
  }
  if (config.enableHealthKit) {
    entries.push('    <key>com.apple.developer.healthkit</key>\n    <true/>')
  }
  if (config.enablePushNotifications) {
    entries.push('    <key>aps-environment</key>\n    <string>$(CRAFT_APNS_ENVIRONMENT)</string>')
  }
  if (config.enableSocialAuth) {
    entries.push('    <key>com.apple.developer.applesignin</key>\n    <array>\n        <string>Default</string>\n    </array>')
  }
  if (config.enableSecureStorage) {
    entries.push('    <key>keychain-access-groups</key>\n    <array>\n        <string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string>\n    </array>')
  }

  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${entries.join('\n')}\n</dict>\n</plist>\n`
}

export function renderWatchEntitlements(config: CraftConfig): string {
  const appGroups = config.appGroups?.length
    ? `    <key>com.apple.security.application-groups</key>\n    <array>\n${plistArray(config.appGroups)}\n    </array>\n`
    : ''
  const healthKit = config.enableHealthKit ? '    <key>com.apple.developer.healthkit</key>\n    <true/>\n' : ''
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${appGroups}${healthKit}</dict>\n</plist>\n`
}

/**
 * The build settings that link the Zig runtime into the app target.
 *
 * Two things are load-bearing here:
 *
 * `LIBRARY_SEARCH_PATHS` is written twice, once per SDK, so `-lcraft-ios`
 * resolves to the device archive for a device build and the simulator archive
 * for a simulator one without the flag itself changing. Xcode applies the
 * `[sdk=...]` condition; xcodegen passes these keys through verbatim.
 *
 * The four `-u` flags are the reason anything works at all. Nothing in the
 * Swift source *references* these symbols — `CraftZigRuntime` and
 * `CraftSwiftShim` both find them with `dlsym` at runtime — so a static
 * archive contributes no objects for them and the linker drops the entire
 * runtime as unreachable. `-u` names them as undefined so the objects are
 * pulled in and the symbols end up in the binary for `dlsym` to find.
 *
 * `-u` rather than `-force_load`: forcing the whole archive would pull in
 * every object whether reachable or not, and these four entry points already
 * reach everything the bridge actually uses.
 */
export function renderRuntimeSettings(): string {
  return [
    '      LIBRARY_SEARCH_PATHS[sdk=iphoneos*]: "$(PROJECT_DIR)/Runtime/device"',
    '      LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]: "$(PROJECT_DIR)/Runtime/simulator"',
    '      OTHER_LDFLAGS: "-lcraft-ios -Wl,-u,_craft_ios_handle_action -Wl,-u,_craft_ios_set_webview '
    + '-Wl,-u,_craft_ios_deliver_result -Wl,-u,_craft_ios_deliver_error"',
  ].join('\n')
}

/**
 * Build settings a feature adds to the app target. WorkoutKit is compiled in
 * only for `enableScheduledWorkouts`: CraftScheduledWorkouts.swift imports it
 * behind the `CRAFT_SCHEDULED_WORKOUTS` condition, so an app that does not
 * schedule workouts does not link it. `$(inherited)` keeps Debug's `DEBUG`.
 */
export function renderFeatureSettings(config: Partial<CraftConfig>): string {
  const conditions: string[] = iosPermissions(config).filter(name => name !== 'music').map(name => `CRAFT_PERMISSION_${name.toUpperCase()}`)
  if (config.enableScheduledWorkouts) conditions.push('CRAFT_SCHEDULED_WORKOUTS')
  if (config.enableAppleMusic) conditions.push('CRAFT_APPLE_MUSIC')
  if (!conditions.length) return ''
  return `      SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ${conditions.join(' ')}"`
}

export function renderPrivacyManifest(config: CraftConfig): string {
  const privacy = config.privacy ?? {}
  const collected = [...(privacy.collectedDataTypes ?? [])]
  // Crash reporting sends crash data and the app's own user id with it, so the
  // manifest has to say so (App Store Connect reads it for the privacy label).
  if (config.crashReporting?.key && !collected.some(item => item.type === 'NSPrivacyCollectedDataTypeCrashData'))
    collected.push({ type: 'NSPrivacyCollectedDataTypeCrashData', linked: true, tracking: false, purposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality'] })
  const accessed = privacy.accessedApiTypes ?? []
  const collectedXml = collected.map(item => `        <dict>\n            <key>NSPrivacyCollectedDataType</key>\n            <string>${xmlEscape(item.type)}</string>\n            <key>NSPrivacyCollectedDataTypeLinked</key>\n            <${item.linked ? 'true' : 'false'}/>\n            <key>NSPrivacyCollectedDataTypeTracking</key>\n            <${item.tracking ? 'true' : 'false'}/>\n            <key>NSPrivacyCollectedDataTypePurposes</key>\n            <array>\n${plistArray(item.purposes, 4)}\n            </array>\n        </dict>`).join('\n')
  const accessedXml = accessed.map(item => `        <dict>\n            <key>NSPrivacyAccessedAPIType</key>\n            <string>${xmlEscape(item.type)}</string>\n            <key>NSPrivacyAccessedAPITypeReasons</key>\n            <array>\n${plistArray(item.reasons, 4)}\n            </array>\n        </dict>`).join('\n')

  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n    <key>NSPrivacyTracking</key>\n    <${privacy.tracking ? 'true' : 'false'}/>\n    <key>NSPrivacyTrackingDomains</key>\n    <array>\n${plistArray(privacy.trackingDomains ?? [])}\n    </array>\n    <key>NSPrivacyCollectedDataTypes</key>\n    <array>\n${collectedXml}\n    </array>\n    <key>NSPrivacyAccessedAPITypes</key>\n    <array>\n${accessedXml}\n    </array>\n</dict>\n</plist>\n`
}

/**
 * Whether a PNG carries an alpha channel, from its header: colour type 4
 * (grey + alpha) or 6 (RGB + alpha), or a tRNS chunk before the image data.
 */
export function pngHasAlpha(bytes: Uint8Array): boolean {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  if (bytes.length < 33 || signature.some((byte, index) => bytes[index] !== byte)) return false
  const colourType = bytes[25]
  if (colourType === 4 || colourType === 6) return true
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  for (let offset = 8; offset + 8 <= bytes.length;) {
    const length = view.getUint32(offset)
    const type = String.fromCharCode(bytes[offset + 4]!, bytes[offset + 5]!, bytes[offset + 6]!, bytes[offset + 7]!)
    if (type === 'tRNS') return true
    if (type === 'IDAT' || type === 'IEND') return false
    offset += 12 + length
  }
  return false
}

/**
 * The App Store icon, without an alpha channel: App Store Connect refuses a
 * build whose 1024 icon has one ("can't be transparent nor contain an alpha
 * channel"), even a fully opaque one. On macOS, sips drops it through a
 * full-quality JPEG; elsewhere (no sips) the icon is copied as it is.
 */
function writeOpaqueIcon(source: string, target: string): void {
  const bytes = new Uint8Array(readFileSync(source))
  if (!pngHasAlpha(bytes) || process.platform !== 'darwin') {
    cpSync(source, target)
    return
  }
  const flattened = `${target}.flatten.jpg`
  const run = (args: string[]) => Bun.spawnSync(['sips', ...args], { stdout: 'ignore', stderr: 'pipe' })
  const toJpeg = run(['-s', 'format', 'jpeg', '-s', 'formatOptions', '100', source, '--out', flattened])
  const toPng = toJpeg.exitCode === 0 ? run(['-s', 'format', 'png', flattened, '--out', target]) : toJpeg
  rmSync(flattened, { force: true })
  if (toPng.exitCode !== 0) {
    cpSync(source, target)
    console.warn(`[craft] Could not remove the app icon's alpha channel; App Store Connect will refuse it: ${toPng.stderr.toString().trim()}`)
  }
}

function renderAssetCatalog(output: string, config: CraftConfig): void {
  const catalog = join(output, 'Assets.xcassets')
  const appIcon = join(catalog, 'AppIcon.appiconset')
  const launchBackground = join(catalog, 'LaunchBackground.colorset')
  mkdirSync(appIcon, { recursive: true })
  mkdirSync(launchBackground, { recursive: true })
  writeFileSync(join(catalog, 'Contents.json'), `${JSON.stringify({ info: { author: 'xcode', version: 1 } }, null, 2)}\n`)

  const iconFilename = config.appIconPath ? 'AppIcon-1024.png' : undefined
  if (config.appIconPath) {
    if (!existsSync(config.appIconPath)) throw new Error(`App icon not found: ${config.appIconPath}`)
    writeOpaqueIcon(config.appIconPath, join(appIcon, iconFilename!))
  }
  writeFileSync(join(appIcon, 'Contents.json'), `${JSON.stringify({
    images: iconFilename ? [{
      filename: iconFilename,
      idiom: 'universal',
      platform: 'ios',
      size: '1024x1024',
    }] : [],
    info: { author: 'xcode', version: 1 },
  }, null, 2)}\n`)

  const colorEntry = (hex: string | undefined) => {
    const color = hex?.replace(/^#/, '') || '000000'
    const normalized = color.length === 3 ? [...color].map(value => `${value}${value}`).join('') : color.padEnd(6, '0').slice(0, 6)
    const components = [0, 2, 4].map(index => (Number.parseInt(normalized.slice(index, index + 2), 16) / 255).toFixed(3))
    return {
      'color-space': 'srgb',
      components: { alpha: '1.000', blue: components[2], green: components[1], red: components[0] },
    }
  }
  const colors: Array<Record<string, unknown>> = [{ color: colorEntry(config.backgroundColor), idiom: 'universal' }]
  if (config.backgroundColorDark) {
    colors.push({
      appearances: [{ appearance: 'luminosity', value: 'dark' }],
      color: colorEntry(config.backgroundColorDark),
      idiom: 'universal',
    })
  }
  writeFileSync(join(launchBackground, 'Contents.json'), `${JSON.stringify({
    colors,
    info: { author: 'xcode', version: 1 },
  }, null, 2)}\n`)

  renderLaunchLogo(catalog, config)
}

/** The asset the launch screen and the splash both draw, so one hands over to the other unseen. */
export const LAUNCH_LOGO = 'LaunchLogo'

function renderLaunchLogo(catalog: string, config: CraftConfig): void {
  const imageset = join(catalog, `${LAUNCH_LOGO}.imageset`)
  rmSync(imageset, { recursive: true, force: true })
  if (!config.splashImagePath) return
  mkdirSync(imageset, { recursive: true })
  const images: Array<Record<string, unknown>> = []
  let vector = false
  for (const [source, dark] of [[config.splashImagePath, false], [config.splashImagePathDark, true]] as const) {
    if (!source) continue
    if (!existsSync(source)) throw new Error(`Splash image not found: ${source}`)
    const extension = source.split('.').pop()!.toLowerCase()
    if (extension === 'svg' || extension === 'pdf') vector = true
    const filename = `${LAUNCH_LOGO}${dark ? '-dark' : ''}.${extension}`
    cpSync(source, join(imageset, filename))
    images.push({
      ...(dark ? { appearances: [{ appearance: 'luminosity', value: 'dark' }] } : {}),
      filename,
      idiom: 'universal',
    })
  }
  writeFileSync(join(imageset, 'Contents.json'), `${JSON.stringify({
    images,
    info: { author: 'xcode', version: 1 },
    // Kept as a vector, so the logo is sharp at every scale rather than rasterised once.
    ...(vector ? { properties: { 'preserves-vector-representation': true } } : {}),
  }, null, 2)}\n`)
}

/** The launch screen: the background colour, and the splash logo on it when there is one. */
export function renderLaunchScreen(config: Pick<CraftConfig, 'splashImagePath'>): string {
  const image = config.splashImagePath ? `\n        <key>UIImageName</key>\n        <string>${LAUNCH_LOGO}</string>` : ''
  return `        <key>UIColorName</key>\n        <string>LaunchBackground</string>${image}`
}

/** `#rgb` or `#rrggbb` as 0-255 channels, or null for anything else. */
function hexChannels(hex: string | undefined): [number, number, number] | null {
  const value = hex?.trim().replace(/^#/, '') ?? ''
  const full = value.length === 3 ? [...value].map(digit => digit + digit).join('') : value.slice(0, 6)
  if (!/^[0-9a-f]{6}$/i.test(full)) return null
  return [0, 2, 4].map(index => Number.parseInt(full.slice(index, index + 2), 16)) as [number, number, number]
}

/** Near-black or near-white, whichever reads on `background` (WCAG relative luminance). */
export function readableTextOn(background: string | undefined): string {
  const channels = hexChannels(background)
  if (!channels) return '#0f172a'
  const [r, g, b] = channels.map((channel) => {
    const c = channel / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  })
  const luminance = 0.2126 * r! + 0.7152 * g! + 0.0722 * b!
  return luminance > 0.4 ? '#0f172a' : '#f8fafc'
}

/**
 * The page the app shows when its own page cannot be reached: the generated
 * `dist/index.html` until the app's web assets replace it.
 *
 * An app whose page has a service worker normally opens from it offline, so
 * this only shows on a first launch without one, or when the remote fails
 * hard. It used to be a placeholder that said "Built with Craft iOS" in white
 * on whatever the background was (invisible on a light one) with a bridge
 * status line under it: debug output, in front of the person using the app.
 *
 * Now it says what happened in the app's own colours, light and dark, sized
 * with Dynamic Type, and Retry asks the shell to load the app's page again.
 * The shell also goes back to the app's page by itself when the connection
 * returns, so the page does not retry on `online` as well.
 */
export function renderOfflinePage(config: Pick<CraftConfig, 'appName' | 'backgroundColor' | 'backgroundColorDark'>): string {
  const light = hexChannels(config.backgroundColor) ? config.backgroundColor! : '#ffffff'
  const dark = hexChannels(config.backgroundColorDark) ? config.backgroundColorDark! : light
  const name = xmlEscape(config.appName)
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="viewport-fit=cover, width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <meta name="color-scheme" content="light dark">
  <title>${name}</title>
  <style>
    :root { --background: ${light}; --text: ${readableTextOn(light)}; }
    @media (prefers-color-scheme: dark) {
      :root { --background: ${dark}; --text: ${readableTextOn(dark)}; }
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      font: -apple-system-body;
      font-family: -apple-system, system-ui, sans-serif;
      background: var(--background);
      color: var(--text);
      display: flex;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: calc(env(safe-area-inset-top) + 24px) calc(env(safe-area-inset-right) + 32px) calc(env(safe-area-inset-bottom) + 24px) calc(env(safe-area-inset-left) + 32px);
      -webkit-user-select: none;
      user-select: none;
      -webkit-tap-highlight-color: transparent;
    }
    main { max-width: 22rem; }
    .app { font: -apple-system-subheadline; font-weight: 600; opacity: 0.6; margin-bottom: 0.5rem; }
    h1 { font: -apple-system-title1; font-weight: 700; margin-bottom: 0.75rem; }
    p { opacity: 0.72; line-height: 1.4; }
    button {
      font: -apple-system-headline;
      margin-top: 1.75rem;
      min-width: 9rem;
      min-height: 44px;
      padding: 0.75rem 1.75rem;
      border: 0;
      border-radius: 999px;
      background: var(--text);
      color: var(--background);
      cursor: pointer;
    }
    button:active { opacity: 0.7; }
    button:disabled { opacity: 0.5; }
  </style>
</head>
<body>
  <main>
    <div class="app">${name}</div>
    <h1>You're offline</h1>
    <p>${name} could not reach the internet. Check your connection, then try again.</p>
    <button id="retry" type="button">Retry</button>
  </main>
  <script>
    (function () {
      var button = document.getElementById('retry');
      function retry() {
        button.disabled = true;
        button.textContent = 'Retrying';
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craft;
        if (handler) handler.postMessage({ action: 'retryRemote' });
        else location.reload();
        // Still here a while later means the page is still out of reach.
        setTimeout(function () { button.disabled = false; button.textContent = 'Retry'; }, 12000);
      }
      button.addEventListener('click', retry);
    })();
  </script>
</body>
</html>
`
}

/** Replace the bundled web application atomically so removed assets cannot linger. */
export function syncWebAssets(source: string, output: string): void {
  const sourcePath = resolve(source)
  if (!existsSync(sourcePath)) throw new Error(`Web asset path not found: ${source}`)

  const distDir = join(output, 'dist')
  rmSync(distDir, { recursive: true, force: true })
  mkdirSync(distDir, { recursive: true })

  if (statSync(sourcePath).isDirectory()) {
    cpSync(sourcePath, distDir, { recursive: true })
  }
  else {
    cpSync(sourcePath, join(distDir, 'index.html'))
  }

  if (!existsSync(join(distDir, 'index.html'))) {
    throw new Error(`Web asset directory must contain index.html: ${source}`)
  }
}

/**
 * Initialize a new iOS project
 */
/**
 * Where the Zig runtime archives live, or null when this build has none.
 *
 * `CRAFT_IOS_RUNTIME` points at a directory holding the archives `zig build
 * build-ios-all` produces. It is opt-in and there is deliberately no fallback
 * search: a generated project with no runtime is the shipping default today,
 * and it works — `CraftZigRuntime.offer` is a `dlsym` miss, every action
 * answers false, and the Swift switch serves the whole surface exactly as it
 * always has. Guessing at a path would turn "no runtime" into "some runtime,
 * from somewhere", which is the failure mode the pantry contract exists to
 * rule out.
 *
 * This is the same shape as `CRAFT_BIN`: an explicit override for the monorepo
 * dev loop, not a lookup path. Shipping the runtime to real apps means putting
 * these archives in the pantry package beside the `craft` binary, which is a
 * distribution decision this function does not make.
 *
 * `override` is what `InitOptions.runtimeDir` passes: a path to use instead of
 * the variable, or `null` to declare there is no runtime regardless of what the
 * environment says. `undefined` falls through to `CRAFT_IOS_RUNTIME`.
 */
export function resolveRuntimeDir(override?: string | null): string | null {
  if (override === null) return null
  const dir = override ?? process.env.CRAFT_IOS_RUNTIME
  if (!dir) return null
  if (!existsSync(dir)) {
    const source = override === undefined ? 'CRAFT_IOS_RUNTIME points at' : 'runtimeDir is'
    throw new Error(`${source} ${dir}, which does not exist.`)
  }
  return dir
}

/** The archives a runtime directory must contain, by Xcode SDK. */
const RUNTIME_ARCHIVES = {
  device: ['libcraft-ios.a'],
  // Both simulator slices, merged into one archive below. A Mac on Apple
  // silicon runs arm64 simulators and an Intel one runs x86_64; shipping a
  // single-slice archive makes the project build on one machine and fail to
  // link on the other, which is the kind of break that only shows up on
  // someone else's laptop.
  simulator: ['libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a'],
} as const

/**
 * Copy the Zig archives into the generated project as `Runtime/<sdk>/libcraft-ios.a`.
 *
 * One name for both SDKs, in two directories, because that is what lets a
 * single `-lcraft-ios` in OTHER_LDFLAGS work for device and simulator builds:
 * Xcode picks the directory by SDK and the flag never changes.
 *
 * Returns true when a runtime was installed.
 */
export async function installRuntime(output: string, runtimeDir: string, config?: CraftConfig): Promise<boolean> {
  if (config) verifyRuntimeProfile(runtimeDir, config)
  // Every SDK resolved before anything is written, and long before the
  // `rmSync` below. The check used to run per-SDK *after* the wipe, so a
  // runtime directory missing an archive destroyed a working install on its
  // way to throwing, and left `project.yml` linking `-lcraft-ios` against a
  // `Runtime/` that no longer existed.
  const resolved = Object.entries(RUNTIME_ARCHIVES).map(([sdk, archives]) => {
    const present = archives.filter(a => existsSync(join(runtimeDir, a)))
    if (present.length === 0) {
      throw new Error(
        `${runtimeDir} has none of ${archives.join(', ')}. `
        + `Run \`zig build build-ios-all\` in packages/zig and point at its zig-out/lib.`,
      )
    }
    return { sdk, archives, present }
  })

  const installed = join(output, 'Runtime')
  const staging = mkdtempSync(join(output, '.craft-runtime-'))
  const dest = join(staging, 'next')
  const previous = join(staging, 'previous')
  try {
    for (const { sdk, archives, present } of resolved) {
      const sdkDir = join(dest, sdk)
      mkdirSync(sdkDir, { recursive: true })
      const target = join(sdkDir, 'libcraft-ios.a')

      if (present.length === 1) {
        // A one-architecture dev loop is legitimate, but it must not silently
        // claim to support the other simulator architecture.
        const missing = archives.filter(a => !present.includes(a))
        if (missing.length > 0) {
          console.warn(
            `   ⚠ ${sdk}: only ${present[0]} was found; ${missing.join(', ')} is missing. `
            + `The generated project will not link on the other architecture.`,
          )
        }
        cpSync(join(runtimeDir, present[0]!), target)
      }
      else {
        await $`lipo -create ${present.map(a => join(runtimeDir, a))} -output ${target}`.quiet()
      }
    }

    if (config) writeInstalledProfile(dest, config)
    if (existsSync(installed)) renameSync(installed, previous)
    try {
      renameSync(dest, installed)
    }
    catch (error) {
      if (existsSync(previous)) renameSync(previous, installed)
      throw error
    }
    return true
  }
  finally {
    rmSync(staging, { recursive: true, force: true })
  }
}

/**
 * Re-copy the Zig runtime into a project that already links one.
 *
 * The archives are *copied* by `init`, not symlinked, so without this a
 * rebuilt runtime never reached the app: edit `packages/zig/src`, run `zig
 * build build-ios-all`, then `craft ios run`, and xcodebuild happily relinks
 * the archive that was copied when the project was first generated. The build
 * succeeds, the app launches, and the change is simply absent — the worst
 * shape a stale artefact can take, because there is no error to chase.
 *
 * Only refreshes; never installs and never removes. A project with no
 * `Runtime/` was generated without a runtime and its `project.yml` carries no
 * link settings, so copying archives in would leave them unreferenced — that
 * decision belongs to `init`. And a project that *does* link one keeps working
 * from the archives it already has when no runtime directory is configured,
 * because a shell that forgot the variable should not quietly turn the runtime
 * off.
 */
async function refreshRuntime(output: string, config: CraftConfig, override?: string | null): Promise<void> {
  if (!existsSync(join(output, 'Runtime'))) return

  const dir = resolveRuntimeDir(override)
  if (!dir) {
    verifyInstalledProfile(join(output, 'Runtime'), config)
    console.log('   Keeping the Zig runtime installed at init (no runtime directory configured)')
    return
  }

  await installRuntime(output, dir, config)
  console.log('   Refreshed the Zig runtime from', dir)
}

async function installAppRuntime(output: string, source: string, config: CraftConfig): Promise<boolean> {
  return withAppRuntime(source, config, async (directory) => {
    verifyRuntimeProfile(directory, config)
    await installRuntime(output, directory, config)
    writeInstalledProfile(join(output, 'Runtime'), config, resolve(source))
    return true
  })
}

/**
 * The identifier an app's display name becomes wherever Xcode or Swift needs
 * one: the project, the target, the product and the `@main` type.
 *
 * The display name goes in front of people and may say anything; an
 * identifier may not. "HQ.training" used to become `struct HQ.trainingApp`,
 * which does not compile. Words are joined in PascalCase ("HQTraining"), and
 * a name that starts with a digit or has no letters at all still yields a
 * valid Swift type.
 */
export function productName(name: string): string {
  const words = name.split(/[^A-Za-z0-9]+/).filter(Boolean)
  const joined = words.map(word => word[0].toUpperCase() + word.slice(1)).join('')
  if (!joined) return 'Craft'
  return /^\d/.test(joined) ? `App${joined}` : joined
}

/** Restore package-owned Swift, retaining Xcode metadata and bundled screens.
 * Xcode Cloud assigns the distributed build number independently of the source
 * config; keep the packaged runtime identity in step with Apple's build.
 */
export function restoreShell(output: string): void {
  const file = join(output, 'craft.config.json')
  const config = JSON.parse(readFileSync(file, 'utf8')) as CraftConfig
  if (existsSync(join(output, 'Runtime'))) verifyInstalledProfile(join(output, 'Runtime'), config)
  const cloudBuild = process.env.CI_BUILD_NUMBER
  if (cloudBuild !== undefined) {
    if (!/^[1-9]\d*$/.test(cloudBuild) || cloudBuild.trim() !== cloudBuild)
      throw new Error('CI_BUILD_NUMBER must be a positive integer')
    config.buildNumber = cloudBuild
  }
  writeShell(output, config)
  refreshUsageDescriptions(output, config)
  if (cloudBuild !== undefined) writeFileSync(file, JSON.stringify(config, null, 2))
}

export { assertNoApplicationSwiftSources, findApplicationSwiftSources } from './source-audit.js'

function writeShell(output: string, config: CraftConfig): void {
  if (!config.appName || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(config.bundleId))
    throw new Error('The iOS shell needs an appName and a valid bundleId in craft.config.json.')
  // Build calls this too: unchanged templates must not force a full Swift rebuild.
  const writeSource = (path: string, source: string): void => {
    const rendered = renderPermissionSource(source, config)
    if (!existsSync(path) || readFileSync(path, 'utf8') !== rendered) writeFileSync(path, rendered)
  }
  const name = productName(config.appName)
  const shortcutSource = appShortcutsSwift(config.appShortcuts, config.urlSchemes)
  mkdirSync(join(output, 'Sources'), { recursive: true })
  mkdirSync(join(output, 'Shared'), { recursive: true })
  const swiftTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftApp.swift'), 'utf-8')
  const swiftSource = swiftTemplate
    .replace(/CraftApp/g, `${name}App`)
    .replace(/\{\{BUNDLE_ID\}\}/g, config.bundleId)
    .replace(/\{\{CRAFT_VERSION\}\}/g, CRAFT_VERSION)
  writeSource(join(output, 'Sources', `${name}App.swift`), swiftSource)
  writeSource(join(output, 'Sources', 'CraftAppShortcuts.swift'), shortcutSource)
  writeSource(join(output, 'Sources', 'CraftNativeScreen.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeScreen.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeFlatList.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeFlatList.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeActions.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeActions.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftHealth.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftHealth.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftMusic.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftMusic.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftBluetooth.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftBluetooth.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftHeartRate.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftHeartRate.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftRecordingArchive.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftRecordingArchive.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftPersistentStorage.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftPersistentStorage.swift'), 'utf8'))
  // Always copied: without enableScheduledWorkouts it compiles to a stub
  // that answers unsupported, and WorkoutKit is not linked.
  writeSource(join(output, 'Sources', 'CraftScheduledWorkouts.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftScheduledWorkouts.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeMutation.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeMutation.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeUI.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeUI.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeServices.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeServices.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftNativeFiles.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftNativeFiles.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftVoiceRecording.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftVoiceRecording.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftWebAudio.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftWebAudio.swift'), 'utf8'))
  writeSource(join(output, 'Sources', 'CraftHybrid.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftHybrid.swift'), 'utf8'))
  // Always copied: without `crashReporting` in the config it installs nothing.
  writeSource(
    join(output, 'Sources', 'CraftCrashReporter.swift'),
    readFileSync(join(TEMPLATES_DIR, 'CraftCrashReporter.swift'), 'utf-8').replace(/\{\{CRAFT_VERSION\}\}/g, CRAFT_VERSION),
  )

  writeSource(join(output, 'Sources', 'CraftLiveActivities.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftLiveActivities.swift'), 'utf8'))
  writeSource(join(output, 'Shared', 'CraftActivityAttributes.swift'), readFileSync(join(TEMPLATES_DIR, 'CraftActivityAttributes.swift'), 'utf8'))
  for (const [enabled, folder, template, filename] of [
    [config.enableLiveActivities, 'WidgetExtension', 'CraftLiveActivityWidget.swift.template', `${name}LiveActivity.swift`],
    [config.enableWatchApp, 'WatchExtension', 'CraftWatchApp.swift.template', `${name}WatchApp.swift`],
  ] as const) {
    if (!enabled) continue
    mkdirSync(join(output, folder), { recursive: true })
    const source = readFileSync(join(TEMPLATES_DIR, template), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, name)
      .replace(/\{\{HEALTH_KIT_ENABLED\}\}/g, config.enableHealthKit ? 'true' : 'false')
    writeSource(join(output, folder, filename), source)
  }
}

function refreshUsageDescriptions(output: string, config: CraftConfig): void {
  const path = join(output, 'Info.plist')
  if (!existsSync(path)) return
  const managed = /\s*<key>(?:NS(?:SpeechRecognition|Microphone|Camera|PhotoLibrary|LocationWhenInUse|LocationAlwaysAndWhenInUse|Contacts|Calendars|BluetoothAlways|Motion|LocalNetwork|HealthShare|HealthUpdate|FaceID|AppleMusic)|NFCReader)UsageDescription<\/key>\s*<string>[\s\S]*?<\/string>/g
  const plist = readFileSync(path, 'utf8').replace(managed, '')
  const end = plist.lastIndexOf('</dict>')
  if (end < 0) throw new Error('Info.plist must contain a root dictionary')
  writeFileSync(path, `${plist.slice(0, end).trimEnd()}\n${renderUsageDescriptions(config)}\n${plist.slice(end)}`)
}

export async function init(options: InitOptions): Promise<void> {
  const { name: displayName, bundleId, teamId, output } = options
  const name = productName(displayName)

  console.log(`\n⚡ Initializing Craft iOS project: ${displayName}`)
  console.log(`   Output: ${output}\n`)

  // Create directory structure
  const dirs = [output, join(output, 'Sources'), join(output, 'Shared'), join(output, 'dist')]
  if (options.config?.enableWatchApp) dirs.push(join(output, 'WatchApp'), join(output, 'WatchExtension'))
  for (const dir of dirs) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
    }
  }

  // Generate bundle ID from name if not provided
  const finalBundleId = bundleId || `com.craft.${name.toLowerCase()}`
  const bundleIdPrefix = finalBundleId.split('.').slice(0, -1).join('.')

  // Create craft.config.json. A key a caller passes as undefined (a Stacks
  // config that leaves `darkMode` unset passes exactly that) keeps its default
  // rather than erasing it: the file would lose the key, and the app then read
  // none of the file.
  const given = Object.fromEntries(Object.entries(options.config ?? {}).filter(([, value]) => value !== undefined))
  const config: CraftConfig = {
    ...DEFAULT_CONFIG,
    appName: displayName,
    bundleId: finalBundleId,
    teamId: teamId || '',
    ...given,
  }
  if (config.renderer !== 'web' && config.renderer !== 'native') {
    throw new Error(`Unknown iOS renderer: ${config.renderer}. Expected web or native.`)
  }
  const selection = config.tabBar?.selection
  if (selection?.cornerRadius !== undefined && (!Number.isFinite(selection.cornerRadius) || selection.cornerRadius < 0))
    throw new Error('iOS tabBar.selection.cornerRadius must be a finite non-negative number')
  if (selection?.color !== undefined && !/^#[0-9a-f]{6}$/i.test(selection.color))
    throw new Error('iOS tabBar.selection.color must be a #RRGGBB color')
  if (config.enableBackgroundLocation) config.enableGeolocation = true
  const problems = hybridConfigProblems(config)
  if (problems.length) throw new Error(problems.join('\n'))
  // Native screens read what the page shares from the Keychain.
  if (Object.keys(config.shareStorage ?? {}).length) config.enableSecureStorage = true

  // Validate/build the runtime before replacing source or privacy metadata.
  // A failed rebuild must not leave an old archive with newly omitted keys.
  const runtimeDir = resolveRuntimeDir(options.runtimeDir)
  const runtimeSource = options.runtimeSource === null || options.runtimeDir === null ? undefined : options.runtimeSource ?? process.env.CRAFT_IOS_RUNTIME_SOURCE
  if (runtimeSource && runtimeDir) throw new Error('Choose runtimeSource or runtimeDir, not both')
  const hasRuntime = runtimeSource ? await installAppRuntime(output, runtimeSource, config) : runtimeDir ? await installRuntime(output, runtimeDir, config) : false
  if (hasRuntime) {
    console.log('   Linked the Zig runtime from', runtimeSource ?? runtimeDir)
  }
  else {
    // A runtime-free regeneration must not leave orphaned runtime archives.
    rmSync(join(output, 'Runtime'), { recursive: true, force: true })
  }

  writeFileSync(join(output, 'craft.config.json'), JSON.stringify(config, null, 2))

  writeShell(output, config)

  const nativeFontFiles = syncNativeFonts(config.nativeFonts, output)

  // Generate Info.plist
  const infoPlistTemplate = readFileSync(join(TEMPLATES_DIR, 'Info.plist.template'), 'utf-8')
  const infoPlist = infoPlistTemplate
    .replace(/\{\{APP_NAME\}\}/g, xmlEscape(displayName))
    .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
    .replace(/\{\{VERSION\}\}/g, config.version || '1.0.0')
    .replace(/\{\{BUILD_NUMBER\}\}/g, config.buildNumber || '1')
    .replace(/\{\{UI_STYLE\}\}/g, renderAppearance(config).interfaceStyle)
    .replace(/\{\{STATUS_BAR_STYLE\}\}/g, renderAppearance(config).statusBarStyle)
    .replace(/\{\{ORIENTATIONS\}\}/g, renderOrientations(config))
    .replace(/\{\{USAGE_DESCRIPTIONS\}\}/g, renderUsageDescriptions(config))
    .replace(/\{\{URL_TYPES\}\}/g, renderUrlTypes(config))
    .replace(/\{\{APP_BOUND_DOMAINS\}\}/g, renderAppBoundDomains(config))
    .replace(/\{\{BACKGROUND_MODES\}\}/g, renderBackgroundModes(config))
    .replace(/\{\{BACKGROUND_TASK_IDENTIFIERS\}\}/g, renderBackgroundTaskIdentifiers(config))
    .replace(/\{\{LAUNCH_SCREEN\}\}/g, renderLaunchScreen(config))
    .replace(/\{\{NATIVE_FONTS\}\}/g, nativeFontFiles.length ? `    <key>UIAppFonts</key>\n    <array>\n${plistArray(nativeFontFiles, 2)}\n    </array>` : '')
    .replace(/\{\{NON_EXEMPT_ENCRYPTION\}\}/g, config.usesNonExemptEncryption ? 'true' : 'false')
    .replace(/\{\{LIVE_ACTIVITY_SUPPORT\}\}/g, config.enableLiveActivities
      ? '    <key>NSSupportsLiveActivities</key>\n    <true/>\n    <key>NSSupportsLiveActivitiesFrequentUpdates</key>\n    <true/>'
      : '')

  writeFileSync(join(output, 'Info.plist'), infoPlist)

  // Generate project.yml for xcodegen
  const projectYmlTemplate = readFileSync(join(TEMPLATES_DIR, 'project.yml.template'), 'utf-8')
  const nativeDependencies: string[] = []
  if (config.enableLiveActivities) nativeDependencies.push(`      - target: ${name}LiveActivity`)
  if (config.enableWatchApp) nativeDependencies.push(`      - target: ${name}Watch\n        embed: true`)
  const nativeTargets: string[] = []
  if (config.enableLiveActivities) {
    nativeTargets.push(`  ${name}LiveActivity:
    type: app-extension
    platform: iOS
    deploymentTarget: "16.2"
    sources:
      - WidgetExtension
      - Shared
    settings:
      INFOPLIST_FILE: WidgetExtension/Info.plist
      PRODUCT_NAME: "$(TARGET_NAME)"
      PRODUCT_BUNDLE_IDENTIFIER: ${finalBundleId}.liveactivity
      SWIFT_VERSION: "5.0"
      APPLICATION_EXTENSION_API_ONLY: YES
      SKIP_INSTALL: YES`)
  }
  if (config.enableWatchApp) {
    nativeTargets.push(`  ${name}Watch:
    type: application.watchapp2
    platform: watchOS
    deploymentTarget: "${config.watchosVersion || '9.0'}"
    sources:
      - WatchApp
    settings:
      INFOPLIST_FILE: WatchApp/Info.plist
      CODE_SIGN_ENTITLEMENTS: WatchApp/Watch.entitlements
      PRODUCT_NAME: "$(TARGET_NAME)"
      PRODUCT_BUNDLE_IDENTIFIER: ${finalBundleId}.watchkitapp
      SWIFT_VERSION: "5.0"
      SKIP_INSTALL: YES
    dependencies:
      - target: ${name}WatchExtension
  ${name}WatchExtension:
    type: watchkit2-extension
    platform: watchOS
    deploymentTarget: "${config.watchosVersion || '9.0'}"
    sources:
      - WatchExtension
    settings:
      INFOPLIST_FILE: WatchExtension/Info.plist
      CODE_SIGN_ENTITLEMENTS: WatchExtension/Watch.entitlements
      PRODUCT_NAME: "$(TARGET_NAME)"
      PRODUCT_BUNDLE_IDENTIFIER: ${finalBundleId}.watchkitapp.watchkitextension
      SWIFT_VERSION: "5.0"
      APPLICATION_EXTENSION_API_ONLY: YES
      SKIP_INSTALL: YES`)
  }

  const projectYml = projectYmlTemplate
    .replace(/\{\{NATIVE_FONT_RESOURCES\}\}/g, nativeFontFiles.length ? '      - path: NativeFonts\n        type: folder\n        buildPhase: resources' : '')
    .replace(/\{\{CRAFT_RUNTIME_SETTINGS\}\}/g, hasRuntime ? renderRuntimeSettings() : '')
    .replace(/\{\{FEATURE_SETTINGS\}\}/g, renderFeatureSettings(config))
    .replace(/\{\{APP_NAME\}\}/g, name)
    .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
    .replace(/\{\{BUNDLE_ID_PREFIX\}\}/g, bundleIdPrefix)
    .replace(/\{\{VERSION\}\}/g, config.version || '1.0.0')
    .replace(/\{\{BUILD_NUMBER\}\}/g, config.buildNumber || '1')
    .replace(/\{\{IOS_VERSION\}\}/g, config.iosVersion || '15.0')
    .replace(/\{\{DEVICE_FAMILIES\}\}/g, renderDeviceFamilies(config))
    .replace(/\{\{TEAM_ID\}\}/g, teamId || '')
    .replace(/\{\{NATIVE_DEPENDENCIES\}\}/g, nativeDependencies.length ? `    dependencies:\n${nativeDependencies.join('\n')}` : '')
    .replace(/\{\{NATIVE_TARGETS\}\}/g, nativeTargets.join('\n'))

  writeFileSync(join(output, 'project.yml'), projectYml)
  writeFileSync(join(output, 'Craft.entitlements'), renderEntitlements(config))
  writeFileSync(join(output, 'PrivacyInfo.xcprivacy'), renderPrivacyManifest(config))
  renderAssetCatalog(output, config)
  if (config.enableLiveActivities) {
    mkdirSync(join(output, 'WidgetExtension'), { recursive: true })
    const widgetInfo = readFileSync(join(TEMPLATES_DIR, 'WidgetExtension.Info.plist'), 'utf8')
    writeFileSync(join(output, 'WidgetExtension', 'Info.plist'), widgetInfo)
  }
  if (config.enableWatchApp) {
    const watchInfo = readFileSync(join(TEMPLATES_DIR, 'WatchApp.Info.plist.template'), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, xmlEscape(displayName))
      .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
    writeFileSync(join(output, 'WatchApp', 'Info.plist'), watchInfo)
    writeFileSync(join(output, 'WatchApp', 'Watch.entitlements'), renderWatchEntitlements(config))
    const watchExtensionInfo = readFileSync(join(TEMPLATES_DIR, 'WatchExtension.Info.plist.template'), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, xmlEscape(displayName))
      .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
      .replace(/\{\{HEALTH_USAGE_DESCRIPTIONS\}\}/g, config.enableHealthKit
        ? `${plistString('NSHealthShareUsageDescription', `${displayName} reads health data you choose to share.`)}\n${plistString('NSHealthUpdateUsageDescription', `${displayName} writes health data only with your permission.`)}`
        : '')
    writeFileSync(join(output, 'WatchExtension', 'Info.plist'), watchExtensionInfo)
    writeFileSync(join(output, 'WatchExtension', 'Watch.entitlements'), renderWatchEntitlements(config))
  }

  // The bundled page, until the app's own web assets replace it: what shows
  // when the app's remote page cannot be reached.
  writeFileSync(join(output, 'dist', 'index.html'), renderOfflinePage(config))
  if (usesNativeBundle(config)) {
    if (config.nativeBundle) installNativeBundle(config.nativeBundle, output)
    else if (isHybrid(config)) console.warn('   ⚠ nativeScreens is set without nativeBundle: every path opens in the web view until `craft ios build --native-bundle` supplies one.')
    else if (hasNativeRoutes(config)) console.warn('   ⚠ nativeScreens is set without nativeBundle: the app has no screens until `craft ios build --native-bundle` supplies one.')
  }

  console.log('✅ Project initialized')
  console.log('')
  console.log('Next steps:')
  console.log(`  1. cd ${output}`)
  if (config.renderer === 'native') {
    console.log('  2. Compile your screen: stx native compile Screen.stx --format bundle --output screen.js')
    console.log('  3. Run: craft ios build --native-bundle screen.js')
  }
  else {
    console.log('  2. Add your web content to dist/index.html')
    console.log('  3. Run: craft ios build')
  }
  console.log('  4. Run: craft ios open')
  console.log('')
}

/**
 * Build web assets and generate Xcode project
 */
export async function build(options: BuildOptions): Promise<void> {
  const { htmlPath, nativeBundlePath, devServer, output, generateProject = true } = options

  console.log('\n📦 Building Craft iOS project...')

  // Load config
  const configPath = join(output, 'craft.config.json')
  if (!existsSync(configPath)) {
    throw new Error(`No craft.config.json found in ${output}. Run 'craft ios init' first.`)
  }

  const config: CraftConfig = JSON.parse(readFileSync(configPath, 'utf-8'))
  if (config.renderer !== undefined && config.renderer !== 'web' && config.renderer !== 'native') {
    throw new Error(`Unknown iOS renderer: ${config.renderer}. Expected web or native.`)
  }

  if (config.renderer === 'native') {
    if (htmlPath || devServer) {
      throw new Error('A native iOS screen cannot use --html-path or --dev-server.')
    }
    const bundle = nativeBundlePath ?? config.nativeBundle
    if (bundle) installNativeBundle(bundle, output)
    if (!hasInstalledNativeBundle(output)) {
      throw new Error('Native iOS mode needs dist/native-screen.js. Compile a .stx screen with `stx native compile` first.')
    }
  }
  else if (nativeBundlePath && !isHybrid(config)) {
    throw new Error('--native-bundle requires renderer: "native", or nativeScreens, in craft.config.json.')
  }
  const problems = hybridConfigProblems(config)
  if (problems.length) throw new Error(problems.join('\n'))

  // Update dev server URL if provided
  if (devServer) {
    config.devServerURL = devServer
    const origin = new URL(devServer).origin
    config.trustedOrigins = [...new Set([...(config.trustedOrigins ?? []), origin])]
    writeFileSync(configPath, JSON.stringify(config, null, 2))
    console.log(`   Dev server: ${devServer}`)
  }

  if (htmlPath) {
    syncWebAssets(htmlPath, output)
    console.log(`   Synced: ${htmlPath} → dist/`)
  }

  // After the web assets, which replace dist/ whole.
  if (isHybrid(config)) {
    const bundle = nativeBundlePath ?? config.nativeBundle
    if (bundle) {
      installNativeBundle(bundle, output)
      console.log(`   Native screens: ${bundle} → ${statSync(bundle).isDirectory() ? 'dist/native-screens/' : 'dist/native-screen.js'}`)
    }
    else if (!hasInstalledNativeBundle(output)) {
      console.warn('   ⚠ nativeScreens is set but there is no native bundle: every path opens in the web view.')
    }
  }

  const profilePath = join(output, 'Runtime', 'profile.json')
  const savedProfile = existsSync(profilePath) ? JSON.parse(readFileSync(profilePath, 'utf8')) : undefined
  const runtimeSource = options.runtimeSource === null || options.runtimeDir === null ? undefined : options.runtimeSource ?? process.env.CRAFT_IOS_RUNTIME_SOURCE ?? savedProfile?.source
  if (runtimeSource && existsSync(join(output, 'Runtime'))) {
    if (options.runtimeDir) throw new Error('Choose runtimeSource or runtimeDir, not both')
    await installAppRuntime(output, runtimeSource, config)
  }
  else {
    if (savedProfile && savedProfile.mask !== iosPermissionMask(config))
      throw new Error('Installed Zig runtime permission profile is stale; provide runtimeSource to rebuild it')
    await refreshRuntime(output, config, options.runtimeDir)
  }

  // Always keep executable gates and plist metadata in step with edited flags.
  writeShell(output, config)
  refreshUsageDescriptions(output, config)

  if (!generateProject) return

  // Generate Xcode project using xcodegen
  try {
    const result = await $`which xcodegen`.quiet()
    if (result.exitCode === 0) {
      console.log('   Running xcodegen...')
      await $`cd ${output} && xcodegen generate`.quiet()
      console.log(`✅ Xcode project created: ${productName(config.appName)}.xcodeproj`)
    }
else {
      throw new Error('xcodegen not found')
    }
  }
catch (error) {
    throw new Error('Unable to generate the Xcode project. Install xcodegen with `brew install xcodegen`.', {
      cause: error,
    })
  }

  runPostGenerateHook(config.postGenerate, output)

  console.log('')
}

/**
 * Open Xcode project
 */
export async function open(options: OpenOptions): Promise<void> {
  const { output } = options

  // Find .xcodeproj
  const files = readdirSync(output)
  const xcodeproj = files.find(f => f.endsWith('.xcodeproj'))

  if (!xcodeproj) {
    throw new Error(`No Xcode project found in ${output}. Run 'craft ios build' first.`)
  }

  const projectPath = join(output, xcodeproj)
  console.log(`🚀 Opening ${xcodeproj}...`)
  await $`open ${projectPath}`
}

/**
 * Build and run on simulator or device
 */
/** One bootable simulator, as `simctl list` describes it. */
export interface SimulatorDevice {
  name: string
  udid: string
  state: string
  runtime: string
}

/**
 * Every available *iOS* simulator, newest runtime first, iPhones before iPads.
 *
 * Exported because the choice is worth testing without a simulator present -
 * `pickSimulator` is the policy and this is the data it reads.
 */
export function orderSimulators(devices: SimulatorDevice[], sdkVersion?: string): SimulatorDevice[] {
  const sdk = sdkVersion?.match(/^(\d+)\.(\d+)/)
  if (sdkVersion !== undefined && !sdk)
    throw new Error(`Invalid iOS Simulator SDK version: ${sdkVersion}`)
  // iOS runtimes only, before anything else is considered. A booted device
  // sorts ahead of every shut-down one, and a developer with an Apple Watch or
  // Apple TV simulator open would otherwise have it handed back as the place
  // to install an iphonesimulator build - which fails at `simctl install`,
  // naming a device nobody asked for.
  return devices
    .filter(device => device.runtime.startsWith('iOS'))
    .filter((device) => {
      if (!sdk) return true
      const runtime = device.runtime.match(/^iOS-(\d+)-(\d+)/)
      if (!runtime) return false
      return Number(runtime[1]) < Number(sdk[1])
        || (Number(runtime[1]) === Number(sdk[1]) && Number(runtime[2]) <= Number(sdk[2]))
    })
    .sort((left, right) => {
      const booted = Number(right.state === 'Booted') - Number(left.state === 'Booted')
      if (booted !== 0)
        return booted

      const phone = Number(right.name.startsWith('iPhone')) - Number(left.name.startsWith('iPhone'))
      if (phone !== 0)
        return phone

      return right.runtime.localeCompare(left.runtime, undefined, { numeric: true })
    })
}

/**
 * The device to run on.
 *
 * A booted one first - if the developer already has a simulator open, that is
 * the one they are looking at - then the newest iPhone.
 *
 * This used to be the string `iPhone 15`, hard-coded into the `-destination`
 * argument. On a machine whose Xcode ships iPhone 17 and no iPhone 15, that is
 * not a fallback, it is `xcodebuild: error: Unable to find a device named
 * 'iPhone 15'` - the command fails for a reason that has nothing to do with the
 * app being built, and the fix is invisible from the error.
 */
export async function pickSimulator(): Promise<SimulatorDevice | null> {
  const listed = await $`xcrun simctl list devices available --json`.quiet().nothrow()

  if (listed.exitCode !== 0)
    return null

  // simctl lists runtimes installed by every Xcode. A newer runtime may boot
  // with an older selected Xcode while its XCTest/WebKit hit testing is wrong.
  // Use the selected toolchain's SDK as the compatibility boundary.
  const sdk = await $`xcrun --sdk iphonesimulator --show-sdk-version`.quiet().nothrow()
  if (sdk.exitCode !== 0)
    throw new Error('Could not determine the selected Xcode iOS Simulator SDK')

  let parsed: { devices?: Record<string, Array<{ name: string, udid: string, state: string }>> }

  try {
    parsed = JSON.parse(listed.stdout.toString())
  }
catch {
    return null
  }

  const devices: SimulatorDevice[] = []

  for (const [runtime, list] of Object.entries(parsed.devices ?? {})) {
    for (const device of list)
      devices.push({ ...device, runtime: runtime.split('.').pop() ?? runtime })
  }

  return orderSimulators(devices, sdk.stdout.toString().trim())[0] ?? null
}

/**
 * Boot it, and wait until it can actually do something.
 *
 * `simctl boot` returns as soon as the device starts booting, and a device
 * that reports `Booted` is minutes away from being able to install anything on
 * a cold runtime. `bootstatus` is the wait, and skipping it is why a first run
 * on a fresh machine fails where the second succeeds.
 */
export async function bootSimulator(device: SimulatorDevice): Promise<void> {
  if (device.state !== 'Booted')
    await $`xcrun simctl boot ${device.udid}`.quiet().nothrow()

  await $`xcrun simctl bootstatus ${device.udid}`.quiet().nothrow()
}

/**
 * Bring the Simulator window to the front, if it can be found.
 *
 * `open -a Simulator` resolves through LaunchServices, and LaunchServices only
 * knows the name if a Simulator.app has been registered under it - which is not
 * true on a machine running Xcode-beta, where the answer is `Unable to find
 * application named 'Simulator'`. The app is always at a known path under the
 * *selected* developer directory, so that is tried first.
 *
 * Never throws. The window is a convenience: the app is installed and launched
 * either way, and failing the whole run because a window did not come to the
 * front would be reporting a cosmetic problem as a build failure.
 */
export async function showSimulator(): Promise<void> {
  const selected = await $`xcode-select -p`.quiet().nothrow()
  const developer = selected.exitCode === 0 ? selected.stdout.toString().trim() : ''

  if (developer) {
    const app = join(developer, 'Applications', 'Simulator.app')

    if (existsSync(app)) {
      await $`open ${app}`.quiet().nothrow()
      return
    }
  }

  await $`open -a Simulator`.quiet().nothrow()
}

export async function run(options: RunOptions): Promise<void> {
  const { simulator, output } = options

  // First build
  await build({ output })

  // Find .xcodeproj
  const files = readdirSync(output)
  const xcodeproj = files.find(f => f.endsWith('.xcodeproj'))

  if (!xcodeproj) {
    throw new Error(`No Xcode project found in ${output}`)
  }

  const projectPath = join(output, xcodeproj)
  const appName = xcodeproj.replace('.xcodeproj', '')

  const configPath = join(output, 'craft.config.json')

  if (!existsSync(configPath))
    throw new Error(`No craft.config.json found in ${output}. Run 'craft-ios init' first.`)

  const config: CraftConfig = JSON.parse(readFileSync(configPath, 'utf-8'))

  if (simulator) {
    console.log('📱 Building and running on simulator...')

    const device = await pickSimulator()

    if (!device) {
      throw new Error(
        'No iOS simulator is available. Install a runtime with '
        + '`xcodebuild -downloadPlatform iOS`, then try again.',
      )
    }

    console.log(`   Device: ${device.name} (${device.runtime})`)

    try {
      await bootSimulator(device)

      /*
       * A derived-data path we choose, so the built `.app` is at a known
       * location.
       *
       * The alternative is parsing `xcodebuild -showBuildSettings` for
       * `BUILT_PRODUCTS_DIR`, which is a second invocation of the slowest tool
       * in the chain to learn something we can simply decide.
       */
      const derivedData = join(output, 'build')
      const product = join(derivedData, 'Build', 'Products', 'Debug-iphonesimulator', `${appName}.app`)

      await $`xcodebuild -project ${projectPath} -scheme ${appName} -configuration Debug -destination ${`id=${device.udid}`} -derivedDataPath ${derivedData} build`

      if (!existsSync(product)) {
        throw new Error(
          `xcodebuild reported success but ${product} does not exist. `
          + 'The scheme may build a different product name than the project.',
        )
      }

      /*
       * Installed and launched, rather than merely built.
       *
       * This used to run `xcodebuild build`, boot a device, open Simulator.app
       * and print "App deployed to simulator" - having installed nothing and
       * launched nothing. What the user saw was a home screen and a success
       * message, which is the worst pair of those two things to see together.
       */
      await $`xcrun simctl install ${device.udid} ${product}`
      await showSimulator()
      await $`xcrun simctl launch ${device.udid} ${config.bundleId}`

      console.log(`✅ ${config.appName} is running on ${device.name}`)
    }
catch (error) {
      throw new Error(`iOS simulator run failed for ${projectPath}`, { cause: error })
    }
  }
else {
    // Open in Xcode for device deployment
    console.log('📱 Opening Xcode for device deployment...')
    await $`open ${projectPath}`
    console.log('')
    console.log('In Xcode:')
    console.log('  1. Select your Team in Signing & Capabilities')
    console.log('  2. Connect your iPhone')
    console.log('  3. Select your device')
    console.log('  4. Click Run (▶️)')
  }
}

export { createNativeMutationValidator, initSimulatorDriver, serializeSimulatorSteps } from './testing.js'
export type { NativeMutationValidator, NativeValidationResult, SimulatorDriverOptions, SimulatorStep, TimedTouchPoint } from './testing.js'
