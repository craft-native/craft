import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import { build, init, installRuntime, renderAndroidDeepLinks, renderAndroidPermissions, resolveRuntimeDir, syncAndroidWebAssets } from './index'

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
    const googleServicesDirectory = join(output, 'google-services-directory')
    mkdirSync(googleServicesDirectory)
    await expect(init({
      name: 'Firebase Directory',
      output: join(output, 'firebase-directory-app'),
      config: { enablePushNotifications: true, googleServicesFile: googleServicesDirectory },
    })).rejects.toThrow('Google services file must be a file')
    const malformedGoogleServices = join(output, 'malformed-google-services.json')
    writeFileSync(malformedGoogleServices, '{')
    await expect(init({
      name: 'Malformed Firebase Config',
      packageName: 'dev.craft.malformed',
      output: join(output, 'malformed-firebase-app'),
      config: { enablePushNotifications: true, googleServicesFile: malformedGoogleServices },
    })).rejects.toThrow('Google services file must contain valid JSON')
    const mismatchedGoogleServices = join(output, 'mismatched-google-services.json')
    writeFileSync(mismatchedGoogleServices, JSON.stringify({
      client: [{ client_info: { android_client_info: { package_name: 'dev.craft.other' } } }],
    }))
    await expect(init({
      name: 'Mismatched Firebase Config',
      packageName: 'dev.craft.expected',
      output: join(output, 'mismatched-firebase-app'),
      config: { enablePushNotifications: true, googleServicesFile: mismatchedGoogleServices },
    })).rejects.toThrow('has no client for Android package dev.craft.expected')
    const unsupportedIcon = join(output, 'icon.svg')
    writeFileSync(unsupportedIcon, '<svg/>')
    await expect(init({
      name: 'Unsupported Icon',
      output: join(output, 'unsupported-icon-app'),
      config: { appIconPath: unsupportedIcon },
    })).rejects.toThrow('Unsupported Android app icon format')
    const iconDirectory = join(output, 'icon.webp')
    mkdirSync(iconDirectory)
    await expect(init({
      name: 'Icon Directory',
      output: join(output, 'icon-directory-app'),
      config: { appIconPath: iconDirectory },
    })).rejects.toThrow('App icon must be a file')
    const outputFile = join(output, 'occupied-output')
    writeFileSync(outputFile, 'not a directory')
    await expect(init({ name: 'Occupied Output', output: outputFile }))
      .rejects.toThrow('Android project output must be a directory')
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

  it('rejects unsafe web asset sources before replacing generated assets', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-asset-guard-'))
    const output = join(root, 'android')
    const incompleteWeb = join(root, 'incomplete-web')
    mkdirSync(incompleteWeb)
    writeFileSync(join(incompleteWeb, 'app.js'), 'export {}')
    await init({ name: 'Asset Guard', packageName: 'dev.craft.assets', output })

    const generatedIndex = join(output, 'app/src/main/assets/index.html')
    const initialHtml = readFileSync(generatedIndex, 'utf8')
    expect(() => syncAndroidWebAssets(incompleteWeb, output))
      .toThrow('Web asset directory entry point not found')
    expect(readFileSync(generatedIndex, 'utf8')).toBe(initialHtml)

    const generatedAssets = join(output, 'app/src/main/assets')
    expect(() => syncAndroidWebAssets(generatedAssets, output))
      .toThrow('Web asset source must not overlap generated asset directory')
    expect(() => syncAndroidWebAssets(output, output))
      .toThrow('Web asset source must not overlap generated asset directory')
    expect(readFileSync(generatedIndex, 'utf8')).toBe(initialHtml)
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
    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    expect(activity).toContain('WebViewAssetLoader')
    expect(activity).toContain('if (origin == BUNDLED_APP_ORIGIN) return true')
    expect(activity).not.toContain('uri.host == BUNDLED_APP_HOST')
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

    // #254: only a main-frame connectivity failure may hide the remote page
    // behind the bundled copy. TLS, authentication, and bad-response failures
    // must remain visible instead of looking like a successful offline launch.
    const failureHandler = activity.slice(
      activity.indexOf('override fun onReceivedError('),
      activity.indexOf('webView.webChromeClient = WebChromeClient()'),
    )
    expect(failureHandler).toContain('CraftLoadFailure.isUnreachable(error.errorCode)')
    expect(failureHandler).not.toContain('hasBundledFallback && !loadedBundledFallback')

    // Falling back is no longer one-way. Bound the assertion to the named
    // recovery method so the field declaration cannot make this pass alone.
    const recovery = activity.slice(
      activity.indexOf('private fun returnFromBundledFallback('),
      activity.indexOf('private fun loadContent()'),
    )
    expect(recovery).toContain('loadedBundledFallback = false')
    expect(recovery).toContain('webView.loadUrl(remoteUrl)')

    expect(activity).toContain('returnFromBundledFallback("the app returned to the foreground")')
    expect(activity).toContain('val wasConnected = isConnected')
    expect(activity).toContain('if (!wasConnected && isConnected) {')
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

  it('queues deep links until the bridge is injected, and marks only the launch link initial', async () => {
    // #215: the launch link used to go only to getInitialURL, and a warm link
    // replaced the launch link as getInitialURL's answer.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-deep-links-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java/org/wildloop/app')
    const bridge = readFileSync(join(sourceRoot, 'CraftBridge.kt'), 'utf8')
    const activity = readFileSync(join(sourceRoot, 'MainActivity.kt'), 'utf8')
    const holder = readFileSync(join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'), 'utf8')

    expect(activity).not.toContain('dispatch = false')
    expect(activity).toContain('intent.data?.toString()?.let(craftBridge::receiveDeepLink)')
    expect(activity).toContain('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY')
    expect(activity).toContain('intent.data?.toString()?.let(craftBridge::receiveDeepLink)')
    // A recreated activity restores what the bridge saved, not getIntent(),
    // which onNewIntent may have replaced with a warm link.
    expect(activity).toContain('craftBridge.saveDeepLinks(outState)')
    expect(activity).toContain('craftBridge.restoreDeepLinks(savedInstanceState)')

    // Flushed in the injection's completion, after the page's replay exists.
    const injected = bridge.slice(bridge.indexOf('webView.evaluateJavascript(onlyOnce(script)) {'))
    const flush = injected.slice(0, injected.indexOf('fun markBridgeLoading()'))
    expect(flush.indexOf('bridgeReady = true')).toBeLessThan(flush.indexOf('links.forEach { (url, initial) -> dispatchDeepLink(url, initial) }'))

    expect(bridge).toContain('val initial = !hasBeenReady && !initialAssigned')
    expect(bridge).toContain('put("initial", initial)')
    expect(bridge).not.toContain('if (initialURL == null)')
    expect(bridge).toContain('pendingDeepLinks.clear()\n    }')
    expect(holder).toContain('private external fun nativeDispatchDeepLink(url: String, initial: Boolean): Boolean')
  })

  it('enforces the capability flags it reports, in the page and in Kotlin', async () => {
    // #209: the flags shaped the manifest and craft.capabilities, and then
    // every call was served anyway.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-capability-gate-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output, config: { enableShare: true } })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('installCapabilityGates')
    expect(bridge).toContain("error.code = 'CAPABILITY_DISABLED'")
    // The gate reads the object the page reads, so the two cannot disagree.
    expect(bridge).toContain('if (craft.capabilities[capability]) { return served.apply(this, arguments); }')
    // Generated from this app's config, not hardcoded.
    expect(bridge).toContain('private val shareEnabled = true')
    expect(bridge).toContain('private val hapticsEnabled = false')
    expect(bridge).toContain('if (!hapticsEnabled && disabled("haptics", "haptic")) return')
    expect(bridge).toContain('if (!keepAwakeEnabled && disabled("keepAwake", "setKeepAwake")) return false')
  })

  it('answers the page from haptic, vibrate and the speech calls', async () => {
    // #219: all four returned Unit, so the page got undefined where iOS
    // returns a promise, and a grant of RECORD_AUDIO went nowhere.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-feedback-answers-'))
    await init({
      name: 'WildLoop',
      packageName: 'org.wildloop.app',
      output,
      config: { enableHaptics: true, enableSpeechRecognition: true },
    })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const signature of [
      'fun haptic(style: String): Boolean',
      'fun vibrate(patternJson: String): Boolean',
      'fun startListening(): Boolean',
      'fun stopListening(): Boolean',
    ]) {
      expect(bridge).toContain(signature)
    }

    // The page reads that return value rather than dropping it.
    expect(bridge).toContain("return CraftAndroid.haptic(style || 'medium') === true;")
    expect(bridge).toContain('return CraftAndroid.startListening() === true;')

    // The microphone grant starts the recogniser, the way iOS starts from
    // inside its authorization callback, and a denial is not silence.
    expect(bridge).toContain('private fun beginSpeechRecognition()')
    expect(bridge).toContain('if (requestCode == REQUEST_SPEECH) {')
    expect(bridge).toContain('if (isPermissionGranted(Manifest.permission.RECORD_AUDIO)) beginSpeechRecognition()')
    expect(bridge).toContain('"Microphone permission denied"')

    // And stopping says the session ended, once, as iOS does.
    expect(bridge).toContain('sendEvent("craftSpeechEnd", emptyMap())')
  })

  it('marks ready only the page its injection ran in, and injects a document once', async () => {
    // #228, two halves. The evaluateJavascript completion is posted, so it
    // can land after the next navigation has started and mark a page that
    // was never injected as ready — flushing the deep-link and shortcut
    // queues into a document with no bridge. And onPageFinished arrives
    // without onPageStarted for a same-document navigation, so the script
    // could run twice in one document.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-injection-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('private var navigationGeneration = 0')
    expect(bridge).toContain('navigationGeneration += 1')
    expect(bridge).toContain('val generation = navigationGeneration')
    expect(bridge).toContain('if (generation != navigationGeneration) return@evaluateJavascript')
    // The generation is taken before the script is handed over, and compared
    // after; either order alone leaves the race open.
    expect(bridge.indexOf('val generation = navigationGeneration'))
      .toBeLessThan(bridge.indexOf('if (generation != navigationGeneration)'))

    expect(bridge).toContain('private fun onlyOnce(script: String): String')
    expect(bridge).toContain('evaluateJavascript(onlyOnce(script))')
    expect(bridge).toContain('if (!window.__craftBridgeInstalled)')
  })

  it('ignores the launch intent on a relaunch from Recents, and the saved one on a recreate', async () => {
    // #229, two halves. The shortcut path had no history check, so the
    // shortcut the app was first opened with was dispatched again every time
    // the task was reopened from Recents. And a recreated activity must read
    // what the bridge saved, not getIntent(), which onNewIntent replaces with
    // the latest warm link — that half landed with #232 and is pinned here so
    // it cannot quietly go back.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-recents-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output, config: { enableDeepLinks: true, urlSchemes: ['wildloop'] } })

    const activity = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/MainActivity.kt'), 'utf8')
    const onCreate = activity.slice(activity.indexOf('override fun onCreate'), activity.indexOf('private fun setupWebView'))

    // One flag, guarding both, rather than the link alone.
    expect(onCreate).toContain('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY')
    expect(onCreate.match(/launchedFromHistory/g)?.length).toBe(2)
    // Bounded by the block's own closing brace: a slice that ran to the end
    // of onCreate would still find a shortcut call that had moved back out.
    const guardStart = onCreate.indexOf('if (!launchedFromHistory) {')
    const guard = onCreate.slice(guardStart, onCreate.indexOf('\n            }', guardStart))
    expect(guard).toContain('craftBridge::receiveDeepLink')
    expect(guard).toContain('handleIncomingShortcut(intent)')
    // And exactly once, so it cannot also be dispatched outside the guard.
    expect(onCreate.match(/handleIncomingShortcut\(intent\)/g)?.length).toBe(1)

    // A genuinely new intent still carries both through.
    const onNewIntent = activity.slice(activity.indexOf('override fun onNewIntent'), activity.indexOf('override fun onBackPressed'))
    expect(onNewIntent).toContain('craftBridge::receiveDeepLink')
    expect(onNewIntent).toContain('handleIncomingShortcut(intent)')

    // And a recreate reads the bundle, never the intent.
    expect(onCreate).toContain('craftBridge.restoreDeepLinks(savedInstanceState)')
    expect(activity).toContain('craftBridge.saveDeepLinks(outState)')
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
    expect(bridge).toContain('if (closed) return requestCode == REQUEST_CAMERA')
    for (const handler of ['handleImageResult', 'handleFilePickerResult', 'handleVideoResult', 'handleContactPickerResult']) {
      const start = bridge.indexOf(`fun ${handler}(`)
      const end = bridge.indexOf('\n    }', start)
      expect(bridge.slice(start, end)).toContain('if (closed) return')
    }
    expect(bridge).toContain('private fun evaluatePromiseJavascript(script: String)')
  })

  it('settles camera calls that need permission or cannot launch', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-camera-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun openCamera()')
    const end = bridge.indexOf('fun pickImage()', start)
    const camera = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(camera.indexOf('checkSelfPermission')).toBeLessThan(camera.indexOf('CraftNative.openCamera'))
    expect(camera).toContain('Camera permission is required; retry after granting it')
    expect(camera.indexOf('rejectMediaPromise(')).toBeLessThan(camera.indexOf('requestPermissionsBestEffort('))
    expect(camera).toContain('catch (error: Exception)')
    expect(camera).toContain('Camera could not be opened')
  })

  it('passes file filters and settles failed media launchers', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-media-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).toContain('require(types.all { MIME_TYPE.matches(it) })')
    expect(bridge).toContain('putExtra(Intent.EXTRA_MIME_TYPES, requestedTypes.toTypedArray())')
    expect(bridge).toContain('if (requestedTypes.isEmpty() && CraftNative.pickFile(activity)) return')
    expect(bridge).toContain('rejectFilePicker(error.message ?: "File picker could not be opened")')
    expect(bridge).toContain('Image picker could not be opened')
    expect(bridge).toContain('Video capture could not be opened')
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
    expect(bridge.match(/ActivityCompat\.requestPermissions\(/g)?.length).toBe(2)
    expect(bridge).toContain('private fun requestPermissionsBestEffort(permissions: Array<String>, requestCode: Int)')
    expect(bridge).toContain('runCatching { ActivityCompat.requestPermissions(activity, permissions, requestCode) }')
    expect(bridge).toContain('group.any(isGranted)')
    expect(bridge).toContain('CraftPermissionPolicy.nextRequest(')
    expect(bridge).toContain('pendingPermissionRequests.remove(requestCode)')
    expect(bridge).toContain('catch (error: Exception)')
    expect(bridge).toContain('pending.groupIndex + 1')
    expect(bridge).toContain('nativePermissionStatus(pending.permission)')
    expect(bridge).toContain('CraftPermissionPolicy.foregroundLocationIsGranted(::isPermissionGranted)')
    expect(bridge.match(/if \(!hasForegroundLocationPermission\(\)\)/g)?.length).toBe(4)
    expect(bridge).toContain('if (hasForegroundLocationPermission())')
    expect(bridge).not.toContain('grantResults.all { it == PackageManager.PERMISSION_GRANTED }')
    expect(bridge).toContain('fun onRequestPermissionsResult(requestCode: Int): Boolean')
    expect(bridge).toContain('if (closed) return requestCode in PERMISSION_REQUEST_START..PERMISSION_REQUEST_END')
    const permissionDelivery = bridge.slice(
      bridge.indexOf('private fun deliverPermissionResult('),
      bridge.indexOf('@JavascriptInterface\n    fun getCurrentPosition(', bridge.indexOf('private fun deliverPermissionResult(')),
    )
    expect(permissionDelivery).toContain('if (closed) return')
    expect(permissionDelivery).toContain('if (closed) return@runOnUiThread')
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
    expect(service).toContain('else -> if (!startUpdates())')
    expect(service).toContain('.addOnFailureListener')
    expect(service).toContain('CraftLocationRecordingStore.stop(this)')
    expect(service).toContain('stopSelf()')
    expect(bridge).toContain('startRecording: function(options)')
    expect(bridge).toContain('fun stopLocationRecording()')
    expect(manifest).toContain('android:name="com.craft.runtime.LocationRecordingService"')
    expect(manifest).toContain('android:foregroundServiceType="location"')
  })

  it('uses Firebase Cloud Messaging instead of placeholder push tokens', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-android-push-'))
    const output = join(root, 'android')
    const googleServicesFile = join(root, 'google-services.json')
    writeFileSync(googleServicesFile, JSON.stringify({
      client: [{
        client_info: { android_client_info: { package_name: 'org.wildloop.app' } },
      }],
      project_info: { project_number: '1' },
    }))
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
    expect(bridge).toContain('evaluatePromiseJavascript("$callback && $callback($payload)")')
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

  it('guards contacts, calendar, notification, and billing promise channels', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-promise-data-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver] of [
      ['contacts read', '_craftContactsResolve'],
      ['contact write', '_craftAddContactResolve'],
      ['calendar read', '_craftCalendarResolve'],
      ['calendar create', '_craftCreateEventResolve'],
      ['calendar delete', '_craftDeleteEventResolve'],
      ['notification schedule', '_craftNotifResolve'],
      ['products', '_craftProductsResolve'],
      ['purchase', '_craftPurchaseResolve'],
      ['purchase restore', '_craftRestoreResolve'],
    ]) {
      expect(bridge).toContain(`window.__craftPromise('${channel}', '${resolver}',`)
      expect(bridge).not.toContain(`window.${resolver} = resolve`)
    }
  })

  it('guards file, media, database, radio, and health promise channels', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-promise-device-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver] of [
      ['QR scan', '_craftQRResolve'],
      ['file picker', '_craftFileResolve'],
      ['file download', '_craftDownloadResolve'],
      ['file save', '_craftSaveResolve'],
      ['Google sign in', '_craftGoogleResolve'],
      ['audio start', '_craftAudioResolve'],
      ['audio stop', '_craftAudioStopResolve'],
      ['video recording', '_craftVideoResolve'],
      ['database execute', '_craftDbExecResolve'],
      ['database query', '_craftDbQueryResolve'],
      ['Bluetooth scan', '_craftBleResolve'],
      ['NFC scan', '_craftNfcResolve'],
      ['health authorization', '_craftFitnessAuthResolve'],
      ['health read', '_craftFitnessDataResolve'],
      ['health write', '_craftFitnessSaveResolve'],
    ]) {
      expect(bridge).toContain(`window.__craftPromise('${channel}', '${resolver}',`)
      expect(bridge).not.toContain(`window.${resolver} = resolve`)
    }
  })

  it('guards lifecycle, utility, and update promise channels without ad hoc callback slots', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-promise-lifecycle-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    for (const [channel, resolver, uses] of [
      ['screenshot', '_craftScreenshotResolve', 1],
      ['background task', '_craftBgTaskResolve', 4],
      ['PDF', '_craftPDFResolve', 2],
      ['contact picker', '_craftPickContactResolve', 1],
      ['shortcuts', '_craftShortcutsResolve', 2],
      ['shared keychain', '_craftSharedKeychainResolve', 3],
      ['auth persistence', '_craftAuthPersistResolve', 4],
      ['AR', '_craftARResolve', 5],
      ['ML', '_craftMLResolve', 3],
      ['widgets', '_craftWidgetResolve', 3],
      ['watch', '_craftWatchResolve', 2],
      ['initial URL', '_craftDeepLinkResolve', 1],
      ['OTA check', '_craftOTACheckResolve', 1],
      ['OTA download', '_craftOTADownloadResolve', 1],
      ['OTA apply', '_craftOTAApplyResolve', 1],
      ['OTA rollback', '_craftOTARollbackResolve', 1],
      ['share', '_craftShareResolve', 1],
    ] as const) {
      const call = `window.__craftPromise('${channel}', '${resolver}',`
      expect(bridge.match(new RegExp(call.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'))?.length).toBe(uses)
    }
    const nativeCallbackNames = new Set(
      [...bridge.matchAll(/window\.(_craft[A-Za-z]+(?:Resolve|Reject))\b/g)]
        .map(match => match[1]),
    )
    for (const callbackName of nativeCallbackNames) {
      expect(bridge).toContain(`'${callbackName}'`)
    }
    const registrations = [...bridge.matchAll(
      /window\.__craftPromise\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'/g,
    )].map(match => [match[1], match[2], match[3]] as const)
    expect(registrations).toHaveLength(66)

    const uniqueRegistrations = new Map(
      registrations.map(registration => [registration.join('\0'), registration]),
    )
    expect(uniqueRegistrations.size).toBe(47)

    const channels = new Set<string>()
    const callbackOwners = new Map<string, string>()
    for (const [channel, resolver, rejecter] of uniqueRegistrations.values()) {
      expect(channels.has(channel)).toBe(false)
      channels.add(channel)
      expect(rejecter).toBe(resolver.replace(/Resolve$/, 'Reject'))
      for (const callback of [resolver, rejecter]) {
        expect(callbackOwners.has(callback)).toBe(false)
        callbackOwners.set(callback, channel)
      }
    }
    expect(channels.size).toBe(47)
    expect(callbackOwners.size).toBe(94)
    expect(bridge.match(/webView\.evaluateJavascript\(\s*"window\._craft[A-Za-z]+(?:Resolve|Reject)/g)).toBeNull()
    expect(bridge.match(/window\._craft[A-Za-z]+(?:Resolve|Reject) = (?:resolve|reject)/g)).toBeNull()
    expect(bridge).toContain('_craftShortcutsResolve({set: true, count: ${shortcuts.size}})')
    expect(bridge.match(/_craftShortcutsResolve\(\{cleared: true\}\)/g)?.length).toBe(2)
    expect(bridge).toContain('_craftSharedKeychainResolve({set: true, key: ${jsQuote(key)}})')
    expect(bridge).toContain('_craftSharedKeychainResolve({removed: true, key: ${jsQuote(key)}})')
    expect(bridge).toContain('window.__craftRejectPermissionRequests = function(message)')
    expect(bridge).toContain("window.__craftRejectPermissionRequests('Android bridge closed')")
    expect(bridge).toContain('var permissionRuntimeClosed = false')
    expect(bridge).toContain('permissionRuntimeClosed = true')
    expect(bridge).toContain("return Promise.reject(new Error('Android bridge is closed'))")
  })

  it('turns synchronous native-call failures into Promise rejections', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-promise-call-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    expect(bridge).not.toMatch(/Promise\.resolve\((?:CraftAndroid|window\.craft|legacy)/)
    expect(bridge).not.toContain('Promise.resolve(JSON.parse(CraftAndroid')
    for (const guardedCall of [
      'Promise.resolve().then(function() { return CraftAndroid.checkPermission(String(permission)); })',
      'Promise.resolve().then(function() { return JSON.parse(CraftAndroid.startLocationRecording(JSON.stringify(options || {}))); })',
      'Promise.resolve().then(function() { return legacySecureStore.get(key); })',
      'Promise.resolve().then(function() { return window.craft.notifications.cancel(id); })',
    ]) {
      expect(bridge).toContain(guardedCall)
    }
    expect(bridge).toContain('return {reachable: CraftAndroid.isWatchReachable()};')
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
    const currentPosition = bridge.slice(
      bridge.indexOf('fun getCurrentPosition('),
      bridge.indexOf('fun watchPosition('),
    )

    expect(bridge).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(native).toContain('GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)')
    expect(bridge).toContain('rejectLocationRequest("Google Play Services is unavailable")')
    expect(bridge).toContain("message: 'Location request timed out; Google Play Services or a location provider may be unavailable'")
    expect(bridge).toContain("'_craftLocationReject',")
    expect(bridge).toContain('15000,')
    expect(native).toContain('rejectLocationRequest("Google Play Services is unavailable")')
    expect(bridge).toContain('private val oneShotLocationCallbacks')
    expect(bridge).toContain('private val oneShotLocationTimeouts')
    expect(bridge).toContain('clearOneShotLocationCallback(client, callback)')
    expect(currentPosition).toContain('private fun requestFreshLocation(')
    expect(currentPosition).toContain('client.lastLocation.addOnSuccessListener')
    expect(currentPosition).not.toContain('fusedLocationClient?.lastLocation')
    expect(currentPosition).not.toContain('fusedLocationClient?.requestLocationUpdates(locationRequest, callback')
    expect(bridge).toContain('reject(error.message ?: "Location request failed")')
    expect(native).toContain('private val currentLocationCallbacks')
    expect(native).toContain('private val currentLocationTimeouts')
    expect(native).toContain('clearCurrentLocationCallback(client, callback)')
    expect(native).toContain('reject(error.message)')
    for (const source of [bridge, native]) {
      expect(source).toContain('private val currentPositionSequence = java.util.concurrent.atomic.AtomicLong(0)')
      expect(source).toContain('val requestId = currentPositionSequence.incrementAndGet()')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (requestId != currentPositionSequence.get()) return')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('currentPositionSequence.incrementAndGet()')
      expect(source).toContain('postDelayed(timeout, LOCATION_REQUEST_TIMEOUT_MS)')
      expect(source).toContain('removeCallbacks(timeout)')
      expect(source).toContain('LOCATION_REQUEST_TIMEOUT_MS = 15_000L')
      expect(source).toContain('Location request timed out; provider returned no position')
    }
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
    expect(contacts).toContain('val contacts = try {')
    expect(contacts).toContain('private fun loadContacts(): JSONArray')
    expect(contacts).toContain('Contacts could not be read')
    expect(contacts).toContain('arrayOf(\n                ContactsContract.Contacts._ID,')
    expect(contacts).toContain('arrayOf(contactIdColumn, valueColumn)')
    expect(contacts).not.toContain('fun getContactPhones(')
    expect(contacts).not.toContain('fun getContactEmails(')
    expect(contacts).not.toContain('CONTACT_ID + " = ?"')
  })

  it('settles contact-picker permission and launch failures', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-contact-picker-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun pickContact(')
    const end = bridge.indexOf('fun handleContactPickerResult(', start)
    const resultEnd = bridge.indexOf('// ==================== App Shortcuts', end)
    const picker = bridge.slice(start, end)
    const pickerResult = bridge.slice(end, resultEnd)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(resultEnd).toBeGreaterThan(end)
    expect(picker.indexOf('checkSelfPermission')).toBeLessThan(picker.indexOf('CraftNative.pickContact'))
    expect(picker).toContain('Contacts permission is required; retry after granting it')
    expect(picker).toContain('Contact picker could not be opened')
    const native = readFileSync(
      join(output, 'app/src/main/java/com/craft/runtime/CraftNative.kt'),
      'utf8',
    )
    const runOnMain = native.slice(
      native.indexOf('fun runOnMain('),
      native.indexOf('fun lockOrientation(', native.indexOf('fun runOnMain(')),
    )
    expect(runOnMain).toContain('taskGeneration != lifecycleGeneration.get()')
    expect(runOnMain).toContain('activity.isFinishing || activity.isDestroyed')
    expect(runOnMain).toContain('nativeCancelTask(token)')
    expect(pickerResult).toContain('if (!cursor.moveToFirst()) return@use null')
    expect(pickerResult).toContain('if (contact == null) {')
    expect(pickerResult).toContain('Selected contact could not be read')
    expect(bridge).toContain('private fun rejectContactPicker(message: String)')
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
    const nativeDelivery = holder.slice(
      holder.indexOf('fun deliver(script: String)'),
      holder.indexOf('private external fun nativeGetDeviceInfo'),
    )
    const bridgeInitialization = bridge.slice(
      bridge.indexOf('fun injectBridge()'),
      bridge.indexOf('fun markBridgeLoading()'),
    )

    expect(activity).toContain('craftBridge.close()')
    expect(bridgeInitialization).toContain('if (closed) return@runOnUiThread')
    expect(bridgeInitialization).toContain('if (closed) return@evaluateJavascript')
    expect(bridge.match(/webView\.evaluateJavascript\(/g)?.length).toBe(4)
    expect(bridge).toContain('private fun evaluateJavascriptUnlessClosed(script: String)')
    expect(bridge).toContain('evaluatePromiseJavascript(script: String) {\n        evaluateJavascriptUnlessClosed(script)')
    // Still no throw back into Zig, and since #231 it answers whether a
    // deliverer took the script rather than swallowing the drop.
    expect(nativeDelivery).toContain('fun deliver(script: String): Boolean')
    expect(nativeDelivery).toContain('val target = deliverer ?: return false')
    expect(nativeDelivery).toContain('runCatching { target(script); true }.getOrDefault(false)')
    for (const cleanup of [
      'window.__craftRejectPendingPromises',
      'CraftNative.close(activity)',
      'speechRecognizer?.destroy()',
      'biometricPrompt?.cancelAuthentication()',
      'fusedLocationClient?.removeLocationUpdates(callback)',
      'manager.unregisterNetworkCallback(callback)',
      'sensorManager?.unregisterListener(listener)',
      'bluetoothScanner?.stopScan(callback)',
      'productBillingClient?.endConnection()',
      'restoreBillingClient?.endConnection()',
      'database?.close()',
      'setFlashlight(false)',
    ]) expect(bridgeClose).toContain(cleanup)
    for (const cleanup of [
      'deliverer = null',
      'speechRecognizer?.destroy()',
      'biometricPrompt?.cancelAuthentication()',
      'productBillingClient?.endConnection()',
      'restoreBillingClient?.endConnection()',
      'manager.unregisterNetworkCallback(watch)',
      'bleScanner?.stopScan(callback)',
      'sensorManager?.unregisterListener(listener)',
    ]) expect(nativeClose).toContain(cleanup)
  })

  it('settles review and biometric callbacks once across activity teardown', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-interactive-callbacks-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeReview = bridge.slice(
      bridge.indexOf('fun requestReview()'),
      bridge.indexOf('// ==================== Flashlight', bridge.indexOf('fun requestReview()')),
    )
    const holderReview = holder.slice(
      holder.indexOf('fun startReviewFlow('),
      holder.indexOf('fun requestReview(', holder.indexOf('fun startReviewFlow(')),
    )
    const bridgeBiometric = bridge.slice(
      bridge.indexOf('fun authenticate(reason: String)'),
      bridge.indexOf('// ==================== Push Notifications', bridge.indexOf('fun authenticate(reason: String)')),
    )
    const holderBiometric = holder.slice(
      holder.indexOf('fun showBiometricPrompt('),
      holder.indexOf('fun authenticate(', holder.indexOf('fun showBiometricPrompt(')),
    )

    for (const source of [bridgeReview, holderReview, bridgeBiometric, holderBiometric]) {
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('catch (error: Exception)')
    }
    expect(bridgeReview).toContain('evaluatePromiseJavascript(')
    expect(bridgeBiometric).toContain('biometricPrompt = prompt')
    expect(bridgeBiometric).toContain('rejectBiometricRequest(error.message ?: "Biometric authentication failed")')
    expect(holderReview).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
    expect(holderBiometric).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
    expect(holderBiometric).toContain('biometricPrompt = prompt')
    expect(bridge).toContain('if (closed) return@runOnUiThread')
  })

  it('settles ML task and serialization failures once and closes every client', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-ml-callbacks-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeMl = bridge.slice(
      bridge.indexOf('// ==================== ML Kit'),
      bridge.indexOf('// ==================== Widget Support'),
    )
    const holderMl = holder.slice(
      holder.indexOf('// ==================== ML Kit'),
      holder.indexOf('// ==================== External PDF viewer'),
    )

    expect(bridgeMl).toContain('private fun createMlSettlement(): Pair<(JSONArray) -> Unit, (String) -> Unit>')
    expect(holderMl).toContain('private fun createMlSettlement(): Pair<(String) -> Unit, (String) -> Unit>')
    for (const source of [bridgeMl, holderMl]) {
      expect(source.match(/val \(resolve, reject\) = createMlSettlement\(\)/g)?.length).toBe(3)
      expect(source.match(/\.addOnCompleteListener \{/g)?.length).toBe(3)
      expect(source.match(/\.close\(\)/g)?.length).toBe(3)
      expect(source.match(/catch \(error: Exception\)/g)?.length).toBe(3)
      expect(source).toContain('settled.compareAndSet(false, true)')
    }
    expect(bridgeMl).toContain('!closed && settled.compareAndSet(false, true)')
    expect(holderMl).toContain('requestGeneration == lifecycleGeneration.get()')
  })

  it('invalidates queued screenshot and PDF replies during teardown', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-queued-replies-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')
    const bridgeScreenshot = bridge.slice(
      bridge.indexOf('fun takeScreenshot()'),
      bridge.indexOf('// ==================== Background Tasks'),
    )
    const holderScreenshot = holder.slice(
      holder.indexOf('fun captureScreenshot('),
      holder.indexOf('fun takeScreenshot('),
    )
    const bridgePdf = bridge.slice(
      bridge.indexOf('fun openPDF('),
      bridge.indexOf('// ==================== Contact Picker'),
    )
    const holderPdf = holder.slice(
      holder.indexOf('fun openPdfExternal('),
      holder.indexOf('fun openPDF('),
    )

    for (const source of [holderScreenshot, holderPdf]) {
      expect(source).toContain('val requestGeneration = lifecycleGeneration.get()')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
      expect(source).toContain('if (!settled.compareAndSet(false, true)) return')
      expect(source).toContain('return@runOnUiThread')
    }
    for (const source of [bridgeScreenshot, bridgePdf]) {
      expect(source).toContain('if (closed) return@runOnUiThread')
      expect(source).toContain('evaluatePromiseJavascript(')
    }
    for (const source of [bridgeScreenshot, holderScreenshot]) {
      expect(source).toContain('finally {')
      expect(source).toContain('view.isDrawingCacheEnabled = false')
    }
  })

  it('connects Play Billing for restores and settles failure paths', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-billing-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const sourceRoot = join(output, 'app/src/main/java')
    const bridge = readFileSync(join(sourceRoot, 'org/wildloop/app/CraftBridge.kt'), 'utf8')
    const holder = readFileSync(join(sourceRoot, 'com/craft/runtime/CraftNative.kt'), 'utf8')

    for (const source of [bridge, holder]) {
      expect(source).toContain('if (connectedClient != null && connectedClient.isReady) {')
      expect(source).toContain('private var productBillingClient: BillingClient? = null')
      expect(source).toContain('private var restoreBillingClient: BillingClient? = null')
      expect(source).toContain('val settled = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(source).toContain('if (!settled.compareAndSet(false, true)')
      expect(source).toContain('queryRestoredPurchases(connectedClient, ::resolveRestoreRequest, ::rejectRestoreRequest)')
      expect(source).toContain('reject: (String) -> Unit')
      expect(source).toContain('Billing setup failed: ${billingResult.debugMessage}')
      expect(source).toContain('Product query failed: ${result.debugMessage}')
      expect(source).toContain('Restore failed: ${result.debugMessage}')
      expect(source).not.toContain('billingClient?.queryPurchasesAsync(')
      expect(source).not.toContain('load products before restoring purchases')
    }
    expect(bridge).toContain('CraftNative.restorePurchases(activity)')
    expect(bridge).toContain('private fun rejectProducts(message: String)')
    expect(bridge).toContain('private fun rejectRestore(message: String)')
    expect(bridge).toContain('put("title", details.name)')
    expect(holder).toContain('put("title", details.name)')
    expect(bridge).toContain('private var closed = false')
    expect(bridge).toContain('closed = true')
    expect(holder).toContain('private external fun nativeRestorePurchases(activity: Activity): Boolean')
    expect(holder).toContain('private val lifecycleGeneration = java.util.concurrent.atomic.AtomicLong(0)')
    expect(holder).toContain('lifecycleGeneration.incrementAndGet()')
    expect(holder).toContain('if (requestGeneration != lifecycleGeneration.get()) return')
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
    expect(getEvents).toContain('jsQuote(e.message ?: "Calendar events could not be read")')
  })

  it('rejects widget reload failures instead of hanging the promise', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-widget-errors-'))
    await init({ name: 'WildLoop', packageName: 'org.wildloop.app', output })

    const bridge = readFileSync(join(output, 'app/src/main/java/org/wildloop/app/CraftBridge.kt'), 'utf8')
    const start = bridge.indexOf('fun reloadWidgets()')
    const end = bridge.indexOf('// ==================== Google Assistant', start)
    const reload = bridge.slice(start, end)

    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    expect(reload).toContain('try {')
    expect(reload).toContain('activity.sendBroadcast(intent)')
    expect(reload).toContain('window._craftWidgetReject')
    expect(reload).toContain('Widget reload failed')
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
    expect(bridge).toContain("'steps', 'heartRate', 'activeEnergy', 'distance', 'workouts'")
    expect(health).toContain('HealthConnectClient')
    expect(health).toContain('ExerciseSessionRecord')
    expect(health).toContain('At least one Health Connect permission type is required')
    expect(health).toContain('Unsupported Health Connect permission type:')
    expect(health).toContain('activity.applicationInfo.loadLabel(activity.packageManager).toString()')
    expect(health).toContain('private val closed = java.util.concurrent.atomic.AtomicBoolean(false)')
    expect(health).toContain('private val authorizationPending = java.util.concurrent.atomic.AtomicBoolean(false)')
    expect(health).toContain('if (closed.get()) return@runOnUiThread')
    expect(health).toContain('if (closed.get()) return true')
    expect(health).toContain('if (!authorizationPending.compareAndSet(true, false)) return true')
    expect(health).toContain('val requested = pendingPermissions')
    expect(health).toContain('granted.containsAll(requested)')
    expect(health).toContain('Health permission result could not be read')
    expect(health).toContain('closed.set(true)')
    expect(health).toContain('pendingPermissions = emptySet()')
    expect(health).toContain('error.message ?: "Health permissions could not be requested"')
    expect(health).not.toContain('title = "WildLoop"')
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

  it('invalidates Health Connect replies in enabled and disabled builds', async () => {
    const disabledOutput = mkdtempSync(join(tmpdir(), 'craft-android-health-disabled-close-'))
    const enabledOutput = mkdtempSync(join(tmpdir(), 'craft-android-health-enabled-close-'))
    await init({ name: 'DisabledHealth', packageName: 'org.health.disabled', output: disabledOutput })
    await init({
      name: 'EnabledHealth',
      packageName: 'org.health.enabled',
      output: enabledOutput,
      config: { enableHealthConnect: true },
    })

    for (const [output, packagePath] of [
      [disabledOutput, 'org/health/disabled'],
      [enabledOutput, 'org/health/enabled'],
    ]) {
      const health = readFileSync(
        join(output, `app/src/main/java/${packagePath}/CraftHealthConnect.kt`),
        'utf8',
      )
      expect(health).toContain('private val closed = java.util.concurrent.atomic.AtomicBoolean(false)')
      expect(health).toContain('closed.set(true)')
      expect(health).toContain('if (closed.get()) return@runOnUiThread')
    }
  })
})

/**
 * A runtime directory shaped like `zig build build-android-all`'s output.
 *
 * The contents are not a real ELF — nothing here loads it — but the layout is
 * exactly `zig-out/android/<abi>/libcraft.so`, because the layout is the part
 * the installer depends on.
 */
function fakeRuntime(abis: string[]): string {
  const dir = mkdtempSync(join(tmpdir(), 'craft-android-runtime-'))
  for (const abi of abis) {
    mkdirSync(join(dir, abi), { recursive: true })
    writeFileSync(join(dir, abi, 'libcraft.so'), `not-really-${abi}`)
  }
  return dir
}

describe('Zig runtime installation', () => {
  it('lands the library where AGP already looks for it', () => {
    // app/src/main/jniLibs is the default jniLibs.srcDirs, which is why no
    // Gradle template has to know this happened.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-jnilibs-'))
    installRuntime(output, fakeRuntime(['arm64-v8a', 'x86_64']))

    expect(readFileSync(join(output, 'app/src/main/jniLibs/arm64-v8a/libcraft.so'), 'utf8')).toBe('not-really-arm64-v8a')
    expect(readFileSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'), 'utf8')).toBe('not-really-x86_64')
  })

  it('installs what it has when an architecture is missing', () => {
    // A one-ABI dev loop is legitimate; it just cannot run on the other kind
    // of device, which the installer warns about rather than refusing.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-one-abi-'))
    expect(installRuntime(output, fakeRuntime(['x86_64']))).toBe(true)

    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a'))).toBe(false)
  })

  it('refuses a directory with no library at all, and names the build step', () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-no-abi-'))
    const empty = mkdtempSync(join(tmpdir(), 'craft-android-empty-'))

    expect(() => installRuntime(output, empty)).toThrow(/zig build build-android-all/)
    // Nothing written on the way to throwing.
    expect(existsSync(join(output, 'app/src/main/jniLibs'))).toBe(false)
  })

  it('does not leave an architecture behind that a later build dropped', () => {
    // A stale .so still ships in the APK and still loads, so the app would run
    // an architecture nobody built for this version.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-stale-'))
    installRuntime(output, fakeRuntime(['arm64-v8a', 'x86_64']))
    installRuntime(output, fakeRuntime(['x86_64']))

    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a'))).toBe(false)
    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
  })

  it('generates a shim-only app when no runtime is configured', async () => {
    // The default, and the state every generated app was in before this
    // existed: System.loadLibrary throws, isAvailable is false, Kotlin serves.
    const output = mkdtempSync(join(tmpdir(), 'craft-android-shim-only-'))
    await init({ name: 'ShimOnly', packageName: 'dev.craft.shimonly', output, runtimeDir: null })

    expect(existsSync(join(output, 'app/src/main/jniLibs'))).toBe(false)
  })

  it('installs the runtime from init when one is given', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-android-with-runtime-'))
    await init({
      name: 'WithRuntime',
      packageName: 'dev.craft.withruntime',
      output,
      runtimeDir: fakeRuntime(['arm64-v8a', 'x86_64']),
    })

    expect(existsSync(join(output, 'app/src/main/jniLibs/arm64-v8a/libcraft.so'))).toBe(true)
    expect(existsSync(join(output, 'app/src/main/jniLibs/x86_64/libcraft.so'))).toBe(true)
  })

  it('reads CRAFT_ANDROID_RUNTIME only when the caller says nothing', () => {
    const dir = fakeRuntime(['x86_64'])
    const previous = process.env.CRAFT_ANDROID_RUNTIME
    process.env.CRAFT_ANDROID_RUNTIME = dir

    try {
      expect(resolveRuntimeDir()).toBe(dir)
      // null is a declaration, not a gap: no runtime whatever the environment
      // says, which is what the E2E suite's shim leg depends on.
      expect(resolveRuntimeDir(null)).toBe(null)
    }
    finally {
      if (previous === undefined) delete process.env.CRAFT_ANDROID_RUNTIME
      else process.env.CRAFT_ANDROID_RUNTIME = previous
    }
  })

  it('names which knob pointed at a directory that is not there', () => {
    const previous = process.env.CRAFT_ANDROID_RUNTIME
    process.env.CRAFT_ANDROID_RUNTIME = '/craft/definitely/not/here'

    try {
      expect(() => resolveRuntimeDir()).toThrow(/CRAFT_ANDROID_RUNTIME points at/)
      expect(() => resolveRuntimeDir('/craft/also/not/here')).toThrow(/runtimeDir is/)
    }
    finally {
      if (previous === undefined) delete process.env.CRAFT_ANDROID_RUNTIME
      else process.env.CRAFT_ANDROID_RUNTIME = previous
    }
  })
})

describe('the Zig library and the generated app agree on how old a device may be', () => {
  it('builds the JNI library for no newer an API than minSdk', () => {
    // One prebuilt libcraft.so serves every generated app, so it has to be
    // linked against the *oldest* API craft's default configuration claims to
    // support. Build it against a newer one and the linker happily binds
    // symbols that are simply absent on an older phone — and the failure is
    // dlopen refusing the library at startup, on exactly the devices the app
    // said it ran on.
    //
    // Nothing else connects a Zig constant to a TypeScript one, so this reads
    // build.zig and compares.
    const buildZig = readFileSync(join(import.meta.dir, '../../zig/build.zig'), 'utf8')
    const declared = buildZig.match(/const android_api_level: u32 = (\d+);/)

    expect(declared).not.toBeNull()

    // DEFAULT_CONFIG is not exported, so read it the same way: from the source
    // that defines it, which is the thing that would have to change.
    const generator = readFileSync(join(import.meta.dir, 'index.ts'), 'utf8')
    const minSdk = generator.match(/minSdk:\s*(\d+)/)

    expect(minSdk).not.toBeNull()
    expect(Number(declared![1])).toBeLessThanOrEqual(Number(minSdk![1]))
  })
})
