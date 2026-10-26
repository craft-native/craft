import { gzipSync } from 'node:zlib'
/**
 * Craft Android Builder
 *
 * Generates Android apps with native Craft components and optional WebView content.
 */

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'

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
import { dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { $ } from 'bun'
import { androidMapHost, type AndroidMapProvider } from './native-map.js'
import { renderAndroidPromiseRuntime } from './promise-runtime'

export type { AndroidMapProvider } from './native-map.js'
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
 * `messages`, `native-screens/__messages/`): the areas its route uses,
 * evaluated ahead of it (an isolate cannot read a file when asked). Stacks leaves the languages
 * out of the screens' code only when this is true.
 */
export const nativeMessages = true

/** Providers this published builder can generate as real Android map views. */
export const nativeMapProviders = ['google', 'maplibre'] as const
export { runKotlinFixture } from './testing.js'
export { createAndroidEmulator } from './emulator.js'
export type { AndroidEmulatorOptions, AndroidEmulatorSession } from './emulator.js'

/** Package custom fonts and their licenses; removed fonts cannot linger in the app. */
export function syncNativeFonts(fonts: CraftAndroidConfig['nativeFonts'], output: string): string[] {
  const destination = join(output, 'app/src/main/assets/NativeFonts')
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

/**
 * This builder's version, which the crash reporter names as its SDK version.
 * Walks up from here because a bundled build puts this module below the
 * package root.
 */
function resolveCraftAndroidVersion(startDir: string = import.meta.dir): string {
  let directory = resolve(startDir)
  while (true) {
    try {
      const pkg = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')) as { name?: unknown, version?: unknown }
      if ((pkg.name === '@craft-native/android' || pkg.name === 'craft-native') && typeof pkg.version === 'string' && pkg.version)
        return pkg.version
    }
    catch {
      // Keep walking.
    }
    const parent = dirname(directory)
    if (parent === directory) return '0.0.0'
    directory = parent
  }
}

const CRAFT_ANDROID_VERSION = resolveCraftAndroidVersion()
const LOCAL_DEVELOPMENT_HOSTS = new Set(['localhost', '127.0.0.1', '10.0.2.2'])
const KOTLIN_KEYWORDS = new Set([
  'as',
  'break',
  'class',
  'continue',
  'do',
  'else',
  'false',
  'for',
  'fun',
  'if',
  'in',
  'interface',
  'is',
  'null',
  'object',
  'package',
  'return',
  'super',
  'this',
  'throw',
  'true',
  'try',
  'typealias',
  'typeof',
  'val',
  'var',
  'when',
  'while',
])

/** Oldest Android API level supported by the generated Kotlin runtime. */
export const ANDROID_MIN_SDK = 26
const ANDROID_HEALTH_SERVICES_MIN_SDK = 30

export interface CraftAndroidConfig {
  /** Bundled font files keyed by their PostScript font name, used as native fontFamily. */
  nativeFonts?: Record<string, { src: string, license?: string }>

  appName: string
  packageName: string
  renderer?: 'web' | 'native'
  /** "system" follows the device; light/dark pin the generated host. */
  appearance?: 'light' | 'dark' | 'system'
  /** Static native tab-bar styling applied before the page's own tabBar.set call. */
  tabBar?: CraftTabBarConfig
  /** Runs from the generated project root before Gradle compiles the app. */
  postGenerate?: CraftPostGenerateHook
  version?: string
  versionCode?: number
  darkMode?: boolean
  backgroundColor?: string
  backgroundColorDark?: string
  enableSpeechRecognition?: boolean
  enableAudioRecording?: boolean
  enableHaptics?: boolean
  enableShare?: boolean
  enableCamera?: boolean
  enableBiometric?: boolean
  enablePushNotifications?: boolean
  enableSecureStorage?: boolean
  enableGeolocation?: boolean
  enableBackgroundLocation?: boolean
  enableBluetooth?: boolean
  /**
   * A Bluetooth heart-rate strap, or a watch broadcasting its heart rate (the
   * standard Heart Rate Service), through `craft.heartRate` on a page and the
   * `HeartRate` module on a native screen (CraftHeartRate.kt): scan, connect,
   * live readings as `craftHeartRate` events, and a recording kept natively,
   * in the foreground (a connectedDevice service) while it runs. The iOS
   * builder's flag of the same name.
   */
  enableHeartRate?: boolean
  enableHealthConnect?: boolean
  /** Android Health Services live exercise tracking for native screens. Requires minSdk 30. */
  enableHealthServices?: boolean
  /** Google Wallet save-link or native SDK handoff for native screens. */
  enableWallet?: boolean
  /**
   * The Health Connect data the app reads and writes, by the shared type
   * names (`steps`, `sleep`, `workouts`...). The manifest declares only
   * these, as Play's health permissions review requires; without it, the
   * original set (steps, heart rate, energy, distance, workouts).
   */
  healthConnect?: {
    read?: HealthConnectType[]
    write?: HealthConnectType[]
    /** Read while the app is in the background (a WorkManager refresh): Android 15's READ_HEALTH_DATA_IN_BACKGROUND. */
    background?: boolean
    /** Read further back than the 30 days before the first grant: READ_HEALTH_DATA_HISTORY. */
    history?: boolean
  }
  enableHealthConnectBackground?: boolean
  enableHealthConnectHistory?: boolean
  /** The app's privacy policy, which Health Connect links to from its permission screen. */
  privacyPolicyURL?: string
  enableKeepAwake?: boolean
  enableDeepLinks?: boolean
  /** Reach the person's own devices on the local network over plain HTTP (a Mac companion). */
  enableLocalNetwork?: boolean
  urlSchemes?: string[]
  /** HTTPS hosts owned by the app; path rules are ordered, with `*` matching any path text. */
  /** Ordered path rules: * matches zero or more characters, ? one, and ?* one or more. */
  appLinks?: Array<{ host: string, paths?: Array<{ pattern: string, exclude?: boolean }> }>
  trustedOrigins?: string[]
  appIconPath?: string
  /**
   * The small icon in the status bar and on every notification the app
   * shows, push or local: an Android vector drawable (`.xml`) or a `.png`,
   * white on transparent, since Android draws only its shape. Without one,
   * a white Craft mark. Never the launcher icon, which shows as a white
   * square.
   */
  notificationIconPath?: string
  /** The `#RRGGBB` Android tints the notification icon and app name with. The system's own colour without it. */
  notificationColor?: string
  googleServicesFile?: string
  /** Native map renderer. MapLibre needs no SDK key; Google remains the default for compatibility. */
  mapProvider?: AndroidMapProvider
  /** Google Maps Android SDK key, used only by the Google native map host. */
  mapsApiKey?: string
  devServerURL?: string
  hasBundledFallback?: boolean
  /** Android API level, at least ANDROID_MIN_SDK (26), or 30 with Health Services. */
  minSdk?: number
  compileSdk?: number
  targetSdk?: number
  /**
   * Native renderer: the app's paths and the screen drawing each
   * (`/m/workout/:id` → `Workout`), its tabs, and the bundle route of the
   * script that runs beside the screens. The same keys as the iOS builder.
   */
  nativeScreens?: Record<string, string>
  tabs?: Array<{
    id: string
    title: string
    symbol?: string
    /** Native selected-tab icon overrides, also supported by navigation.setOptions({ tabItem }). */
    selectedSymbol?: string
    selectedIconTint?: string
    selectedIconPulse?: boolean
  }>
  nativeApp?: string
  /**
   * The secure-storage key the signed-in account's token lives under
   * (default `auth.token`). `craft.session` follows it on every native
   * screen, and a change of it is `SESSION_CHANGED { key, token, previous }`.
   */
  sessionTokenKey?: string
  /** Wake the app script every so often (`craftBackgroundRefresh`), through WorkManager. */
  backgroundRefresh?: { enabled?: boolean, minimumIntervalMinutes?: number }
  /**
   * Crash and error reporting to bughq (CraftCrashReporter.kt): uncaught JVM
   * exceptions, ANRs and native crashes (ApplicationExitInfo), uncaught
   * JavaScript errors, and what the page sends through `craft.crashReporter`.
   * Queued on disk and sent when online. Release builds are minified: upload
   * `app/build/outputs/mapping/release/mapping.txt` so bughq can retrace.
   */
  crashReporting?: {
    /** The bughq project's public ingest key. */
    key: string
    /** Default https://bughq.org. */
    host?: string
    /** Default `production`. */
    environment?: string
    /** Default `<versionName>+<versionCode>`, e.g. `1.0.0+41`. */
    release?: string
    /** One session per launch, for crash-free sessions. Default on. */
    sessions?: boolean
  }
}

export interface CraftTabBarConfig {
  selection?: {
    /** The selected tab indicator's corner radius in dp; omitted keeps the default. */
    cornerRadius?: number
    /** The selected tab indicator fill as #RRGGBB. */
    color?: string
  }
}

/** A declared command Craft runs after the native project has been generated. */
export interface CraftPostGenerateHook {
  command: string
  args?: string[]
}

/** The shared health data types (the iOS builder's HealthKit names). */
export type HealthConnectType = 'steps' | 'heartRate' | 'activeEnergy' | 'distance' | 'workouts' | 'restingHeartRate'
  | 'heartRateVariability' | 'bodyMass' | 'sleep' | 'mindful' | 'dietaryEnergy' | 'dietaryProtein'
  | 'dietaryCarbohydrates' | 'dietaryFat' | 'bloodGlucose' | 'insulinDelivery'

/**
 * The Health Connect permissions behind each type, for reading and for
 * writing. CraftNativeHealth.kt asks for the same ones; a permission the
 * manifest does not declare is refused without a prompt.
 */
export const HEALTH_CONNECT_PERMISSIONS: Record<HealthConnectType, { read: string[], write: string[] }> = {
  steps: { read: ['READ_STEPS'], write: [] },
  heartRate: { read: ['READ_HEART_RATE'], write: [] },
  activeEnergy: { read: ['READ_ACTIVE_CALORIES_BURNED'], write: ['WRITE_ACTIVE_CALORIES_BURNED'] },
  distance: { read: ['READ_DISTANCE'], write: ['WRITE_DISTANCE'] },
  workouts: {
    read: ['READ_EXERCISE', 'READ_HEART_RATE', 'READ_ACTIVE_CALORIES_BURNED', 'READ_DISTANCE'],
    write: ['WRITE_EXERCISE', 'WRITE_ACTIVE_CALORIES_BURNED', 'WRITE_DISTANCE'],
  },
  restingHeartRate: { read: ['READ_RESTING_HEART_RATE'], write: [] },
  heartRateVariability: { read: ['READ_HEART_RATE_VARIABILITY'], write: [] },
  bodyMass: { read: ['READ_WEIGHT'], write: [] },
  sleep: { read: ['READ_SLEEP'], write: [] },
  mindful: { read: ['READ_MINDFULNESS'], write: ['WRITE_MINDFULNESS'] },
  dietaryEnergy: { read: ['READ_NUTRITION'], write: ['WRITE_NUTRITION'] },
  dietaryProtein: { read: ['READ_NUTRITION'], write: ['WRITE_NUTRITION'] },
  dietaryCarbohydrates: { read: ['READ_NUTRITION'], write: ['WRITE_NUTRITION'] },
  dietaryFat: { read: ['READ_NUTRITION'], write: ['WRITE_NUTRITION'] },
  bloodGlucose: { read: ['READ_BLOOD_GLUCOSE'], write: [] },
  // Health Connect has no insulin record; asking for it adds nothing.
  insulinDelivery: { read: [], write: [] },
}

const DEFAULT_HEALTH_CONNECT = { read: ['steps', 'heartRate', 'activeEnergy', 'distance', 'workouts'], write: ['workouts'] } as const

/** Every `android.permission.health.*` the app's Health Connect types need. */
export function healthConnectPermissions(config: Pick<CraftAndroidConfig, 'healthConnect'>): string[] {
  const read = config.healthConnect?.read ?? DEFAULT_HEALTH_CONNECT.read
  const write = config.healthConnect?.write ?? (config.healthConnect ? [] : DEFAULT_HEALTH_CONNECT.write)
  const permissions = new Set<string>()
  for (const type of read) {
    const known = HEALTH_CONNECT_PERMISSIONS[type as HealthConnectType]
    if (!known) throw new Error(`Unknown Health Connect type: ${type}`)
    known.read.forEach(permission => permissions.add(`android.permission.health.${permission}`))
  }
  for (const type of write) {
    const known = HEALTH_CONNECT_PERMISSIONS[type as HealthConnectType]
    if (!known) throw new Error(`Unknown Health Connect type: ${type}`)
    known.write.forEach(permission => permissions.add(`android.permission.health.${permission}`))
  }
  if (config.healthConnect?.background) permissions.add('android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')
  if (config.healthConnect?.history) permissions.add('android.permission.health.READ_HEALTH_DATA_HISTORY')
  return [...permissions]
}

export interface InitOptions {
  name: string
  packageName?: string
  output: string
  config?: Partial<CraftAndroidConfig>
  /**
   * Where to find the Zig runtime's `<abi>/libcraft.so`.
   *
   * `null` means no runtime regardless of the environment; `undefined` falls
   * through to `CRAFT_ANDROID_RUNTIME`. Same shape as the iOS builder's
   * `runtimeDir`.
   */
  runtimeDir?: string | null
}

export interface BuildOptions {
  htmlPath?: string
  nativeBundlePath?: string
  /**
   * Native renderer: the app's icons as vectors (`{ viewBox, strokeWidth,
   * icons: { name: svgBody } }`, keyed by Iconify name and SF Symbol), which
   * `<Icon>`, the tab bar and the bar buttons draw. Without it they fall
   * back to the glyphs Android's fonts have.
   */
  iconsPath?: string
  devServer?: string
  output: string
  release?: boolean
  /**
   * An Android App Bundle (`bundleRelease`, `.aab`), what Google Play takes,
   * rather than an APK. Signed with CRAFT_ANDROID_KEYSTORE,
   * CRAFT_ANDROID_KEYSTORE_PASSWORD, CRAFT_ANDROID_KEY_ALIAS and
   * CRAFT_ANDROID_KEY_PASSWORD when they are set.
   */
  bundle?: boolean
  compile?: boolean
  /** Same meaning as `InitOptions.runtimeDir`; refreshes what init installed. */
  runtimeDir?: string | null
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
    throw new Error('Android postGenerate.command must be a non-empty executable')
  if (hook.args !== undefined && (!Array.isArray(hook.args) || hook.args.some(argument => typeof argument !== 'string')))
    throw new Error('Android postGenerate.args must be an array of strings')

  const command = [hook.command, ...(hook.args ?? [])]
  let result: ReturnType<typeof Bun.spawnSync>
  try {
    result = Bun.spawnSync(command, {
      cwd: output,
      env: { ...process.env, CRAFT_PROJECT_ROOT: output, CRAFT_PLATFORM: 'android', CRAFT_GENERATE_PHASE: phase },
      stdout: 'inherit',
      stderr: 'pipe',
    })
  }
  catch (error) {
    throw new Error(`Android postGenerate hook could not start in ${output}: ${hook.command}`, { cause: error })
  }
  if (result.exitCode !== 0) {
    const stderr = result.stderr?.toString().trim()
    throw new Error(`Android postGenerate hook failed in ${output} with exit code ${result.exitCode}${stderr ? `: ${stderr}` : ''}`)
  }
}

export interface OpenOptions {
  output: string
}

export interface RunOptions {
  device?: string
  output: string
}

const DEFAULT_CONFIG: Omit<CraftAndroidConfig, 'appName' | 'packageName'> = {
  renderer: 'web',
  version: '1.0.0',
  versionCode: 1,
  darkMode: true,
  backgroundColor: '#0b1712',
  enableSpeechRecognition: false,
  enableAudioRecording: false,
  enableHaptics: false,
  enableShare: false,
  enableCamera: false,
  enableBiometric: false,
  enablePushNotifications: false,
  enableSecureStorage: false,
  enableGeolocation: false,
  enableBackgroundLocation: false,
  enableBluetooth: false,
  enableHeartRate: false,
  enableHealthConnect: false,
  enableHealthServices: false,
  enableWallet: false,
  enableKeepAwake: false,
  enableDeepLinks: false,
  urlSchemes: [],
  appLinks: [],
  trustedOrigins: [],
  minSdk: ANDROID_MIN_SDK,
  compileSdk: 36,
  targetSdk: 35,
}

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll('\'', '&apos;')
}

function escapeKotlinString(value: string): string {
  return value
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('$', '\\$')
    .replaceAll('\r', '\\r')
    .replaceAll('\n', '\\n')
}

function generatedPackageSegment(name: string): string {
  const normalized = name.toLowerCase().replace(/[^a-z0-9_]/g, '')
  if (!normalized) return 'app'
  return /^[a-z_]/.test(normalized) ? normalized : `app${normalized}`
}

function generatedGradleProjectName(name: string): string {
  const invalidCharacters = ['/', '\\', ':', '<', '>', '"', '?', '*', '|']
  const normalized = invalidCharacters.reduce(
    (value, character) => value.replaceAll(character, '-'),
    name,
  ).trim()
  return normalized || 'craft-app'
}

function requireRegularFile(path: string, label: string): void {
  if (!existsSync(path)) throw new Error(`${label} not found: ${path}`)
  if (!statSync(path).isFile()) throw new Error(`${label} must be a file: ${path}`)
}

function containsPath(parent: string, candidate: string): boolean {
  const relativePath = relative(parent, candidate)
  return relativePath === ''
    || (relativePath !== '..' && !relativePath.startsWith(`..${sep}`) && !isAbsolute(relativePath))
}

function validateGoogleServicesFile(path: string, packageName: string): void {
  requireRegularFile(path, 'Google services file')

  let document: {
    client?: Array<{
      client_info?: { android_client_info?: { package_name?: string } }
    }>
  }
  try {
    document = JSON.parse(readFileSync(path, 'utf8'))
  }
  catch (error) {
    throw new Error(`Google services file must contain valid JSON: ${path}`, { cause: error })
  }

  const matchingClient = document.client?.some((client) => {
    return client.client_info?.android_client_info?.package_name === packageName
  })
  if (!matchingClient) {
    throw new Error(`Google services file has no client for Android package ${packageName}: ${path}`)
  }
}

function androidWebUrl(value: string, field: string): URL {
  let url: URL
  try {
    url = new URL(value)
  }
  catch {
    throw new Error(`Invalid ${field}: ${value}`)
  }

  const localDevelopment = url.protocol === 'http:' && LOCAL_DEVELOPMENT_HOSTS.has(url.hostname)
  if ((url.protocol !== 'https:' && !localDevelopment) || url.username || url.password) {
    throw new Error(`${field} must use HTTPS or local HTTP without credentials: ${value}`)
  }
  return url
}

function normalizeAndroidNetworkConfig(config: CraftAndroidConfig): void {
  const schemes = config.urlSchemes?.map(value => value.trim().toLowerCase()) ?? []
  if (schemes.some(value => !/^[a-z][a-z0-9+.-]*$/.test(value))) {
    throw new Error('Android deep-link schemes must be valid URI schemes')
  }
  config.urlSchemes = [...new Set(schemes)]
  config.appLinks = (config.appLinks ?? []).map((link) => {
    const host = link.host.trim().toLowerCase()
    const parsed = new URL(`https://${host}`)
    if (!host || parsed.hostname !== host || parsed.port || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash)
      throw new Error('Android App Links need a hostname without a scheme, port or path')
    for (const rule of link.paths ?? []) {
      if (!rule.pattern.startsWith('/') || /[\x00-\x1f]/.test(rule.pattern) || (rule.exclude !== undefined && typeof rule.exclude !== 'boolean'))
        throw new Error('Android App Link path rules need an absolute path pattern and a boolean exclude')
    }
    return { ...link, host }
  })
  if (new Set(config.appLinks.map(link => link.host)).size !== config.appLinks.length)
    throw new Error('Android App Link hosts must be unique')
  if (config.enableDeepLinks && config.urlSchemes.length === 0 && config.appLinks.length === 0) {
    throw new Error('Android deep links require at least one URL scheme or an App Link host')
  }

  const trustedOrigins = (config.trustedOrigins ?? []).map((value) => {
    return androidWebUrl(value, 'Android trusted origin').origin
  })
  if (config.devServerURL) {
    const devServer = androidWebUrl(config.devServerURL, 'Android dev server URL')
    config.devServerURL = devServer.toString()
    trustedOrigins.push(devServer.origin)
  }
  config.trustedOrigins = [...new Set(trustedOrigins)]
}

function validateAndroidConfig(config: CraftAndroidConfig): void {
  androidMapHost(config.mapProvider)
  if (!config.appName.trim()) throw new Error('Android app name must not be empty')
  if (config.renderer !== undefined && config.renderer !== 'web' && config.renderer !== 'native') {
    throw new Error(`Unknown Android renderer: ${config.renderer}. Expected web or native.`)
  }
  if (config.appearance !== undefined && !['light', 'dark', 'system'].includes(config.appearance)) {
    throw new Error(`Unknown Android appearance: ${config.appearance}. Expected light, dark, or system.`)
  }
  const selection = config.tabBar?.selection
  if (selection?.cornerRadius !== undefined && (!Number.isFinite(selection.cornerRadius) || selection.cornerRadius < 0))
    throw new Error('Android tabBar.selection.cornerRadius must be a finite non-negative number')
  if (selection?.color !== undefined && !/^#[0-9a-f]{6}$/i.test(selection.color))
    throw new Error('Android tabBar.selection.color must be a #RRGGBB color')

  const packageSegments = config.packageName.split('.')
  if (packageSegments.length < 2
    || packageSegments.some(segment => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(segment) || KOTLIN_KEYWORDS.has(segment))) {
    throw new Error(`Invalid Android package name: ${config.packageName}`)
  }

  if (!/^#(?:[\dA-F]{3,4}|[\dA-F]{6}|[\dA-F]{8})$/i.test(config.backgroundColor ?? '')) {
    throw new Error(`Invalid Android background color: ${config.backgroundColor}`)
  }

  if (config.backgroundColorDark !== undefined && !config.backgroundColorDark.match(/^#[\dA-F]{3,4}$|^#[\dA-F]{6}$|^#[\dA-F]{8}$/i)) {
    throw new Error(`Invalid Android dark background color: ${config.backgroundColorDark}`)
  }

  if (config.mapsApiKey !== undefined && !config.mapsApiKey.trim()) {
    throw new Error('Android mapsApiKey must not be empty')
  }

  for (const [name, value] of [
    ['versionCode', config.versionCode],
    ['minSdk', config.minSdk],
    ['compileSdk', config.compileSdk],
    ['targetSdk', config.targetSdk],
  ] as const) {
    if (!Number.isInteger(value) || Number(value) < 1) {
      throw new Error(`Android ${name} must be a positive integer`)
    }
  }

  if (Number(config.minSdk) < ANDROID_MIN_SDK) {
    throw new Error(`Android minSdk must be at least ${ANDROID_MIN_SDK} (Android 8.0) for the Craft runtime`)
  }
  if (config.enableHealthServices && Number(config.minSdk) < ANDROID_HEALTH_SERVICES_MIN_SDK) {
    throw new Error(`Android Health Services requires minSdk at least ${ANDROID_HEALTH_SERVICES_MIN_SDK} (Android 11)`)
  }
  if (Number(config.minSdk) > Number(config.targetSdk)) {
    throw new Error('Android minSdk must not exceed targetSdk')
  }
  if (Number(config.targetSdk) > Number(config.compileSdk)) {
    throw new Error('Android targetSdk must not exceed compileSdk')
  }
}

function normalizeNativeRoutePath(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  let path = raw
  const cut = path.search(/[?#]/)
  if (cut >= 0) path = path.slice(0, cut)
  if (!path.startsWith('/')) return null
  path = path.replace(/\/{2,}/g, '/')
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  return path
}

function nativeRouteSegments(path: string): string[] {
  return path === '/' ? [] : path.slice(1).split('/')
}

function matchesNativeRoute(nativeScreens: Record<string, string> | undefined, raw: string): boolean {
  const path = normalizeNativeRoutePath(raw)
  if (path === null) return false
  const parts = nativeRouteSegments(path)
  return Object.entries(nativeScreens ?? {}).some(([pattern, screen]) => {
    if (!screen) return false
    const normalized = normalizeNativeRoutePath(pattern)
    if (normalized === null) return false
    const route = nativeRouteSegments(normalized)
    for (let index = 0; index < route.length; index++) {
      const segment = route[index]
      if (segment === '*') return index === route.length - 1
      if (index >= parts.length) return false
      if (segment.startsWith(':')) {
        if (!parts[index]) return false
      }
      else if (segment !== parts[index]) return false
    }
    return route.length === parts.length
  })
}

function nativeStartPath(config: CraftAndroidConfig): string {
  if (!config.devServerURL) return '/'
  try {
    const url = new URL(config.devServerURL)
    return `${url.pathname || '/'}${url.search}`
  }
  catch {
    return '/'
  }
}

function validateNativeRouteConfig(config: CraftAndroidConfig): void {
  const screens = Object.entries(config.nativeScreens ?? {})
  for (const [pattern, screen] of screens) {
    if (normalizeNativeRoutePath(pattern) !== pattern || /[?#]/.test(pattern))
      throw new Error(`nativeScreens path "${pattern}" must be an absolute path with no query, hash or trailing slash.`)
    if (nativeRouteSegments(normalizeNativeRoutePath(pattern) ?? '/').slice(0, -1).includes('*'))
      throw new Error(`nativeScreens path "${pattern}" may only end in *.`)
    if (typeof screen !== 'string' || !/^[A-Za-z_$][\w$-]*$/.test(screen))
      throw new Error(`nativeScreens screen "${String(screen)}" for "${pattern}" must be a screen name from the native bundle.`)
  }

  const ids = new Set<string>()
  for (const tab of config.tabs ?? []) {
    if (!tab || typeof tab.id !== 'string' || !tab.id || typeof tab.title !== 'string' || !tab.title)
      throw new Error('Each tab needs an id (its root path) and a title.')
    if (ids.has(tab.id)) throw new Error(`Tab "${tab.id}" is listed twice.`)
    ids.add(tab.id)
  }

  if (config.renderer === 'native' && screens.length > 0) {
    for (const id of ids) {
      if (!matchesNativeRoute(config.nativeScreens, id))
        throw new Error(`Tab "${id}" is not a nativeScreens path; with renderer: "native" every tab must be a native screen.`)
    }
    const start = nativeStartPath(config)
    if (!matchesNativeRoute(config.nativeScreens, start))
      throw new Error(`The start path "${start}" (from devServerURL) is not a nativeScreens path; with renderer: "native" the app must start on a native screen.`)
  }

  if (config.nativeApp !== undefined) {
    if (typeof config.nativeApp !== 'string' || !/^[A-Za-z_$][\w$-]*$/.test(config.nativeApp))
      throw new Error(`nativeApp "${String(config.nativeApp)}" must be a route name from the native bundle.`)
    if (config.renderer !== 'native' && screens.length === 0)
      throw new Error('nativeApp runs in the native bundle; it needs nativeScreens or renderer: "native".')
  }
}

function writeAndroidConfig(output: string, config: CraftAndroidConfig): void {
  writeFileSync(join(output, 'craft.config.json'), JSON.stringify(config, null, 2))

  // Generator-only paths can reveal the developer machine's directory layout
  // and have no meaning to the installed app. Keep them in the project config
  // but never package them into the APK's assets.
  const runtimeConfig = { ...config }
  delete runtimeConfig.appIconPath
  delete runtimeConfig.notificationIconPath
  delete runtimeConfig.googleServicesFile
  writeFileSync(
    join(output, 'app/src/main/assets/craft.config.json'),
    JSON.stringify(runtimeConfig, null, 2),
  )
}

export function syncAndroidWebAssets(source: string, output: string): void {
  const sourcePath = resolve(source)
  if (!existsSync(sourcePath)) throw new Error(`Web asset path not found: ${source}`)
  const sourceStat = statSync(sourcePath)
  if (!sourceStat.isDirectory() && !sourceStat.isFile()) {
    throw new Error(`Web asset path must be a file or directory: ${source}`)
  }

  const assetsDir = resolve(output, 'app/src/main/assets')
  if (containsPath(sourcePath, assetsDir) || containsPath(assetsDir, sourcePath)) {
    throw new Error(`Web asset source must not overlap generated asset directory: ${source}`)
  }
  if (sourceStat.isDirectory()) {
    requireRegularFile(join(sourcePath, 'index.html'), 'Web asset directory entry point')
  }

  const configPath = join(assetsDir, 'craft.config.json')
  const config = existsSync(configPath) ? readFileSync(configPath) : undefined
  rmSync(assetsDir, { recursive: true, force: true })
  mkdirSync(assetsDir, { recursive: true })
  if (sourceStat.isDirectory()) cpSync(sourcePath, assetsDir, { recursive: true })
  else cpSync(sourcePath, join(assetsDir, 'index.html'))
  if (!existsSync(join(assetsDir, 'index.html'))) throw new Error(`Web asset directory must contain index.html: ${source}`)
  if (config) writeFileSync(configPath, config)
}

export function renderAndroidPermissions(config: CraftAndroidConfig): string {
  const permissions = new Set(['android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE'])
  if (config.enableSpeechRecognition || config.enableAudioRecording) permissions.add('android.permission.RECORD_AUDIO')
  if (config.enableCamera) permissions.add('android.permission.CAMERA')
  if (config.enableHaptics) permissions.add('android.permission.VIBRATE')
  if (config.enableBiometric) permissions.add('android.permission.USE_BIOMETRIC')
  if (config.enableGeolocation || config.enableBackgroundLocation) {
    permissions.add('android.permission.ACCESS_FINE_LOCATION')
    permissions.add('android.permission.ACCESS_COARSE_LOCATION')
  }
  if (config.enableBackgroundLocation) {
    permissions.add('android.permission.ACCESS_BACKGROUND_LOCATION')
    permissions.add('android.permission.FOREGROUND_SERVICE')
    permissions.add('android.permission.FOREGROUND_SERVICE_LOCATION')
  }
  if (config.enablePushNotifications) permissions.add('android.permission.POST_NOTIFICATIONS')
  if (config.enableKeepAwake) permissions.add('android.permission.WAKE_LOCK')
  if (config.enableHealthConnect) healthConnectPermissions(config).forEach(permission => permissions.add(permission))
  // A background refresh (WorkManager) after a restart.
  if (config.renderer === 'native' && config.backgroundRefresh?.enabled) permissions.add('android.permission.RECEIVE_BOOT_COMPLETED')
  // A heart-rate recording keeps the process in the foreground while it
  // runs (CraftHeartRateService), as a connectedDevice service.
  if (config.enableHeartRate) {
    permissions.add('android.permission.FOREGROUND_SERVICE')
    permissions.add('android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE')
  }
  if (config.enableHealthServices) {
    permissions.add('android.permission.BODY_SENSORS')
    permissions.add('android.permission.BODY_SENSORS_BACKGROUND')
    permissions.add('android.permission.health.READ_HEART_RATE')
    permissions.add('android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')
    permissions.add('android.permission.ACTIVITY_RECOGNITION')
    permissions.add('android.permission.ACCESS_FINE_LOCATION')
    permissions.add('android.permission.ACCESS_COARSE_LOCATION')
    permissions.add('android.permission.FOREGROUND_SERVICE')
    permissions.add('android.permission.FOREGROUND_SERVICE_HEALTH')
  }
  const bluetooth = config.enableBluetooth || config.enableHeartRate ? [
    '    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />',
    '    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />',
    '    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />',
    '    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />',
    ...(permissions.has('android.permission.ACCESS_FINE_LOCATION') ? [] : ['    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />']),
  ].join('\n') : ''
  return [bluetooth, ...[...permissions].map(permission => `    <uses-permission android:name="${permission}" />`)].filter(Boolean).join('\n')
}

/**
 * The native renderer's own sources: the app around the screens (routes,
 * stores, bars), its services (dialogs, browser, share, push, Health
 * Connect), background refresh, and Firebase messaging when push is on.
 */
function writeNativeShellSources(output: string, packagePath: string, packageName: string, config: CraftAndroidConfig): void {
  const javaDir = join(output, 'app/src/main/java', packagePath)
  const write = (template: string, file: string, replace: (source: string) => string = source => source): void => {
    const source = readFileSync(join(TEMPLATES_DIR, template), 'utf-8').replace(/\{\{PACKAGE_NAME\}\}/g, packageName)
    writeFileSync(join(javaDir, file), replace(source))
  }
  write('CraftBluetooth.kt.template', 'CraftBluetooth.kt')
  write('CraftNativeShell.kt.template', 'CraftNativeShell.kt')
  write('CraftSnapshotFile.kt.template', 'CraftSnapshotFile.kt')
  write('CraftNativeImageCache.kt.template', 'CraftNativeImageCache.kt')
  write('CraftNativeHaptics.kt.template', 'CraftNativeHaptics.kt')
  write('CraftNativeBackground.kt.template', 'CraftNativeBackground.kt')
  write(config.enableHealthConnect ? 'CraftNativeHealth.kt.template' : 'CraftNativeHealthStub.kt.template', 'CraftNativeHealth.kt')
  write(config.enableHealthServices ? 'CraftHealthServices.kt.template' : 'CraftHealthServicesStub.kt.template', 'CraftHealthServices.kt')
  if (config.enableHealthServices) {
    write('CraftHealthServicesService.kt.template', 'CraftHealthServicesService.kt')
  }
  else {
    rmSync(join(javaDir, 'CraftHealthServicesService.kt'), { force: true })
  }
  write('CraftNativeServices.kt.template', 'CraftNativeServices.kt', source => source
    .replace('{{NATIVE_PUSH_IMPORTS}}', config.enablePushNotifications ? 'import com.google.firebase.messaging.FirebaseMessaging' : '')
    .replace('{{NATIVE_WALLET_IMPORTS}}', config.enableWallet ? `import com.google.android.gms.pay.Pay
import com.google.android.gms.pay.PayApiAvailabilityStatus
import com.google.android.gms.pay.PayClient` : '')
    .replace('{{NATIVE_WALLET_FIELDS}}', config.enableWallet ? `    private var pendingWallet: ((CraftNativeCapabilityResult) -> Unit)? = null
    private val walletRequestCode = 9517` : '')
    .replace('{{NATIVE_WALLET_AVAILABILITY}}', config.enableWallet ? `                val host = activity()
                if (host == null) {
                    done(success(false))
                } else {
                    Pay.getClient(host).getPayApiAvailabilityStatus(PayClient.RequestType.SAVE_PASSES_JWT)
                        .addOnSuccessListener { status -> done(success(status == PayApiAvailabilityStatus.AVAILABLE)) }
                        .addOnFailureListener { done(success(false)) }
                }` : `                done(success(runCatching {
                    context.packageManager.getLaunchIntentForPackage("com.google.android.apps.walletnfcrel") != null
                }.getOrDefault(false)))`)
    .replace('{{NATIVE_WALLET_JWT_ADD}}', config.enableWallet
      ? '                    saveWalletJwt(jwt, host, done)'
      : '                    done(failure("UNSUPPORTED", "Android Wallet JWT saves are not enabled"))')
    .replace('{{NATIVE_WALLET_HELPER}}', config.enableWallet ? `    private fun saveWalletJwt(jwt: String, host: Activity, done: (CraftNativeCapabilityResult) -> Unit) {
        if (pendingWallet != null) return done(failure("BUSY", "A Google Wallet save is already in progress"))
        pendingWallet = done
        try {
            Pay.getClient(host).savePassesJwt(jwt, host, walletRequestCode)
        } catch (error: Exception) {
            pendingWallet = null
            done(failure("PRESENTATION_FAILED", error.message ?: "Google Wallet could not open"))
        }
    }
` : '')
    .replace('{{NATIVE_WALLET_RESULT}}', config.enableWallet ? `        if (requestCode == walletRequestCode) {
            val completion = pendingWallet
            pendingWallet = null
            if (completion == null) return true
            when (resultCode) {
                Activity.RESULT_OK -> completion(success(true))
                Activity.RESULT_CANCELED -> completion(success(false))
                PayClient.SavePassesResult.API_UNAVAILABLE -> completion(failure("UNAVAILABLE", "Google Wallet save is unavailable"))
                PayClient.SavePassesResult.INTERNAL_ERROR -> completion(failure("WALLET_ERROR", "Google Wallet returned an internal error"))
                PayClient.SavePassesResult.SAVE_ERROR -> completion(failure("SAVE_ERROR", data?.getStringExtra(PayClient.EXTRA_API_ERROR_MESSAGE) ?: "Google Wallet could not save the pass"))
                else -> completion(failure("WALLET_ERROR", "Google Wallet returned an unknown result"))
            }
            return true
        }
` : '')
    .replace('{{NATIVE_PUSH_REGISTER}}', config.enablePushNotifications
      ? `        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                if (token.isNullOrBlank()) done(failure("PUSH_UNAVAILABLE", task.exception?.message ?: "Firebase Cloud Messaging gave no token"))
                else {
                    context.getSharedPreferences("craft-native-push", Context.MODE_PRIVATE).edit().putString("token", token).apply()
                    done(success(token))
                }
            }
        } catch (error: Exception) {
            done(failure("PUSH_UNAVAILABLE", error.message ?: "Firebase Cloud Messaging is not configured"))
        }`
      : '        done(failure("CAPABILITY_DISABLED", "Push notifications are disabled"))'))
  write('CraftNativeSounds.kt.template', 'CraftNativeSounds.kt')
  if (config.enablePushNotifications) write('CraftNativeMessagingService.kt.template', 'CraftNativeMessagingService.kt')
  else rmSync(join(javaDir, 'CraftNativeMessagingService.kt'), { force: true })
  // Files a screen shares (craft.files' copies, in the cache) go to other apps through this provider.
  mkdirSync(join(output, 'app/src/main/res/xml'), { recursive: true })
  writeFileSync(join(output, 'app/src/main/res/xml/craft_file_paths.xml'), `<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="craft-files" path="craft-files/" />
    <files-path name="craft-media" path="craft-media/" />
</paths>
`)
}

/** What the native renderer adds to the manifest's application element. */
function renderNativeShellManifest(config: CraftAndroidConfig): string {
  const parts = [
    '        <receiver android:name=".CraftNativeNotificationReceiver" android:exported="false" />',
    `        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${config.packageName}.craftfiles"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/craft_file_paths" />
        </provider>`,
  ]
  if (config.enablePushNotifications) {
    // What Android shows for a push that arrives while the app is in the
    // background, which Firebase draws without the service.
    parts.push(`        <service android:name=".CraftNativeMessagingService" android:exported="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT" />
            </intent-filter>
        </service>
        <meta-data android:name="com.google.firebase.messaging.default_notification_icon" android:resource="@drawable/craft_notification_icon" />${config.notificationColor ? `
        <meta-data android:name="com.google.firebase.messaging.default_notification_color" android:resource="@color/craft_notification_color" />` : ''}`)
  }
  if (config.enableHealthConnect) {
    // Android 14 and later open the app's privacy policy from Health
    // Connect's permission screen through this alias.
    parts.push(`        <activity-alias
            android:name="ViewPermissionUsageActivity"
            android:exported="true"
            android:targetActivity=".MainActivity"
            android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
            <intent-filter>
                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
                <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
            </intent-filter>
        </activity-alias>`)
  }
  return parts.join('\n')
}

export function renderAndroidDeepLinks(config: CraftAndroidConfig): string {
  if (!config.enableDeepLinks) return ''
  const schemes = [...new Set(config.urlSchemes?.map(value => value.trim()).filter(value => /^[a-z][a-z0-9+.-]*$/i.test(value)) ?? [])]
  const custom = schemes.map(scheme => `            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="${scheme}" />
            </intent-filter>`).join('\n')
  const verified = (config.appLinks ?? []).map(link => {
    if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i.test(link.host)) throw new Error('Invalid Android App Link host')
    return `            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="https" android:host="${link.host}" />
            </intent-filter>`
  }).join('\n')
  return [custom, verified].filter(Boolean).join('\n')
}

/**
 * Initialize a new Android project
 */
/**
 * The ABI directories a runtime directory is expected to hold.
 *
 * These are Android's own names for the two architectures craft builds, and
 * they are also `zig build build-android-all`'s output layout — `zig-out/android/`
 * already contains `arm64-v8a/libcraft.so` and `x86_64/libcraft.so`, which is
 * exactly the shape `app/src/main/jniLibs/` wants. So the install below is a
 * copy and not a rearrangement.
 *
 * x86_64 is not optional-in-practice: every Android emulator anyone tests on
 * is x86_64, so a runtime shipped for arm64 alone is one that never runs in
 * CI and never runs on a developer's machine either.
 */
const RUNTIME_ABIS = ['arm64-v8a', 'x86_64'] as const

/**
 * Where the runtime directory comes from when the caller does not say.
 *
 * The same shape as `CRAFT_BIN` and the iOS builder's `CRAFT_IOS_RUNTIME`: an
 * explicit override for the monorepo dev loop, not a lookup path. Shipping the
 * runtime to real apps means putting these libraries in the pantry package
 * beside the `craft` binary, which is a distribution decision this function
 * does not make.
 */
export function resolveRuntimeDir(override?: string | null): string | null {
  if (override === null) return null
  const dir = override ?? process.env.CRAFT_ANDROID_RUNTIME
  if (!dir) return null
  if (!existsSync(dir)) {
    const source = override === undefined ? 'CRAFT_ANDROID_RUNTIME points at' : 'runtimeDir is'
    throw new Error(`${source} ${dir}, which does not exist.`)
  }
  return dir
}

/**
 * Copy the Zig runtime into the generated project as
 * `app/src/main/jniLibs/<abi>/libcraft.so`.
 *
 * That path is AGP's default `jniLibs.srcDirs`, so nothing in the Gradle
 * templates has to know about it — the library is packaged into the APK and
 * `System.loadLibrary("craft")` finds it because the file is named for the
 * `craft` it asks for.
 *
 * Until this existed, nothing put the library anywhere. `CraftNative` caught
 * the `UnsatisfiedLinkError`, set `isAvailable = false`, and every action fell
 * through to the Kotlin shim — by design, so an app with no runtime still
 * works, which is also why nobody noticed that *every* generated app was in
 * that state and the whole Android half of the Zig bridge had never run.
 *
 * Returns true when a runtime was installed.
 */
export function installRuntime(output: string, runtimeDir: string): boolean {
  // Every ABI resolved before anything is written, so a half-populated
  // runtime directory cannot leave a project carrying one architecture and
  // claiming both. A single-ABI APK installs fine and then fails to load on
  // the other kind of device, which is the break that only shows up on
  // somebody else's phone.
  const found = RUNTIME_ABIS.map(abi => ({ abi, source: join(runtimeDir, abi, 'libcraft.so') }))
    .filter(entry => existsSync(entry.source))

  if (found.length === 0) {
    throw new Error(
      `${runtimeDir} has no <abi>/libcraft.so for any of ${RUNTIME_ABIS.join(', ')}. `
      + 'Run `zig build build-android-all -Doptimize=ReleaseSafe` in packages/zig and point at its zig-out/android.',
    )
  }

  if (found.length < RUNTIME_ABIS.length) {
    const missing = RUNTIME_ABIS.filter(abi => !found.some(entry => entry.abi === abi))
    console.warn(
      `   ⚠ only ${found.map(entry => entry.abi).join(', ')} was found; ${missing.join(', ')} is missing. `
      + 'The app will fall back to the Kotlin shim on those devices.',
    )
  }

  const dest = join(output, 'app/src/main/jniLibs')
  // Wiped rather than merged, so an ABI dropped from a later build does not
  // linger in the project as a stale library the APK still ships.
  rmSync(dest, { force: true, recursive: true })

  for (const { abi, source } of found) {
    const abiDir = join(dest, abi)
    mkdirSync(abiDir, { recursive: true })
    cpSync(source, join(abiDir, 'libcraft.so'))
  }

  return true
}

export async function init(options: InitOptions): Promise<void> {
  const { name, packageName, output } = options

  console.log(`\n⚡ Initializing Craft Android project: ${name}`)
  console.log(`   Output: ${output}\n`)

  // Generate package name from app name if not provided
  const finalPackageName = packageName || `com.craft.${generatedPackageSegment(name)}`
  const packagePath = finalPackageName.replace(/\./g, '/')

  // Command-level identity always wins over duplicate fields in `config`.
  // Normalize implied capabilities before validation so craft.config.json and
  // the generated Gradle source describe the same effective project.
  // Undefined keeps the default instead of erasing it (see the iOS builder).
  const given = Object.fromEntries(Object.entries(options.config ?? {}).filter(([, value]) => value !== undefined))
  const config: CraftAndroidConfig = {
    ...DEFAULT_CONFIG,
    ...given,
    appName: name,
    packageName: finalPackageName,
  }
  if (config.enableHealthServices && given.minSdk === undefined) config.minSdk = ANDROID_HEALTH_SERVICES_MIN_SDK
  if (config.enableBackgroundLocation) config.enableGeolocation = true
  if (config.enableHealthConnect) {
    config.compileSdk = Math.max(config.compileSdk ?? 36, 36)
    config.enableHealthConnectBackground = Boolean(config.healthConnect?.background)
    config.enableHealthConnectHistory = Boolean(config.healthConnect?.history)
    healthConnectPermissions(config)
  }
  normalizeAndroidNetworkConfig(config)
  validateAndroidConfig(config)
  validateNativeRouteConfig(config)
  if (config.enablePushNotifications && !config.googleServicesFile) {
    throw new Error('Android push notifications require a googleServicesFile')
  }
  if (config.googleServicesFile) validateGoogleServicesFile(config.googleServicesFile, finalPackageName)
  if (config.appIconPath) requireRegularFile(config.appIconPath, 'App icon')
  const appIconExtension = config.appIconPath ? extname(config.appIconPath).toLowerCase() : undefined
  if (config.appIconPath && !['.gif', '.jpg', '.png', '.webp'].includes(appIconExtension ?? '')) {
    throw new Error(`Unsupported Android app icon format: ${appIconExtension || '(none)'}`)
  }
  if (config.notificationIconPath) requireRegularFile(config.notificationIconPath, 'Notification icon')
  const notificationIconExtension = config.notificationIconPath ? extname(config.notificationIconPath).toLowerCase() : undefined
  if (config.notificationIconPath && !['.png', '.xml'].includes(notificationIconExtension ?? '')) {
    throw new Error(`Unsupported Android notification icon format: ${notificationIconExtension || '(none)'} (use a vector drawable .xml or a white-on-transparent .png)`)
  }
  if (config.notificationIconPath && notificationIconExtension === '.xml' && !/<vector[\s>]/.test(readFileSync(config.notificationIconPath, 'utf8'))) {
    throw new Error('Notification icon .xml must be an Android vector drawable (<vector>)')
  }
  if (config.notificationColor !== undefined && !/^#[0-9a-f]{6}$/i.test(config.notificationColor)) {
    throw new Error(`notificationColor must be #RRGGBB, not ${String(config.notificationColor)}`)
  }

  // Create directory structure
  const dirs = [
    output,
    join(output, 'app/src/main/java', packagePath),
    join(output, 'app/src/main/res/layout'),
    join(output, 'app/src/main/res/values'),
    join(output, 'app/src/main/res/values-night'),
    join(output, 'app/src/main/res/drawable'),
    join(output, 'app/src/main/assets'),
    join(output, 'gradle/wrapper'),
  ]

  if (existsSync(output) && !statSync(output).isDirectory()) {
    throw new Error(`Android project output must be a directory: ${output}`)
  }

  for (const dir of dirs) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
    }
  }

  // Create craft.config.json
  writeAndroidConfig(output, config)

  const hasGoogleServices = Boolean(config.googleServicesFile)
  if (config.googleServicesFile) {
    cpSync(config.googleServicesFile, join(output, 'app/google-services.json'))
  }

  // Copy templates
  const mainActivityTemplate = readFileSync(join(
    TEMPLATES_DIR,
    config.renderer === 'native' ? 'MainActivityNative.kt.template' : 'MainActivity.kt.template',
  ), 'utf-8')
  const mainActivity = mainActivityTemplate
    .replace(/\{\{NATIVE_MAP_IMPORTS\}\}/g, () => androidMapHost(config.mapProvider).imports)
    .replace(/\{\{NATIVE_MAP_HOST\}\}/g, () => readFileSync(join(TEMPLATES_DIR, androidMapHost(config.mapProvider).template), 'utf8'))
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{APP_NAME\}\}/g, name)

  writeFileSync(join(output, 'app/src/main/java', packagePath, 'MainActivity.kt'), mainActivity)
  writeFileSync(
    join(output, 'app/src/main/java', packagePath, 'CraftAppLinks.kt'),
    readFileSync(join(TEMPLATES_DIR, 'CraftAppLinks.kt.template'), 'utf8').replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
  )
  // Both renderers: crash reporting does not depend on how screens are drawn.
  writeFileSync(
    join(output, 'app/src/main/java', packagePath, 'CraftCrashReporter.kt'),
    readFileSync(join(TEMPLATES_DIR, 'CraftCrashReporter.kt.template'), 'utf-8')
      .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
      .replace(/\{\{CRAFT_VERSION\}\}/g, CRAFT_ANDROID_VERSION),
  )
  if (config.renderer === 'native') {
    const mutationTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftNativeMutation.kt.template'), 'utf-8')
    const flatListTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftNativeFlatList.kt.template'), 'utf-8')
    const refreshableFlatListTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftNativeRefreshableFlatList.kt.template'), 'utf-8')
    const capabilityTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftNativeCapabilities.kt.template'), 'utf-8')
    const notificationTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftNativeNotificationReceiver.kt.template'), 'utf-8')
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'CraftNativeMutation.kt'),
      mutationTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'CraftNativeFlatList.kt'),
      flatListTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'CraftNativeRefreshableFlatList.kt'),
      refreshableFlatListTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'CraftNativeCapabilities.kt'),
      capabilityTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'CraftNativeNotificationReceiver.kt'),
      notificationTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
    writeNativeShellSources(output, packagePath, finalPackageName, config)
  }

  const permissionPolicy = readFileSync(join(TEMPLATES_DIR, 'CraftPermissionPolicy.kt.template'), 'utf8')
  writeFileSync(join(output, 'app/src/main/java', packagePath, 'CraftPermissionPolicy.kt'), permissionPolicy.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName))

  // Create CraftBridge.kt
  const craftBridgeTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftBridge.kt.template'), 'utf-8')
  const craftBridge = craftBridgeTemplate
    .replace(/\{\{PROMISE_RUNTIME\}\}/g, () => renderAndroidPromiseRuntime('            '))
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{ENABLE_SPEECH\}\}/g, String(Boolean(config.enableSpeechRecognition)))
    .replace(/\{\{ENABLE_HAPTICS\}\}/g, String(Boolean(config.enableHaptics)))
    .replace(/\{\{ENABLE_SHARE\}\}/g, String(Boolean(config.enableShare)))
    .replace(/\{\{ENABLE_CAMERA\}\}/g, String(Boolean(config.enableCamera)))
    .replace(/\{\{ENABLE_BIOMETRIC\}\}/g, String(Boolean(config.enableBiometric)))
    .replace(/\{\{ENABLE_PUSH\}\}/g, String(Boolean(config.enablePushNotifications)))
    .replace(/\{\{ENABLE_SECURE_STORAGE\}\}/g, String(Boolean(config.enableSecureStorage)))
    .replace(/\{\{ENABLE_GEOLOCATION\}\}/g, String(Boolean(config.enableGeolocation)))
    .replace(/\{\{ENABLE_BACKGROUND_LOCATION\}\}/g, String(Boolean(config.enableBackgroundLocation)))
    .replace(/\{\{ENABLE_KEEP_AWAKE\}\}/g, String(Boolean(config.enableKeepAwake)))
    .replace(/\{\{ENABLE_DEEP_LINKS\}\}/g, String(Boolean(config.enableDeepLinks)))
    .replace(/\{\{ENABLE_HEALTH_CONNECT\}\}/g, String(Boolean(config.enableHealthConnect)))
    .replace(/\{\{ENABLE_HEART_RATE\}\}/g, String(Boolean(config.enableHeartRate)))
    .replace(/\{\{FIREBASE_IMPORT\}\}/g, config.enablePushNotifications ? 'import com.google.firebase.messaging.FirebaseMessaging' : '')
    .replace(/\{\{REGISTER_PUSH_IMPLEMENTATION\}\}/g, config.enablePushNotifications
      ? `activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4204)
            }
            try {
                FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                    val token = if (task.isSuccessful) task.result else null
                    val callback = if (token.isNullOrBlank()) "window._craftPushReject" else "window._craftPushResolve"
                    val payload = JSONObject.quote(token ?: task.exception?.message ?: "Firebase Cloud Messaging is not configured")
                    evaluatePromiseJavascript("$callback && $callback($payload)")
                }
            } catch (error: Exception) {
                val payload = JSONObject.quote(error.message ?: "Firebase Cloud Messaging is not configured")
                evaluatePromiseJavascript("window._craftPushReject && window._craftPushReject($payload)")
            }
        }`
      : `evaluatePromiseJavascript(
            "window._craftPushReject && window._craftPushReject('Push notifications are disabled')"
        )`)
  // Typed native screens have no WebView bridge or ML surface. Shipping its
  // otherwise unreachable OCR models added ~100 MB of native libraries.
  const bridgeFile = join(output, 'app/src/main/java', packagePath, 'CraftBridge.kt')
  if (config.renderer === 'native') rmSync(bridgeFile, { force: true })
  else writeFileSync(bridgeFile, craftBridge)

  // CraftNative goes to a fixed package, not the app's. The prebuilt
  // libcraft.so binds its natives by class name in JNI_OnLoad, and it cannot
  // know a name chosen here — so this one file is deliberately not templated
  // and deliberately not under packagePath.
  let craftNative = readFileSync(join(TEMPLATES_DIR, 'CraftNative.kt.template'), 'utf-8')
  if (config.renderer === 'native') {
    craftNative = craftNative.replace(/^import com\.google\.mlkit\..*\n/gm, '')
      .replace(/    \/\/ CRAFT_WEB_ML_START[\s\S]*?    \/\/ CRAFT_WEB_ML_END/, () =>
        // The fixed JNI holder keeps these callback signatures, even though
        // typed screens do not expose the WebView's machine-learning API.
        ['runImageClassification', 'runObjectDetection', 'runTextRecognition'].map(name =>
          `    @JvmStatic\n    fun ${name}(imageBase64: String) {\n        val (_, reject) = createMlSettlement()\n        reject("Machine learning is unavailable in the native renderer")\n    }`).join('\n\n'))
  }
  const nativeDir = join(output, 'app/src/main/java/com/craft/runtime')
  mkdirSync(nativeDir, { recursive: true })
  writeFileSync(join(nativeDir, 'CraftNative.kt'), craftNative)
  // The bridge and native holder both reference the recording store/service,
  // even when the service is not registered in the manifest. Keep these
  // support types in the same fixed package as CraftNative so every generated
  // app compiles regardless of its chosen package name or feature flags.
  const serviceTemplate = readFileSync(join(TEMPLATES_DIR, 'LocationRecordingService.kt.template'), 'utf-8')
  writeFileSync(join(nativeDir, 'LocationRecordingService.kt'), serviceTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName))
  const healthTemplate = readFileSync(join(
    TEMPLATES_DIR,
    config.enableHealthConnect ? 'CraftHealthConnect.kt.template' : 'CraftHealthConnectStub.kt.template',
  ), 'utf-8')
  writeFileSync(
    join(output, 'app/src/main/java', packagePath, 'CraftHealthConnect.kt'),
    healthTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
  )
  // The heart-rate strap service, in every app as iOS has CraftHeartRate.swift
  // in every app: the page's bridge and the native screens' services refer to
  // it. Only `enableHeartRate` registers it, declares its service and asks
  // for Bluetooth.
  for (const [template, file] of [['CraftHeartRateCore.kt.template', 'CraftHeartRateCore.kt'], ['CraftHeartRate.kt.template', 'CraftHeartRate.kt']]) {
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, file!),
      readFileSync(join(TEMPLATES_DIR, template!), 'utf8').replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
  }
  // Create AndroidManifest.xml
  const manifestTemplate = readFileSync(join(TEMPLATES_DIR, 'AndroidManifest.xml.template'), 'utf-8')
  const manifest = manifestTemplate
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{APP_NAME\}\}/g, name)
    .replace(/\{\{PERMISSIONS\}\}/g, renderAndroidPermissions(config))
    // Plain HTTP only for a local dev server, or an app that talks to the
    // person's own devices on the LAN (which have no public certificate).
    .replace(/\{\{USES_CLEARTEXT\}\}/g, config.devServerURL?.startsWith('http://') || config.enableLocalNetwork ? 'true' : 'false')
    .replace(/\{\{DEEP_LINK_INTENT_FILTERS\}\}/g, renderAndroidDeepLinks(config))
    .replace(/\{\{BACKGROUND_SERVICE\}\}/g, config.enableBackgroundLocation
      ? '        <service android:name="com.craft.runtime.LocationRecordingService" android:exported="false" android:foregroundServiceType="location" android:stopWithTask="false" />'
      : '')
    .replace(/\{\{HEART_RATE_SERVICE\}\}/g, config.enableHeartRate
      ? '        <service android:name=".CraftHeartRateService" android:exported="false" android:foregroundServiceType="connectedDevice" />'
      : '')
    .replace(/\{\{HEALTH_SERVICES_SERVICE\}\}/g, config.enableHealthServices
      ? '        <service android:name=".CraftHealthServicesService" android:exported="false" android:foregroundServiceType="health" android:stopWithTask="false" />'
      : '')
    .replace(/\{\{NATIVE_NOTIFICATION_RECEIVER\}\}/g, config.renderer === 'native'
      ? renderNativeShellManifest(config)
      : '')
    // Starts the crash reporter before Application.onCreate, for every way
    // the process starts (CraftCrashReporter.kt). Inert without a key.
    .replace(/\{\{CRASH_REPORTER_PROVIDER\}\}/g, `        <provider android:name=".CraftCrashReporterInit" android:authorities="\${applicationId}.craft-crash" android:exported="false" android:initOrder="1000" />`)
    .replace(/\{\{GOOGLE_MAPS_API_KEY\}\}/g, config.mapProvider !== 'maplibre' && config.mapsApiKey
      ? `        <meta-data android:name="com.google.android.geo.API_KEY" android:value="${escapeXml(config.mapsApiKey)}" />`
      : '')
    .replace(/\{\{HEALTH_CONNECT_QUERIES\}\}/g, config.enableHealthConnect
      ? '    <queries>\n        <package android:name="com.google.android.apps.healthdata" />\n    </queries>'
      : '')
    .replace(/\{\{HEALTH_CONNECT_RATIONALE\}\}/g, config.enableHealthConnect
      ? `            <intent-filter>
                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />
            </intent-filter>${config.renderer === 'native' ? '' : `
            <intent-filter>
                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
                <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
            </intent-filter>`}`
      : '')

  writeFileSync(join(output, 'app/src/main/AndroidManifest.xml'), manifest)

  // Create build.gradle.kts (project level)
  const projectGradleTemplate = readFileSync(join(TEMPLATES_DIR, 'build.gradle.kts.project.template'), 'utf-8')
  writeFileSync(join(output, 'build.gradle.kts'), projectGradleTemplate
    .replace(/\{\{GOOGLE_SERVICES_PLUGIN\}\}/g, hasGoogleServices ? '    id("com.google.gms.google-services") version "4.4.2" apply false' : ''))

  // Create build.gradle.kts (app level)
  const appGradleTemplate = readFileSync(join(TEMPLATES_DIR, 'build.gradle.kts.app.template'), 'utf-8')
  const appGradle = appGradleTemplate
    .replace(/\{\{MACHINE_LEARNING_DEPENDENCIES\}\}/g, config.renderer === 'native' ? '' : [
      'barcode-scanning:17.3.0', 'image-labeling:17.0.9', 'object-detection:17.0.2', 'text-recognition:16.0.1',
    ].map(module => `    implementation("com.google.mlkit:${module}")`).join('\n'))
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{VERSION_NAME\}\}/g, escapeKotlinString(config.version || '1.0.0'))
    .replace(/\{\{VERSION_CODE\}\}/g, String(config.versionCode || 1))
    .replace(/\{\{MIN_SDK\}\}/g, String(config.minSdk ?? ANDROID_MIN_SDK))
    .replace(/\{\{COMPILE_SDK\}\}/g, String(config.compileSdk || 36))
    .replace(/\{\{TARGET_SDK\}\}/g, String(config.targetSdk || 35))
    .replace(/\{\{GOOGLE_SERVICES_PLUGIN\}\}/g, hasGoogleServices ? '    id("com.google.gms.google-services")' : '')
    .replace(/\{\{FIREBASE_MESSAGING_DEPENDENCY\}\}/g, config.enablePushNotifications
      ? '    implementation("com.google.firebase:firebase-messaging:24.1.0")'
      : '')
    .replace(/\{\{REFRESH_LAYOUT_DEPENDENCY\}\}/g, config.renderer === 'native'
      ? '    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.1.0")'
      : '')
    .replace(/\{\{NATIVE_MAP_DEPENDENCY\}\}/g, config.renderer === 'native'
      ? `    // Native STX Map overlays and trail routes\n    implementation("${androidMapHost(config.mapProvider).dependency}")`
      : '')
    .replace(/\{\{HEALTH_CONNECT_DEPENDENCIES\}\}/g, config.enableHealthConnect
      ? `    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")`
      : '')
    .replace(/\{\{HEALTH_SERVICES_DEPENDENCIES\}\}/g, config.enableHealthServices
      ? '    implementation("androidx.health:health-services-client:1.1.0")'
      : '')
    .replace(/\{\{WALLET_DEPENDENCY\}\}/g, config.enableWallet
      ? '    // Native Google Wallet save flow for signed pass JWTs\n    implementation("com.google.android.gms:play-services-pay:16.5.0")'
      : '')
    .replace(/\{\{JAVASCRIPT_ENGINE_DEPENDENCY\}\}/g, config.renderer === 'native'
      ? `    implementation("androidx.javascriptengine:javascriptengine:1.1.0")
    // Native background refresh (WorkManager).
    implementation("androidx.work:work-runtime-ktx:2.9.1")`
      : '')

  writeFileSync(join(output, 'app/build.gradle.kts'), appGradle)
  const proguardTemplate = readFileSync(join(TEMPLATES_DIR, 'proguard-rules.pro.template'), 'utf-8')
  writeFileSync(
    join(output, 'app/proguard-rules.pro'),
    proguardTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
  )

  // Create settings.gradle.kts
  const settingsTemplate = readFileSync(join(TEMPLATES_DIR, 'settings.gradle.kts.template'), 'utf-8')
  const settings = settingsTemplate.replace(
    /\{\{APP_NAME\}\}/g,
    escapeKotlinString(generatedGradleProjectName(name)),
  )
  writeFileSync(join(output, 'settings.gradle.kts'), settings)

  // Create gradle.properties
  const gradleProperties = `org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
android.nonTransitiveRClass=true
`
  writeFileSync(join(output, 'gradle.properties'), gradleProperties)

  // Create local.properties placeholder
  writeFileSync(join(output, 'local.properties'), '# SDK location will be set by Android Studio\n')

  // Create gradle wrapper properties
  const gradleWrapperProps = `distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\\://services.gradle.org/distributions/gradle-8.11.1-bin.zip
networkTimeout=10000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
`
  writeFileSync(join(output, 'gradle/wrapper/gradle-wrapper.properties'), gradleWrapperProps)

  // Create res/values files
  const stringsXml = `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">${escapeXml(name)}</string>
</resources>
`
  writeFileSync(join(output, 'app/src/main/res/values/strings.xml'), stringsXml)

  const colorsXml = `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="primary">#1a1a2e</color>
    <color name="primary_dark">#16162b</color>
    <color name="accent">#4ade80</color>
    <color name="background">${config.backgroundColor}</color>
    <!-- Transparent is NotificationCompat's COLOR_DEFAULT: the system picks. -->
    <color name="craft_notification_color">${config.notificationColor ?? '#00000000'}</color>
</resources>
`
  writeFileSync(join(output, 'app/src/main/res/values/colors.xml'), colorsXml)
  const darkColorsPath = join(output, 'app/src/main/res/values-night/colors.xml')
  if (config.backgroundColorDark) {
    writeFileSync(darkColorsPath, `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="background">${config.backgroundColorDark}</color>
</resources>
`)
  }
  else {
    rmSync(darkColorsPath, { force: true })
  }

  const appIconXml = `<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:fillColor="${config.backgroundColor}" android:pathData="M0,0h108v108h-108z" />
    <path android:fillColor="#10B981" android:pathData="M18,78L42,42l12,18l12,-12l24,30z" />
</vector>
`
  if (config.appIconPath) {
    cpSync(
      config.appIconPath,
      join(output, `app/src/main/res/drawable/craft_app_icon${appIconExtension}`),
    )
  }
  else {
    writeFileSync(join(output, 'app/src/main/res/drawable/craft_app_icon.xml'), appIconXml)
  }
  // Android draws a notification icon's alpha only, so it has its own white
  // glyph: the launcher icon there is a white square.
  for (const extension of ['.png', '.xml']) rmSync(join(output, `app/src/main/res/drawable/craft_notification_icon${extension}`), { force: true })
  if (config.notificationIconPath) {
    cpSync(config.notificationIconPath, join(output, `app/src/main/res/drawable/craft_notification_icon${notificationIconExtension}`))
  }
  else {
    writeFileSync(join(output, 'app/src/main/res/drawable/craft_notification_icon.xml'), `<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:fillColor="#FFFFFFFF" android:pathData="M18,78L42,42l12,18l12,-12l24,30z" />
</vector>
`)
  }

  const themesXml = `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.CraftApp" parent="Theme.Material3.DayNight.NoActionBar">
        <item name="android:statusBarColor">@color/primary_dark</item>
        <item name="android:navigationBarColor">@color/primary</item>
        <item name="android:windowBackground">@color/background</item>
    </style>
</resources>
`
  writeFileSync(join(output, 'app/src/main/res/values/themes.xml'), themesXml)

  // Create activity_main.xml
  const activityMainXml = config.renderer === 'native'
    ? `<?xml version="1.0" encoding="utf-8"?>
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/native_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent" />
`
    : `<?xml version="1.0" encoding="utf-8"?>
<androidx.coordinatorlayout.widget.CoordinatorLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:fitsSystemWindows="true">

    <WebView
        android:id="@+id/webview"
        android:layout_width="match_parent"
        android:layout_height="match_parent" />

</androidx.coordinatorlayout.widget.CoordinatorLayout>
`
  writeFileSync(join(output, 'app/src/main/res/layout/activity_main.xml'), activityMainXml)

  syncNativeFonts(config.nativeFonts, output)

  // Create placeholder index.html
  const placeholderHtml = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="viewport-fit=cover, width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>${escapeXml(name)}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Roboto', sans-serif;
      background: ${config.backgroundColor};
      color: white;
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
    }
    .container { text-align: center; padding: 2rem; }
    h1 { font-size: 2.5rem; margin-bottom: 1rem; }
    p { opacity: 0.7; }
    .ready { color: #4ade80; font-size: 0.9rem; margin-top: 2rem; }
  </style>
</head>
<body>
  <div class="container">
    <h1>⚡ ${escapeXml(name)}</h1>
    <p>Built with Craft Android</p>
    <p class="ready" id="status">Waiting for Craft bridge...</p>
  </div>
  <script>
    window.addEventListener('craftReady', (e) => {
      document.getElementById('status').textContent = \`✓ Craft bridge ready (platform: \${e.detail.platform})\`;
      console.log('Craft capabilities:', e.detail.capabilities);
    });
  </script>
</body>
</html>`

  writeFileSync(join(output, 'app/src/main/assets/index.html'), placeholderHtml)

  // The Zig runtime, when one was configured. Absent, the generated app is the
  // Kotlin shim and behaves exactly as it always has — which is the fallback
  // `CraftNative` was written for, not a failure.
  const runtimeDir = resolveRuntimeDir(options.runtimeDir)
  if (runtimeDir) {
    installRuntime(output, runtimeDir)
    console.log('   Installed the Zig runtime from', runtimeDir)
  }

  console.log('✅ Project initialized')
  console.log('')
  console.log('Next steps:')
  console.log(`  1. cd ${output}`)
  if (config.renderer === 'native') {
    console.log('  2. Compile your screen: stx native compile Screen.stx --format bundle --output screen.js')
    console.log('  3. Run: craft android build --native-bundle screen.js')
  }
  else {
    console.log('  2. Add your web content to app/src/main/assets/index.html')
    console.log('  3. Run: craft android build')
  }
  console.log('  4. Run: craft android open')
  console.log('')
}

/**
 * Build Android project
 */
export async function build(options: BuildOptions): Promise<void> {
  const { htmlPath, nativeBundlePath, devServer, output, release, bundle, compile = true } = options

  console.log('\n📦 Building Craft Android project...')

  // Load config
  const configPath = join(output, 'craft.config.json')
  if (!existsSync(configPath)) {
    throw new Error(`No craft.config.json found in ${output}. Run 'craft android init' first.`)
  }

  const config: CraftAndroidConfig = JSON.parse(readFileSync(configPath, 'utf-8'))
  validateAndroidConfig(config)
  validateNativeRouteConfig(config)

  if (config.renderer === 'native') {
    if (htmlPath || devServer) throw new Error('A native Android screen cannot use --html-path or --dev-server.')
    const destination = join(output, 'app/src/main/assets/native-screen.js')
    const routeDestination = join(output, 'app/src/main/assets/native-screens')
    if (nativeBundlePath) {
      // One file, or a directory of route bundles (stx's routesDir); each
      // replaces the other, since a route's own file wins at runtime.
      if (!existsSync(nativeBundlePath)) throw new Error(`Native bundle not found: ${nativeBundlePath}`)
      if (statSync(nativeBundlePath).isDirectory()) {
        if (resolve(nativeBundlePath) !== resolve(routeDestination)) {
          rmSync(routeDestination, { recursive: true, force: true })
          cpSync(nativeBundlePath, routeDestination, { recursive: true })
          compressNativeSources(routeDestination)
        }
        rmSync(destination, { force: true })
      }
      else {
        if (resolve(nativeBundlePath) !== resolve(destination)) cpSync(nativeBundlePath, destination)
        compressNativeSources(destination)
        rmSync(routeDestination, { recursive: true, force: true })
      }
    }
    const icons = join(output, 'app/src/main/assets/craft-icons.json')
    if (options.iconsPath) {
      requireRegularFile(options.iconsPath, 'Icon table')
      if (resolve(options.iconsPath) !== resolve(icons)) cpSync(options.iconsPath, icons)
    }
    if (!existsSync(destination) && !existsSync(routeDestination)) {
      throw new Error('Native Android mode needs app/src/main/assets/native-screen.js. Compile a .stx screen with `stx native compile` first.')
    }
  }
  else if (nativeBundlePath) {
    throw new Error('--native-bundle requires renderer: "native" in craft.config.json.')
  }

  // Refresh the runtime the same way the iOS builder does: only for a project
  // that already has one, so `craft android build` in a shim-only project does
  // not quietly acquire a native library it was never generated with.
  if (existsSync(join(output, 'app/src/main/jniLibs'))) {
    const runtimeDir = resolveRuntimeDir(options.runtimeDir)
    if (runtimeDir) {
      installRuntime(output, runtimeDir)
      console.log('   Refreshed the Zig runtime from', runtimeDir)
    }
    else {
      console.log('   Keeping the Zig runtime installed at init (no runtime directory configured)')
    }
  }

  // Update dev server URL if provided
  if (devServer) {
    const url = androidWebUrl(devServer, 'Android dev server URL')
    config.devServerURL = url.toString()
    config.trustedOrigins = [...new Set([
      ...(config.trustedOrigins ?? []).map(value => androidWebUrl(value, 'Android trusted origin').origin),
      url.origin,
    ])]
    writeAndroidConfig(output, config)
    console.log(`   Dev server: ${devServer}`)
  }

  // Copy the complete web application if provided.
  if (htmlPath) {
    syncAndroidWebAssets(htmlPath, output)
    config.hasBundledFallback = Boolean(devServer)
    writeAndroidConfig(output, config)
    console.log(`   Synced: ${htmlPath} → assets/`)
  }

  syncNativeFonts(config.nativeFonts, output)

  runPostGenerateHook(config.postGenerate, output)

  if (!compile) return

  // Check if gradlew exists
  const gradlewPath = join(output, 'gradlew')
  if (!existsSync(gradlewPath)) {
    console.log('   Generating Gradle wrapper...')
    try {
      await $`cd ${output} && gradle wrapper`.quiet()
    }
    catch (error) {
      throw new Error('Gradle is unavailable. Install Android Studio or Gradle before building Android.', { cause: error })
    }
  }

  // Build the project
  const variant = release ? 'Release' : 'Debug'
  const buildType = `${bundle ? 'bundle' : 'assemble'}${variant}`
  console.log(`   Building ${release ? 'release' : 'debug'} ${bundle ? 'app bundle' : 'APK'}...`)
  if (release && !process.env.CRAFT_ANDROID_KEYSTORE)
    console.log('   CRAFT_ANDROID_KEYSTORE is not set: the release build is unsigned.')

  try {
    await $`cd ${output} && ./gradlew ${buildType}`
    const artifact = bundle
      ? `app/build/outputs/bundle/${variant.toLowerCase()}/app-${variant.toLowerCase()}.aab`
      : release
        ? 'app/build/outputs/apk/release/app-release.apk'
        : 'app/build/outputs/apk/debug/app-debug.apk'
    console.log(`✅ ${bundle ? 'App bundle' : 'APK'} built: ${artifact}`)
  }
catch (error) {
    console.error('Build failed. Open in Android Studio for details.')
    throw error
  }

  console.log('')
}

/**
 * Open Android project in Android Studio
 */
export async function open(options: OpenOptions): Promise<void> {
  const { output } = options

  if (!existsSync(output)) {
    throw new Error(`No Android project found in ${output}. Run 'craft android init' first.`)
  }

  console.log(`🚀 Opening Android project in Android Studio...`)

  // Try to open with Android Studio
  try {
    // macOS
    await $`open -a "Android Studio" ${output}`.quiet()
  }
catch {
    try {
      // Linux
      await $`studio ${output}`.quiet()
    }
catch {
      console.log('⚠️  Android Studio not found.')
      console.log('   Please open the project manually in Android Studio:')
      console.log(`   ${output}`)
    }
  }
}

/**
 * Run on Android device or emulator
 */
export async function run(options: RunOptions): Promise<void> {
  const { device, output } = options

  // First build
  await build({ output })

  // Install and run
  console.log('📱 Installing and running on device...')

  try {
    const apkPath = join(output, 'app/build/outputs/apk/debug/app-debug.apk')

    if (device) {
      await $`adb -s ${device} install -r ${apkPath}`
    }
else {
      await $`adb install -r ${apkPath}`
    }

    // Get package name from config
    const config: CraftAndroidConfig = JSON.parse(
      readFileSync(join(output, 'craft.config.json'), 'utf-8')
    )

    // Launch the app
    const launchCmd = `${config.packageName}/.MainActivity`
    if (device) {
      await $`adb -s ${device} shell am start -n ${launchCmd}`
    }
else {
      await $`adb shell am start -n ${launchCmd}`
    }

    console.log('✅ App launched')
  }
catch (error) {
    console.error('Failed to install/run. Make sure:')
    console.error('  1. ADB is installed and in PATH')
    console.error('  2. A device/emulator is connected (run: adb devices)')
    throw error
  }
}
