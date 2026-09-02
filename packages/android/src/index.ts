/**
 * Craft Android Builder
 *
 * Generates native Android apps from web content using WebView.
 */

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { $ } from 'bun'

const TEMPLATES_DIR = join(dirname(import.meta.dir), 'templates')

export interface CraftAndroidConfig {
  appName: string
  packageName: string
  version?: string
  versionCode?: number
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
  enableBackgroundLocation?: boolean
  enableHealthConnect?: boolean
  enableKeepAwake?: boolean
  enableDeepLinks?: boolean
  urlSchemes?: string[]
  trustedOrigins?: string[]
  appIconPath?: string
  googleServicesFile?: string
  devServerURL?: string
  hasBundledFallback?: boolean
  minSdk?: number
  compileSdk?: number
  targetSdk?: number
}

export interface InitOptions {
  name: string
  packageName?: string
  output: string
  config?: Partial<CraftAndroidConfig>
}

export interface BuildOptions {
  htmlPath?: string
  devServer?: string
  output: string
  release?: boolean
  compile?: boolean
}

export interface OpenOptions {
  output: string
}

export interface RunOptions {
  device?: string
  output: string
}

const DEFAULT_CONFIG: Omit<CraftAndroidConfig, 'appName' | 'packageName'> = {
  version: '1.0.0',
  versionCode: 1,
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
  enableBackgroundLocation: false,
  enableHealthConnect: false,
  enableKeepAwake: false,
  enableDeepLinks: false,
  urlSchemes: [],
  trustedOrigins: [],
  minSdk: 26,
  compileSdk: 36,
  targetSdk: 35,
}

export function syncAndroidWebAssets(source: string, output: string): void {
  const sourcePath = resolve(source)
  if (!existsSync(sourcePath)) throw new Error(`Web asset path not found: ${source}`)
  const assetsDir = join(output, 'app/src/main/assets')
  const configPath = join(assetsDir, 'craft.config.json')
  const config = existsSync(configPath) ? readFileSync(configPath) : undefined
  rmSync(assetsDir, { recursive: true, force: true })
  mkdirSync(assetsDir, { recursive: true })
  if (statSync(sourcePath).isDirectory()) cpSync(sourcePath, assetsDir, { recursive: true })
  else cpSync(sourcePath, join(assetsDir, 'index.html'))
  if (!existsSync(join(assetsDir, 'index.html'))) throw new Error(`Web asset directory must contain index.html: ${source}`)
  if (config) writeFileSync(configPath, config)
}

export function renderAndroidPermissions(config: CraftAndroidConfig): string {
  const permissions = new Set(['android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE'])
  if (config.enableSpeechRecognition) permissions.add('android.permission.RECORD_AUDIO')
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
  if (config.enableHealthConnect) {
    permissions.add('android.permission.health.READ_STEPS')
    permissions.add('android.permission.health.READ_HEART_RATE')
    permissions.add('android.permission.health.READ_ACTIVE_CALORIES_BURNED')
    permissions.add('android.permission.health.READ_DISTANCE')
    permissions.add('android.permission.health.READ_EXERCISE')
    permissions.add('android.permission.health.WRITE_EXERCISE')
    permissions.add('android.permission.health.WRITE_ACTIVE_CALORIES_BURNED')
    permissions.add('android.permission.health.WRITE_DISTANCE')
  }
  return [...permissions].map(permission => `    <uses-permission android:name="${permission}" />`).join('\n')
}

export function renderAndroidDeepLinks(config: CraftAndroidConfig): string {
  if (!config.enableDeepLinks) return ''
  const schemes = [...new Set(config.urlSchemes?.map(value => value.trim()).filter(value => /^[a-z][a-z0-9+.-]*$/i.test(value)) ?? [])]
  return schemes.map(scheme => `            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="${scheme}" />
            </intent-filter>`).join('\n')
}

/**
 * Initialize a new Android project
 */
export async function init(options: InitOptions): Promise<void> {
  const { name, packageName, output } = options

  console.log(`\n⚡ Initializing Craft Android project: ${name}`)
  console.log(`   Output: ${output}\n`)

  // Generate package name from app name if not provided
  const finalPackageName = packageName || `com.craft.${name.toLowerCase().replace(/[^a-z0-9]/g, '')}`
  const packagePath = finalPackageName.replace(/\./g, '/')

  // Create directory structure
  const dirs = [
    output,
    join(output, 'app/src/main/java', packagePath),
    join(output, 'app/src/main/res/layout'),
    join(output, 'app/src/main/res/values'),
    join(output, 'app/src/main/res/drawable'),
    join(output, 'app/src/main/assets'),
    join(output, 'gradle/wrapper'),
  ]

  for (const dir of dirs) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
    }
  }

  // Create craft.config.json
  const config: CraftAndroidConfig = {
    ...DEFAULT_CONFIG,
    appName: name,
    packageName: finalPackageName,
    ...options.config,
  }
  if (config.enableBackgroundLocation) config.enableGeolocation = true

  writeFileSync(join(output, 'craft.config.json'), JSON.stringify(config, null, 2))
  writeFileSync(join(output, 'app/src/main/assets/craft.config.json'), JSON.stringify(config, null, 2))

  const hasGoogleServices = Boolean(config.googleServicesFile)
  if (config.googleServicesFile) {
    if (!existsSync(config.googleServicesFile)) throw new Error(`Google services file not found: ${config.googleServicesFile}`)
    cpSync(config.googleServicesFile, join(output, 'app/google-services.json'))
  }

  // Copy templates
  const mainActivityTemplate = readFileSync(join(TEMPLATES_DIR, 'MainActivity.kt.template'), 'utf-8')
  const mainActivity = mainActivityTemplate
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{APP_NAME\}\}/g, name)

  writeFileSync(join(output, 'app/src/main/java', packagePath, 'MainActivity.kt'), mainActivity)

  // Create CraftBridge.kt
  const craftBridgeTemplate = readFileSync(join(TEMPLATES_DIR, 'CraftBridge.kt.template'), 'utf-8')
  const craftBridge = craftBridgeTemplate
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
                    webView.evaluateJavascript("$callback && $callback($payload)", null)
                }
            } catch (error: Exception) {
                val payload = JSONObject.quote(error.message ?: "Firebase Cloud Messaging is not configured")
                webView.evaluateJavascript("window._craftPushReject && window._craftPushReject($payload)", null)
            }
        }`
      : `activity.runOnUiThread {
            webView.evaluateJavascript(
                "window._craftPushReject && window._craftPushReject('Push notifications are disabled')",
                null
            )
        }`)
  writeFileSync(join(output, 'app/src/main/java', packagePath, 'CraftBridge.kt'), craftBridge)
  const healthTemplate = readFileSync(join(
    TEMPLATES_DIR,
    config.enableHealthConnect ? 'CraftHealthConnect.kt.template' : 'CraftHealthConnectStub.kt.template',
  ), 'utf-8')
  writeFileSync(
    join(output, 'app/src/main/java', packagePath, 'CraftHealthConnect.kt'),
    healthTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
  )
  if (config.enableBackgroundLocation) {
    const serviceTemplate = readFileSync(join(TEMPLATES_DIR, 'LocationRecordingService.kt.template'), 'utf-8')
    writeFileSync(
      join(output, 'app/src/main/java', packagePath, 'LocationRecordingService.kt'),
      serviceTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
    )
  }

  // Create AndroidManifest.xml
  const manifestTemplate = readFileSync(join(TEMPLATES_DIR, 'AndroidManifest.xml.template'), 'utf-8')
  const manifest = manifestTemplate
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{APP_NAME\}\}/g, name)
    .replace(/\{\{PERMISSIONS\}\}/g, renderAndroidPermissions(config))
    .replace(/\{\{USES_CLEARTEXT\}\}/g, config.devServerURL?.startsWith('http://') ? 'true' : 'false')
    .replace(/\{\{DEEP_LINK_INTENT_FILTERS\}\}/g, renderAndroidDeepLinks(config))
    .replace(/\{\{BACKGROUND_SERVICE\}\}/g, config.enableBackgroundLocation
      ? '        <service android:name=".LocationRecordingService" android:exported="false" android:foregroundServiceType="location" android:stopWithTask="false" />'
      : '')
    .replace(/\{\{HEALTH_CONNECT_QUERIES\}\}/g, config.enableHealthConnect
      ? '    <queries>\n        <package android:name="com.google.android.apps.healthdata" />\n    </queries>'
      : '')
    .replace(/\{\{HEALTH_CONNECT_RATIONALE\}\}/g, config.enableHealthConnect
      ? `            <intent-filter>
                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
                <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
            </intent-filter>`
      : '')

  writeFileSync(join(output, 'app/src/main/AndroidManifest.xml'), manifest)

  // Create build.gradle.kts (project level)
  const projectGradleTemplate = readFileSync(join(TEMPLATES_DIR, 'build.gradle.kts.project.template'), 'utf-8')
  writeFileSync(join(output, 'build.gradle.kts'), projectGradleTemplate
    .replace(/\{\{GOOGLE_SERVICES_PLUGIN\}\}/g, hasGoogleServices ? '    id("com.google.gms.google-services") version "4.4.2" apply false' : ''))

  // Create build.gradle.kts (app level)
  const appGradleTemplate = readFileSync(join(TEMPLATES_DIR, 'build.gradle.kts.app.template'), 'utf-8')
  const appGradle = appGradleTemplate
    .replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName)
    .replace(/\{\{VERSION_NAME\}\}/g, config.version || '1.0.0')
    .replace(/\{\{VERSION_CODE\}\}/g, String(config.versionCode || 1))
    .replace(/\{\{MIN_SDK\}\}/g, String(config.minSdk || 24))
    .replace(/\{\{COMPILE_SDK\}\}/g, String(Math.max(config.compileSdk || 36, config.enableHealthConnect ? 36 : 1)))
    .replace(/\{\{TARGET_SDK\}\}/g, String(config.targetSdk || 35))
    .replace(/\{\{GOOGLE_SERVICES_PLUGIN\}\}/g, hasGoogleServices ? '    id("com.google.gms.google-services")' : '')
    .replace(/\{\{FIREBASE_MESSAGING_DEPENDENCY\}\}/g, config.enablePushNotifications
      ? '    implementation("com.google.firebase:firebase-messaging:24.1.0")'
      : '')
    .replace(/\{\{HEALTH_CONNECT_DEPENDENCIES\}\}/g, config.enableHealthConnect
      ? `    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")`
      : '')

  writeFileSync(join(output, 'app/build.gradle.kts'), appGradle)
  const proguardTemplate = readFileSync(join(TEMPLATES_DIR, 'proguard-rules.pro.template'), 'utf-8')
  writeFileSync(
    join(output, 'app/proguard-rules.pro'),
    proguardTemplate.replace(/\{\{PACKAGE_NAME\}\}/g, finalPackageName),
  )

  // Create settings.gradle.kts
  const settingsTemplate = readFileSync(join(TEMPLATES_DIR, 'settings.gradle.kts.template'), 'utf-8')
  const settings = settingsTemplate.replace(/\{\{APP_NAME\}\}/g, name)
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
    <string name="app_name">${name}</string>
</resources>
`
  writeFileSync(join(output, 'app/src/main/res/values/strings.xml'), stringsXml)

  const colorsXml = `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="primary">#1a1a2e</color>
    <color name="primary_dark">#16162b</color>
    <color name="accent">#4ade80</color>
    <color name="background">${config.backgroundColor}</color>
</resources>
`
  writeFileSync(join(output, 'app/src/main/res/values/colors.xml'), colorsXml)

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
    if (!existsSync(config.appIconPath)) throw new Error(`App icon not found: ${config.appIconPath}`)
    cpSync(config.appIconPath, join(output, 'app/src/main/res/drawable/craft_app_icon.png'))
  }
  else {
    writeFileSync(join(output, 'app/src/main/res/drawable/craft_app_icon.xml'), appIconXml)
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
  const activityMainXml = `<?xml version="1.0" encoding="utf-8"?>
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
    <h1>⚡ ${name}</h1>
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

  console.log('✅ Project initialized')
  console.log('')
  console.log('Next steps:')
  console.log(`  1. cd ${output}`)
  console.log('  2. Add your web content to app/src/main/assets/index.html')
  console.log('  3. Run: craft android build')
  console.log('  4. Run: craft android open')
  console.log('')
}

/**
 * Build Android project
 */
export async function build(options: BuildOptions): Promise<void> {
  const { htmlPath, devServer, output, release, compile = true } = options

  console.log('\n📦 Building Craft Android project...')

  // Load config
  const configPath = join(output, 'craft.config.json')
  if (!existsSync(configPath)) {
    throw new Error(`No craft.config.json found in ${output}. Run 'craft android init' first.`)
  }

  const config: CraftAndroidConfig = JSON.parse(readFileSync(configPath, 'utf-8'))

  // Update dev server URL if provided
  if (devServer) {
    config.devServerURL = devServer
    config.trustedOrigins = [...new Set([...(config.trustedOrigins ?? []), new URL(devServer).origin])]
    writeFileSync(configPath, JSON.stringify(config, null, 2))
    writeFileSync(join(output, 'app/src/main/assets/craft.config.json'), JSON.stringify(config, null, 2))
    console.log(`   Dev server: ${devServer}`)
  }

  // Copy the complete web application if provided.
  if (htmlPath) {
    syncAndroidWebAssets(htmlPath, output)
    config.hasBundledFallback = Boolean(devServer)
    writeFileSync(configPath, JSON.stringify(config, null, 2))
    writeFileSync(join(output, 'app/src/main/assets/craft.config.json'), JSON.stringify(config, null, 2))
    console.log(`   Synced: ${htmlPath} → assets/`)
  }

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
  const buildType = release ? 'assembleRelease' : 'assembleDebug'
  console.log(`   Building ${release ? 'release' : 'debug'} APK...`)

  try {
    await $`cd ${output} && ./gradlew ${buildType}`
    const apkPath = release
      ? 'app/build/outputs/apk/release/app-release.apk'
      : 'app/build/outputs/apk/debug/app-debug.apk'
    console.log(`✅ APK built: ${apkPath}`)
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
