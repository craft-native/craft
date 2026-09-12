import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import { build, init, renderAndroidDeepLinks, renderAndroidPermissions, syncAndroidWebAssets } from './index'

describe('Craft Android builder', () => {
  it('renders only permissions required by enabled capabilities', () => {
    const permissions = renderAndroidPermissions({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableGeolocation: true,
      enableCamera: false,
    })

    expect(permissions).toContain('android.permission.ACCESS_FINE_LOCATION')
    expect(permissions).not.toContain('android.permission.CAMERA')
  })

  it('registers configured deep-link schemes only when enabled', () => {
    expect(renderAndroidDeepLinks({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableDeepLinks: true,
      urlSchemes: ['wildloop', 'wildloop'],
    })).toContain('android:scheme="wildloop"')
    expect(renderAndroidDeepLinks({
      appName: 'WildLoop',
      packageName: 'org.wildloop.app',
      enableDeepLinks: false,
      urlSchemes: ['wildloop'],
    })).toBe('')
  })

  it('emits the native holder to a fixed package, whatever the app is called', async () => {
    // The prebuilt libcraft.so binds its natives by class name in JNI_OnLoad
    // and cannot know a package chosen here. So CraftNative lives at a path
    // that does not depend on the app, and CraftBridge — which does — reaches
    // it by import. If this file ever moves under packagePath, registration
    // stops finding the class and every action silently stays on the shim.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-native-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const holder = join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt')
    expect(existsSync(holder)).toBe(true)

    const source = readFileSync(holder, 'utf-8')
    expect(source).toContain('package com.craft.runtime')
    // Nothing here is substituted, and an unreplaced marker would mean it was
    // routed through the templating that rewrites CraftBridge.
    expect(source).not.toContain('{{')
    expect(source).not.toContain('org.wildloop.app')

    // And the generated bridge actually reaches it.
    const bridge = readFileSync(
      join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'),
      'utf-8',
    )
    expect(bridge).toContain('import com.craft.runtime.CraftNative')
    expect(bridge).toContain('CraftNative.getDeviceInfo(activity)?.let { return it }')
  })

  it('copies a complete web distribution while preserving native configuration', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-assets-'))
    const web = join(root, 'web')
    const output = join(root, 'android')
    Bun.spawnSync(['mkdir', '-p', join(web, 'assets')])
    writeFileSync(join(web, 'index.html'), '<main>WildLoop</main>')
    writeFileSync(join(web, 'assets', 'app.js'), 'export {}')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    syncAndroidWebAssets(web, output)

    expect(readFileSync(join(output, 'app/src/main/assets/index.html'), 'utf8')).toContain('WildLoop')
    expect(existsSync(join(output, 'app/src/main/assets/assets/app.js'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/assets/craft.config.json'))).toBe(true)
  })

  it('generates a least-privilege bridge contract and secure manifest', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-project-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableHaptics: true, enableGeolocation: true, enableDeepLinks: true, urlSchemes: ['wildloop'] },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(bridge).toContain("craft.contractVersion = '1.0.0'")
    expect(bridge).toContain('haptics: true')
    expect(bridge).toContain('camera: false')
    expect(manifest).toContain('android:allowBackup="false"')
    expect(manifest).toContain('android:usesCleartextTraffic="false"')
    expect(manifest).toContain('android:scheme="wildloop"')
    expect(bridge).toContain('fun setInitialURL')
    expect(readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')).toContain('WebViewAssetLoader')
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).toContain('androidx.webkit:webkit')
    expect(gradle).toContain('ignoreAssetsPattern')
    expect(gradle).not.toContain('<dir>_*')
    expect(readFileSync(join(output, 'app/proguard-rules.pro'), 'utf8')).toContain('android.webkit.JavascriptInterface')
  })

  it('marks bundled assets as the remote-app recovery path', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-fallback-'))
    const web = join(root, 'web')
    const output = join(root, 'android')
    Bun.spawnSync(['mkdir', '-p', web])
    writeFileSync(join(web, 'index.html'), '<main>Available offline</main>')
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })
    await build({ htmlPath: web, devServer: 'https://wildloop.org', output, compile: false })

    const config = JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8'))
    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    expect(config.hasBundledFallback).toBe(true)
    expect(activity).toContain('hasBundledFallback && !loadedBundledFallback')
  })

  it('generates a foreground service for durable background recording', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-location-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableBackgroundLocation: true },
    })

    const service = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/LocationRecordingService.kt'), 'utf8')
    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(service).toContain('START_STICKY')
    expect(service).toContain('CraftLocationRecordingStore.append')
    expect(bridge).toContain('startRecording: function(options)')
    expect(bridge).toContain('fun stopLocationRecording()')
    expect(manifest).toContain('android:foregroundServiceType="location"')
  })

  it('uses Firebase Cloud Messaging instead of placeholder push tokens', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-push-'))
    const output = join(root, 'android')
    const googleServicesFile = join(root, 'google-services.json')
    writeFileSync(googleServicesFile, JSON.stringify({ project_info: { project_number: '1' } }))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enablePushNotifications: true, googleServicesFile },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const appGradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    const projectGradle = readFileSync(join(output, 'build.gradle.kts'), 'utf8')
    expect(bridge).toContain('FirebaseMessaging.getInstance().token')
    expect(bridge).not.toContain('push-token-placeholder')
    expect(bridge).not.toContain('?: \\"Review flow failed\\"')
    expect(appGradle).toContain('com.google.firebase:firebase-messaging')
    expect(appGradle).toContain('id("com.google.gms.google-services")')
    expect(projectGradle).toContain('id("com.google.gms.google-services")')
    expect(existsSync(join(output, 'app/google-services.json'))).toBe(true)
  })

  it('declares the libraries used by the generated bridge', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-dependencies-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(gradle).toContain('androidx.fragment:fragment-ktx')
    expect(gradle).toContain('com.google.mlkit:barcode-scanning')
    expect(gradle).toContain('com.google.mlkit:image-labeling')
    expect(gradle).toContain('com.google.mlkit:object-detection')
    expect(gradle).toContain('com.google.mlkit:text-recognition')
  })

  it('rejects Bluetooth scans that never reach the platform scanner', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-bluetooth-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(bridge).not.toContain('bluetoothScanner?.startScan')
    expect(holder).not.toContain('bleScanner?.startScan')
    for (const message of [
      'Bluetooth is unavailable on this device',
      'Bluetooth is switched off',
      'Bluetooth permission denied',
      'Bluetooth LE scanning is unavailable',
      'Bluetooth scan could not start',
    ]) {
      expect(bridge).toContain(message)
    }
    expect(holder).toContain('fun startBluetoothWatch(activity: Activity): Int')
    expect(holder).toContain('scanner.startScan(callback)')
    expect(holder).toContain('BLUETOOTH_STARTED')
  })

  it('keeps repeated network-monitoring starts idempotent', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-network-watch-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(bridge).toContain('if (networkCallback != null) return')
    expect(bridge).toContain('connectivityManager.registerNetworkCallback(request, callback)')
    expect(bridge).toContain('networkCallback = callback')
    expect(holder).toContain('if (networkWatch != null) return')
    expect(holder).toContain('manager.registerNetworkCallback(request, watch)')
    expect(holder).toContain('networkWatch = watch')
  })

  it('keeps every location watch addressable by its returned id', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-location-watch-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).toContain('private val locationCallbacks = mutableMapOf<Int, LocationCallback>()')
    expect(bridge).toContain('locationCallbacks[currentWatchId] = callback')
    expect(bridge).toContain('locationCallbacks.remove(watchId)?.let')
    expect(bridge).toContain('requestLocationUpdates(locationRequest, callback, Looper.getMainLooper())')
    expect(bridge).not.toContain('private var locationCallback: LocationCallback?')
    expect(bridge).not.toContain('locationCallback = object : LocationCallback()')
  })

  it('rejects background-task methods instead of fabricating success', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-background-tasks-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Background Tasks ====================')
    const end = bridge.indexOf('// ==================== PDF Viewer ====================', start)
    const backgroundTasks = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(backgroundTasks.match(/rejectBackgroundTask\(/g)?.length).toBe(5)
    expect(backgroundTasks).toContain('Background task $taskId is unavailable on Android')
    expect(backgroundTasks).toContain('Background tasks are unavailable on Android')
    expect(backgroundTasks).not.toContain('registered: true')
    expect(backgroundTasks).not.toContain('scheduled: true')
    expect(backgroundTasks).not.toContain('cancelled: true')
    expect(backgroundTasks).not.toContain('This is a placeholder that shows the API structure')
  })

  it('rejects malformed data URLs before resolving a saved-file path', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-save-file-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).toContain('if (parts.size != 2)')
    expect(bridge).toContain('rejectSaveFile("Malformed data URL")')
    expect(bridge).toContain('private fun rejectSaveFile(message: String?)')
    expect(bridge).not.toContain('if (parts.size == 2)')
  })

  it('omits unreachable dynamic voice-action registration', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-voice-actions-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')

    expect(bridge).not.toContain('fun registerVoiceAction(')
    expect(bridge).not.toContain('fun removeVoiceAction(')
    expect(bridge).not.toContain('craft_voice_actions')
    expect(bridge).not.toContain('_craftVoiceResolve')
    expect(bridge).toContain('fun handleVoiceAction(intent: Intent?)')
    expect(bridge).toContain("new CustomEvent('craftVoiceAction'")
  })

  it('generates Health Connect permissions, APIs, and workout write-back only when enabled', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-health-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableHealthConnect: true },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const health = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftHealthConnect.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
    expect(bridge).toContain('health: true')
    expect(bridge).toContain('saveHealthWorkout')
    expect(health).toContain('HealthConnectClient')
    expect(health).toContain('ExerciseSessionRecord')
    expect(manifest).toContain('android.permission.health.WRITE_EXERCISE')
    expect(manifest).toContain('com.google.android.apps.healthdata')
    expect(manifest).toContain('android.intent.category.HEALTH_PERMISSIONS')
    expect(gradle).toContain('androidx.health.connect:connect-client')
    expect(gradle).toContain('compileSdk = 36')
  })
})
