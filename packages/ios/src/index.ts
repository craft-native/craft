/**
 * Craft iOS Builder
 *
 * Generates native iOS apps from web content using WKWebView.
 */

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { $ } from 'bun'

const TEMPLATES_DIR = join(dirname(import.meta.dir), 'templates')

export interface CraftConfig {
  appName: string
  bundleId: string
  version?: string
  buildNumber?: string
  darkMode?: boolean
  backgroundColor?: string
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
  enableFilePicker?: boolean
  enableFileDownload?: boolean
  enableSocialAuth?: boolean
  enableAudioRecording?: boolean
  enableVideoRecording?: boolean
  enableMotionSensors?: boolean
  enableLocalDatabase?: boolean
  enableBluetooth?: boolean
  enableNFC?: boolean
  enableHealthKit?: boolean
  enableLiveActivities?: boolean
  enableWatchApp?: boolean
  enableBackgroundLocation?: boolean
  enableBackgroundTasks?: boolean
  enableScreenCapture?: boolean
  enablePDFViewer?: boolean
  enableAR?: boolean
  enableMLKit?: boolean
  devServerURL?: string
  iosVersion?: string
  watchosVersion?: string
  teamId?: string
  urlSchemes?: string[]
  trustedOrigins?: string[]
  associatedDomains?: string[]
  appGroups?: string[]
  appIconPath?: string
  privacy?: CraftPrivacyManifest
  orientations?: Array<'portrait' | 'landscape-left' | 'landscape-right' | 'portrait-upside-down'>
  deviceFamilies?: Array<'iphone' | 'ipad'>
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
}

export interface BuildOptions {
  htmlPath?: string
  devServer?: string
  output: string
  generateProject?: boolean
}

export interface OpenOptions {
  output: string
}

export interface RunOptions {
  simulator: boolean
  output: string
}

const DEFAULT_CONFIG: Omit<CraftConfig, 'appName' | 'bundleId'> = {
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
  enableFilePicker: false,
  enableFileDownload: false,
  enableSocialAuth: false,
  enableAudioRecording: false,
  enableVideoRecording: false,
  enableMotionSensors: false,
  enableLocalDatabase: false,
  enableBluetooth: false,
  enableNFC: false,
  enableHealthKit: false,
  enableLiveActivities: false,
  enableWatchApp: false,
  enableBackgroundLocation: false,
  enableBackgroundTasks: false,
  enableScreenCapture: false,
  enablePDFViewer: false,
  enableAR: false,
  enableMLKit: false,
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

export function renderUsageDescriptions(config: CraftConfig): string {
  const entries: Array<[boolean | undefined, string, string]> = [
    [config.enableSpeechRecognition, 'NSSpeechRecognitionUsageDescription', `${config.appName} uses speech recognition for voice input.`],
    [config.enableSpeechRecognition || config.enableAudioRecording, 'NSMicrophoneUsageDescription', `${config.appName} uses the microphone to record audio.`],
    [config.enableCamera || config.enableVideoRecording || config.enableQRScanner || config.enableAR, 'NSCameraUsageDescription', `${config.appName} uses the camera for photos, video, scanning, and augmented reality.`],
    [config.enableCamera || config.enableVideoRecording, 'NSPhotoLibraryUsageDescription', `${config.appName} lets you choose photos and videos from your library.`],
    [config.enableGeolocation || config.enableBackgroundLocation, 'NSLocationWhenInUseUsageDescription', `${config.appName} uses your location while you record an activity.`],
    [config.enableBackgroundLocation, 'NSLocationAlwaysAndWhenInUseUsageDescription', `${config.appName} continues recording your route when the screen is locked or the app is in the background.`],
    [config.enableContacts, 'NSContactsUsageDescription', `${config.appName} accesses contacts only when you choose a contact feature.`],
    [config.enableCalendar, 'NSCalendarsUsageDescription', `${config.appName} accesses your calendar only when you choose a calendar feature.`],
    [config.enableBluetooth, 'NSBluetoothAlwaysUsageDescription', `${config.appName} uses Bluetooth to connect to nearby devices.`],
    [config.enableMotionSensors, 'NSMotionUsageDescription', `${config.appName} uses motion data for activity features.`],
    [config.enableNFC, 'NFCReaderUsageDescription', `${config.appName} reads NFC tags when you start a scan.`],
    [config.enableHealthKit, 'NSHealthShareUsageDescription', `${config.appName} reads health data you choose to share.`],
    [config.enableHealthKit, 'NSHealthUpdateUsageDescription', `${config.appName} writes health data only with your permission.`],
    [config.enableBiometric, 'NSFaceIDUsageDescription', `${config.appName} uses Face ID to protect your account.`],
  ]

  return entries
    .filter(([enabled]) => enabled)
    .map(([, key, value]) => plistString(key, value))
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
  if (config.enableBackgroundLocation) modes.add('location')
  if (config.enableBackgroundTasks) modes.add('processing')
  if (config.enablePushNotifications) modes.add('remote-notification')
  if (!modes.size) return ''

  return `    <key>UIBackgroundModes</key>\n    <array>\n${plistArray([...modes])}\n    </array>`
}

export function renderEntitlements(config: CraftConfig): string {
  const entries: string[] = []
  if (config.associatedDomains?.length) {
    entries.push(`    <key>com.apple.developer.associated-domains</key>\n    <array>\n${plistArray(config.associatedDomains)}\n    </array>`)
  }
  if (config.appGroups?.length) {
    entries.push(`    <key>com.apple.security.application-groups</key>\n    <array>\n${plistArray(config.appGroups)}\n    </array>`)
  }
  if (config.enableHealthKit) {
    entries.push('    <key>com.apple.developer.healthkit</key>\n    <true/>')
  }
  if (config.enablePushNotifications) {
    entries.push('    <key>aps-environment</key>\n    <string>development</string>')
  }

  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${entries.join('\n')}\n</dict>\n</plist>\n`
}

export function renderWatchEntitlements(config: CraftConfig): string {
  const appGroups = config.appGroups?.length
    ? `    <key>com.apple.security.application-groups</key>\n    <array>\n${plistArray(config.appGroups)}\n    </array>\n`
    : ''
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${appGroups}</dict>\n</plist>\n`
}

export function renderPrivacyManifest(config: CraftConfig): string {
  const privacy = config.privacy ?? {}
  const collected = privacy.collectedDataTypes ?? []
  const accessed = privacy.accessedApiTypes ?? []
  const collectedXml = collected.map(item => `        <dict>\n            <key>NSPrivacyCollectedDataType</key>\n            <string>${xmlEscape(item.type)}</string>\n            <key>NSPrivacyCollectedDataTypeLinked</key>\n            <${item.linked ? 'true' : 'false'}/>\n            <key>NSPrivacyCollectedDataTypeTracking</key>\n            <${item.tracking ? 'true' : 'false'}/>\n            <key>NSPrivacyCollectedDataTypePurposes</key>\n            <array>\n${plistArray(item.purposes, 4)}\n            </array>\n        </dict>`).join('\n')
  const accessedXml = accessed.map(item => `        <dict>\n            <key>NSPrivacyAccessedAPIType</key>\n            <string>${xmlEscape(item.type)}</string>\n            <key>NSPrivacyAccessedAPITypeReasons</key>\n            <array>\n${plistArray(item.reasons, 4)}\n            </array>\n        </dict>`).join('\n')

  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n    <key>NSPrivacyTracking</key>\n    <${privacy.tracking ? 'true' : 'false'}/>\n    <key>NSPrivacyTrackingDomains</key>\n    <array>\n${plistArray(privacy.trackingDomains ?? [])}\n    </array>\n    <key>NSPrivacyCollectedDataTypes</key>\n    <array>\n${collectedXml}\n    </array>\n    <key>NSPrivacyAccessedAPITypes</key>\n    <array>\n${accessedXml}\n    </array>\n</dict>\n</plist>\n`
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
    cpSync(config.appIconPath, join(appIcon, iconFilename!))
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

  const color = config.backgroundColor?.replace(/^#/, '') || '000000'
  const normalized = color.length === 3 ? [...color].map(value => `${value}${value}`).join('') : color.padEnd(6, '0').slice(0, 6)
  const components = [0, 2, 4].map(index => (Number.parseInt(normalized.slice(index, index + 2), 16) / 255).toFixed(3))
  writeFileSync(join(launchBackground, 'Contents.json'), `${JSON.stringify({
    colors: [{
      color: {
        'color-space': 'srgb',
        components: { alpha: '1.000', blue: components[2], green: components[1], red: components[0] },
      },
      idiom: 'universal',
    }],
    info: { author: 'xcode', version: 1 },
  }, null, 2)}\n`)
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
export async function init(options: InitOptions): Promise<void> {
  const { name, bundleId, teamId, output } = options

  console.log(`\n⚡ Initializing Craft iOS project: ${name}`)
  console.log(`   Output: ${output}\n`)

  // Create directory structure
  const dirs = [output, join(output, 'Sources'), join(output, 'Shared'), join(output, 'dist')]
  if (options.config?.enableWatchApp) dirs.push(join(output, 'WatchApp'))
  for (const dir of dirs) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
    }
  }

  // Generate bundle ID from name if not provided
  const finalBundleId = bundleId || `com.craft.${name.toLowerCase().replace(/[^a-z0-9]/g, '')}`
  const bundleIdPrefix = finalBundleId.split('.').slice(0, -1).join('.')

  // Create craft.config.json
  const config: CraftConfig = {
    ...DEFAULT_CONFIG,
    appName: name,
    bundleId: finalBundleId,
    teamId: teamId || '',
    ...options.config,
  }
  if (config.enableBackgroundLocation) config.enableGeolocation = true

  writeFileSync(join(output, 'craft.config.json'), JSON.stringify(config, null, 2))

  // Copy and customize Swift template
  const swiftTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftApp.swift'), 'utf-8')
  const swiftSource = swiftTemplate
    .replace(/CraftApp/g, `${name}App`)
    .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
  writeFileSync(join(output, 'Sources', `${name}App.swift`), swiftSource)

  // Generate Info.plist
  const infoPlistTemplate = readFileSync(join(TEMPLATES_DIR, 'Info.plist.template'), 'utf-8')
  const infoPlist = infoPlistTemplate
    .replace(/\{\{APP_NAME\}\}/g, name)
    .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
    .replace(/\{\{VERSION\}\}/g, config.version || '1.0.0')
    .replace(/\{\{BUILD_NUMBER\}\}/g, config.buildNumber || '1')
    .replace(/\{\{UI_STYLE\}\}/g, config.darkMode ? 'Dark' : 'Light')
    .replace(/\{\{ORIENTATIONS\}\}/g, renderOrientations(config))
    .replace(/\{\{USAGE_DESCRIPTIONS\}\}/g, renderUsageDescriptions(config))
    .replace(/\{\{URL_TYPES\}\}/g, renderUrlTypes(config))
    .replace(/\{\{BACKGROUND_MODES\}\}/g, renderBackgroundModes(config))
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
      PRODUCT_BUNDLE_IDENTIFIER: ${finalBundleId}.liveactivity
      SWIFT_VERSION: "5.0"
      APPLICATION_EXTENSION_API_ONLY: YES
      SKIP_INSTALL: YES`)
  }
  if (config.enableWatchApp) {
    nativeTargets.push(`  ${name}Watch:
    type: application
    platform: watchOS
    deploymentTarget: "${config.watchosVersion || '9.0'}"
    sources:
      - WatchApp
    settings:
      INFOPLIST_FILE: WatchApp/Info.plist
      CODE_SIGN_ENTITLEMENTS: WatchApp/Watch.entitlements
      PRODUCT_BUNDLE_IDENTIFIER: ${finalBundleId}.watchkitapp
      SWIFT_VERSION: "5.0"
      SKIP_INSTALL: YES`)
  }

  const projectYml = projectYmlTemplate
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
  cpSync(join(TEMPLATES_DIR, 'CraftActivityAttributes.swift'), join(output, 'Shared', 'CraftActivityAttributes.swift'))
  if (config.enableLiveActivities) {
    mkdirSync(join(output, 'WidgetExtension'), { recursive: true })
    const widgetSource = readFileSync(join(TEMPLATES_DIR, 'CraftLiveActivityWidget.swift.template'), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, name)
    writeFileSync(join(output, 'WidgetExtension', `${name}LiveActivity.swift`), widgetSource)
    const widgetInfo = readFileSync(join(TEMPLATES_DIR, 'WidgetExtension.Info.plist'), 'utf8')
    writeFileSync(join(output, 'WidgetExtension', 'Info.plist'), widgetInfo)
  }
  if (config.enableWatchApp) {
    const watchSource = readFileSync(join(TEMPLATES_DIR, 'CraftWatchApp.swift.template'), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, name)
    writeFileSync(join(output, 'WatchApp', `${name}WatchApp.swift`), watchSource)
    const watchInfo = readFileSync(join(TEMPLATES_DIR, 'WatchApp.Info.plist.template'), 'utf8')
      .replace(/\{\{APP_NAME\}\}/g, name)
      .replace(/\{\{BUNDLE_ID\}\}/g, finalBundleId)
    writeFileSync(join(output, 'WatchApp', 'Info.plist'), watchInfo)
    writeFileSync(join(output, 'WatchApp', 'Watch.entitlements'), renderWatchEntitlements(config))
  }

  // Create placeholder index.html
  const placeholderHtml = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="viewport-fit=cover, width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>${name}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, system-ui, sans-serif;
      background: ${config.backgroundColor};
      color: white;
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
      padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
    }
    .container { text-align: center; padding: 2rem; }
    h1 { font-size: 2.5rem; margin-bottom: 1rem; }
    p { opacity: 0.7; }
    .ready { color: #4ade80; font-size: 0.9rem; margin-top: 2rem; }
  </style>
</head>
<body>
  <div class="container">
    <h1>⚡ ${name}</h1>
    <p>Built with Craft iOS</p>
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

  writeFileSync(join(output, 'dist', 'index.html'), placeholderHtml)

  console.log('✅ Project initialized')
  console.log('')
  console.log('Next steps:')
  console.log(`  1. cd ${output}`)
  console.log('  2. Add your web content to dist/index.html')
  console.log('  3. Run: craft ios build')
  console.log('  4. Run: craft ios open')
  console.log('')
}

/**
 * Build web assets and generate Xcode project
 */
export async function build(options: BuildOptions): Promise<void> {
  const { htmlPath, devServer, output, generateProject = true } = options

  console.log('\n📦 Building Craft iOS project...')

  // Load config
  const configPath = join(output, 'craft.config.json')
  if (!existsSync(configPath)) {
    throw new Error(`No craft.config.json found in ${output}. Run 'craft ios init' first.`)
  }

  const config: CraftConfig = JSON.parse(readFileSync(configPath, 'utf-8'))

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

  if (!generateProject) return

  // Generate Xcode project using xcodegen
  try {
    const result = await $`which xcodegen`.quiet()
    if (result.exitCode === 0) {
      console.log('   Running xcodegen...')
      await $`cd ${output} && xcodegen generate`.quiet()
      console.log(`✅ Xcode project created: ${config.appName}.xcodeproj`)
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
 * Every available simulator, newest runtime first, iPhones before iPads.
 *
 * Exported because the choice is worth testing without a simulator present -
 * `pickSimulator` is the policy and this is the data it reads.
 */
export function orderSimulators(devices: SimulatorDevice[]): SimulatorDevice[] {
  return [...devices].sort((left, right) => {
    const booted = Number(right.state === 'Booted') - Number(left.state === 'Booted')
    if (booted !== 0)
      return booted

    const phone = Number(right.name.startsWith('iPhone')) - Number(left.name.startsWith('iPhone'))
    if (phone !== 0)
      return phone

    return right.runtime.localeCompare(left.runtime)
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

  return orderSimulators(devices)[0] ?? null
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
