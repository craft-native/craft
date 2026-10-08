import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import {
  build,
  init,
  installRuntime,
  renderRuntimeSettings,
  resolveRuntimeDir,
  orderSimulators,
  pngHasAlpha,
  productName,
  renderAppearance,
  renderBackgroundModes,
  renderEntitlements,
  renderOrientations,
  renderPrivacyManifest,
  renderUsageDescriptions,
  renderAppBoundDomains,
  renderUrlTypes,
  renderWatchEntitlements,
  syncWebAssets,
} from './index'

describe('Craft iOS builder', () => {
  it('keeps WebView as the default and opt-in native screens load a compiled bundle', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-native-'))
    await init({ runtimeDir: null, name: 'Native Slice', output, config: { renderer: 'native' } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const swift = readFileSync(join(output, 'Sources', 'NativeSliceApp.swift'), 'utf8')
    const nativeSwift = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    const flatListSwift = readFileSync(join(output, 'Sources', 'CraftNativeFlatList.swift'), 'utf8')
    const actionsSwift = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const mutationSwift = readFileSync(join(output, 'Sources', 'CraftNativeMutation.swift'), 'utf8')
    expect(config.renderer).toBe('native')
    expect(swift).toContain('if appState.config.renderer == "native"')
    expect(nativeSwift).toContain('import JavaScriptCore')
    expect(nativeSwift).not.toContain('WKWebView')
    expect(nativeSwift).toContain('CraftNativeActions.perform(')
    expect(nativeSwift).toContain('platform: "ios"')
    expect(nativeSwift).toContain('mutationProtocolVersion: 1')
    expect(nativeSwift).toContain('capabilityProtocolVersion: \\(craftNativeCapabilityProtocolVersion)')
    expect(nativeSwift).toContain('capabilityTimeoutMs: \\(craftNativeCapabilityTimeoutMilliseconds)')
    expect(nativeSwift).toContain('"code": "TIMEOUT"')
    expect(nativeSwift).toContain('pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()')
    expect(nativeSwift).toContain('initialAppState: "\\(CraftNativeActions.currentAppState())"')
    expect(nativeSwift).toContain('case "API_CANCEL":')
    expect(nativeSwift).toContain('UIApplication.didBecomeActiveNotification')
    expect(nativeSwift).toContain('DeepLinkManager.shared.addNativeListener')
    expect(nativeSwift).toContain('navigationController?.topViewController === self')
    expect(nativeSwift).toContain('private final class CraftNativeFlowView: UIStackView')
    expect(nativeSwift).toContain('required init(coder: NSCoder)')
    expect(nativeSwift).toContain('stack.wrap = style["flexWrap"] as? String == "wrap"')
    expect(nativeSwift).toContain('style.position == "absolute"')
    expect(nativeSwift).toContain('style.minWidth')
    expect(nativeSwift).toContain('style.alignSelf ?? alignItems')
    expect(nativeSwift).toContain('let desiredKeyboardType = keyboardType(props["keyboardType"])')
    expect(nativeSwift).toContain('if field.keyboardType != desiredKeyboardType')
    expect(nativeSwift).toContain('if field.isSecureTextEntry != desiredSecureEntry')
    expect(nativeSwift).toContain('let desiredReturnKeyType = returnKeyType(props["returnKeyType"])')
    expect(nativeSwift).toContain('private func restoreFocus(_ focused: UIView?)')
    expect(nativeSwift).toContain('_ = focused.becomeFirstResponder()')
    expect(nativeSwift).toContain('let focused = firstResponder(in: rootStack)')
    expect(nativeSwift).toContain('private weak var lastFocusedInput: UITextField?')
    expect(nativeSwift).toContain('firstResponder(in: rootStack) ?? lastFocusedInput')
    expect(nativeSwift).toContain('DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)')
    expect(nativeSwift).toContain('restoreFocus(focused)')
    expect(nativeSwift).toContain('textSubmitted(_:))')
    expect(nativeSwift).toContain('focusHandlers')
    expect(nativeSwift).toContain('becomeFirstResponder()')
    expect(nativeSwift).toContain('class CraftNativeScreenController: UIViewController, UIScrollViewDelegate')
    expect(nativeSwift).toContain('scrollViewDidScroll')
    expect(nativeSwift).toContain('contentOffset')
    expect(nativeSwift).toContain('scroll.alwaysBounceVertical')
    expect(nativeSwift).toContain('?? (direction == .vertical)')
    expect(nativeSwift).toContain('if let control = view as? UIControl')
    expect(nativeSwift).toContain('accessibilityValue')
    expect(nativeSwift).not.toContain('else if type == "TextInput", let field = view as? UITextField')
    expect(nativeSwift).toContain('traits.insert(.notEnabled)')
    expect(nativeSwift).toContain('traits.insert(.selected)')
    expect(flatListSwift).toContain('UICollectionViewDiffableDataSource<Int, String>')
    expect(flatListSwift).toContain('reconfigureItems(changedLive)')
    expect(flatListSwift).toContain('preferredLayoutAttributesFitting')
    expect(flatListSwift).toContain('pendingApply')
    expect(swift).toContain('CraftNativeActions.perform(action: action, body: body, config: config)')
    expect(swift).toContain('private var nativeListeners: [UUID: (URL, Bool) -> Void] = [:]')
    expect(mutationSwift).toContain('final class CraftNativeMutationDocument')
    expect(mutationSwift).toContain('case "moveChild"')
    expect(actionsSwift).toContain('case "getDeviceInfo":')
    expect(actionsSwift).toContain('case "haptic":')
    expect(actionsSwift).toContain('case "clipboardWrite":')
    expect(actionsSwift).toContain('case "clipboardRead":')
    expect(actionsSwift).toContain('CAPABILITY_DISABLED')
    expect(actionsSwift).toContain('INVALID_ARGUMENT')
    expect(actionsSwift).toContain('let craftNativeCapabilityProtocolVersion = 1')
    expect(actionsSwift).toContain('case ("Storage", _)')
    expect(actionsSwift).toContain('case ("Database", _)')
    expect(actionsSwift).toContain('case ("Notifications", _)')
    expect(actionsSwift).toContain('case ("DeepLinks", "getInitialURL")')
    expect(actionsSwift).toContain('private static func claimInitialDeepLink() -> URL?')
    expect(actionsSwift).toContain('guard !initialDeepLinkClaimed else { return nil }')
    expect(actionsSwift).toContain('case ("SecureStorage", _)')
    expect(actionsSwift).toContain('case ("Biometrics", "authenticate")')
    expect(actionsSwift).toContain('import LocalAuthentication')
    expect(actionsSwift).toContain('import Security')

    await expect(build({ output, generateProject: false, runtimeDir: null })).rejects.toThrow('native-screen.js')
    const bundle = join(output, 'compiled.js')
    writeFileSync(bundle, 'globalThis.screenLoaded = true')
    await build({ output, nativeBundlePath: bundle, generateProject: false, runtimeDir: null })
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('globalThis.screenLoaded = true')
    await build({ output, nativeBundlePath: join(output, 'dist', 'native-screen.js'), generateProject: false, runtimeDir: null })
    await expect(build({ output, htmlPath: bundle, generateProject: false, runtimeDir: null })).rejects.toThrow('cannot use --html-path')
    await expect(init({ runtimeDir: null, name: 'Invalid', output: join(output, 'invalid'), config: { renderer: 'canvas' as 'native' } })).rejects.toThrow('Unknown iOS renderer')
  })

  it('copies a complete web distribution and removes stale assets', () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-ios-assets-'))
    const source = join(root, 'web')
    const output = join(root, 'ios')
    Bun.spawnSync(['mkdir', '-p', join(source, 'assets'), join(output, 'dist')])
    writeFileSync(join(source, 'index.html'), '<main>WildLoop</main>')
    writeFileSync(join(source, 'assets', 'app.js'), 'export {}')
    writeFileSync(join(output, 'dist', 'stale.js'), 'stale')

    syncWebAssets(source, output)

    expect(readFileSync(join(output, 'dist', 'index.html'), 'utf8')).toContain('WildLoop')
    expect(existsSync(join(output, 'dist', 'assets', 'app.js'))).toBe(true)
    expect(existsSync(join(output, 'dist', 'stale.js'))).toBe(false)
  })

  it('renders only metadata for enabled native capabilities', () => {
    const config = {
      appName: 'WildLoop',
      bundleId: 'org.wildloop.app',
      enableGeolocation: true,
      enableBackgroundLocation: true,
      enableCamera: false,
      enableBiometric: true,
      orientations: ['portrait'] as const,
      urlSchemes: ['wildloop'],
    }

    expect(renderUsageDescriptions(config)).toContain('NSLocationWhenInUseUsageDescription')
    expect(renderUsageDescriptions(config)).toContain('NSLocationAlwaysAndWhenInUseUsageDescription')
    expect(renderUsageDescriptions(config)).toContain('NSFaceIDUsageDescription')
    // The shell links the camera whether or not this app uses it, and App Store
    // Connect refuses a binary without the key (ITMS-90683), so it is always
    // there, saying it is only asked for when a feature needs it.
    expect(renderUsageDescriptions(config)).toContain('<key>NSCameraUsageDescription</key>\n    <string>WildLoop asks for the camera only in a feature that needs it.</string>')
    for (const key of ['NSSpeechRecognitionUsageDescription', 'NSMicrophoneUsageDescription', 'NSCalendarsUsageDescription', 'NSMotionUsageDescription', 'NSContactsUsageDescription'])
      expect(renderUsageDescriptions(config)).toContain(`<key>${key}</key>`)
    // An entitlement gates these, so a key without the feature would only invite questions.
    expect(renderUsageDescriptions(config)).not.toContain('NSHealthShareUsageDescription')
    expect(renderUsageDescriptions(config)).not.toContain('NFCReaderUsageDescription')
    // Only an app that asks for it explains reaching the local network.
    expect(renderUsageDescriptions(config)).not.toContain('NSLocalNetworkUsageDescription')
    expect(renderUsageDescriptions({ ...config, enableLocalNetwork: true })).toContain('<key>NSLocalNetworkUsageDescription</key>')
    expect(renderOrientations(config)).toContain('UIInterfaceOrientationPortrait')
    expect(renderUrlTypes(config)).toContain('<string>wildloop</string>')
    expect(renderBackgroundModes(config)).toContain('<string>location</string>')
  })

  it('declares the app-bound domains a service worker needs, with the dev server among them', () => {
    expect(renderAppBoundDomains({ appName: 'HQ', bundleId: 'training.hq.app' })).toBe('')
    // Unset: the origins the bridge already trusts.
    const derived = renderAppBoundDomains({ appName: 'HQ', bundleId: 'training.hq.app', trustedOrigins: ['https://hq.training', 'craft://app'], devServerURL: 'https://hq.training' })
    expect(derived.match(/<string>[^<]+<\/string>/g)).toEqual(['<string>hq.training</string>'])
    // An explicit empty list declares none.
    expect(renderAppBoundDomains({ appName: 'HQ', bundleId: 'x', appBoundDomains: [], trustedOrigins: ['https://hq.training'] })).toBe('')
    const plist = renderAppBoundDomains({ appName: 'HQ', bundleId: 'training.hq.app', appBoundDomains: ['hq.training', ' HQ.training ', 'www.hq.training'], devServerURL: 'http://localhost:3100' })
    expect(plist).toContain('<key>WKAppBoundDomains</key>')
    expect(plist).toContain('<string>hq.training</string>')
    expect(plist).toContain('<string>www.hq.training</string>')
    // Script injection is limited to app-bound domains once any are declared.
    expect(plist).toContain('<string>localhost</string>')
    expect(plist.match(/<string>hq\.training<\/string>/g)).toHaveLength(1)
    const many = renderAppBoundDomains({ appName: 'HQ', bundleId: 'x', appBoundDomains: Array.from({ length: 14 }, (_, i) => `d${i}.example`) })
    expect(many.match(/<string>/g)).toHaveLength(10)
  })

  it('generates entitlements and privacy declarations from explicit configuration', () => {
    const config = {
      appName: 'WildLoop',
      bundleId: 'org.wildloop.app',
      associatedDomains: ['applinks:wildloop.org'],
      enableHealthKit: true,
      enablePushNotifications: true,
      enableSecureStorage: true,
      privacy: {
        collectedDataTypes: [{
          type: 'NSPrivacyCollectedDataTypePreciseLocation',
          linked: true,
          purposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality'],
        }],
        accessedApiTypes: [{
          type: 'NSPrivacyAccessedAPICategoryUserDefaults',
          reasons: ['CA92.1'],
        }],
      },
    }

    const entitlements = renderEntitlements(config)
    expect(entitlements).toContain('applinks:wildloop.org')
    expect(entitlements).toContain('com.apple.developer.healthkit')
    expect(entitlements).toContain('<string>$(CRAFT_APNS_ENVIRONMENT)</string>')
    expect(entitlements).toContain('keychain-access-groups')
    expect(entitlements).toContain('$(AppIdentifierPrefix)$(CFBundleIdentifier)')
    expect(entitlements).not.toContain('<string>development</string>')
    expect(renderWatchEntitlements({ ...config, appGroups: ['group.org.wildloop.app'] })).toContain('group.org.wildloop.app')
    expect(renderPrivacyManifest(config)).toContain('NSPrivacyCollectedDataTypePreciseLocation')
    expect(renderPrivacyManifest(config)).toContain('CA92.1')
  })

  it('ships an App Store icon without an alpha channel, and declares exempt encryption', async () => {
    // A 1x1 RGBA PNG: App Store Connect refuses an icon with an alpha channel.
    const rgba = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')
    expect(pngHasAlpha(new Uint8Array(rgba))).toBe(true)
    expect(pngHasAlpha(new Uint8Array([1, 2, 3]))).toBe(false)
    const dir = mkdtempSync(join(tmpdir(), 'craft-ios-icon-'))
    const icon = join(dir, 'icon.png')
    writeFileSync(icon, rgba)
    const output = join(dir, 'app')
    await init({ runtimeDir: null, name: 'IconApp', bundleId: 'org.example.icon', output, config: { appIconPath: icon } })
    const written = new Uint8Array(readFileSync(join(output, 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-1024.png')))
    if (process.platform === 'darwin') expect(pngHasAlpha(written)).toBe(false)
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    expect(plist).toContain('<key>ITSAppUsesNonExemptEncryption</key>\n    <false/>')

    const custom = join(dir, 'custom')
    await init({ runtimeDir: null, name: 'CryptoApp', bundleId: 'org.example.crypto', output: custom, config: { usesNonExemptEncryption: true } })
    expect(readFileSync(join(custom, 'Info.plist'), 'utf8')).toContain('<key>ITSAppUsesNonExemptEncryption</key>\n    <true/>')
  })

  it('shows the splash logo on the launch screen, light and dark, kept as a vector', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'craft-ios-splash-'))
    const light = join(dir, 'logo.svg')
    const dark = join(dir, 'logo-dark.svg')
    writeFileSync(light, '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="48"/>')
    writeFileSync(dark, '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="48"/>')
    const output = join(dir, 'app')
    await init({ runtimeDir: null, name: 'SplashApp', bundleId: 'org.example.splash', output, config: { splashImagePath: light, splashImagePathDark: dark } })
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    expect(plist).toContain('<key>UILaunchScreen</key>\n    <dict>\n        <key>UIColorName</key>\n        <string>LaunchBackground</string>\n        <key>UIImageName</key>\n        <string>LaunchLogo</string>\n    </dict>')
    const contents = JSON.parse(readFileSync(join(output, 'Assets.xcassets', 'LaunchLogo.imageset', 'Contents.json'), 'utf8'))
    expect(contents.images.map((image: any) => image.filename)).toEqual(['LaunchLogo.svg', 'LaunchLogo-dark.svg'])
    expect(contents.images[1].appearances).toEqual([{ appearance: 'luminosity', value: 'dark' }])
    expect(contents.properties).toEqual({ 'preserves-vector-representation': true })

    // Without one, the launch screen is the colour alone and no stale logo is left behind.
    await init({ runtimeDir: null, name: 'SplashApp', bundleId: 'org.example.splash', output, config: {} })
    expect(readFileSync(join(output, 'Info.plist'), 'utf8')).not.toContain('UIImageName')
    expect(existsSync(join(output, 'Assets.xcassets', 'LaunchLogo.imageset'))).toBe(false)
  })

  it('shares a scheme that builds and archives the app, for CI such as Xcode Cloud', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-scheme-'))
    await init({ runtimeDir: null, name: 'SchemeApp', bundleId: 'org.example.scheme', output })
    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    expect(project).toContain('schemes:\n  SchemeApp:\n    build:\n      targets:\n        SchemeApp: all')
    expect(project).toContain('    archive:\n      config: Release')
  })

  it('generates a production project whose bundled index lives under dist', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-project-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: {
        enableGeolocation: true,
        enableBackgroundLocation: true,
        enablePushNotifications: true,
        enableHaptics: true,
        trustedOrigins: ['https://wildloop.org'],
        associatedDomains: ['applinks:wildloop.org'],
        urlSchemes: ['wildloop'],
      },
    })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const generatedConfig = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const entitlements = readFileSync(join(output, 'Craft.entitlements'), 'utf8')
    expect(swift).toContain('BundledAssetSchemeHandler')
    expect(swift).toContain('craft://app/index.html')
    expect(swift).toContain('bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist")')
    expect(swift).toContain('.skipsPackageDescendants')
    expect(swift).not.toContain('loadFileURL')
    expect(swift).toContain("craft.contractVersion = '1.0.0'")
    expect(swift).toContain('craft.location = {')
    expect(swift).toContain("error.name = 'GeolocationPositionError'")
    expect(swift).toContain('error.code = 3')
    expect(swift).toContain("action: 'getCurrentPosition'")
    expect(swift).toContain('enableHighAccuracy: options.enableHighAccuracy === true')
    expect(swift).toContain('private var singleLocationTimeoutWorkItem: DispatchWorkItem?')
    expect(swift).toContain('manager.delegate = self')
    expect(swift).toContain('let alreadyGranted = status == .authorizedAlways')
    expect(swift).toContain('max(0, Date().timeIntervalSince(cachedLocation.timestamp) * 1000) <= maximumAge')
    expect(swift).toContain('code: "LOCATION_TIMEOUT"')
    expect(swift.match(/private var pendingCallbackId/g)?.length).toBe(1)
    expect(plist).toContain('NSLocationWhenInUseUsageDescription')
    expect(plist).toContain('<string>wildloop</string>')
    expect(project).not.toContain('    resources:')
    expect(project).toContain('      - path: dist\n        type: folder\n        buildPhase: resources')
    expect(project).toContain('debug:\n      CRAFT_APNS_ENVIRONMENT: development')
    expect(project).toContain('release:\n      CRAFT_APNS_ENVIRONMENT: production')
    expect(entitlements).toContain('<string>$(CRAFT_APNS_ENVIRONMENT)</string>')
    expect(plist).toContain('<string>location</string>')
    expect(existsSync(join(output, 'Craft.entitlements'))).toBe(true)
    expect(existsSync(join(output, 'PrivacyInfo.xcprivacy'))).toBe(true)
    expect(existsSync(join(output, 'Assets.xcassets', 'AppIcon.appiconset', 'Contents.json'))).toBe(true)
    expect(generatedConfig.enableHaptics).toBe(true)
    expect(generatedConfig.enableSecureStorage).toBe(false)
    expect(generatedConfig.enableScreenCapture).toBe(false)
  })

  it('attaches keychain entitlements to secure-storage targets', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-secure-storage-'))
    await init({
      runtimeDir: null,
      name: 'SecureStorage',
      bundleId: 'dev.craft.secure-storage',
      output,
      config: { enableSecureStorage: true },
    })

    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const entitlements = readFileSync(join(output, 'Craft.entitlements'), 'utf8')
    expect(project).toContain('CODE_SIGN_ENTITLEMENTS: Craft.entitlements')
    expect(entitlements).toContain('keychain-access-groups')
    expect(entitlements).toContain('$(AppIdentifierPrefix)$(CFBundleIdentifier)')
  })

  it('names the Swift types and target after an identifier, and shows the display name as given', async () => {
    expect(productName('HQ.training')).toBe('HQTraining')
    expect(productName('my app')).toBe('MyApp')
    expect(productName('WildLoop')).toBe('WildLoop')
    expect(productName('7 Summits')).toBe('App7Summits')
    expect(productName('…')).toBe('Craft')

    const output = mkdtempSync(join(tmpdir(), 'craft-ios-dotted-'))
    await init({ runtimeDir: null, name: 'HQ.training', bundleId: 'training.hq.app', output, config: {} })

    const swift = readFileSync(join(output, 'Sources', 'HQTrainingApp.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    expect(swift).toContain('struct HQTrainingApp: App')
    expect(swift).toContain('final class HQTrainingAppDelegate')
    expect(swift).not.toContain('HQ.training')
    expect(project).toContain('name: HQTraining\n')
    expect(project).toContain('\n  HQTraining:\n')
    expect(plist).toContain('<key>CFBundleDisplayName</key>\n    <string>HQ.training</string>')
    expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).appName).toBe('HQ.training')
  })

  it('follows the phone\'s appearance when asked, with a status bar that reads on it', async () => {
    expect(renderAppearance({ appearance: 'system' })).toEqual({ interfaceStyle: 'Automatic', statusBarStyle: 'UIStatusBarStyleDefault' })
    expect(renderAppearance({ appearance: 'light' })).toEqual({ interfaceStyle: 'Light', statusBarStyle: 'UIStatusBarStyleDarkContent' })
    expect(renderAppearance({ appearance: 'dark' })).toEqual({ interfaceStyle: 'Dark', statusBarStyle: 'UIStatusBarStyleLightContent' })
    // Configs from before `appearance` keep what darkMode pinned.
    expect(renderAppearance({ darkMode: true }).interfaceStyle).toBe('Dark')
    expect(renderAppearance({ darkMode: false }).interfaceStyle).toBe('Light')

    const output = mkdtempSync(join(tmpdir(), 'craft-ios-appearance-'))
    await init({
      runtimeDir: null,
      name: 'Appearance',
      bundleId: 'com.example.appearance',
      output,
      config: { appearance: 'system', backgroundColor: '#f8fafc', backgroundColorDark: '#020617' },
    })
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    const swift = readFileSync(join(output, 'Sources', 'AppearanceApp.swift'), 'utf8')
    const launch = JSON.parse(readFileSync(join(output, 'Assets.xcassets', 'LaunchBackground.colorset', 'Contents.json'), 'utf8'))
    expect(plist).toContain('<key>UIUserInterfaceStyle</key>\n    <string>Automatic</string>')
    expect(plist).toContain('<string>UIStatusBarStyleDefault</string>')
    expect(swift).toContain('.preferredColorScheme(appState.config.colorScheme)')
    expect(launch.colors).toHaveLength(2)
    expect(launch.colors[1].appearances).toEqual([{ appearance: 'luminosity', value: 'dark' }])
    expect(launch.colors[1].color.components.red).toBe('0.008')
    // Swipe-back is opt-in, and only a debug build can be inspected.
    expect(swift).toContain('webView.allowsBackForwardNavigationGestures = config.swipeNavigation ?? false')
    expect(swift).toContain('#if DEBUG\n        // Safari\'s Develop menu can attach to a debug build; never a release.\n        if #available(iOS 16.4, *) { webView.isInspectable = true }')
    // A debug build relays the page's errors to the device log; a release
    // build carries neither the handler nor the script.
    expect(swift).toContain('contentController.add(PageConsoleRelay(), name: "craftLog")')
    expect(swift).toContain('NSLog("[craft page] %@: %@"')
    const relayStart = swift.indexOf('final class PageConsoleRelay')
    expect(swift.lastIndexOf('#if DEBUG', relayStart)).toBeGreaterThan(swift.lastIndexOf('#endif', relayStart))
  })

  it('reads Apple Health workouts and daily values, each with the statistic its type has', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-health-'))
    await init({ runtimeDir: null, name: 'Health', bundleId: 'com.example.health', output, config: { enableHealthKit: true } })
    const swift = readFileSync(join(output, 'Sources', 'HealthApp.swift'), 'utf8')

    expect(swift).toContain("getWorkouts: function(options) {")
    expect(swift).toContain("craft._invoke('getHealthWorkouts'")
    expect(swift).toContain("craft._invoke('getHealthDailyStatistics'")
    expect(swift).toContain('case "getHealthWorkouts":')
    expect(swift).toContain('case "getHealthDailyStatistics":')
    // Heart rate is discrete: asking HealthKit for its sum failed the query.
    expect(swift).toContain('case "heartRate": return (HKQuantityType.quantityType(forIdentifier: .heartRate), bpm, .discreteAverage)')
    expect(swift).toContain('options: spec.options) { [weak self] _, result, error in')
    expect(swift).not.toContain('options: .cumulativeSum) { [weak self]')
    // Every new read type is requested, so a grant covers what is then read.
    for (const identifier of ['.restingHeartRate', '.heartRateVariabilitySDNN', '.bodyMass', '.sleepAnalysis'])
      expect(swift).toContain(identifier)
    expect(swift).toContain('HKStatisticsCollectionQuery(')
    expect(swift).toContain('"id": workout.uuid.uuidString')
    // A reader asks to read only, and the sheet a person is reading is never
    // timed out from the page.
    expect(swift).toContain("readOnly: Boolean(options && options.write === false)")
    expect(swift).toContain('if readOnly { shareTypes.removeAll() }')
    expect(swift).toContain('requestHealthAuthorization: true,')
    expect(swift).toContain("var timeout = personFacing[action] ? null : setTimeout(")
  })

  it('keeps a default when a caller passes undefined, and the app reads a partial config over its defaults', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-undefined-'))
    await init({ runtimeDir: null, name: 'Partial', bundleId: 'com.example.partial', output, config: { darkMode: undefined, enableHaptics: true } })
    const generated = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(generated.darkMode).toBe(true)
    expect(generated.enableHaptics).toBe(true)

    const swift = readFileSync(join(output, 'Sources', 'PartialApp.swift'), 'utf8')
    expect(swift).toContain('self.config = CraftConfig.load(from: data)')
    expect(swift).toContain('let merged = defaults.merging(given.filter { !($0.value is NSNull) }) { _, bundled in bundled }')
    expect(swift).toContain('craft.config.json could not be read, running on defaults')
    expect(swift).not.toContain('let config = try? JSONDecoder().decode(CraftConfig.self, from: data)')
  })

  it('keeps bundled assets as a remote-app recovery path', async () => {
    const root = mkdtempSync(join(tmpdir(), 'craft-ios-fallback-'))
    const web = join(root, 'web')
    const output = join(root, 'ios')
    Bun.spawnSync(['mkdir', '-p', web])
    writeFileSync(join(web, 'index.html'), '<main>Available offline</main>')
    await init({ runtimeDir: null, name: 'WildLoop', bundleId: 'org.wildloop.app', output })
    await build({ htmlPath: web, devServer: 'https://wildloop.org', output, generateProject: false })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('loadBundledFallback(in: webView)')
    expect(readFileSync(join(output, 'dist/index.html'), 'utf8')).toContain('Available offline')
  })

  it('delivers shortcut and Siri activations after cold launches', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-shortcut-events-'))
    await init({ runtimeDir: null, name: 'WildLoop', bundleId: 'org.wildloop.app', output })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('launchOptions?[.shortcutItem] as? UIApplicationShortcutItem')
    expect(swift).toContain('performActionFor shortcutItem: UIApplicationShortcutItem')
    expect(swift).toContain('continue userActivity: NSUserActivity')
    expect(swift).toContain('sendToWeb("craftShortcut", data: ["type": shortcut.type])')
    expect(swift).toContain('sendToWeb("craftSiriShortcut", data: ["action": action, "data": data])')
    expect(swift).toContain('pendingEvents.append((event, data))')
    expect(swift).toContain('CraftEventManager.shared.setReady()')
    expect(swift).not.toContain("addEventListener('craftOTAProgress'")
    expect(swift).not.toContain("addEventListener('craftOTAStatus'")
  })

  it('settles a Siri shortcut removal whose completion never comes', async () => {
    // #211: the deletion completion comes from a system daemon, and on a
    // fresh simulator it sometimes never does. The Swift arm only runs in
    // apps without the Zig runtime, so no simulator suite reaches it.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-siri-removal-'))
    await init({ runtimeDir: null, name: 'WildLoop', bundleId: 'org.wildloop.app', output })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const start = swift.indexOf('private func removeSiriShortcut(')
    const removal = swift.slice(start, swift.indexOf('// MARK: - Watch Connectivity', start))

    expect(start).toBeGreaterThan(-1)
    expect(removal).toContain('DispatchQueue.main.asyncAfter(deadline: .now() + Coordinator.siriRemovalDeadline, execute: deadline)')
    expect(removal).toContain('code: "TIMEOUT"')
    // Exactly one answer: both halves take the same entry, and only the one
    // that finds it replies.
    expect(removal.split('self.pendingSiriRemovals.removeValue(forKey: token)')).toHaveLength(3)
    expect(removal).toContain('pending.cancel()')
    // The deadline never claims the shortcut is gone.
    const deadline = removal.slice(removal.indexOf('let deadline'), removal.indexOf('pendingSiriRemovals[token] = deadline'))
    expect(deadline).not.toContain('"removed": true')
  })

  it('returns completed video recordings as the documented base64 string', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-video-recording-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { enableVideoRecording: true },
    })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('if let movieURL = info[.mediaURL] as? URL')
    expect(swift).toContain('Data(contentsOf: movieURL, options: .mappedIfSafe)')
    expect(swift).toContain('result: "data:video/quicktime;base64," + base64')
    expect(swift).toContain('error: "Failed to process video: \\(error.localizedDescription)"')
  })

  it('generates a native Live Activity extension when enabled', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-live-activity-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { enableLiveActivities: true },
    })

    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    expect(project).toContain('WildLoopLiveActivity:')
    expect(project).toContain('type: app-extension')
    expect(swift).toContain('startLiveActivity')
    expect(swift).toContain('craft.liveActivity = {')
    expect(swift).toContain("{id: idOrState}")
    expect(swift.split('activities.first(where: { $0.id == activityId })')).toHaveLength(3)
    expect(swift).toContain('endLiveActivity(body: body, callbackId: callbackId)')
    expect(swift).toContain('saveHealthWorkout')
    expect(swift).toContain('HKWorkoutRouteBuilder')
    expect(plist).toContain('NSSupportsLiveActivities')
    expect(existsSync(join(output, 'Shared', 'CraftActivityAttributes.swift'))).toBe(true)
    expect(existsSync(join(output, 'WidgetExtension', 'WildLoopLiveActivity.swift'))).toBe(true)
  })

  it('seeds each page load\'s callback ids above every id already handed out', async () => {
    // #226: the page's counter restarted at 0 on every injection, and native
    // recorded nothing about which load a call came from — so an answer owed
    // to a call made before a reload settled whichever call on the new page
    // drew the same number.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-callback-ids-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('private var highestCallbackId = 0')
    expect(swift).toContain('_callbackId: \\(highestCallbackId)')
    expect(swift).not.toContain('_callbackId: 0,')

    // Raised from the message handler, so it covers the ids Zig serves too,
    // and before `offer` rather than after it.
    expect(swift).toContain('noteCallbackId(callbackId)')
    expect(swift).toContain('if drawn > highestCallbackId { highestCallbackId = drawn }')
    expect(swift.indexOf('noteCallbackId(callbackId)'))
      .toBeLessThan(swift.indexOf('if CraftZigRuntime.offer('))
  })

  it('gives every Swift-only call that waits on a framework callback a deadline', async () => {
    // #224: each of these is answered only by Swift, on both runtimes, and
    // only by a framework callback no person is waiting on. Nothing settled
    // the page's promise if it never came — the shape #211 hit twice on CI.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-swift-deadlines-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    // One mechanism, and both halves of it: arming alone would never answer,
    // claiming alone would let both paths answer.
    expect(swift).toContain('private func armDeadline(')
    expect(swift).toContain('private func claimDeadline(_ token: UUID) -> Bool')
    expect(swift).toContain('guard let work = pendingDeadlines.removeValue(forKey: token) else { return false }')
    // It reports a timeout, never the work having happened.
    expect(swift).toContain('self.rejectCallback(callbackId, error: error, code: "TIMEOUT")')

    // Five call sites, each with its own budget, all well under the 30s the
    // page's own _invoke allows so the caller hears the native answer.
    for (const [constant, uses] of [
      ['notificationSettingsDeadline', 1],
      ['pushRegistrationDeadline', 1],
      ['storeKitDeadline', 1],
      // Live Activities share one budget across update and end.
      ['liveActivityDeadline', 2],
    ] as const) {
      expect(swift).toContain(`private static let ${constant}: TimeInterval =`)
      expect(swift.match(new RegExp(`Coordinator\\.${constant},`, 'g'))?.length).toBe(uses)
    }
    // Every arm has a claim. Five sites arm; the claims are those five plus
    // the push helper's own and the two places it is reached through.
    expect(swift.match(/armDeadline\(/g)?.length).toBe(6)
    expect(swift.match(/claimDeadline\(/g)?.length).toBe(8)

    // The push registration's second call used to overwrite the first's
    // callbackId, so the first promise never settled at all.
    const register = swift.slice(
      swift.indexOf('private func registerPushNotifications('),
      swift.indexOf('@objc private func receivePushToken('),
    )
    expect(register).toContain('if let displaced = pendingPushCallbackId {')
    expect(register).toContain('Replaced by another push registration')
    // Armed after the grant, not at dispatch: the prompt has a person in front
    // of it and must not be timed out.
    expect(register.indexOf('UIApplication.shared.registerForRemoteNotifications()'))
      .toBeGreaterThan(register.indexOf('Coordinator.pushRegistrationDeadline'))

    // A token that arrives late still reaches a page listening for the event,
    // even though the caller that timed out is gone.
    const receive = swift.slice(
      swift.indexOf('@objc private func receivePushToken('),
      swift.indexOf('@objc private func receiveNotificationResponse('),
    )
    expect(receive).toContain('if let claimed = claimPushRegistration() { resolveCallback(claimed, result: token) }')
    expect(receive).toContain('sendToWeb("craftPushToken", data: ["token": token])')
  })

  it('falls back to the bundle only when the remote is out of reach, and comes back', async () => {
    // #252: any failed or cancelled main-frame load sent the app to its bundled
    // copy for the rest of the process. The classifier's answers are run for
    // real by scripts/load-failure.ts; this pins that it is actually consulted,
    // and that the way back is wired.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-load-failure-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    // Both failure callbacks go through the classifier, and neither reaches
    // the fallback directly any more — which is the whole bug.
    const failures = swift.slice(
      swift.indexOf('func webView(_ webView: WKWebView, didFailProvisionalNavigation'),
      swift.indexOf('private func fallBackIfUnreachable('),
    )
    expect(failures.match(/fallBackIfUnreachable\(webView, after: error\)/g)?.length).toBe(2)
    expect(failures).not.toContain('loadBundledFallback(in: webView)')
    expect(swift).toContain('guard CraftLoadFailure.isUnreachable(error) else { return }')

    // No longer one-way: two ways back to the remote origin. Bound the reset
    // to the named recovery function, because `private var
    // loadedBundledFallback = false` declares the field with the same text —
    // an unbounded assertion passes on the declaration alone, and passed
    // before this recovery existed at all.
    expect(swift).toContain('private func returnFromBundledFallback(because reason: String)')
    const recovery = swift.slice(
      swift.indexOf('private func returnFromBundledFallback(because reason: String)'),
      swift.indexOf('@objc private func appWillEnterForeground('),
    )
    // A renamed boundary must fail here rather than widen the slice back to
    // the whole file and quietly restore the hole this replaces.
    expect(recovery.length).toBeGreaterThan(0)
    expect(recovery.length).toBeLessThan(swift.length / 2)
    expect(recovery).toContain('loadedBundledFallback = false')
    expect(recovery).toContain('webView.load(URLRequest(url: remote))')
    expect(swift).toContain('name: UIApplication.willEnterForegroundNotification')

    // And the network trigger retries on a transition only. Retrying whenever
    // the path is satisfied would loop against a server that is down on a
    // network that is up.
    expect(swift).toContain('let wasConnected = self?.isConnected ?? true')
    expect(swift).toContain('if !wasConnected, self?.isConnected == true {')
  })

  it('holds a notification tap that launches the app until the page is ready', async () => {
    // A tap on a killed app reaches the app delegate before SwiftUI has built
    // the Coordinator. It was posted through NotificationCenter, which keeps
    // nothing for an observer that does not exist yet, so the tap was lost.
    // CraftEventManager exists from process start and holds it, as it already
    // does for a home-screen shortcut.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-notification-tap-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    const didReceive = swift.slice(
      swift.indexOf('didReceive response: UNNotificationResponse'),
      swift.indexOf('willPresent notification: UNNotification'),
    )
    expect(didReceive).toContain('CraftEventManager.shared.handleNotificationResponse(')
    expect(didReceive).not.toContain('NotificationCenter.default.post(')

    // And only that path: a Coordinator still observing a NotificationCenter
    // post would deliver a warm tap twice.
    expect(swift).not.toContain('name: .craftNotificationResponse')
    expect(swift).not.toContain('func receiveNotificationResponse(')

    // It goes through the manager's buffer rather than straight to the page.
    const handle = swift.slice(swift.indexOf('func handleNotificationResponse('))
    expect(handle.slice(0, handle.indexOf('\n    }\n'))).toContain('sendToWeb("craftNotificationResponse"')
  })

  it('tells the page about a notification that arrives while the app is open', async () => {
    // willPresent used to show the banner and nothing else, so a page on
    // screen when a push landed heard about it only if someone tapped it.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-notification-received-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    const willPresent = swift.slice(swift.indexOf('willPresent notification: UNNotification'))
    const body = willPresent.slice(0, willPresent.indexOf('\n    }\n'))
    expect(body).toContain('CraftEventManager.shared.handleNotificationReceived(notification.request.content.userInfo)')
    // Told, not asked: the banner still shows.
    expect(body).toContain('completionHandler([.banner, .badge, .sound])')

    const handle = swift.slice(swift.indexOf('func handleNotificationReceived('))
    expect(handle.slice(0, handle.indexOf('\n    }\n'))).toContain('sendToWeb("craftNotificationReceived"')
  })

  it('schedules a local notification with the data the page gave it', async () => {
    // #258: `data` never reached userInfo, so a tap on a scheduled
    // notification handed the page {} and it had nothing to route on.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-notification-data-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output, config: { enableLocalNotifications: true } })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    const schedule = swift.slice(swift.indexOf('private func scheduleLocalNotification('))
    const body = schedule.slice(0, schedule.indexOf('\n        }\n'))
    expect(body).toContain('if let info = data["data"] as? [String: Any] { content.userInfo = info }')
    // Set on the content the request is made from, before it is filed.
    expect(body.indexOf('content.userInfo = info')).toBeLessThan(body.indexOf('UNNotificationRequest(identifier: id, content: content'))
  })

  it('asks again when Core Location has no fix yet, rather than failing the caller', async () => {
    // #260: kCLErrorLocationUnknown rejected a getCurrentPosition whose fix
    // was seconds away. requestLocation gives up on it, so the one-shot asks
    // again while the same caller waits; its timeout still bounds the wait.
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-location-no-fix-'))
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output, config: { enableGeolocation: true } })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    const failed = swift.slice(swift.indexOf('didFailWithError error: Error) {'))
    const body = failed.slice(0, failed.indexOf('\n        }\n'))
    const noFixYet = body.indexOf('nativeError.code == CLError.Code.locationUnknown.rawValue')
    expect(noFixYet).toBeGreaterThan(-1)
    // Decided before anything settles the caller or tells the page.
    expect(noFixYet).toBeLessThan(body.indexOf('finishSingleLocationRequest()'))
    expect(noFixYet).toBeLessThan(body.indexOf('rejectCallback('))
    expect(noFixYet).toBeLessThan(body.indexOf('sendToWeb("craftLocationError"'))
    // Asks again only for the caller that was told to wait.
    expect(body).toContain('guard let self, self.singleLocationCallbackId == waiting else { return }')
    expect(body).toContain('self.locationManager?.requestLocation()')
  })

  it('settles calendar callbacks only after a real EventKit operation', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-calendar-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { enableCalendar: true },
    })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('guard let store = eventStore else {')
    expect(swift).toContain('try store.save(event, span: .thisEvent)')
    expect(swift).toContain('guard let identifier = event.eventIdentifier else {')
    expect(swift).toContain('try store.remove(event, span: .thisEvent)')
    expect(swift).not.toContain('self!.eventStore!')
    expect(swift).not.toContain('try self?.eventStore?.save')
    expect(swift).not.toContain('try eventStore?.remove')
  })

  it('settles contacts callbacks only after a real Contacts operation', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-contacts-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { enableContacts: true },
    })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    expect(swift).toContain('guard let store = contactStore else {')
    expect(swift).toContain('try store.enumerateContacts(with: request)')
    expect(swift).toContain('try store.execute(saveRequest)')
    expect(swift).not.toContain('try self?.contactStore?.enumerateContacts')
    expect(swift).not.toContain('try self?.contactStore?.execute')
  })

  it('generates an embedded watchOS companion when enabled', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-watch-'))
    const iosOutput = mkdtempSync(join(tmpdir(), 'craft-ios-watch-sibling-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { deviceFamilies: ['iphone'], enableWatchApp: true, watchosVersion: '9.0' },
    })
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output: iosOutput,
      config: { deviceFamilies: ['iphone'], watchosVersion: '9.0' },
    })

    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const watch = readFileSync(join(output, 'WatchExtension', 'WildLoopWatchApp.swift'), 'utf8')
    const watchInfo = readFileSync(join(output, 'WatchApp', 'Info.plist'), 'utf8')
    const watchExtensionInfo = readFileSync(join(output, 'WatchExtension', 'Info.plist'), 'utf8')
    expect(project).toContain('WildLoopWatch:')
    expect(project).toContain('type: application.watchapp2')
    expect(project).toContain('WildLoopWatchExtension:')
    expect(project).toContain('type: watchkit2-extension')
    expect(project).toContain('target: WildLoopWatchExtension')
    expect(project).toContain('platform: watchOS')
    expect(project).toContain('embed: true')
    expect(project).toContain('TARGETED_DEVICE_FAMILY: "1"')
    expect(swift).toContain('setupWatchConnectivity()')
    expect(swift).toBe(readFileSync(join(iosOutput, 'Sources', 'WildLoopApp.swift'), 'utf8'))
    expect(watch).toContain('recording-control')
    expect(watch).toContain('WCSessionDelegate')
    expect(watch).toContain('sessionDidBecomeInactive')
    expect(watch).toContain('sessionDidDeactivate')
    expect(watch).toContain('session.activate()')
    expect(watchInfo).toContain('<key>CFBundleIdentifier</key>')
    expect(watchInfo).toContain('<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>')
    expect(watchInfo).toContain('<key>CFBundleExecutable</key>')
    expect(watchInfo).toContain('<key>CFBundleShortVersionString</key>')
    expect(watchInfo).toContain('<string>org.wildloop.app</string>')
    expect(watchInfo).toContain('<key>WKWatchKitApp</key>')
    expect(watchInfo).toContain('<true/>')
    expect(watchExtensionInfo).toContain('<string>com.apple.watchkit</string>')
    expect(watchExtensionInfo).toContain('<string>org.wildloop.app.watchkitapp</string>')
    expect(existsSync(join(output, 'WatchApp', 'Info.plist'))).toBe(true)
    expect(existsSync(join(output, 'WatchApp', 'Watch.entitlements'))).toBe(true)
    expect(existsSync(join(output, 'WatchApp', 'WildLoopWatchApp.swift'))).toBe(false)
    expect(existsSync(join(output, 'WatchExtension', 'WildLoopWatchApp.swift'))).toBe(true)
    expect(existsSync(join(output, 'WatchExtension', 'Watch.entitlements'))).toBe(true)
  })
})

/**
 * Which simulator `run --simulator` picks.
 *
 * It used to pick none. The destination was the literal string `iPhone 15`, so
 * on a machine whose Xcode ships iPhone 17 and no iPhone 15 the command is
 * `xcodebuild: error: Unable to find a device named 'iPhone 15'` - a failure
 * with nothing to do with the app being built, and no hint in it about the fix.
 */
describe('choosing a simulator', () => {
  const device = (name: string, runtime: string, state = 'Shutdown') =>
    ({ name, udid: `${name}-${runtime}`, state, runtime })

  it('prefers one that is already booted', () => {
    // If a simulator is open, that is the one the developer is looking at.
    const chosen = orderSimulators([
      device('iPhone 17 Pro', 'iOS-27-0'),
      device('iPad Air', 'iOS-26-0', 'Booted'),
    ])[0]

    expect(chosen?.name).toBe('iPad Air')
  })

  it('then an iPhone over an iPad', () => {
    const chosen = orderSimulators([
      device('iPad Pro 13-inch', 'iOS-27-0'),
      device('iPhone 17', 'iOS-27-0'),
    ])[0]

    expect(chosen?.name).toBe('iPhone 17')
  })

  it('then the newest runtime', () => {
    const chosen = orderSimulators([
      device('iPhone 16', 'iOS-18-0'),
      device('iPhone 17 Pro', 'iOS-27-0'),
    ])[0]

    expect(chosen?.name).toBe('iPhone 17 Pro')
  })

  it('ignores simulators that cannot run an iOS app', () => {
    // Booted sorts ahead of everything, so an open Apple Watch or Apple TV
    // simulator would otherwise be handed back as the place to install an
    // iphonesimulator build.
    const chosen = orderSimulators([
      device('Apple Watch Series 10', 'watchOS-11-0', 'Booted'),
      device('Apple TV 4K', 'tvOS-18-0', 'Booted'),
      device('iPhone 17', 'iOS-27-0'),
    ])[0]

    expect(chosen?.name).toBe('iPhone 17')
  })

  it('returns nothing when only non-iOS simulators exist', () => {
    expect(orderSimulators([device('Apple Watch Series 10', 'watchOS-11-0', 'Booted')])[0]).toBeUndefined()
  })

  it('and never invents one that is not installed', () => {
    // The regression in one line: no devices means no device, rather than a
    // hard-coded name xcodebuild will refuse.
    expect(orderSimulators([])[0]).toBeUndefined()
  })

  it('leaves the array it was given alone', () => {
    const devices = [device('iPad Air', 'iOS-26-0'), device('iPhone 17', 'iOS-27-0')]
    orderSimulators(devices)

    expect(devices[0]?.name).toBe('iPad Air')
  })
})

describe('Zig runtime installation', () => {
  // A runtime directory holding *one* simulator slice, so `installRuntime`
  // takes the `cpSync` branch. The two-slice branch shells out to `lipo`,
  // which needs genuine Mach-O input and does not exist off macOS — it is
  // covered by building a real generated app, not from here. What these do
  // cover is everything around it: resolution, ordering, and the warning.
  function fakeRuntime(archives = ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a']): string {
    const dir = mkdtempSync(join(tmpdir(), 'craft-rt-'))
    for (const a of archives) writeFileSync(join(dir, a), 'stand-in for an archive')
    return dir
  }

  it('resolves an explicit directory, and null means no runtime whatever the environment says', () => {
    const dir = fakeRuntime()
    const saved = process.env.CRAFT_IOS_RUNTIME
    process.env.CRAFT_IOS_RUNTIME = dir
    try {
      // The gap this closes: the suite used to inherit the developer's shell,
      // and went from 12 passing to 8 passing and 4 failing when this variable
      // happened to be set.
      expect(resolveRuntimeDir(null)).toBeNull()
      expect(resolveRuntimeDir(dir)).toBe(dir)
      expect(resolveRuntimeDir()).toBe(dir)
    }
    finally {
      if (saved === undefined) delete process.env.CRAFT_IOS_RUNTIME
      else process.env.CRAFT_IOS_RUNTIME = saved
    }
  })

  it('names the source in the error, so a bad path says which knob set it', () => {
    expect(() => resolveRuntimeDir('/no/such/runtime')).toThrow(/runtimeDir is/)
  })

  it('writes one archive name per SDK, which is what a single -lcraft-ios needs', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-out-'))
    expect(await installRuntime(output, fakeRuntime())).toBe(true)
    expect(existsSync(join(output, 'Runtime', 'device', 'libcraft-ios.a'))).toBe(true)
    expect(existsSync(join(output, 'Runtime', 'simulator', 'libcraft-ios.a'))).toBe(true)
  })

  it('warns when only one simulator slice is present, rather than shipping it silently', async () => {
    const warnings: string[] = []
    const saved = console.warn
    console.warn = (...args: unknown[]) => void warnings.push(args.join(' '))
    try {
      await installRuntime(mkdtempSync(join(tmpdir(), 'craft-out-')), fakeRuntime())
    }
    finally {
      console.warn = saved
    }
    // RUNTIME_ARCHIVES' own comment calls this the failure that "only shows up
    // on someone else's laptop", so it must not be silent.
    expect(warnings.join('\n')).toContain('libcraft-ios-simulator-x64.a')
  })

  it('leaves a working install alone when the source directory is incomplete', async () => {
    // The ordering bug: validation ran after the wipe, so a bad runtime dir
    // destroyed the archives already in place and left project.yml linking
    // against a Runtime/ that no longer existed.
    const output = mkdtempSync(join(tmpdir(), 'craft-out-'))
    await installRuntime(output, fakeRuntime())
    const installed = join(output, 'Runtime', 'device', 'libcraft-ios.a')
    expect(existsSync(installed)).toBe(true)

    const empty = mkdtempSync(join(tmpdir(), 'craft-rt-empty-'))
    await expect(installRuntime(output, empty)).rejects.toThrow(/has none of/)
    expect(existsSync(installed)).toBe(true)
  })

  it('renders both SDK search paths and forces the four entry points', () => {
    const settings = renderRuntimeSettings()
    expect(settings).toContain('LIBRARY_SEARCH_PATHS[sdk=iphoneos*]')
    expect(settings).toContain('LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]')
    // Without -u the linker drops the whole archive as unreachable, because
    // nothing in the Swift references these symbols — both seams use dlsym.
    for (const sym of ['handle_action', 'set_webview', 'deliver_result', 'deliver_error']) {
      expect(settings).toContain(`-Wl,-u,_craft_ios_${sym}`)
    }
    // Six-space indent: this is spliced into project.yml under `settings:`.
    for (const line of settings.split('\n')) expect(line.startsWith('      ')).toBe(true)
  })

  it('generates a project whose settings match whether a runtime was installed', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-app-'))
    await init({ runtimeDir: fakeRuntime(), name: 'HasRuntime', output })
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toContain('-lcraft-ios')

    // And re-running without one leaves no orphaned archives claiming otherwise.
    await init({ runtimeDir: null, name: 'HasRuntime', output })
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).not.toContain('-lcraft-ios')
    expect(existsSync(join(output, 'Runtime'))).toBe(false)
  })
})

describe('runtime staleness', () => {
  function runtimeWith(marker: string): string {
    const dir = mkdtempSync(join(tmpdir(), 'craft-rt-'))
    for (const a of ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a']) {
      writeFileSync(join(dir, a), marker)
    }
    return dir
  }

  it('build picks up a rebuilt runtime instead of relinking the one init copied', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-app-'))
    await init({ runtimeDir: runtimeWith('first build'), name: 'Stale', output })
    const installed = join(output, 'Runtime', 'device', 'libcraft-ios.a')
    expect(readFileSync(installed, 'utf8')).toBe('first build')

    // The dev loop: edit Zig, rebuild the archives, run the app again. Before
    // this, xcodebuild relinked the copy from init and the change was absent
    // with no error anywhere.
    await build({ output, runtimeDir: runtimeWith('second build'), generateProject: false })
    expect(readFileSync(installed, 'utf8')).toBe('second build')
  })

  it('build leaves a runtimeless project alone rather than installing one behind init', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-app-'))
    await init({ runtimeDir: null, name: 'NoRuntime', output })
    expect(existsSync(join(output, 'Runtime'))).toBe(false)

    // A runtime is available, but this project does not link one: its
    // project.yml has no link settings, so archives here would be dead weight.
    await build({ output, runtimeDir: runtimeWith('ignored'), generateProject: false })
    expect(existsSync(join(output, 'Runtime'))).toBe(false)
  })

  it('build keeps the installed runtime when no runtime directory is configured', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-app-'))
    await init({ runtimeDir: runtimeWith('from init'), name: 'Keep', output })
    // A shell that forgot the variable must not quietly turn the runtime off.
    await build({ output, runtimeDir: null, generateProject: false })
    expect(readFileSync(join(output, 'Runtime', 'device', 'libcraft-ios.a'), 'utf8')).toBe('from init')
  })
})
