import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import { build, init, renderAndroidDeepLinks, renderAndroidPermissions, syncAndroidWebAssets } from './index'

function generatedFiles(path: string): string[] {
  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = join(path, entry.name)
    return entry.isDirectory() ? generatedFiles(entryPath) : [entryPath]
  })
}

describe('Craft Android builder', () => {
  it('routes every Kotlin template through the project generator', () => {
    const templates = readdirSync(join(import.meta.dir, '../templates'))
      .filter(name => name.endsWith('.kt.template'))
    const generator = readFileSync(join(import.meta.dir, 'index.ts'), 'utf8')

    for (const template of templates) expect(generator).toContain(`'${template}'`)
  })

  it('resolves every marker in a generated project', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-template-markers-'))
    await init({ name: 'Marker Check', packageName: 'dev.craft.markers', output })

    const unresolved = generatedFiles(output).filter((path) => {
      return /\{\{[A-Z0-9_]+\}\}/.test(readFileSync(path, 'utf8'))
    })
    expect(unresolved).toEqual([])
  })

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

  it('normalizes deep links and remote origins to the runtime trust contract', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-network-config-'))
    await init({
      name: 'Remote App',
      output,
      config: {
        devServerURL: 'https://app.example.com/nested/path',
        enableDeepLinks: true,
        trustedOrigins: ['https://cdn.example.com/path', 'https://cdn.example.com'],
        urlSchemes: [' Craft+Preview ', 'craft+preview'],
      },
    })

    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.devServerURL).toBe('https://app.example.com/nested/path')
    expect(config.trustedOrigins).toEqual(['https://cdn.example.com', 'https://app.example.com'])
    expect(config.urlSchemes).toEqual(['craft+preview'])
    expect(readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8'))
      .toContain('android:scheme="craft+preview"')
  })

  it('rejects metadata that would produce an invalid Android project', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-invalid-'))

    await expect(init({ name: 'Bad Package', packageName: 'dev.when.app', output }))
      .rejects.toThrow('Invalid Android package name')
    await expect(init({
      name: 'Bad Color',
      output,
      config: { backgroundColor: 'transparent' },
    })).rejects.toThrow('Invalid Android background color')
    await expect(init({
      name: 'Bad SDKs',
      output,
      config: { compileSdk: 34, targetSdk: 35 },
    })).rejects.toThrow('targetSdk must not exceed compileSdk')
    await expect(init({
      name: 'Missing Deep Link',
      output,
      config: { enableDeepLinks: true },
    })).rejects.toThrow('deep links require at least one URL scheme')
    await expect(init({
      name: 'Insecure Remote',
      output,
      config: { devServerURL: 'http://example.com' },
    })).rejects.toThrow('must use HTTPS or local HTTP')
    await expect(init({
      name: 'Missing Firebase Config',
      output,
      config: { enablePushNotifications: true },
    })).rejects.toThrow('push notifications require a googleServicesFile')
    const unsupportedIcon = join(output, 'icon.svg')
    writeFileSync(unsupportedIcon, '<svg/>')
    await expect(init({
      name: 'Unsupported Icon',
      output: join(output, 'unsupported-icon-app'),
      config: { appIconPath: unsupportedIcon },
    })).rejects.toThrow('Unsupported Android app icon format')
  })

  it('escapes user-facing metadata without changing generator-owned identity', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-metadata-'))
    await init({
      name: 'Rock & "Roll" $Build',
      packageName: 'dev.craft.metadata',
      output,
      config: {
        appName: 'Ignored config name',
        packageName: 'dev.ignored.package',
        version: '1.0 "preview" $build',
      },
    })

    expect(readFileSync(join(output, 'settings.gradle.kts'), 'utf8'))
      .toContain('rootProject.name = "Rock & -Roll- \\$Build"')
    expect(readFileSync(join(output, 'app/build.gradle.kts'), 'utf8'))
      .toContain('versionName = "1.0 \\"preview\\" \\$build"')
    expect(readFileSync(join(output, 'app/src/main/res/values/strings.xml'), 'utf8'))
      .toContain('Rock &amp; &quot;Roll&quot; $Build')
    expect(readFileSync(join(output, 'app/src/main/assets/index.html'), 'utf8'))
      .toContain('<h1>⚡ Rock &amp; &quot;Roll&quot; $Build</h1>')

    const generated = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(generated.appName).toBe('Rock & "Roll" $Build')
    expect(generated.packageName).toBe('dev.craft.metadata')
  })

  it('preserves a supported custom launcher icon format', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-icon-'))
    const icon = join(root, 'launcher.webp')
    const output = join(root, 'android')
    writeFileSync(icon, 'fixture webp bytes')
    await init({ name: 'Icon App', output, config: { appIconPath: icon } })

    expect(existsSync(join(output, 'app/src/main/res/drawable/craft_app_icon.webp'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/res/drawable/craft_app_icon.png'))).toBe(false)
    expect(JSON.parse(readFileSync(
      join(output, 'app/src/main/assets/craft.config.json'),
      'utf8',
    ))).not.toHaveProperty('appIconPath')
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
    const proguard = readFileSync(join(output, 'app/proguard-rules.pro'), 'utf8')
    expect(proguard).toContain('android.webkit.JavascriptInterface')
    expect(proguard).toContain('-keep class com.craft.runtime.CraftNative { *; }')
    expect(proguard).toContain('com.craft.runtime.LocationRecordingService')
    expect(proguard).not.toContain('org.wildloop.app.LocationRecordingService')
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

  it('delivers shortcut activations and refuses impossible event streams', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-shortcut-events-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    expect(activity).toContain('handleIncomingShortcut(intent)')
    expect(activity).toContain('getStringExtra(SHORTCUT_TYPE_EXTRA)')
    expect(activity).toContain('craftBridge.markBridgeLoading()')
    expect(bridge).toContain('sendEvent("craftShortcut", data)')
    expect(bridge).toContain('pendingEvents.add("craftShortcut" to data)')
    expect(bridge).not.toContain("addEventListener('craftOTAProgress'")
    expect(bridge).not.toContain("addEventListener('craftOTAStatus'")
    expect(bridge).not.toContain("addEventListener('craftARPlane'")
    expect(bridge).toContain('craft.ar.onPlaneDetected is unavailable because ARCore requires native Activity integration')
  })

  it('routes external Activity results back to every pending media promise', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-activity-results-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const request of ['REQUEST_CAMERA, REQUEST_GALLERY', 'REQUEST_FILE_PICKER', 'REQUEST_VIDEO', 'REQUEST_PICK_CONTACT']) {
      expect(bridge).toContain(request)
    }
    expect(bridge).toContain('handleImageResult(requestCode, resultCode, data)')
    expect(bridge).toContain('handleFilePickerResult(resultCode, data)')
    expect(bridge).toContain('handleVideoResult(resultCode, data)')
    expect(bridge).toContain('handleContactPickerResult(resultCode, data)')
    expect(bridge).toContain('window._craftVideoResolve && window._craftVideoResolve')
    expect(bridge).toContain('val result = "data:$mimeType;base64,$encoded"')
    expect(bridge).toContain('window._craftFileResolve && window._craftFileResolve($result)')
    expect(bridge).toContain('resolveMediaPromise(promise, "data:$mimeType;base64,$encoded")')
    expect(bridge).toContain('rejectMediaPromise(promise, "Camera returned no image")')
    expect(bridge).toContain('else -> healthConnect.onActivityResult(requestCode, resultCode, data)')
  })

  it('exposes native Android permission checks, requests, and settings', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-permissions-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    const service = join(output, 'app/src/main/java/com/craft/runtime/LocationRecordingService.kt')

    expect(bridge).toContain('craft.permissions = {')
    expect(bridge).toContain('CraftAndroid.checkPermission(String(permission))')
    expect(bridge).toContain('CraftAndroid.requestPermission(String(permission), id)')
    expect(bridge).toContain('group.any(isGranted)')
    expect(bridge).toContain('CraftPermissionPolicy.nextRequest(')
    expect(bridge).toContain('pending.groupIndex + 1')
    expect(bridge).toContain('nativePermissionStatus(pending.permission)')
    expect(bridge).toContain('CraftPermissionPolicy.foregroundLocationIsGranted(::isPermissionGranted)')
    expect(bridge.match(/if \(!hasForegroundLocationPermission\(\)\)/g)?.length).toBe(4)
    expect(bridge).toContain('if (hasForegroundLocationPermission())')
    expect(bridge).not.toContain('grantResults.all { it == PackageManager.PERMISSION_GRANTED }')
    expect(bridge).toContain('fun onRequestPermissionsResult(requestCode: Int): Boolean')
    expect(bridge).toContain('Settings.ACTION_APPLICATION_DETAILS_SETTINGS')
    expect(existsSync(service)).toBe(true)
    const serviceSource = readFileSync(service, 'utf8')
    expect(serviceSource).toContain('package com.craft.runtime')
    expect(serviceSource).toContain('Manifest.permission.ACCESS_COARSE_LOCATION')
    expect(activity).toContain('craftBridge.onRequestPermissionsResult(requestCode)')
  })

  it('generates a foreground service for durable background recording', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-location-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableBackgroundLocation: true },
    })

    const service = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/LocationRecordingService.kt'), 'utf8')
    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
    expect(service).toContain('START_STICKY')
    expect(service).toContain('CraftLocationRecordingStore.append')
    expect(bridge).toContain('startRecording: function(options)')
    expect(bridge).toContain('fun stopLocationRecording()')
    expect(manifest).toContain('android:name="com.craft.runtime.LocationRecordingService"')
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
    expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).googleServicesFile)
      .toBe(googleServicesFile)
    expect(JSON.parse(readFileSync(
      join(output, 'app/src/main/assets/craft.config.json'),
      'utf8',
    ))).not.toHaveProperty('googleServicesFile')
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

  it('settles location calls when Play Services is unavailable or silent', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-location-failure-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const appSource = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(appSource, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const native = readFileSync(join(appSource, 'com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(bridge).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(native).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(bridge).toContain("message: 'Google Play Services is unavailable'")
    expect(bridge).toContain("message: 'Location request timed out; Google Play Services or a location provider may be unavailable'")
    expect(bridge).toContain('}, 15000);')
    expect(native).toContain('failLocation("Google Play Services is unavailable")')
    expect(bridge).toContain('private val oneShotLocationCallbacks')
    expect(bridge).toContain('oneShotLocationCallbacks.remove(callback)')
    expect(bridge).toContain('rejectLocation(error.message ?: "Location request failed")')
    expect(native).toContain('private val currentLocationCallbacks')
    expect(native).toContain('currentLocationCallbacks.remove(callback)')
    expect(native).toContain('failLocation(error.message)')
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

  it('reports app badges unavailable instead of silently succeeding', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-app-badge-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// App Badge')
    const end = bridge.indexOf('// Network Status', start)
    const appBadge = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(bridge).toContain('appBadge: false')
    expect(appBadge.match(/throw new Error\('App badges are unavailable on Android'\)/g)?.length).toBe(2)
    expect(appBadge).not.toContain('CraftAndroid.setBadge')
    expect(appBadge).not.toContain('CraftAndroid.clearBadge')
    expect(bridge).not.toContain('fun setBadge(')
    expect(bridge).not.toContain('fun clearBadge(')
    expect(bridge).not.toContain('NotificationManagerCompat')
  })

  it('loads contacts with three projected provider queries', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-contacts-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Contacts ====================')
    const end = bridge.indexOf('// ==================== Calendar ====================', start)
    const contacts = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(contacts.match(/getContactValues\(/g)?.length).toBe(3)
    expect(contacts).toContain('arrayOf(\n                ContactsContract.Contacts._ID,')
    expect(contacts).toContain('arrayOf(contactIdColumn, valueColumn)')
    expect(contacts).not.toContain('fun getContactPhones(')
    expect(contacts).not.toContain('fun getContactEmails(')
    expect(contacts).not.toContain('CONTACT_ID + " = ?"')
  })

  it('persists local auth sessions in encrypted preferences', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-auth-persistence-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('// ==================== Local Auth Persistence ====================')
    const end = bridge.indexOf('// ==================== AR (ARCore) ====================', start)
    const authPersistence = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(authPersistence).toContain('private val authSessionExpiryKey = "craft_auth_session_expiry"')
    expect(authPersistence).toContain('securePrefs.edit().putLong(authSessionExpiryKey, expiresAt).apply()')
    expect(authPersistence).toContain('securePrefs.getLong(authSessionExpiryKey, 0L)')
    expect(authPersistence.match(/securePrefs\.edit\(\)\.remove\(authSessionExpiryKey\)\.apply\(\)/g)?.length).toBe(2)
    expect(authPersistence).not.toContain('private var authSessionExpiry')
  })

  it('releases long-lived bridge and native-holder resources on destroy', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-close-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'org/wildloop/app/MainActivity.kt'), 'utf8')
    const bridgeClose = bridge.slice(bridge.indexOf('fun close()'), bridge.indexOf('// ==================== Screen Capture'))
    const nativeClose = holder.slice(holder.indexOf('fun close(activity: Activity)'), holder.indexOf('/**\n     * Run `script`'))

    expect(activity).toContain('craftBridge.close()')
    for (const cleanup of [
      'CraftNative.close(activity)',
      'speechRecognizer?.destroy()',
      'fusedLocationClient?.removeLocationUpdates(callback)',
      'manager.unregisterNetworkCallback(callback)',
      'sensorManager?.unregisterListener(listener)',
      'bluetoothScanner?.stopScan(callback)',
      'billingClient?.endConnection()',
      'database?.close()',
      'setFlashlight(false)',
    ]) expect(bridgeClose).toContain(cleanup)
    for (const cleanup of [
      'deliverer = null',
      'speechRecognizer?.destroy()',
      'billingClient?.endConnection()',
      'manager.unregisterNetworkCallback(watch)',
      'bleScanner?.stopScan(callback)',
      'sensorManager?.unregisterListener(listener)',
    ]) expect(nativeClose).toContain(cleanup)
  })

  it('rejects calendar-provider failures instead of hanging the promise', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-calendar-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun getCalendarEvents(')
    const end = bridge.indexOf('fun createCalendarEvent(', start)
    const getEvents = bridge.slice(start, end)
    const tryStart = getEvents.indexOf('try {')
    const queryStart = getEvents.indexOf('activity.contentResolver.query(')

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(tryStart).toBeGreaterThan(-1)
    expect(queryStart).toBeGreaterThan(tryStart)
    expect(getEvents.match(/catch \(e: Exception\)/g)?.length).toBe(1)
    expect(getEvents).toContain('window._craftCalendarReject && window._craftCalendarReject(${jsQuote(e.message)})')
  })

  it('reports SQLite changed rows instead of a constant', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-database-count-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun dbExecute(')
    const end = bridge.indexOf('fun dbQuery(', start)
    const execute = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(execute).toContain('database!!.compileStatement(sql).use { statement ->')
    expect(execute).toContain('statement.bindString(index + 1, value)')
    expect(execute).toContain('statement.executeUpdateDelete()')
    expect(execute).toContain('{rowsAffected: $rowsAffected}')
    expect(execute).not.toContain('{rowsAffected: 1}')
    expect(execute).not.toContain('database?.execSQL(sql, args)')
  })

  it('generates Health Connect permissions, APIs, and workout write-back only when enabled', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-health-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { compileSdk: 34, enableHealthConnect: true, minSdk: 24 },
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
    expect(gradle).toContain('minSdk = 26')
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.compileSdk).toBe(36)
    expect(config.minSdk).toBe(26)
  })
})
