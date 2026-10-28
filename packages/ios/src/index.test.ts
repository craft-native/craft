import { mkdtempSync, rmSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { gunzipSync } from 'node:zlib'
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createContext, runInContext } from 'node:vm'
import { afterAll, describe, expect, it } from 'bun:test'
import { addSchemeBuildTargets, addSchemeTestTargets, insertProjectTargetsBeforeSchemes } from '../scripts/insert-project-targets'
import {
  compressNativeSources,
  associatedDomainEntries,
  build,
  init,
  installRuntime,
  nativeMessages,
  nativeRouteBundles,
  nativeRouteRuntime,
  renderFeatureSettings,
  renderRuntimeSettings,
  resolveRuntimeDir,
  orderSimulators,
  pngHasAlpha,
  productName,
  readableTextOn,
  renderAppearance,
  renderOfflinePage,
  renderBackgroundModes,
  renderEntitlements,
  renderOrientations,
  renderPrivacyManifest,
  renderUsageDescriptions,
  renderAppBoundDomains,
  renderUrlTypes,
  renderWatchEntitlements,
  resolveCraftVersion,
  restoreShell,
  runPostGenerateHook,
  syncWebAssets,
  syncNativeFonts,
} from './index'
import { createTempDir, removeAllTempDirs } from '../../typescript/src/temp-dir'
import { iosPermissionMask, iosPermissionNames, iosPermissions, renderPermissionSource, verifyInstalledProfile, verifyRuntimeProfile, withAppRuntime } from './runtime-profile'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

function profileFixture(directory: string, names: string[]): void {
  writeFileSync(join(directory, 'ios-permissions.json'), JSON.stringify({ version: 1, mask: 0,
    sha256: Object.fromEntries(names.map(name => [name, createHash('sha256').update(readFileSync(join(directory, name))).digest('hex')])),
  }))
}

describe('Craft iOS builder', () => {
  it('bakes each permission gate into restored Swift without changing unrelated build conditions', () => {
    const source = iosPermissionNames.map(name => `#if CRAFT_PERMISSION_${name.toUpperCase()}\nuse_${name}()\n#endif`).join('\n')
    expect(renderPermissionSource(source, {})).not.toContain('#if CRAFT_PERMISSION_')
    expect(renderPermissionSource(source, {}).match(/#if false/g)).toHaveLength(13)
    const selected = renderPermissionSource(source, { enableVideoRecording: true })
    expect(selected.match(/#if true/g)).toHaveLength(3)
    expect(selected).toContain('#if true\nuse_microphone()')
    expect(renderPermissionSource('#if CRAFT_APPLE_MUSIC\n#endif\n#if DEBUG', {})).toBe('#if false\n#endif\n#if DEBUG')
    expect(() => renderPermissionSource('#if CRAFT_PERMISSION_UNKNOWN', {})).toThrow('Unknown Swift permission gate')
  })

  it('keeps source and plist permissions synchronized during restore, without accumulating edits', async () => {
    const output = createTempDir('craft-permission-restore-')
    await init({ name: 'PermissionRestore', output, runtimeDir: null, config: { enableCamera: true } })
    const plistPath = join(output, 'Info.plist')
    const sourcePath = join(output, 'Sources', 'PermissionRestoreApp.swift')
    const configPath = join(output, 'craft.config.json')
    expect(readFileSync(plistPath, 'utf8')).toContain('NSCameraUsageDescription')
    writeFileSync(plistPath, readFileSync(plistPath, 'utf8').replace('</dict>', '<key>AppOwnedValue</key><string>keep me</string>\n</dict>'))
    const config = JSON.parse(readFileSync(configPath, 'utf8'))
    config.enableCamera = false
    config.enableVideoRecording = true
    writeFileSync(configPath, JSON.stringify(config))
    restoreShell(output)
    expect(readFileSync(plistPath, 'utf8')).toContain('NSMicrophoneUsageDescription')
    config.enableVideoRecording = false
    writeFileSync(configPath, JSON.stringify(config))
    restoreShell(output)
    const plist = readFileSync(plistPath, 'utf8')
    expect(plist).not.toContain('NSCameraUsageDescription')
    expect(plist).not.toContain('NSMicrophoneUsageDescription')
    expect(plist).toContain('<key>AppOwnedValue</key><string>keep me</string>')
    expect(readFileSync(sourcePath, 'utf8')).toContain('#if false\n        let cameraEnabled = true')
    const unchangedTime = new Date('2000-01-01T00:00:00Z')
    utimesSync(sourcePath, unchangedTime, unchangedTime)
    const appOwned = join(output, 'Sources', 'AppOwned.swift')
    writeFileSync(appOwned, '#if CRAFT_PERMISSION_CUSTOM\n// App-owned source\n#endif')
    restoreShell(output)
    expect(readFileSync(plistPath, 'utf8')).toBe(plist)
    expect(statSync(sourcePath).mtimeMs).toBe(unchangedTime.getTime())
    expect(readFileSync(appOwned, 'utf8')).toContain('#if CRAFT_PERMISSION_CUSTOM')
  })

  it('omits all default purpose strings and keeps explicit custom descriptions opt-in', () => {
    const base = { appName: 'Permissions', bundleId: 'dev.craft.permissions' }
    expect(renderUsageDescriptions(base).trim()).toBe('')
    const custom = renderUsageDescriptions({ ...base, usageDescriptions: { NSCameraUsageDescription: 'A & B <photos>', NSMicrophoneUsageDescription: '  ' } })
    expect(custom).toContain('A &amp; B &lt;photos&gt;')
    expect(custom).not.toContain('NSMicrophoneUsageDescription')
    expect(renderUsageDescriptions({ ...base, enableVideoRecording: true })).toContain('NSMicrophoneUsageDescription')
  })

  it('derives independent permission bits and feature dependencies without using purpose strings as feature flags', () => {
    expect(iosPermissionMask({})).toBe(0)
    expect(iosPermissions({ enableVideoRecording: true })).toEqual(['microphone', 'camera', 'photos'])
    expect(iosPermissions({ enableSpeechRecognition: true })).toEqual(['speech', 'microphone'])
    expect(iosPermissions({ enableBackgroundLocation: true, enableHeartRate: true })).toEqual(['location', 'bluetooth'])
    expect(iosPermissions({ enableAR: true, enableQRScanner: true })).toEqual(['camera'])
    expect(iosPermissions({ usageDescriptions: { NSCameraUsageDescription: 'Custom' } })).toEqual([])
    const zig = readFileSync(join(import.meta.dir, '../../zig/src/ios_permissions.zig'), 'utf8')
    const order = zig.slice(zig.indexOf('enum(u4) {') + 'enum(u4) {'.length, zig.indexOf('    pub fn bit'))
    expect(order.trim().split(',').map(value => value.trim()).filter(Boolean)).toEqual([...iosPermissionNames])
  })

  it('builds a fresh per-app archive profile with the pinned toolchain and rejects stale or altered archives', async () => {
    const source = createTempDir('craft-ios-runtime-source-')
    writeFileSync(join(source, 'build.zig.zon'), '.{ .minimum_zig_version = "1.2.3" }')
    const executable = join(source, 'zig')
    writeFileSync(executable, `#!${process.execPath}
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
if (process.argv[2] === 'version') { console.log('1.2.3'); process.exit(0); }
const args = process.argv.slice(2);
if (!args.includes('-Dios-permissions=camera,photos') || !args.includes('build-ios-all')) process.exit(2);
const dir = join(args[args.indexOf('--prefix') + 1], 'lib'); mkdirSync(dir, { recursive: true });
for (const name of ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a']) writeFileSync(join(dir, name), 'fixture ' + name);
writeFileSync(join(dir, 'ios-permissions.json'), JSON.stringify({ version: 1, mask: 12 }));
`)
    chmodSync(executable, 0o755)
    const previous = process.env.CRAFT_ZIG
    process.env.CRAFT_ZIG = executable
    let built = ''
    try {
      await withAppRuntime(source, { enableCamera: true }, async (directory) => {
        built = directory
        expect(() => verifyRuntimeProfile(directory, { enableCamera: true })).not.toThrow()
        expect(() => verifyRuntimeProfile(directory, {})).toThrow('does not match')
        writeFileSync(join(directory, 'libcraft-ios.a'), 'different archive')
        expect(() => verifyRuntimeProfile(directory, { enableCamera: true })).toThrow('identity mismatch')
      })
      expect(existsSync(built)).toBe(false)
      writeFileSync(join(source, 'build.zig.zon'), '.{ .minimum_zig_version = "9.9.9" }')
      await expect(withAppRuntime(source, {}, async () => { throw new Error('must not install') })).rejects.toThrow('requires Zig 9.9.9')
    }
    finally {
      if (previous === undefined) delete process.env.CRAFT_ZIG
      else process.env.CRAFT_ZIG = previous
    }
  }, 30_000)
  it('uses a system tab controller for native and hybrid route stacks', () => {
    const shell = readFileSync(join(import.meta.dir, '../templates/CraftHybrid.swift'), 'utf8')
    expect(shell).toContain('CraftHybridController: UITabBarController, UITabBarControllerDelegate')
    expect(shell).toContain('setViewControllers(controllers, animated: false)')
    expect(shell).toContain('item.badgeValue = tab.badge')
    expect(shell).toContain('UITabAccessory(contentView: accessoryButton)')
    expect(shell).toContain('tabBarMinimizeBehavior = .never')
    expect(shell).toContain('iconOnly')
    expect(shell).toContain('accessoryBadge')
    const screen = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')
    expect(screen).toContain('setContentScrollView(scroll, for: [.top, .bottom])')
    expect(screen).toContain('setContentScrollView(nil, for: [.top, .bottom])')
    const app = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
    const hybrid = app.slice(app.indexOf('if CraftHybrid.shared.isEnabled {'), app.indexOf('} else if appState.config.renderer == "native"'))
    expect(hybrid).not.toContain('CraftTabBarView()')
    const legacy = app.slice(app.indexOf('} else if appState.config.renderer == "native"'))
    expect(legacy).toContain('CraftTabBarView()')
  })
  it('runs a declared postGenerate command from the project root with metadata', async () => {
    const output = createTempDir('craft-ios-post-generate-')
    await init({ name: 'Hook App', output, runtimeDir: null, config: {
      postGenerate: { command: 'sh', args: ['-c', 'printf "%s|%s|%s" "$PWD" "$CRAFT_PLATFORM" "$CRAFT_GENERATE_PHASE" > hook.txt'] },
    } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.postGenerate).toEqual({ command: 'sh', args: ['-c', 'printf "%s|%s|%s" "$PWD" "$CRAFT_PLATFORM" "$CRAFT_GENERATE_PHASE" > hook.txt'] })
    runPostGenerateHook(config.postGenerate, output)
    expect(readFileSync(join(output, 'hook.txt'), 'utf8')).toBe(`${realpathSync(output)}|ios|build`)
  })

  it('runs the postGenerate hook after the iOS builder generates its Xcode project', async () => {
    const root = createTempDir('craft-ios-post-generate-build-')
    const output = join(root, 'app')
    const xcodegen = join(root, 'xcodegen')
    writeFileSync(xcodegen, '#!/bin/sh\nmkdir -p HookBuild.xcodeproj\n')
    chmodSync(xcodegen, 0o755)
    const previousPath = process.env.PATH
    process.env.PATH = `${root}:${previousPath ?? ''}`
    try {
      await init({ name: 'Hook Build', output, runtimeDir: null, config: {
        postGenerate: { command: 'sh', args: ['-c', 'test -d HookBuild.xcodeproj && printf "%s" "$CRAFT_GENERATE_PHASE" > hook-phase.txt'] },
      } })
      await build({ output, runtimeDir: null })
      expect(readFileSync(join(output, 'hook-phase.txt'), 'utf8')).toBe('build')
    }
    finally {
      if (previousPath === undefined) delete process.env.PATH
      else process.env.PATH = previousPath
    }
  })

  it('reports invalid iOS postGenerate commands and non-zero exits', () => {
    const output = createTempDir('craft-ios-post-generate-errors-')
    expect(() => runPostGenerateHook({ command: '' }, output)).toThrow('postGenerate.command must be a non-empty executable')
    expect(() => runPostGenerateHook({ command: join(output, 'missing-hook') }, output)).toThrow('postGenerate hook could not start')
    expect(() => runPostGenerateHook({ command: 'sh', args: ['-c', 'printf "patch failed" >&2; exit 7'] }, output))
      .toThrow('postGenerate hook failed')
  })

  it('generates static tab-bar selection appearance and validates its shape', async () => {
    const output = createTempDir('craft-ios-tab-bar-appearance-')
    await init({ name: 'Tab Bar', output, runtimeDir: null, config: {
      tabBar: { selection: { cornerRadius: 8, color: '#123456' } },
    } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const swift = readFileSync(join(output, 'Sources', 'TabBarApp.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    expect(config.tabBar).toEqual({ selection: { cornerRadius: 8, color: '#123456' } })
    expect(swift).toContain('private(set) var tabSelectionColor: UIColor?')
    expect(swift).toContain('appearance: CraftConfig.TabBar? = nil')
    expect(swift).toContain('chrome.tabSelectionColor.map { Color($0) }')
    expect(swift).toContain('@ObservedObject private var chrome = CraftChrome.shared')
    expect(hybrid).toContain('appearance: config.tabBar')
    await expect(init({ name: 'Invalid Tab Bar', output: join(output, 'invalid'), runtimeDir: null, config: {
      tabBar: { selection: { cornerRadius: -1 } },
    } })).rejects.toThrow('cornerRadius must be a finite non-negative number')
    await expect(init({ name: 'Invalid Tab Color', output: join(output, 'invalid-color'), runtimeDir: null, config: {
      tabBar: { selection: { color: 'red' } },
    } })).rejects.toThrow('color must be a #RRGGBB color')
  })

  it('restores the shell with the actual Xcode Cloud build identity without changing other resources', () => {
    const output = createTempDir('craft-cloud-identity-')
    const file = join(output, 'craft.config.json')
    const original = { appName: 'Cloud App', bundleId: 'com.example.cloud', version: '1.0.0', buildNumber: '73', renderer: 'native', custom: { retained: true } }
    writeFileSync(file, JSON.stringify(original))
    writeFileSync(join(output, 'Info.plist'), '<plist><dict><key>XcodeOwned</key><string>metadata</string></dict></plist>')
    writeFileSync(join(output, 'native-screen.js'), 'immutable compiled screens')
    const saved = process.env.CI_BUILD_NUMBER
    try {
      process.env.CI_BUILD_NUMBER = '74'
      restoreShell(output)
      expect(JSON.parse(readFileSync(file, 'utf8'))).toEqual({ ...original, buildNumber: '74' })
      expect(readFileSync(join(output, 'Info.plist'), 'utf8')).toContain('<key>XcodeOwned</key><string>metadata</string>')
      expect(readFileSync(join(output, 'native-screen.js'), 'utf8')).toBe('immutable compiled screens')
      expect(existsSync(join(output, 'Sources', 'CloudAppApp.swift'))).toBe(true)
      const restored = readFileSync(file, 'utf8')
      restoreShell(output)
      expect(readFileSync(file, 'utf8')).toBe(restored)
      delete process.env.CI_BUILD_NUMBER
      writeFileSync(file, JSON.stringify(original))
      restoreShell(output)
      expect(readFileSync(file, 'utf8')).toBe(JSON.stringify(original))
    }
    finally {
      if (saved === undefined) delete process.env.CI_BUILD_NUMBER
      else process.env.CI_BUILD_NUMBER = saved
    }
  })

  it('rejects invalid Xcode Cloud build numbers before changing the restored project', () => {
    const output = createTempDir('craft-cloud-identity-invalid-')
    const file = join(output, 'craft.config.json')
    const original = JSON.stringify({ appName: 'Cloud App', bundleId: 'com.example.cloud', buildNumber: '73' })
    writeFileSync(file, original)
    const saved = process.env.CI_BUILD_NUMBER
    try {
      for (const value of ['', '0', '-1', '1.2', ' 74', '74\n', 'hash']) {
        process.env.CI_BUILD_NUMBER = value
        expect(() => restoreShell(output)).toThrow('CI_BUILD_NUMBER must be a positive integer')
        expect(readFileSync(file, 'utf8')).toBe(original)
        expect(existsSync(join(output, 'Sources'))).toBe(false)
      }
    }
    finally {
      if (saved === undefined) delete process.env.CI_BUILD_NUMBER
      else process.env.CI_BUILD_NUMBER = saved
    }
  })

  it('bundles custom fonts with their licenses and removes retired fonts', async () => {
    const root = createTempDir('craft-native-fonts-')
    const font = join(root, 'Signature.ttf')
    const license = join(root, 'OFL.txt')
    const output = join(root, 'app')
    writeFileSync(font, new Uint8Array([0, 1, 0, 0, 7, 8]))
    writeFileSync(license, 'Test font license')
    await init({ name: 'Font App', output, runtimeDir: null, config: {
      renderer: 'native', nativeFonts: { 'Signature-Regular': { src: font, license } },
    } })
    const bundled = join(output, 'NativeFonts')
    expect(readFileSync(join(output, 'Info.plist'), 'utf8')).toContain('<string>NativeFonts/Signature-Regular.ttf</string>')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    expect(plist.indexOf('<key>UIAppFonts</key>')).toBeLessThan(plist.indexOf('<key>UILaunchScreen</key>'))
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toContain('- path: NativeFonts')
    expect([...readFileSync(join(bundled, 'Signature-Regular.ttf'))]).toEqual([0, 1, 0, 0, 7, 8])
    expect(readFileSync(join(bundled, 'Signature-Regular.LICENSE.txt'), 'utf8')).toBe('Test font license')
    expect(() => syncNativeFonts({ Signature: { src: join(bundled, 'Signature-Regular.ttf') } }, output)).toThrow('sources must be outside')
    expect(existsSync(join(bundled, 'Signature-Regular.ttf'))).toBe(true)
    expect(() => syncNativeFonts({ Signature: { src: font }, signature: { src: font } }, output)).toThrow('Duplicate native font')
    syncNativeFonts({}, output)
    expect(existsSync(bundled)).toBe(false)
    await init({ name: 'Font App', output, runtimeDir: null, config: { renderer: 'native' } })
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).not.toContain('- path: NativeFonts')
    expect(readFileSync(join(output, 'Info.plist'), 'utf8')).not.toContain('<key>UIAppFonts</key>')
    expect(() => syncNativeFonts({ '../escape': { src: font } }, output)).toThrow('Invalid native font')
    expect(() => syncNativeFonts({ Missing: { src: join(root, 'missing.ttf') } }, output)).toThrow('existing TTF or OTF')
    expect(() => syncNativeFonts({ Signature: { src: font, license: join(root, 'missing-license') } }, output)).toThrow('license not found')
  })

  it('resolves the package version from bundled module directories', () => {
    const version = JSON.parse(readFileSync(join(import.meta.dir, '..', 'package.json'), 'utf8')).version
    expect(resolveCraftVersion(resolve(import.meta.dir, '..', 'dist', 'ios', 'src'))).toBe(version)
    expect(resolveCraftVersion(resolve(import.meta.dir, '..', 'dist', 'ios', 'src', 'nested'))).toBe(version)
  })

  it('reads the version from craft-native when the builder is bundled inside it', () => {
    const root = createTempDir('craft-native-bundle-')
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'craft-native', version: '9.8.7' }))
    expect(resolveCraftVersion(join(root, 'dist', 'ios', 'src'))).toBe('9.8.7')
  })

  it('inserts simulator test targets before the shared schemes block', () => {
    const project = 'targets:\n  App:\n    type: application\n\nschemes:\n  App:\n    build:\n      targets:\n        App: all\n    test:\n      config: Debug\n'
    const result = insertProjectTargetsBeforeSchemes(project, '  AppTests:\n    type: bundle.unit-test')
    expect(result.indexOf('  AppTests:')).toBeLessThan(result.indexOf('schemes:'))
    const withTests = addSchemeTestTargets(result, 'App', ['AppTests'])
    expect(withTests).toContain('    test:\n      config: Debug\n      targets:\n        - AppTests')
    const withBuild = addSchemeBuildTargets(withTests, 'App', ['AppTests'])
    expect(withBuild).toContain('        App: all\n        AppTests: [test]')
  })

  it('keeps WebView as the default and opt-in native screens load a compiled bundle', async () => {
    const output = createTempDir('craft-ios-native-')
    await init({ runtimeDir: null, name: 'Native Slice', output, config: { renderer: 'native' } })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const swift = readFileSync(join(output, 'Sources', 'NativeSliceApp.swift'), 'utf8')
    const nativeSwift = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    const guide = readFileSync(join(import.meta.dir, '../../../docs/guides/native-stx.md'), 'utf8')
    const flatListSwift = readFileSync(join(output, 'Sources', 'CraftNativeFlatList.swift'), 'utf8')
    const actionsSwift = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const mutationSwift = readFileSync(join(output, 'Sources', 'CraftNativeMutation.swift'), 'utf8')
    expect(config.renderer).toBe('native')
    expect(swift).toContain('if appState.config.renderer == "native"')
    expect(swift).toContain('// CRAFT_IOS_PAGE_BRIDGE_DISPATCHER')
    expect(swift).toContain('#if compiler(>=6.2)')
    expect(swift).toContain('GlassEffectContainer')
    expect(nativeSwift).toContain('import JavaScriptCore')
    expect(nativeSwift).not.toContain('WKWebView')
    expect(nativeSwift).toContain('CraftNativeActions.perform(')
    expect(nativeSwift).toContain('private static func safeJavaScriptString(_ value: JSValue?)')
    expect(nativeSwift).toContain('guard let value, !value.isUndefined, !value.isNull, value.isString else { return nil }')
    expect(nativeSwift).not.toContain('let message = exception?.toString()')
    expect(nativeSwift).not.toContain('exception?.objectForKeyedSubscript("stack")?.toString()')
    expect(guide).toContain('`ScrollView` and `FlatList` emit the scroll callbacks described above, accept')
    expect(nativeSwift).toContain('platform: "ios"')
    expect(nativeSwift).toContain('mutationProtocolVersion: 1')
    expect(nativeSwift).toContain('CraftNativeScriptThread.run(label: "unmount \\(route)") {')
    expect(nativeSwift).toContain('storageLifetime.unmount { context.objectForKeyedSubscript("__stxNativeUnmount")?.call(withArguments: []) }')
    expect(nativeSwift).toContain('capabilityProtocolVersion: \\(craftNativeCapabilityProtocolVersion)')
    expect(nativeSwift).toContain('capabilityTimeoutMs: \\(craftNativeCapabilityTimeoutMilliseconds)')
    expect(nativeSwift).toContain('"code": "TIMEOUT"')
    expect(nativeSwift).toContain('pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()')
    // Read on the main thread, before the script (maybe on its own thread) starts.
    expect(nativeSwift).toContain('appState: CraftNativeActions.currentAppState(),')
    expect(nativeSwift).toContain('initialAppState: "\\(inputs.appState)"')
    expect(nativeSwift).toContain('case "API_CANCEL":')
    expect(nativeSwift).toContain('let interval = Int(number(props["minuteInterval"]) ?? 1)')
    expect(nativeSwift).toContain('columns: Int(number(props["numColumns"]) ?? 1)')
    expect(nativeSwift).toContain('compactMap { number($0).map { Int($0) } }')
    expect(nativeSwift).toContain('guard let number = craftNativeNumber(value) else { return nil }')
    expect(nativeSwift).toContain('CFGetTypeID(number) != CFBooleanGetTypeID()')
    expect(nativeSwift).toContain('if let value = craftNativeNumber(value), value.doubleValue.isFinite { return String(value.doubleValue) }')
    expect(flatListSwift).toContain('guard let number = craftNativeNumber(value) else { return nil }')
    expect(nativeSwift).toContain("request('Dialog', 'alert', [options || {}], true)")
    expect(nativeSwift).toContain("request('Shortcuts', 'set', [items])")
    expect(nativeSwift).toContain("request('Shortcuts', 'clear', [])")
    expect(nativeSwift).toContain("actionSheet: function(options)")
    expect(nativeSwift).toContain('bridge.addMessageListener')
    expect(nativeSwift).toContain('UIApplication.didBecomeActiveNotification')
    expect(nativeSwift).toContain('DeepLinkManager.shared.addNativeListener')
    expect(nativeSwift).toContain('navigationController?.topViewController === self')
    expect(nativeSwift).toContain('final class CraftNativeFrameClock: NSObject')
    expect(nativeSwift).toContain('let link = CADisplayLink(target: self, selector: #selector(frame(_:)))')
    expect(nativeSwift).toContain('link.add(to: .main, forMode: .common)')
    expect(nativeSwift).toContain('if waiting.isEmpty { link.isPaused = true }')
    expect(nativeSwift).toContain('private class CraftNativeFlowView: UIStackView')
    expect(nativeSwift).toContain('let frameCount = output.count')
    expect(nativeSwift).toContain('private func sharedTreeFrames(')
    expect(nativeSwift).toContain('craft_native_layout_tree_v4')
    expect(nativeSwift).toContain('private static func treeFramesV4(')
    expect(nativeSwift).toContain('input.gridAutoRows = node.gridAutoRows.map')
      expect(nativeSwift).toContain('craft_native_layout_tree_v5')
      expect(nativeSwift).toContain('private static func treeFramesV5(')
      expect(nativeSwift).toContain('input.gridRows = UInt32(max(0, node.gridRows ?? 0))')
    expect(nativeSwift).not.toContain('guard gridAutoRows == nil else { return nil }')
    expect(nativeSwift).toContain('offset.x - parentFrame.x')
    expect(nativeSwift).toContain('let maxContent = label.sizeThatFits(CGSize(width: unbounded, height: unbounded))')
    expect(nativeSwift).toContain('collapses shrink-to-fit bubbles and pills')
    expect(nativeSwift).toContain('UIImage(systemName: indeterminate ? "minus.square" : "checkmark.square.fill")')
    expect(nativeSwift).toContain('self.textContainer.lineFragmentPadding = 0')
    expect(nativeSwift).toContain('required init(coder: NSCoder)')
    expect(nativeSwift).toContain('required init?(coder: NSCoder) { nil }')
    expect(nativeSwift).toContain('UIResponder.keyboardWillChangeFrameNotification')
    expect(nativeSwift).toContain('self.additionalSafeAreaInsets.bottom = globalInset')
    expect(nativeSwift).toContain('stack.wrap = flexWrap == "wrap" || flexWrap == "wrap-reverse"')
    expect(nativeSwift).toContain('stack.wrapReverse = flexWrap == "wrap-reverse"')
    expect(nativeSwift).toContain('defaultShrink = horizontal ? 1 : 0')
    expect(nativeSwift).toContain('stack.alignContent = style["alignContent"] as? String ?? "flex-start"')
    expect(nativeSwift).toContain('crossOffset += lineCross + crossBetween')
    expect(nativeSwift).toContain('craftLayoutStyle.position == "absolute"')
    expect(nativeSwift).toContain('style.minWidth')
    expect(nativeSwift).toContain('case .percent(let fraction): return base.map { max(0, $0 * fraction) }')
    expect(nativeSwift).toContain('marginTop: CGFloat')
    expect(nativeSwift).toContain('items[$1].mainMargins')
    expect(nativeSwift).toContain('let elevation = max(0, number(style["elevation"]) ?? 0)')
    expect(nativeSwift).toContain('number(style["shadowOpacity"]) ?? (elevation > 0')
    expect(nativeSwift).toContain('flexGrow')
    expect(nativeSwift).toContain('func fallbackWidths(for line: Range<Int>, available: CGFloat, gap: CGFloat)')
    expect(nativeSwift).toContain('frozen.insert(offset)')
    expect(nativeSwift).toContain('style.alignSelf ?? alignItems')
    expect(nativeSwift).toContain('let desiredKeyboardType = keyboardType(props["keyboardType"])')
    expect(nativeSwift).toContain('if field.keyboardType != desiredKeyboardType')
    expect(nativeSwift).toContain('if field.isSecureTextEntry != desiredSecureEntry')
    expect(nativeSwift).toContain('placeholderTextColor')
    expect(nativeSwift).toContain('textMaxLengths')
    expect(nativeSwift).toContain('shouldChangeCharactersIn range: NSRange')
    expect(nativeSwift).toContain('let desiredReturnKeyType = returnKeyType(props["returnKeyType"])')
    expect(nativeSwift).toContain('case "ActivityIndicator":')
    expect(nativeSwift).toContain('CraftNativeActivityIndicatorView(style: .medium)')
    expect(nativeSwift).toContain('case "Slider":')
    expect(nativeSwift).toContain('slider.value = snappedSliderValue(value, for: slider)')
    expect(nativeSwift).toContain('events["onSlidingComplete"]')
    expect(nativeSwift).toContain('case "Picker":')
    // Vector drawing (stx svg.ts): an Svg draws its shapes' geometry
    // commands, and a change to a shape redraws its Svg.
    expect(nativeSwift).toContain('final class CraftNativeSvgView: UIView')
    expect(nativeSwift).toContain('private var overlayCoordinatesByID: [String: [CLLocationCoordinate2D]] = [:]')
    expect(nativeSwift).toContain('let staleOverlays = overlaysByID.keys.filter { nextPolylines[$0] == nil }')
    expect(nativeSwift).toContain('Self.coordinatesEqual(coordinates, value.coordinates)')
    expect(nativeSwift).toContain('private static func coordinatesEqual(_ lhs: [CLLocationCoordinate2D], _ rhs: [CLLocationCoordinate2D])')
    expect(nativeSwift).toContain('guard authoredWidth.isFinite, width.isFinite, width > 0 else { continue }')
    expect(nativeSwift).toContain('(-90...90).contains(latitude), (-180...180).contains(longitude)')
    expect(nativeSwift).toContain('latitudeDelta > 0, latitudeDelta <= 180, longitudeDelta > 0, longitudeDelta <= 360')
    expect(nativeSwift).toContain('latitude - latitudeDelta / 2 >= -90, latitude + latitudeDelta / 2 <= 90')
    expect(nativeSwift).toContain('case "Svg":')
    expect(nativeSwift).toContain('flatListOwners[candidate] ?? svgOwners[candidate] ?? candidate')
    expect(nativeSwift).toContain('path.addCurve(to: point(i + 5), controlPoint1: point(i + 1), controlPoint2: point(i + 3))')
    expect(nativeSwift).toContain('size.width * box.height / box.width')
    // A chart stretched to its box (preserveAspectRatio="none") keeps its
    // strokes' width (vector-effect="non-scaling-stroke").
    expect(nativeSwift).toContain('if preserveAspectRatio?.trimmingCharacters(in: .whitespaces) != "none" {')
    expect(nativeSwift).toContain('let nonScaling = own.vectorEffect == "non-scaling-stroke"')
    expect(nativeSwift).toContain('line.lineCapStyle = own.linecap')
    expect(nativeSwift).toContain('line.lineJoinStyle = own.linejoin')
    expect(nativeSwift).toContain('line.setLineDash(dashes, count: dashes.count, phase: own.strokeDashoffset)')
    expect(nativeSwift).toContain('context.concatenate(viewTransform.inverted())')
    expect(nativeSwift).toContain('guard n.count == 4, n.allSatisfy(\\.isFinite), n[2] > 0, n[3] > 0 else { return nil }')
    // A linear gradient (stx bg-gradient-to-*) is drawn under the subviews.
    expect(nativeSwift).toContain('private final class CraftNativeGradientLayer: CAGradientLayer')
    expect(nativeSwift).toContain('direction: style["gradientDirection"] as? String')
    // A styled button keeps its padding (px-4 py-2) instead of hugging its label.
    expect(nativeSwift).toContain('private final class CraftNativeButton: UIButton')
    expect(nativeSwift).toContain('let button = CraftNativeButton(type: .system)')
    expect(nativeSwift).toContain('(button as? CraftNativeButton)?.padding = paddingInsets(style)')
    expect(nativeSwift).toContain('UIPickerViewDataSource, UIPickerViewDelegate')
    expect(nativeSwift).toContain('pickerOptions[pickerID] = options')
    expect(nativeSwift).toContain('private final class CraftNativeModalView: UIView')
    expect(nativeSwift).toContain('modal.setVisible(visible, opacity: number(style["opacity"]) ?? 1, animationType: props["animationType"] as? String)')
    expect(nativeSwift).toContain('if let propVisible = props["visible"] as? Bool')
    expect(nativeSwift).toContain('visible = display != nil && display != "none"')
    expect(nativeSwift).toContain('!($0.element is CraftNativeModalView)')
    expect(nativeSwift).toContain('button.isEnabled = props["disabled"] as? Bool != true')
    expect(nativeSwift).toContain('let transformedTitle = transformedText(title, style: style)')
    expect(nativeSwift).toContain('private func transformedText(_ text: String, style: [String: Any])')
    expect(nativeSwift).toContain('buttonTitleAttributes(style, color: titleColor, font: font, forceUnderline: type == "Link")')
    expect(nativeSwift).toContain('button.contentHorizontalAlignment = buttonAlignment(style["textAlign"])')
    expect(nativeSwift).toContain('field.defaultTextAttributes = inputTextAttributes(style, font: field.font ?? .systemFont(ofSize: 16), alignment: field.textAlignment)')
    expect(nativeSwift).toContain('textView.typingAttributes = attributes')
    expect(nativeSwift).toContain('textView.selectedRange = selectedRange')
    expect(nativeSwift).toContain('updateAuxiliaryHandler(events["onSubmitEditing"], in: &submitHandlers, for: textView)')
    expect(nativeSwift).toContain('if text == "\\n", let handler = submitHandlers[ObjectIdentifier(textView)]')
    expect(nativeSwift).toContain('textView.keyboardType = keyboardType(props["keyboardType"])')
    expect(nativeSwift).toContain('case "numeric", "number-pad": return .numberPad')
    expect(nativeSwift).toContain('case "web-search": return .webSearch')
    expect(nativeSwift).toContain('case "visible-password": return .asciiCapable')
    expect(nativeSwift).toContain('textView.returnKeyType = returnKeyType(props["returnKeyType"])')
    expect(nativeSwift).toContain('textView.isSecureTextEntry = props["secureTextEntry"] as? Bool == true')
    expect(nativeSwift).toContain('events["onSlidingComplete"]')
    expect(nativeSwift).toContain('minimumTrackTintColor')
    expect(nativeSwift).toContain('sliderFinished')
    expect(nativeSwift).toContain('toggle.onTintColor')
    expect(nativeSwift).toContain('toggle.thumbTintColor')
    expect(nativeSwift).toContain('toggle.onTintColor = color(style["color"])')
    expect(nativeSwift).toContain('imageLoadStartHandlers')
    expect(nativeSwift).toContain('imageLoadEndHandlers')
    expect(nativeSwift).toContain('imageFailure')
    expect(nativeSwift).toContain('private var imageErrors: [ObjectIdentifier: String] = [:]')
    expect(nativeSwift).toContain('imageTasks.removeValue(forKey: id)?.cancel()')
    expect(nativeSwift).toContain('image.withRenderingMode(tintedImages.contains(ObjectIdentifier(view)) ? .alwaysTemplate : .alwaysOriginal)')
    expect(nativeSwift).toContain('private func imageDidChange(_ view: UIImageView)')
    expect(nativeSwift).toContain('view.invalidateIntrinsicContentSize()')
    expect(nativeSwift).toContain('CraftNativeFlexLayout.invalidateAncestors(of: view)')
    expect(nativeSwift).toContain('case "cover": return .scaleAspectFill')
    expect(nativeSwift).toContain('private func restoreFocus(_ focused: UIView?)')
    expect(nativeSwift).toContain('if rootStyle["flex"] == nil, rootStyle["height"] == nil { rootStyle["flex"] = 1 }')
    expect(nativeSwift).toContain('let lifecycleHandler = visible ? events["onShow"] : events["onDismiss"]')
    expect(nativeSwift).toContain('if let lifecycleHandler = nonEmptyHandler(lifecycleHandler) {')
    expect(nativeSwift).not.toContain('consumeDismissSuppression')
    expect(nativeSwift).toContain('_ = focused.becomeFirstResponder()')
    expect(nativeSwift).toContain('let focused = firstResponder(in: rootStack)')
    expect(nativeSwift).toContain('private weak var lastFocusedInput: UIView?')
    expect(nativeSwift).toContain('if let handler, !handler.isEmpty { handlers[id] = handler }')
    expect(nativeSwift).toContain('let handler = handler?.isEmpty == false ? handler : nil')
    expect(nativeSwift).toContain('list.onScrollEvent = nonEmptyHandler(events["onScroll"]).map')
    expect(nativeSwift).toContain('endReached: nonEmptyHandler(events["onEndReached"]).map')
    expect(nativeSwift).toContain('nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"])')
    expect(nativeSwift).toContain('nonEmptyHandler(events["onChange"]) ?? nonEmptyHandler(events["onChangeText"])')
    expect(nativeSwift).toContain('nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"])')
    expect(nativeSwift).toContain('UITextViewDelegate')
    expect(nativeSwift).toContain('textViewDidChange')
    expect(nativeSwift).toContain('numberOfLines')
    expect(nativeSwift).toContain('CraftNativeTextView')
    expect(nativeSwift).toContain('placeholderTextColor')
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
    expect(nativeSwift).toContain('scroll.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])')
    expect(nativeSwift).toContain('case "on-drag": return .onDrag')
    expect(nativeSwift).toContain('list.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])')
    expect(nativeSwift).toContain('?? (direction == .vertical)')
    expect(nativeSwift).toContain('|| flexDirection == "row-reverse"')
    expect(nativeSwift).toContain('if let control = view as? UIControl')
    expect(nativeSwift).toContain('accessibilityValue')
    expect(nativeSwift).toContain('} else if type != "TextInput" {\n            view.accessibilityValue = nil')
    expect(nativeSwift).not.toContain('else if type == "TextInput", let field = view as? UITextField')
    expect(nativeSwift).toContain('traits.insert(.notEnabled)')
    expect(nativeSwift).toContain('traits.insert(.selected)')
    expect(nativeSwift).toContain('if !ownsTouches(view) { view.isUserInteractionEnabled = handlers[id] != nil || linkTargets[id] != nil || longPressHandlers[id] != nil || view is CraftNativeFlowView }')
    expect(nativeSwift).toContain('if let control = view as? UIControl {')
    expect(nativeSwift).toContain('else if handlers[ObjectIdentifier(view)] != nil || longPressHandlers[ObjectIdentifier(view)] != nil {')
    expect(flatListSwift).toContain('UICollectionViewDiffableDataSource<Int, String>')
    expect(flatListSwift).toContain('reconfigureItems(changedLive)')
    expect(flatListSwift).toContain('preferredLayoutAttributesFitting')
    expect(flatListSwift).toContain('attributes.size = CGSize(width: max(1, ceil(measured.width + margins.left + margins.right)), height: max(1, height))')
    expect(flatListSwift).toContain('attributes.size = CGSize(width: max(1, width), height: max(1, ceil(measured.height + margins.top + margins.bottom)))')
    expect(flatListSwift).toContain('let fittingExtent = list?.itemExtent(isChrome: isChrome)')
    expect(flatListSwift).toContain('func fittingHeight(width: CGFloat) -> CGFloat')
    expect(flatListSwift).toContain('pendingApply')
    expect(swift).toContain('CraftNativeActions.perform(action: action, body: body, config: config)')
    expect(swift).toContain('private var nativeListeners: [UUID: (canReceive: () -> Bool, receive: (URL, Bool) -> Void)] = [:]')
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
    expect(actionsSwift).toContain('case ("Badge", "set"):')
    expect(actionsSwift).toContain('case ("Badge", "clear"):')
    expect(actionsSwift).toContain('case ("DeepLinks", "getInitialURL")')
    expect(actionsSwift).toContain('DeepLinkManager.shared.resolveInitialURL { url in')
    expect(actionsSwift).toContain('private static func claimInitialDeepLink(_ url: URL?) -> URL?')
    expect(actionsSwift).toContain('guard !initialDeepLinkClaimed else { return nil }')
    expect(actionsSwift).toContain('case ("SecureStorage", _)')
    expect(actionsSwift).toContain('case ("Biometrics", "authenticate")')
    expect(actionsSwift).toContain('import LocalAuthentication')
    expect(actionsSwift).toContain('case ("Passkeys", "create"), ("Passkeys", "get"):')
    expect(actionsSwift).toContain('webcredentials associated domain')
    expect(actionsSwift).toContain('ASAuthorizationPlatformPublicKeyCredentialProvider')
    expect(actionsSwift).toContain('import Security')
    // fetch: a URLSession task per request token, cancelled with the request.
    expect(actionsSwift).toContain('var values = ["device", "clipboard", "haptics", "storage", "lifecycle", "fetch", "dialog", "speech", "audio", "eventStream", "linking", "badge", "animation", "viewFocus", "viewMeasure", "viewReparent", "viewNonModalPresentation", "nativePlatformControls"]')
    expect(actionsSwift).toContain('case ("Network", "fetch"):')
    expect(actionsSwift).toContain('let craftNativeFetchTimeoutSeconds: TimeInterval = 30')
    expect(actionsSwift).toContain('fetchTasks[requestToken] = task')
    expect(actionsSwift).toContain('let task = fetchTasks.removeValue(forKey: requestToken)')
    expect(actionsSwift).toContain('task?.cancel()')
    expect(actionsSwift).toContain('"fetch needs an absolute http or https URL"')
    expect(actionsSwift).toContain('"A GET or HEAD request cannot have a body"')
    expect(actionsSwift).toContain('"fetch header values must be strings"')
    expect(actionsSwift).toContain('"fetch body must be a string"')
    expect(actionsSwift).toContain('failure("RESPONSE_TOO_LARGE"')
    expect(actionsSwift).toContain('"status": http.statusCode,')
    expect(actionsSwift).toContain('"body": String(decoding: body, as: UTF8.self),')
    // Timers: JavaScriptCore has none, and route teardown cancels them.
    expect(nativeSwift).toContain('if (typeof globalThis.setTimeout !== \'function\') {')
    expect(nativeSwift).toContain('globalThis.clearTimeout = function(id) {')
    expect(nativeSwift).toContain('jsContext.setObject(scheduleTimer, forKeyedSubscript: "craftNativeScheduleTimer" as NSString)')
    expect(nativeSwift).toContain('CraftNativeScriptThread.run { timers.pending.values.forEach { $0.cancel() } }')
    expect(guide).toContain('const response = await fetch(')

    await expect(build({ output, generateProject: false, runtimeDir: null })).rejects.toThrow('native-screen.js')
    const bundle = join(output, 'compiled.js')
    writeFileSync(bundle, 'globalThis.screenLoaded = true')
    await build({ output, nativeBundlePath: bundle, generateProject: false, runtimeDir: null })
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('globalThis.screenLoaded = true')
    await build({ output, nativeBundlePath: join(output, 'dist', 'native-screen.js'), generateProject: false, runtimeDir: null })

    // A directory of route bundles (stx's routesDir) replaces the one-file
    // bundle, and the one file replaces the routes again: the app prefers a
    // route's own file, so a stale one beside the fresh layout would run.
    const routes = join(output, 'routes')
    mkdirSync(routes)
    writeFileSync(join(routes, 'Home.js'), 'globalThis.home = true')
    writeFileSync(join(routes, '__app.js'), 'globalThis.app = true')
    await build({ output, nativeBundlePath: routes, generateProject: false, runtimeDir: null })
    expect(readFileSync(join(output, 'dist', 'native-screens', 'Home.js'), 'utf8')).toBe('globalThis.home = true')
    expect(existsSync(join(output, 'dist', 'native-screens', '__app.js'))).toBe(true)
    expect(existsSync(join(output, 'dist', 'native-screen.js'))).toBe(false)
    await build({ output, generateProject: false, runtimeDir: null })
    await build({ output, nativeBundlePath: bundle, generateProject: false, runtimeDir: null })
    expect(existsSync(join(output, 'dist', 'native-screens'))).toBe(false)
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('globalThis.screenLoaded = true')
    mkdirSync(join(output, 'empty-routes'))
    await expect(build({ output, nativeBundlePath: join(output, 'empty-routes'), generateProject: false, runtimeDir: null })).rejects.toThrow('Native route bundles not found')
    expect(nativeRouteBundles).toBe(true)
    expect(nativeRouteRuntime).toBe(true)
    expect(nativeMessages).toBe(true)
    // Each screen runs from its route's file when there is one, in one
    // shared virtual machine, with the one-file bundle as the fallback.
    expect(nativeSwift).toContain('subdirectory: "dist/native-screens"')
    expect(nativeSwift).toContain('JSContext(virtualMachine: CraftNativeBundle.virtualMachine)')
    expect(nativeSwift).toContain('jsContext.evaluateScript(bundle.source, withSourceURL: bundle.url)')
    // A route file runs on stx's shared runtime prelude, evaluated first and
    // as a source of its own so the shared VM parses it once.
    expect(nativeSwift).toContain('forResource: "__runtime", withExtension: "js", subdirectory: "dist/native-screens"')
    expect(nativeSwift.indexOf('jsContext.evaluateScript(runtime.source, withSourceURL: runtime.url)')).toBeLessThan(nativeSwift.indexOf('jsContext.evaluateScript(bundle.source, withSourceURL: bundle.url)'))
    // A language's messages are read for a screen when it first looks inside
    // them (stx's `messages`), from beside the route files, and only by name.
    expect(nativeSwift).toContain('jsContext.setObject(readMessages, forKeyedSubscript: "__stxNativeReadMessages" as NSString)')
    expect(nativeSwift).toContain('CraftNativeBundle.messages(language: language, area: area) ?? NSNull()')
    expect(nativeSwift).toContain('.appendingPathComponent("__messages", isDirectory: true)')
    expect(nativeSwift).toContain('area.range(of: #"^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil')
    await expect(build({ output, htmlPath: bundle, generateProject: false, runtimeDir: null })).rejects.toThrow('cannot use --html-path')
    await expect(init({ runtimeDir: null, name: 'Invalid', output: join(output, 'invalid'), config: { renderer: 'canvas' as 'native' } })).rejects.toThrow('Unknown iOS renderer')
  })

  it('copies a complete web distribution and removes stale assets', () => {
    const root = createTempDir('craft-ios-assets-')
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

  it('keeps native route teardown and missing-bundle fallback explicit', async () => {
    const output = createTempDir('craft-ios-native-lifecycle-')
    await init({ runtimeDir: null, name: 'NativeLifecycle', output, config: { renderer: 'native' } })

    const native = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(native).toContain('showError("Missing dist/native-screen.js. Compile a .stx screen with `stx native compile` first.")')
    expect(native).toContain('imageTasks.values.forEach { $0.cancel() }')
    expect(native).toContain('pendingCapabilityDeadlines.values.forEach { $0.cancel() }')
    expect(native).toContain('CraftNativeScriptThread.run { timers.pending.values.forEach { $0.cancel() } }')
    expect(native).toContain('pendingCapabilityRequests.forEach { CraftNativeActions.cancel(requestToken: $0) }')
    expect(native).toContain('self?.runtimeDisposed != false ? false : ok')
    expect(native).toContain('let snapshotSet: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, done in')
    expect(native).toContain('let snapshotClear: @convention(block) (JSValue, JSValue) -> Void = { [weak self] keep, done in')
    expect(native).toContain('storageLifetime.access(closedValue: nil) { CraftSnapshots.read(name) }')
    expect(native).toContain('storageLifetime.access(closedValue: ()) {\n                CraftSnapshots.write(name, json: json)')
    expect(native).toContain('storageLifetime.access(closedValue: ()) {\n                CraftSnapshots.clear(keeping: Set(names))')
    expect(native).toContain('never as a successful write into a dead runtime')
    expect(native).toContain('lifecycleObservers.forEach(NotificationCenter.default.removeObserver)')
    expect(native).not.toContain('WKWebView')
  })

  it('keeps hybrid routes on the WebView when the native bundle is absent', async () => {
    const output = createTempDir('craft-ios-hybrid-missing-bundle-')
    await init({
      runtimeDir: null,
      name: 'HybridFallback',
      output,
      config: {
        renderer: 'web',
        devServerURL: 'https://example.com/home',
        nativeScreens: { '/home': 'Home' },
      },
    })

    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    expect(hybrid).toContain('if hybrid.isEnabled, let match = hybrid.routes.match(path)')
  })

  it('keeps hybrid external links on the configured scheme and port', async () => {
    const output = createTempDir('craft-ios-hybrid-site-origin-')
    await init({
      runtimeDir: null,
      name: 'HybridSiteOrigin',
      output,
      config: { renderer: 'web', devServerURL: 'https://example.com:8443/home' },
    })

    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    expect(hybrid).toContain('let siteScheme = site?.scheme?.lowercased(), scheme == siteScheme')
    expect(hybrid).toContain('url.port == site?.port')
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
    // Disabled APIs are compiled out of both the shell and per-app runtime.
    expect(renderUsageDescriptions(config)).not.toContain('NSCameraUsageDescription')
    for (const key of ['NSSpeechRecognitionUsageDescription', 'NSMicrophoneUsageDescription', 'NSCalendarsUsageDescription', 'NSMotionUsageDescription', 'NSContactsUsageDescription'])
      expect(renderUsageDescriptions(config)).not.toContain(`<key>${key}</key>`)
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

  it('tells a screen its width, at launch and whenever it changes, for width classes', () => {
    const source = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    // stx applies sm:/md:/lg: classes for this width (an iPad, split view, Stage Manager).
    expect(source).toContain('viewportWidth: \\(inputs.viewportWidth),')
    expect(source).toContain('sendViewportIfChanged()')
    expect(source).toContain('send(type: "VIEWPORT", payload: ["width": Double(width), "height": Double(view.bounds.height)])')
    expect(source).toContain('guard width > 0, abs(width - reportedViewportWidth) >= 0.5 else { return }')
  })

  it('preserves native shortcut requests through the full prelude and bundle namespace replacement', async () => {
    const source = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    // Execute the actual two template preludes, including any later keep()
    // registrations. A source-string assertion cannot catch accessor replacement.
    function prelude(anchor: string): string {
      const marker = source.indexOf(anchor)
      expect(marker).toBeGreaterThan(-1)
      const opening = 'jsContext.evaluateScript("""'
      const start = source.lastIndexOf(opening, marker) + opening.length
      const end = source.indexOf('""")', marker)
      expect(end).toBeGreaterThan(start)
      return source.slice(start, end)
    }
    const requests: Array<{ module: string, method: string, args: unknown[] }> = []
    const sandbox: {
      __stxNativeBridge: { capabilities: string[], postMessage: (raw: string) => void }
      __stxNativeCallback?: (message: unknown) => void
    } = {
      __stxNativeBridge: {
        capabilities: ['shortcuts'],
        postMessage(raw) {
          const message = JSON.parse(raw)
          requests.push({ module: message.payload.module, method: message.payload.method, args: message.payload.args })
          sandbox.__stxNativeCallback?.({ type: 'API_RESPONSE', payload: {
            requestId: message.id, data: message.payload.method === 'set' ? { count: 1 } : true,
          } })
        },
      },
    }
    const context = createContext(sandbox)
    runInContext(prelude('var bridge = globalThis.__stxNativeBridge;'), context)
    const nativeSetter = runInContext('Object.getOwnPropertyDescriptor(craft, "shortcuts").set', context)
    runInContext(prelude('function keep(name, extras)'), context)
    // Exercise bootstrap *before* loadBundle's reinstall can hide the regression,
    // and normal calls after that reinstall too.
    for (const reinstall of [false, true]) {
      if (reinstall) runInContext('__craftInstallNativeDialog()', context)
      for (const replacement of ['{extra:42}', '{extra:42,set:function(){return false},clear:function(){return false}}', 'null', 'undefined']) {
        runInContext(`craft.shortcuts = ${replacement}`, context)
        expect(await runInContext('craft.shortcuts.set([{type:"saved",title:"Saved"}])', context)).toEqual({ count: 1 })
        expect(await runInContext('craft.shortcuts.clear()', context)).toBe(true)
        expect(runInContext('craft.shortcuts.extra', context)).toBe(42)
      }
      if (!reinstall) expect(runInContext('Object.getOwnPropertyDescriptor(craft, "shortcuts").set', context)).toBe(nativeSetter)
    }
    expect(requests).toEqual(Array.from({ length: 8 }, () => [
      { module: 'Shortcuts', method: 'set', args: [[{ type: 'saved', title: 'Saved' }]] },
      { module: 'Shortcuts', method: 'clear', args: [] },
    ]).flat())
  })

  it('keeps native workout discard available across older bundle initialization', async () => {
    const source = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const marker = source.indexOf('var bridge = globalThis.__stxNativeBridge;')
    const opening = 'jsContext.evaluateScript("""'
    const prelude = source.slice(source.lastIndexOf(opening, marker) + opening.length, source.indexOf('""")', marker))
    for (const enabled of [false, true]) {
      const requests: unknown[] = []
      const sandbox: { __stxNativeBridge: unknown, __stxNativeCallback?: (message: unknown) => void } = {
        __stxNativeBridge: { capabilities: enabled ? ['health'] : [], postMessage(raw: string) {
          const message = JSON.parse(raw)
          requests.push(message.payload)
          sandbox.__stxNativeCallback?.({ type: 'API_RESPONSE', payload: { requestId: message.id, data: true } })
        } },
      }
      const context = createContext(sandbox)
      runInContext(prelude, context)
      if (!enabled) {
        expect(runInContext('craft.health', context)).toBeUndefined()
        expect(requests).toEqual([])
        continue
      }
      for (const replacement of ['{endWorkout:function(){throw new Error("must not save")}}', '{discardWorkout:function(){return false}}', 'null', 'undefined']) {
        runInContext(`craft.health = ${replacement}`, context)
        expect(await runInContext('craft.health.discardWorkout()', context)).toBe(true)
      }
      runInContext('__craftInstallNativeDialog()', context)
      expect(await runInContext('craft.health.discardWorkout()', context)).toBe(true)
      expect(requests).toHaveLength(5)
      for (const request of requests) expect(request).toMatchObject({ module: 'Health', method: 'discardWorkout', args: [] })
    }
  })

  it('advertises mounted-view focus and measurement in native screens', () => {
    const source = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const actions = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeActions.swift'), 'utf8')
    expect(source).toContain('case ("View", "focus"):')
    expect(source).toContain('case ("View", "measure"):')
    expect(source).toContain('UIAccessibility.post(notification: .layoutChanged, argument: node.view)')
    expect(actions).toContain('"viewFocus", "viewMeasure"')
  })

  it('keeps sound playing with the screen locked only when the app asks for it', () => {
    const config = { appName: 'HQ.training', bundleId: 'training.hq.app' }
    expect(renderBackgroundModes(config)).toBe('')
    expect(renderBackgroundModes({ ...config, enableBackgroundAudio: true })).toBe('    <key>UIBackgroundModes</key>\n    <array>\n        <string>audio</string>\n    </array>')
    expect(renderBackgroundModes({ ...config, enableBackgroundAudio: true, enableHeartRate: true })).toContain('<string>bluetooth-central</string>\n        <string>audio</string>')
  })

  it('explains Apple Music access, in the app\'s own words when it gives them', () => {
    const config = { appName: 'HQ.training', bundleId: 'training.hq.app' }
    // The media-library implementation is compiled out when disabled (#424).
    expect(renderUsageDescriptions(config)).not.toContain('NSAppleMusicUsageDescription')
    expect(renderUsageDescriptions({ ...config, enableAppleMusic: false, usageDescriptions: { NSAppleMusicUsageDescription: '  ' } })).not.toContain('NSAppleMusicUsageDescription')
    expect(renderUsageDescriptions({ ...config, enableAppleMusic: true })).toContain('<string>HQ.training shows and controls the music playing in the Music app.</string>')
    const own = renderUsageDescriptions({
      ...config,
      enableAppleMusic: true,
      usageDescriptions: { NSAppleMusicUsageDescription: 'Shows the song you\'re training to & lets you skip it.', NSCameraUsageDescription: '  ' },
    })
    expect(own).toContain('<key>NSAppleMusicUsageDescription</key>\n    <string>Shows the song you&apos;re training to &amp; lets you skip it.</string>')
    // A blank override is no override.
    expect(own).not.toContain('NSCameraUsageDescription')
  })

  it('pairs the Music purpose string with its compiled implementation, including explicit overrides', async () => {
    for (const enabled of [false, true]) {
      const output = createTempDir('craft-ios-music-permission-')
      await init({ runtimeDir: null, name: 'MusicGate', output, config: { enableAppleMusic: enabled } })
      const settings = readFileSync(join(output, 'project.yml'), 'utf8')
      const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
      expect(settings.includes('CRAFT_APPLE_MUSIC')).toBe(enabled)
      expect(plist.includes('NSAppleMusicUsageDescription')).toBe(enabled)
      const source = readFileSync(join(output, 'Sources', 'CraftMusic.swift'), 'utf8')
      expect(source.startsWith(`#if ${enabled}\n`)).toBe(true)
      restoreShell(output)
      expect(readFileSync(join(output, 'Sources', 'CraftMusic.swift'), 'utf8')).toBe(source)
    }
    const config = { appName: 'MusicGate', bundleId: 'dev.craft.musicgate', enableAppleMusic: false,
      usageDescriptions: { NSAppleMusicUsageDescription: '  A custom player reads my library.  ' } }
    expect(renderUsageDescriptions(config)).toContain('<string>A custom player reads my library.</string>')
    // A purpose string is metadata, not permission to compile a feature in.
    expect(renderFeatureSettings(config)).not.toContain('CRAFT_APPLE_MUSIC')
    expect(renderFeatureSettings({ enableScheduledWorkouts: true, enableAppleMusic: true })).toContain('CRAFT_SCHEDULED_WORKOUTS CRAFT_APPLE_MUSIC')
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
    const dir = createTempDir('craft-ios-icon-')
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
    const dir = createTempDir('craft-ios-splash-')
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
    const output = createTempDir('craft-ios-scheme-')
    await init({ runtimeDir: null, name: 'SchemeApp', bundleId: 'org.example.scheme', output })
    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    expect(project).toContain('schemes:\n  SchemeApp:\n    build:\n      targets:\n        SchemeApp: all')
    expect(project).toContain('    archive:\n      config: Release')
  })

  it('generates a production project whose bundled index lives under dist', async () => {
    const output = createTempDir('craft-ios-project-')
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
    const output = createTempDir('craft-ios-secure-storage-')
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

    const output = createTempDir('craft-ios-dotted-')
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

    const output = createTempDir('craft-ios-appearance-')
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
    expect(swift).toContain('.preferredColorScheme(appState.appearanceScheme)')
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

  it('refreshes native screen backgrounds when the iOS trait changes', async () => {
    const output = createTempDir('craft-ios-native-trait-')
    await init({
      runtimeDir: null,
      name: 'NativeTraitRefresh',
      bundleId: 'org.example.native-trait',
      output,
      config: { renderer: 'native', appearance: 'system', backgroundColor: '#ffffff', backgroundColorDark: '#000000' },
    })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('traitCollectionDidChange')
    expect(source).toContain('config.resolvedBackgroundColor')
    expect(source).toContain('mutationDocument.node("root")')
    expect(source).toContain('renderCommitted(document)')
  })

  it('lets native screens pin UIKit appearance at launch and at runtime', async () => {
    const output = createTempDir('craft-ios-native-appearance-')
    await init({
      runtimeDir: null,
      name: 'NativeAppearance',
      bundleId: 'org.example.native-appearance',
      output,
      config: { renderer: 'native', appearance: 'system' },
    })
    const swift = readFileSync(join(output, 'Sources', 'NativeAppearanceApp.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(swift).toContain('CraftInterfaceStyleController.configure(config)')
    expect(swift).toContain('CraftInterfaceStyleController.set(appearance)')
    expect(swift).toContain('.preferredColorScheme(appState.appearanceScheme)')
    expect(swift).toContain('CraftInterfaceStyleController.colorScheme(for: self.config)')
    expect(swift).toContain('case "getAppearance":')
    expect(screen).toContain('CraftInterfaceStyleController.apply(to: self, config: config)')
    expect(screen).toContain('craftNativeSetAppearance')
    expect(screen).toContain("keep('app', {")
  })

  it('emits native layout measurements only when a view changes frame', async () => {
    const output = createTempDir('craft-ios-native-layout-')
    await init({
      runtimeDir: null,
      name: 'NativeLayout',
      bundleId: 'org.example.native-layout',
      output,
      config: { renderer: 'native' },
    })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('events["onLayout"]')
    expect(source).toContain('emitLayoutEvents()')
    expect(source).toContain('isEffectivelyVisible(node.view)')
    expect(source).toContain('if current.isHidden { return false }')
    expect(source).toContain('lastLayoutFrames[id] != frame')
    expect(source).toContain('"layout": [')
    expect(source).toContain('frame.minX')
    expect(source).toContain('frame.width')
    expect(source).toContain('CraftNativeGridBridge.frames')
    expect(source).toContain('UnsafeRawPointer')
    expect(source).toContain('let maxContent = label.sizeThatFits(CGSize(width: unbounded, height: unbounded))')
    expect(source).toContain('collapses shrink-to-fit bubbles and pills')
  })

  it('keeps an absolute root sibling pinned to the viewport beside a ScrollView', async () => {
    const output = createTempDir('craft-ios-native-root-viewport-')
    await init({ runtimeDir: null, name: 'NativeRootViewport', bundleId: 'org.example.native-root-viewport', output, config: { renderer: 'native' } })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('private weak var viewportChild: UIView?')
    expect(source).toContain('func setViewportChild(_ view: UIView?, fillsHeight: Bool)')
    expect(source).toContain('rootStack.setViewportChild(next.view, fillsHeight: rootStyle["height"] == nil)')
    expect(source).toContain('viewportFrame.size.height = bounds.height')
    expect(source).toContain('absolute sibling is positioned against the scroll content')
  })

  it('sizes intrinsic native grids from flow children only', async () => {
    const output = createTempDir('craft-ios-native-grid-intrinsic-')
    await init({ runtimeDir: null, name: 'NativeGridIntrinsic', bundleId: 'org.example.native-grid-intrinsic', output, config: { renderer: 'native' } })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('let flow = children.filter { $0.craftLayoutStyle.position != "absolute" }')
    expect(source).toContain('layoutGrid(flow,')
    expect(source).toContain('gridAutoRows = CraftNativeLength(raw["gridAutoRows"])')
    expect(source).toContain('private enum CraftNativeLength: Equatable')
    expect(source).toContain('var gridAutoRows: CraftNativeLength?')
    expect(source).toContain('autoRowHeight: gridAutoRows.map { $0.resolve(innerHeight) ?? 0 }')
    expect(source).toContain('if containsGridAutoRows(root)')
    expect(source).toContain('gridAutoRows: nested?.gridAutoRows')
      expect(source).toContain('gridRows: nested?.gridRows')
  })

  it('keeps native scroll views\' sticky headers stuck and scrolls to a target', async () => {
    const output = createTempDir('craft-ios-native-sticky-')
    await init({ runtimeDir: null, name: 'NativeSticky', bundleId: 'org.example.native-sticky', output, config: { renderer: 'native' } })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('scroll.setStickyHeaderIndices(props["stickyHeaderIndices"])')
    expect(source).toContain('scroll.setScrollTarget(props["scrollTarget"])')
    // Headers follow the scroll on every layout pass, over the content.
    expect(source).toContain('updateStickyHeaders()')
    expect(source).toContain('let visibleTop = contentOffset.y + adjustedContentInset.top')
    expect(source).toContain('contentStack.bringSubviewToFront(header)')
    // A target lands below the header that would cover it, and a repeated
    // target scrolls only when its key changes.
    expect(source).toContain('stickyHeight(above: rect.minY)')
    expect(source).toContain('guard key != scrollTargetKey else { return }')
    // A target created by the same render is retried until it is laid out.
    expect(source).toContain('pendingScrollTarget = (target.id, target.animated, target.attempts + 1)')
    // A transformed child is placed without its (undefined) frame.
    expect(source).toContain('if child.transform.isIdentity {')
    expect(source).toContain('if child.center != center { child.center = center; moved = true }')
    // Snapping never takes a pixel off a label, which would truncate it.
    expect(source).toContain('snapped.size = CraftNativeFlexLayout.ceiled(frame.size, scale: scale, atLeast: snapped.size)')
  })

  it('keeps transform angle parsing unambiguous for current Swift toolchains', async () => {
    const output = createTempDir('craft-ios-transform-angle-')
    await init({ runtimeDir: null, name: 'TransformAngle', bundleId: 'org.example.transform-angle', output, config: { renderer: 'native' } })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('return Double(text).map { CGFloat($0) }')
    expect(source).not.toContain('return Double(text).map(CGFloat.init)')
  })

  it('applies image tinting to every native image source', async () => {
    const output = createTempDir('craft-ios-native-image-tint-')
    await init({ runtimeDir: null, name: 'NativeImageTint', bundleId: 'org.example.native-image-tint', output, config: { renderer: 'native' } })
    const source = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(source).toContain('private var tintedImages = Set<ObjectIdentifier>()')
    expect(source).toContain('.alwaysTemplate')
    expect(source).toContain('imageForDisplay(image, view: view)')
  })

  it('reads Apple Health workouts and daily values, each with the statistic its type has', async () => {
    const output = createTempDir('craft-ios-health-')
    await init({ runtimeDir: null, name: 'Health', bundleId: 'com.example.health', output, config: { enableHealthKit: true } })
    // The page's bridge lives in the app; the HealthKit reads it calls, in CraftHealth.swift.
    const swift = readFileSync(join(output, 'Sources', 'HealthApp.swift'), 'utf8') + readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

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
    // A food log's day comes in summed, and asking to read it is asking for it.
    for (const identifier of ['.dietaryEnergyConsumed', '.dietaryProtein', '.dietaryCarbohydrates', '.dietaryFatTotal'])
      expect(swift).toContain(identifier)
    expect(swift).toContain('case "dietaryEnergy", "dietaryProtein", "dietaryCarbohydrates", "dietaryFat":')
    expect(swift).toContain('if !readOnly { shareTypes.insert(dietaryType) }')
    expect(swift).toContain('saveData: function(type, value, options) {')
    expect(swift).toContain("craft._invoke('saveHealthData', {type: type, value: value, startDate: options.startDate, endDate: options.endDate})")
    expect(swift).toContain('HKQuantitySample(')
    expect(swift).toContain('Unknown health data type: \\(type)')
    expect(swift).toContain('HKStatisticsCollectionQuery(')
    expect(swift).toContain('"id": workout.uuid.uuidString')
    // A reader asks to read only, and the sheet a person is reading is never
    // timed out from the page.
    expect(swift).toContain("readOnly: Boolean(options && options.write === false)")
    expect(swift).toContain('if readOnly { shareTypes.removeAll() }')
    expect(swift).toContain('requestHealthAuthorization: true,')
    expect(swift).toContain("var timeout = personFacing[action] ? null : setTimeout(")
  })

  it('reads heart rate through the day and the night\'s sleep stages', async () => {
    const output = createTempDir('craft-ios-heart-')
    await init({ runtimeDir: null, name: 'Heart', bundleId: 'com.example.heart', output, config: { enableHealthKit: true } })
    const swift = readFileSync(join(output, 'Sources', 'HeartApp.swift'), 'utf8') + readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

    expect(swift).toContain("getHeartRateSamples: function(options) {")
    expect(swift).toContain("craft._invoke('getHealthHeartRateSamples', {startDate: options.startDate, endDate: options.endDate, limit: options.limit})")
    expect(swift).toContain("getSleepIntervals: function(options) {")
    expect(swift).toContain("craft._invoke('getHealthSleepIntervals', {startDate: options.startDate, endDate: options.endDate})")
    expect(swift).toContain('case "getHealthHeartRateSamples":')
    expect(swift).toContain('case "getHealthSleepIntervals":')
    // Readings come back as they were taken, with the device that took them.
    expect(swift).toContain('HKSampleQuery(sampleType: heartType, predicate: predicate, limit: cap, sortDescriptors: [oldestFirst])')
    expect(swift).toContain('item["deviceName"] = device')
    // Time in bed and awake are stages of a night, not sleep.
    expect(swift).toContain('"asleep": !notAsleep.contains(sample.value)')
    // Both are read under the grants requestAuthorization already asks for.
    expect(swift).toMatch(/case "heartRate":\n\s+if let heartType = HKQuantityType\.quantityType\(forIdentifier: \.heartRate\)/)
    expect(swift).toMatch(/case "sleep":\n\s+if let sleepType = HKObjectType\.categoryType\(forIdentifier: \.sleepAnalysis\)/)
  })

  it('reads glucose, insulin and carbs one sample at a time, with the dose\'s reason', async () => {
    const output = createTempDir('craft-ios-glucose-')
    await init({ runtimeDir: null, name: 'Sugar', bundleId: 'com.example.sugar', output, config: { enableHealthKit: true } })
    const swift = readFileSync(join(output, 'Sources', 'SugarApp.swift'), 'utf8') + readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

    expect(swift).toContain('getSamples: function(type, options) {')
    expect(swift).toContain("craft._invoke('getHealthSamples', {type: type, startDate: options.startDate, endDate: options.endDate, limit: options.limit})")
    expect(swift).toContain('case "getHealthSamples":')
    // Asked for read only: HQ never writes glucose or insulin back.
    expect(swift).toMatch(/case "bloodGlucose", "insulinDelivery":\n(\s+\/\/.*\n)*\s+if let diabetesType = Self\.healthQuantity\(type\)\?\.type \{\n\s+readTypes\.insert\(diabetesType\)\n\s+\}/)
    expect(swift).toContain('case "bloodGlucose": return (HKQuantityType.quantityType(forIdentifier: .bloodGlucose), HKUnit(from: "mg/dL"), .discreteAverage)')
    expect(swift).toContain('case "insulinDelivery": return (HKQuantityType.quantityType(forIdentifier: .insulinDelivery), .internationalUnit(), .cumulativeSum)')
    // Each sample keeps its UUID, and a dose says basal or bolus.
    expect(swift).toContain('"id": sample.uuid.uuidString,')
    expect(swift).toContain('sample.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber')
    expect(swift).toContain('case .basal: item["insulinReason"] = "basal"')
    expect(swift).toContain('sample.metadata?[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber')
  })

  it('writes and reads mindful sessions, keeping one sample per session', async () => {
    const output = createTempDir('craft-ios-mindful-')
    await init({ runtimeDir: null, name: 'Calm', bundleId: 'com.example.calm', output, config: { enableHealthKit: true } })
    const swift = readFileSync(join(output, 'Sources', 'CalmApp.swift'), 'utf8') + readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

    expect(swift).toContain("saveMindfulSession: function(session) {")
    expect(swift).toContain("craft._invoke('saveHealthMindfulSession', {id: session.id, startDate: session.startDate, endDate: session.endDate})")
    expect(swift).toContain("getMindfulSessions: function(options) {")
    expect(swift).toContain("craft._invoke('getHealthMindfulSessions', {startDate: options.startDate, endDate: options.endDate, limit: options.limit})")
    expect(swift).toContain('case "saveHealthMindfulSession":')
    expect(swift).toContain('case "getHealthMindfulSessions":')
    // Asked for as `mindful`, readable and (unless read only) writable.
    expect(swift).toMatch(/case "mindful":\n(\s+\/\/.*\n)*\s+if let mindfulType = HKObjectType\.categoryType\(forIdentifier: \.mindfulSession\) \{\n\s+readTypes\.insert\(mindfulType\)\n\s+shareTypes\.insert\(mindfulType\)/)
    // The app's id rides along as the external UUID, and a second save of it finds the first.
    expect(swift).toContain('metadata: [HKMetadataKeyExternalUUID: id]')
    expect(swift).toContain('HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id])')
    expect(swift).toContain('HKQuery.predicateForObjects(from: HKSource.default())')
    expect(swift).toContain('"existing": true')
    // A read says which samples this app wrote, so a page can skip its own.
    expect(swift).toContain('"ownApp": ownBundle != nil && source.bundleIdentifier == ownBundle')
    expect(swift).toContain('item["externalId"] = external')
  })

  it('streams Apple Health heart rate as it arrives, to the page and every native screen', async () => {
    const output = createTempDir('craft-ios-health-stream-')
    await init({ runtimeDir: null, name: 'Breathe', bundleId: 'com.example.breathe', output, config: { enableHealthKit: true } })
    const app = readFileSync(join(output, 'Sources', 'BreatheApp.swift'), 'utf8')
    const health = readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

    expect(app).toContain('startHeartRateUpdates: function(options) {')
    expect(app).toContain("return craft._invoke('startHealthHeartRateUpdates', {since: since});")
    expect(app).toContain("stopHeartRateUpdates: function() { return craft._invoke('stopHealthHeartRateUpdates'); }")
    expect(app).toContain("startWorkout: function(options) { return craft._invoke('startHealthWorkout', options || {}); }")
    expect(app).toContain("endWorkout: function() { return craft._invoke('endHealthWorkout'); }")
    expect(app).toContain("discardWorkout: function() { return craft._invoke('discardHealthWorkout'); }")
    expect(app).toMatch(/case "discardHealthWorkout":\n\s+if config\.enableHealthKit \{\n\s+CraftHealth\.shared\.discardWorkout/)
    expect(health).toContain('case "discardWorkout":\n            discardWorkout(completion: completion)')
    const discard = health.slice(health.indexOf('private func discardLiveWorkout('), health.indexOf('private func clearLiveWorkout()'))
    expect(discard).toContain('!liveWorkoutEnding')
    expect(discard).toContain('liveWorkoutID == expectedID')
    expect(discard).toContain('session.end()')
    expect(discard).toContain('builder.discardWorkout()')
    expect(discard).toContain('clearLiveWorkout()')
    expect(discard).not.toContain('finishWorkout')
    expect(app).toMatch(/case "startHealthHeartRateUpdates":\n\s+if config\.enableHealthKit \{\n\s+CraftHealth\.shared\.startHeartRateUpdates\(since: body\["since"\] as\? Double\)/)
    expect(app).toMatch(/case "stopHealthHeartRateUpdates":\n\s+if config\.enableHealthKit \{\n\s+CraftHealth\.shared\.stopHeartRateUpdates/)
    // Batches reach the page, and native screens with or without it.
    expect(app).toContain('CraftHealth.shared.pageSink = { [weak self] detail in')
    expect(app).toContain('self.sendToWeb("craftHealthHeartRate", data: detail)')
    expect(app).toContain('self.sendToWeb("craftHealthWorkout", data: detail)')
    expect(app).toContain('"craftHealthHeartRate", "craftHealthWorkout", "craftMusicChange", "craftHeartRate"]')
    expect(health).toContain('HKWorkoutSession(healthStore: healthStore, configuration: configuration)')
    expect(health).toContain('builder.beginCollection(withStart: start)')
    expect(health).toContain('if pageSink?(detail) != true { CraftWebServices.forward("craftHealthHeartRate", data: detail) }')
    // An anchored query from `since` (two minutes ago by default), one at a time.
    expect(health).toContain('(since ?? Date().timeIntervalSince1970 * 1000 - 120_000) / 1000')
    expect(health).toContain('HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)')
    expect(health).toContain('HKAnchoredObjectQuery(type: heartType, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)')
    expect(health).toContain('query.updateHandler = { [weak self] _, samples, _, _, error in')
    expect(health).toMatch(/onMain \{ \[self\] in\n\s+stopHeartRateStream\(\)/)
    expect(health).toContain('if let query = heartRateQuery { healthStore?.stop(query) }')
    // Each sample once, oldest first, in getHeartRateSamples' shape; nothing for an empty batch.
    expect(health).toContain('.filter { heartRateSent.insert($0.0).inserted }')
    expect(health).toContain('guard !fresh.isEmpty else { return }')
    expect(health).toContain('completion(.success((samples as? [HKQuantitySample] ?? []).map(Self.heartRateRow)))')
    expect(health).toContain('let rows = (samples as? [HKQuantitySample] ?? []).map { ($0.uuid, Self.heartRateRow($0)) }')
    // A late batch from a stopped stream is dropped.
    expect(health).toContain('guard let self, self.heartRateStream == stream else { return }')
    // The simulator's stand-in watch never ships to a device.
    expect(health).toMatch(/#if targetEnvironment\(simulator\)\n\s+if UserDefaults\.standard\.bool\(forKey: "CraftFakeHealthHeartRate"\)/)
    expect(health).toContain('"sourceName": "Apple Watch (simulated)",')
    expect(health).toContain('Timer.scheduledTimer(withTimeInterval: 5, repeats: true)')
  })

  it('answers a native screen\'s Apple Health reads from the same service the page uses', async () => {
    const output = createTempDir('craft-ios-native-health-')
    await init({ runtimeDir: null, name: 'Pulse', bundleId: 'com.example.pulse', output, config: { enableHealthKit: true } })
    const app = readFileSync(join(output, 'Sources', 'PulseApp.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const health = readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')

    // One HealthKit store and one implementation, shared by both callers.
    expect(health).toContain('static let shared = CraftHealth()')
    for (const method of ['requestAuthorization', 'getData', 'saveData', 'saveWorkout', 'getWorkouts', 'getDailyStatistics', 'getHeartRateSamples', 'getSamples', 'getSleepIntervals', 'saveMindfulSession', 'getMindfulSessions', 'startHeartRateUpdates', 'stopHeartRateUpdates'])
      expect(health).toContain(`case "${method}":`)
    expect(app).toContain('CraftHealth.shared.getWorkouts(')
    expect(app).not.toContain('HKHealthStore()')
    // A native screen reaches it as the `Health` module, gated like the page is.
    expect(actions).toContain('case ("Health", _):')
    expect(actions).toContain('guard config.enableHealthKit else {')
    expect(actions).toContain('CraftHealth.shared.perform(method: method, args: args)')
    expect(actions).toContain('if config.enableHealthKit { values.append("health") }')
    // HealthKit invokes query and authorization handlers off-main on some OS
    // versions. Every public entry point normalizes its bridge completion so
    // native-screen JavaScript can resume safely after the sheet/query ends.
    expect(health).toContain('private func completeOnMain(_ completion: @escaping Completion) -> Completion')
    expect(health).toContain('DispatchQueue.main.async { completion(result) }')
    expect(health.match(/let completion = completeOnMain\(rawCompletion\)/g)?.length).toBe(19)
  })

  it('gates native Apple Wallet passes behind the app config', async () => {
    const output = createTempDir('craft-ios-native-wallet-')
    await init({ runtimeDir: null, name: 'Wallet', bundleId: 'com.example.wallet', output, config: { enableWallet: true } })
    const config = readFileSync(join(output, 'craft.config.json'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'WalletApp.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')

    expect(JSON.parse(config).enableWallet).toBe(true)
    expect(app).toContain('enableWallet: Bool = false')
    expect(actions).toContain('import PassKit')
    expect(actions).toContain('if config.enableWallet { values.append("wallet") }')
    expect(actions).toContain('case ("Wallet", "isAvailable"):')
    expect(actions).toContain('case ("Wallet", "has"):')
    expect(actions).toContain('case ("Wallet", "add"):')
    expect(actions).toContain('PKAddPassesViewController(pass: pass)')
    expect(actions).toContain('Wallet.add needs base64 data or an https URL')
  })

  it('asks a native screen\'s questions with the system\'s own alerts and sheets', async () => {
    const output = createTempDir('craft-ios-native-dialog-')
    await init({ runtimeDir: null, name: 'Ask', bundleId: 'com.example.ask', output })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    expect(actions).toContain('"fetch", "dialog", "speech"')
    expect(actions).toContain('case ("Dialog", _):')
    for (const call of ['CraftDialogs.alert(body, from: nil)', 'CraftDialogs.confirm(body, from: nil)', 'CraftDialogs.actionSheet(body, from: nil)'])
      expect(actions).toContain(call)
  })

  it('keeps a default when a caller passes undefined, and the app reads a partial config over its defaults', async () => {
    const output = createTempDir('craft-ios-undefined-')
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
    const root = createTempDir('craft-ios-fallback-')
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
    const output = createTempDir('craft-ios-shortcut-events-')
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
    const output = createTempDir('craft-ios-siri-removal-')
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
    const output = createTempDir('craft-ios-video-recording-')
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
    const output = createTempDir('craft-ios-live-activity-')
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
    expect(project.match(/PRODUCT_NAME: "\$\(TARGET_NAME\)"/g)).toHaveLength(2)
    expect(swift).toContain('startLiveActivity')
    expect(swift).toContain('craft.liveActivity = {')
    expect(swift).toContain("{id: idOrState}")
    const activities = readFileSync(join(output, 'Sources', 'CraftLiveActivities.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const widget = readFileSync(join(output, 'WidgetExtension', 'WildLoopLiveActivity.swift'), 'utf8')
    expect(activities).toContain('activities.first(where: { $0.id == id })')
    expect(activities).toContain('activities.first(where: { $0.attributes.activityId == key })')
    expect(activities).toContain('guard let number = craftNativeNumber(body[key]), number.doubleValue.isFinite else { return nil }')
    expect(actions).toContain('values.append("liveActivities")')
    expect(actions).toContain('case ("LiveActivities", _):')
    expect(widget).toContain('Text(timerInterval:')
    expect(widget).toContain('.foregroundStyle(.white)')
    expect(widget).toContain('.widgetURL(')
    expect(widget).toContain('context.state.paused == true')
    expect(widget).toContain('context.state.showsDistance != false')
    expect(widget).toContain('context.state.remainingSeconds != nil || context.state.timerEndsAt != nil')
    expect(widget).toContain('timer(context).font(.caption2.monospacedDigit()')
    expect(swift).toContain('endLiveActivity(body: body, callbackId: callbackId)')
    expect(swift).toContain('saveHealthWorkout')
    expect(readFileSync(join(output, 'Sources', 'CraftHealth.swift'), 'utf8')).toContain('HKWorkoutRouteBuilder')
    expect(plist).toContain('NSSupportsLiveActivities')
    expect(existsSync(join(output, 'Shared', 'CraftActivityAttributes.swift'))).toBe(true)
    expect(existsSync(join(output, 'WidgetExtension', 'WildLoopLiveActivity.swift'))).toBe(true)
  })

  it('plays each haptic on the generator UIKit has for it, kept warm, and none on a tab tap', async () => {
    const output = createTempDir('craft-ios-haptics-')
    await init({ runtimeDir: null, name: 'Haptics', bundleId: 'org.example.haptics', output })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const swift = readFileSync(join(output, 'Sources', 'HapticsApp.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')

    // Notifications and selections on their own generators, every impact
    // weight UIKit has, and the generators held rather than made per tap.
    expect(actions).toContain('notification().notificationOccurred(.success)')
    expect(actions).toContain('notification().notificationOccurred(.error)')
    expect(actions).toContain('selection().selectionChanged()')
    expect(actions).toContain('case "soft": return .soft')
    expect(actions).toContain('case "rigid": return .rigid')
    expect(actions).toContain('private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]')
    expect(actions).not.toContain('UIImpactFeedbackGenerator(style: .light).impactOccurred()')
    expect(actions).toContain('case "hapticPrepare":')
    expect(actions).toContain('CraftHaptics.prepare(body["kind"] as? String)')

    // UITabBar plays nothing when a tab is tapped, so the shell's bar does not.
    const tap = swift.slice(swift.indexOf('func tap(_ tab: Tab) {'), swift.indexOf('/// A completed horizontal swipe selects the adjacent tab.'))
    expect(tap.length).toBeGreaterThan(0)
    expect(tap).not.toContain('FeedbackGenerator')
    expect(swift).toContain('private(set) var tabSwipeEnabled = true')
    expect(swift).toContain('if let swipeEnabled = body["swipeEnabled"] as? Bool { tabSwipeEnabled = swipeEnabled }')
    expect(swift).toContain('tabSelectionCornerRadius = Self.selectionCornerRadius(body["selection"])')
    expect(swift).toContain('private struct CraftTabSelectionShape: Shape')
    expect(swift).toContain('contentShape(CraftTabSelectionShape(cornerRadius: chrome.tabSelectionCornerRadius))')
    expect(swift).toContain('cornerRadius: chrome.tabSelectionCornerRadius')
    expect(hybrid).toContain('guard CraftChrome.shared.tabSwipeEnabled else { return false }')
  })

  it('seeds each page load\'s callback ids above every id already handed out', async () => {
    // #226: the page's counter restarted at 0 on every injection, and native
    // recorded nothing about which load a call came from — so an answer owed
    // to a call made before a reload settled whichever call on the new page
    // drew the same number.
    const output = createTempDir('craft-ios-callback-ids-')
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

  it('installs the bridge at document start, with the coordinator wired before the first load', async () => {
    const output = createTempDir('craft-ios-bridge-timing-')
    await init({ runtimeDir: null, name: 'Timing', bundleId: 'org.example.timing', output })
    const swift = readFileSync(join(output, 'Sources', 'TimingApp.swift'), 'utf8')

    // A user script, once per document, rather than ~1800 lines evaluated
    // after every load.
    expect(swift).toContain('controller.addUserScript(WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))')
    // Rebuilt before each main-frame navigation, so the seed (#226) moves on.
    const policy = swift.slice(swift.indexOf('decidePolicyFor navigationAction: WKNavigationAction'), swift.indexOf('private func isEmbeddableFrameURL('))
    expect(policy).toContain('installUserScripts(into: webView.configuration.userContentController)')

    // The coordinator has its web view from creation, not from didFinish.
    const make = swift.slice(swift.indexOf('func makeUIView(context: Context) -> WKWebView {'), swift.indexOf('func updateUIView('))
    expect(make.indexOf('coordinator.attach(webView)')).toBeGreaterThan(-1)
    expect(make.indexOf('coordinator.attach(webView)')).toBeLessThan(make.indexOf('webView.load('))
    const finish = swift.slice(swift.indexOf('func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {'), swift.indexOf('func webView(_ webView: WKWebView, decidePolicyFor'))
    expect(finish).not.toContain('self.webView = webView')
    // Kept only as the fallback for a document that came without it.
    expect(finish).toContain('webView.evaluateJavaScript(self.bridgeScript(), completionHandler: nil)')

    // Native delivers held links and events when the page announces itself.
    expect(swift).toContain('if action == "__craftReady" {')
    const ready = swift.slice(swift.indexOf('private func pageBecameReady() {'), swift.indexOf('private func trustedPageOrigins()'))
    expect(ready).toContain('DeepLinkManager.shared.setReady()')
    expect(ready).toContain('CraftEventManager.shared.setReady()')
  })

  it('bundles an offline page in the app\'s colours, with a Retry that asks the shell', async () => {
    const output = createTempDir('craft-ios-offline-')
    await init({ runtimeDir: null, name: 'HQ.training', bundleId: 'training.hq.app', output, config: { backgroundColor: '#f8fafc', backgroundColorDark: '#020617' } })
    const page = readFileSync(join(output, 'dist', 'index.html'), 'utf8')

    expect(page).toContain("<h1>You're offline</h1>")
    expect(page).toContain('HQ.training could not reach the internet')
    // Light and dark, each with text that reads on it. The old placeholder
    // was white text whatever the background, invisible on a light app.
    expect(page).toContain(':root { --background: #f8fafc; --text: #0f172a; }')
    expect(page).toContain('@media (prefers-color-scheme: dark)')
    expect(page).toContain(':root { --background: #020617; --text: #f8fafc; }')
    expect(page).toContain('font: -apple-system-body')
    // No debug output in front of the person using the app.
    expect(page).not.toContain('Built with Craft')
    expect(page).not.toContain('bridge')
    expect(page).not.toContain('console.')

    // Retry posts straight to the native handler, which reloads the remote.
    const script = page.slice(page.indexOf('<script>') + 8, page.indexOf('</script>'))
    const posts: unknown[] = []
    const listeners: Record<string, () => void> = {}
    const button = { disabled: false, textContent: 'Retry', addEventListener: (type: string, listener: () => void) => { listeners[type] = listener } }
    // eslint-disable-next-line no-new-func
    new Function('window', 'document', 'location', 'setTimeout', script)(
      { webkit: { messageHandlers: { craft: { postMessage: (message: unknown) => posts.push(message) } } }, addEventListener() {} },
      { getElementById: () => button },
      { reload() { throw new Error('reloaded the bundled page instead of asking for the remote') } },
      () => 0,
    )
    listeners.click!()
    expect(posts).toEqual([{ action: 'retryRemote' }])
    expect(button.disabled).toBe(true)

    const swift = readFileSync(join(output, 'Sources', 'HQTrainingApp.swift'), 'utf8')
    expect(swift).toContain('case "retryRemote":')
    // An app with app-bound domains cannot navigate to craft://app from its
    // own page (WebKit ignores the load), so the offline page is loaded as a
    // page of the remote origin instead; the fallback used to be blank there.
    const bundled = swift.slice(swift.indexOf('private func loadBundledPage(in webView: WKWebView) {'), swift.indexOf('// MARK: - Lifecycle'))
    expect(bundled).toContain('if Self.declaresAppBoundDomains,')
    expect(bundled).toContain('webView.loadHTMLString(html, baseURL: remote)')
    const fallback = swift.slice(swift.indexOf('private func loadBundledFallback(in webView: WKWebView) {'), swift.indexOf('private func returnFromBundledFallback('))
    expect(fallback).toContain('loadBundledPage(in: webView)')
    expect(swift).toContain('private func retryRemote() {')
    // Behind a hybrid app's native screen nobody sees the offline page's
    // Retry, so the shell retries the page itself, backing off, until it
    // loads; a page that loads resets the backoff.
    expect(fallback).toContain('retryHiddenFallbackLater()')
    const hidden = swift.slice(swift.indexOf('private func retryHiddenFallbackLater() {'), swift.indexOf('private func returnFromBundledFallback('))
    expect(hidden).toContain('CraftHybrid.shared.isEnabled, !CraftHybrid.shared.webIsVisible')
    expect(hidden).toContain('min(30.0, 2.0 * pow(2.0')
    expect(hidden).toContain('self.returnFromBundledFallback(because:')
    const finished = swift.slice(swift.indexOf('func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {'), swift.indexOf('func webView(_ webView: WKWebView, decidePolicyFor navigationAction'))
    expect(finished).toContain('hiddenFallbackRetries = 0')
  })

  it('picks offline-page text that reads on the background', () => {
    expect(readableTextOn('#ffffff')).toBe('#0f172a')
    expect(readableTextOn('#0b1712')).toBe('#f8fafc')
    expect(readableTextOn('#fff')).toBe('#0f172a')
    expect(readableTextOn('not a colour')).toBe('#0f172a')
    // An unreadable dark colour falls back to the light one.
    expect(renderOfflinePage({ appName: 'A & B', backgroundColor: '#ffffff', backgroundColorDark: 'oops' }))
      .toContain('@media (prefers-color-scheme: dark) {\n      :root { --background: #ffffff; --text: #0f172a; }')
    expect(renderOfflinePage({ appName: 'A & B', backgroundColor: '#ffffff' })).toContain('<title>A &amp; B</title>')
  })

  it('keeps the splash until the page is ready or has painted, for splashMaxSeconds at most, and times out a dead load', async () => {
    const output = createTempDir('craft-ios-launch-')
    await init({ runtimeDir: null, name: 'Launch', bundleId: 'org.example.launch', output, config: { splashMaxSeconds: 2, requestTimeoutSeconds: 8 } })
    const swift = readFileSync(join(output, 'Sources', 'LaunchApp.swift'), 'utf8')
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))

    expect(config.splashMaxSeconds).toBe(2)
    expect(config.requestTimeoutSeconds).toBe(8)
    expect(swift).toContain('var splashMaxSeconds: Double = 3')
    expect(swift).toContain('var requestTimeoutSeconds: Double = 10')
    // The ten-second cap in CraftChrome's init is gone; the configured one is armed with the web view.
    expect(swift).not.toContain('DispatchQueue.main.asyncAfter(deadline: .now() + 10)')
    expect(swift).toContain('CraftChrome.shared.holdSplash(atMost: config.splashMaxSeconds)')
    // First contentful paint hides it too.
    expect(swift).toContain("if (entry.name === 'first-contentful-paint') { send(); observer.disconnect(); }")
    expect(swift).toContain('controller.addUserScript(WKUserScript(source: CraftChrome.paintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))')
    expect(swift).toContain('case "painted":')
    // Every load of the app's own page carries the timeout.
    expect(swift).toContain('URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: max(1, requestTimeoutSeconds))')
    expect(swift).toContain('webView.load(config.request(for: url))')
    expect(swift).toContain('webView.load(config.request(for: remote))')
  })

  it('shows the page\'s alerts natively and opens new windows where they can open', async () => {
    const output = createTempDir('craft-ios-ui-delegate-')
    await init({ runtimeDir: null, name: 'Dialogs', bundleId: 'org.example.dialogs', output })
    const swift = readFileSync(join(output, 'Sources', 'DialogsApp.swift'), 'utf8')
    const ui = readFileSync(join(output, 'Sources', 'CraftNativeUI.swift'), 'utf8')

    expect(swift).toContain('webView.uiDelegate = context.coordinator')
    expect(swift).toContain('extension CraftWebView.Coordinator: WKUIDelegate {')
    for (const panel of ['runJavaScriptAlertPanelWithMessage', 'runJavaScriptConfirmPanelWithMessage', 'runJavaScriptTextInputPanelWithPrompt'])
      expect(swift).toContain(panel)
    // Every panel answers even when nothing can present it, or the page's
    // script would wait forever on a dialog no one can see.
    expect(swift).toContain('if !CraftPresenter.present(alert, from: webView) { completionHandler() }')
    expect(swift).toContain('if !CraftPresenter.present(alert, from: webView) { completionHandler(false) }')
    expect(swift).toContain('if !CraftPresenter.present(alert, from: webView) { completionHandler(nil) }')

    // target=_blank reaches createWebViewWith: the app's own pages load in
    // place, anything else in Safari's in-app view.
    const policy = swift.slice(swift.indexOf('decidePolicyFor navigationAction: WKNavigationAction'), swift.indexOf('private func isEmbeddableFrameURL('))
    expect(policy.indexOf('if navigationAction.targetFrame == nil {')).toBeLessThan(policy.indexOf('if isTrustedURL(url) {'))
    const create = swift.slice(swift.indexOf('createWebViewWith configuration: WKWebViewConfiguration'), swift.indexOf('requestMediaCapturePermissionFor origin'))
    expect(create).toContain('webView.load(navigationAction.request)')
    expect(create).toContain('SFSafariViewController(url: url)')
    expect(create).toContain('return nil')
    expect(swift).toContain('decisionHandler(trusts(origin) && trusts(frame.securityOrigin) ? .grant : .prompt)')

    // Presented from whatever is on top, never from a root that is busy.
    expect(ui).toContain('while let presented = top?.presentedViewController, !presented.isBeingDismissed {')
  })

  it('serves the native UI actions and lets the status bar follow the page', async () => {
    const output = createTempDir('craft-ios-native-ui-')
    await init({ runtimeDir: null, name: 'NativeUI', bundleId: 'org.example.nativeui', output, config: { enableShare: true } })
    const swift = readFileSync(join(output, 'Sources', 'NativeUIApp.swift'), 'utf8')
    const ui = readFileSync(join(output, 'Sources', 'CraftNativeUI.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')

    for (const action of ['dialogAlert', 'dialogConfirm', 'dialogActionSheet', 'contextMenuShow', 'browserOpen', 'symbolImage', 'statusBarSetStyle', 'chromeSetUnderPageColor', 'chromeSetKeyboardAccessory', 'refreshEnable', 'refreshDisable', 'refreshEnd'])
      expect(swift).toContain(`case "${action}":`)
    // The system's own context menu from code on iOS 17.4 and later, the
    // edit menu before it.
    expect(ui).toContain('button.performPrimaryAction()')
    expect(ui).toContain('button.showsMenuAsPrimaryAction = true')
    expect(ui).toContain('override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration')
    expect(ui).toContain('UIEditMenuInteraction(delegate: self)')
    expect(ui).toContain('interaction.presentEditMenu(with: configuration)')
    expect(ui).toContain('ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme)')
    expect(ui).toContain('session.prefersEphemeralWebBrowserSession = false')
    expect(ui).toContain('UIImage.SymbolConfiguration(pointSize: max(1, pointSize), weight: weight, scale: scale)')
    expect(ui).toContain('scrollView.refreshControl = control')
    expect(swift).toContain('webView.underPageBackgroundColor = color')
    expect(swift).toContain('self?.sendToWeb("craftRefresh", data: [:])')

    // View-controller based, so the page's style and the system sheets' own both apply.
    expect(plist).toContain('<key>UIViewControllerBasedStatusBarAppearance</key>\n    <true/>')

    // The share sheet presents from whatever is on top, anchored for iPad,
    // and nothing presents from the first window's root any more.
    expect(swift).toContain('CraftPresenter.present(activityVC, from: webView, anchor: CraftPresenter.rect(options["anchor"]))')
    expect(swift).not.toContain('windows.first?.rootViewController')
    const services = readFileSync(join(output, 'Sources', 'CraftNativeServices.swift'), 'utf8')
    expect(services).toContain('final class CraftShareLink: NSObject, UIActivityItemSource')
    expect(services).toContain('metadata.originalURL = url')
    expect(services).toContain('metadata.title = title')
    expect(services).toContain('subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }')
    expect(services).toContain('activityType == .copyToPasteboard ? url.absoluteString : url')
    for (const source of [swift, services]) {
      expect(source).toContain('items.append(CraftShareLink(url: url, title: title))')
      expect(source).not.toContain('if let title = options["title"] as? String, !title.isEmpty { items.append(title) }')
    }
    expect(services).toContain('CraftPresenter.present(sheet, from: nil, anchor: CraftPresenter.rect(options["anchor"]))')
    expect(ui).toContain('CFGetTypeID(number) != CFBooleanGetTypeID()')
    expect(ui).toContain('return value.isFinite ? value : nil')
  })

  it('keeps generated iOS native service numbers strict at the bridge boundary', async () => {
    const output = createTempDir('craft-ios-native-service-numbers-')
    await init({ runtimeDir: null, name: 'NativeServiceNumbers', bundleId: 'org.example.nativeservicenumbers', output })
    const ui = readFileSync(join(output, 'Sources', 'CraftNativeUI.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const services = readFileSync(join(output, 'Sources', 'CraftNativeServices.swift'), 'utf8')
    expect(ui).toContain('craftNativeNumber(options["pointSize"])')
    expect(actions).toContain('craftNativeNumber(options["rate"]).map { $0.doubleValue }')
    expect(actions).toContain('craftNativeNumber(value["badge"])')
    expect(services).toContain('craftNativeNumber(options["volume"]).map { $0.doubleValue }')
  })

  it('generates the native Map node in iOS screen projects', async () => {
    const output = createTempDir('craft-ios-native-map-')
    await init({ runtimeDir: null, name: 'NativeMap', bundleId: 'org.example.nativemap', output, config: { renderer: 'native' } as any })
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(screen).toContain('case "Map":')
    expect(screen).toContain('private final class CraftNativeMapView: MKMapView, MKMapViewDelegate')
    expect(screen).toContain('let polygonKey = polygons.keys.sorted().compactMap')
    expect(screen).toContain('g[\\(polygonKey)]')
  })

  it('names browser URL globals that are intentionally unavailable on native screens', async () => {
    const output = createTempDir('craft-ios-native-web-apis-')
    await init({ runtimeDir: null, name: 'NativeWebAPIs', bundleId: 'org.example.nativewebapis', output, config: { renderer: 'native' } as any })
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(screen).toContain('private static let nativeWebAPICompatibilityPrelude')
    expect(screen).toContain("globalThis.URLSearchParams = unavailable('URLSearchParams'")
    expect(screen).toContain("globalThis.TextEncoder = unavailable('TextEncoder'")
  })

  it('keeps every unsupported browser global actionable in generated iOS hosts', async () => {
    const output = createTempDir('craft-ios-native-web-api-docs-')
    await init({ runtimeDir: null, name: 'NativeWebAPIDocs', bundleId: 'org.example.nativewebapidocs', output, config: { renderer: 'native' } as any })
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    for (const name of ['URL', 'URLSearchParams', 'TextEncoder']) {
      expect(screen).toContain(`unavailable('${name}'`)
    }
    expect(screen).toContain('is not available on a native screen')
  })

  it('keeps generated iOS media limits strict and finite', async () => {
    const output = createTempDir('craft-ios-native-media-numbers-')
    await init({ runtimeDir: null, name: 'NativeMediaNumbers', bundleId: 'org.example.nativemedianumbers', output })
    const files = readFileSync(join(output, 'Sources', 'CraftNativeFiles.swift'), 'utf8')
    expect(files).toContain('craftNativeNumber(options["maxPixels"])')
    expect(files).toContain('Double(largestMaxPixels)')
    expect(files).toContain('craftNativeNumber(options["quality"])')
    expect(files).toContain('craftNativeNumber(options["maxBytes"])')
  })

  it('makes the web view feel like the app: no previews, no zoom, no keyboard bar, an app user agent', async () => {
    const output = createTempDir('craft-ios-feel-')
    await init({ runtimeDir: null, name: 'HQ.training', bundleId: 'training.hq.app', output })
    const swift = readFileSync(join(output, 'Sources', 'HQTrainingApp.swift'), 'utf8')
    const version = JSON.parse(readFileSync(join(import.meta.dir, '..', 'package.json'), 'utf8')).version

    expect(swift).toContain('webView.allowsLinkPreview = config.allowsLinkPreview ?? false')
    expect(swift).toContain('webView.scrollView.keyboardDismissMode = .interactive')
    expect(swift).toContain('if config.disableZoom != false {')
    expect(swift).toContain('webView.scrollView.pinchGestureRecognizer?.isEnabled = false')
    expect(swift).toContain('controller.addUserScript(WKUserScript(source: CraftConfig.viewportScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))')
    expect(swift).toContain('private lazy var keyboardAccessoryVisible = config.keyboardAccessory ?? false')
    expect(swift).toContain('if !keyboardAccessoryVisible { CraftKeyboardAccessory.setVisible(false, in: webView) }')
    expect(swift).toContain('webConfig.allowsPictureInPictureMediaPlayback = true')
    expect(swift).toContain('webConfig.applicationNameForUserAgent = config.applicationNameForUserAgent(after: webConfig.applicationNameForUserAgent)')
    // The generator fills in its own version.
    expect(swift).toContain(`"Craft/${version}"`)
    expect(swift).not.toContain('{{CRAFT_VERSION}}')
  })

  it('tells the page the text size and motion settings, and sizes the tab bar with Dynamic Type', async () => {
    const output = createTempDir('craft-ios-appearance-')
    await init({ runtimeDir: null, name: 'Appearance', bundleId: 'org.example.appearance', output })
    const swift = readFileSync(join(output, 'Sources', 'AppearanceApp.swift'), 'utf8')

    // From the first byte of every document, and again on every change.
    expect(swift).toContain('controller.addUserScript(WKUserScript(source: CraftPageAppearance.script(appearanceSnapshot(), announce: false), injectionTime: .atDocumentStart, forMainFrameOnly: true))')
    expect(swift).toContain("root.style.setProperty('--craft-font-scale', String(a.fontScale));")
    expect(swift).toContain("root.setAttribute('data-craft-reduce-motion', a.reduceMotion ? 'true' : 'false');")
    expect(swift).toContain('UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17')
    for (const name of ['UIContentSizeCategory.didChangeNotification', 'UIAccessibility.reduceMotionStatusDidChangeNotification', 'UIAccessibility.reduceTransparencyStatusDidChangeNotification', '.craftColorSchemeChanged'])
      expect(swift).toContain(name)
    expect(swift).toContain('webView.evaluateJavaScript(CraftPageAppearance.script(self.appearanceSnapshot(), announce: true), completionHandler: nil)')

    // The bar's type scales, up to the cap UITabBar has, and its motion
    // respects Reduce Motion.
    expect(swift).toContain('@ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 11')
    expect(swift).toContain('.font(.system(size: labelSize, weight: isSelected ? .semibold : .medium))')
    expect(swift).not.toContain('.font(.system(size: 11, weight:')
    expect(swift).toContain('.dynamicTypeSize(...DynamicTypeSize.xxxLarge)')
    expect(swift).toContain('.accessibilityShowsLargeContentViewer {')
    expect(swift).toContain('UIAccessibility.isReduceMotionEnabled ? nil : animation')
    expect(swift).not.toContain('withAnimation(.spring(')
  })

  it('brings a dead page back on a budget, where the person left it, and tells the page about resumes and memory', async () => {
    const output = createTempDir('craft-ios-recovery-')
    await init({ runtimeDir: null, name: 'Recovery', bundleId: 'org.example.recovery', output })
    const swift = readFileSync(join(output, 'Sources', 'RecoveryApp.swift'), 'utf8')

    // Budgeted (scripts/recovery-budget.ts runs the struct), deferred while
    // in the background, under the splash, and the offline page past it.
    expect(swift).toContain('struct CraftRecoveryBudget {')
    const terminated = swift.slice(swift.indexOf('func webViewWebContentProcessDidTerminate('), swift.indexOf('private func showOfflinePage(in webView: WKWebView)'))
    expect(terminated).toContain('recoverOnForeground = true')
    expect(terminated).toContain('switch recoveryBudget.onCrash(at: ProcessInfo.processInfo.systemUptime) {')
    expect(terminated).toContain('CraftChrome.shared.showSplash(atMost: config.splashMaxSeconds)')
    expect(terminated).toContain('webView.load(config.request(for: lastURL))')
    expect(terminated).toContain('showOfflinePage(in: webView)')
    expect(swift).not.toMatch(/webViewWebContentProcessDidTerminate\(_ webView: WKWebView\) \{\n\s+webView\.reload\(\)\n\s+\}/)
    // Retry starts a new budget.
    const retry = swift.slice(swift.indexOf('private func retryRemote() {'), swift.indexOf('fileprivate func isTrustedURL('))
    expect(retry).toContain('recoveryBudget.reset()')

    // The page's place survives iOS ending the app, once, in the same build.
    expect(swift).toContain('let state = webView.interactionState as? Data')
    expect(swift).toContain('webView.interactionState = state')
    expect(swift).toContain('if coordinator.restoreInteractionState(into: webView) {')
    expect(swift).toContain('UserDefaults.standard.string(forKey: Self.interactionStateBuildKey) == Self.currentBuild')

    // Resume and memory, as the contract names them.
    expect(swift).toContain('sendToWeb("craftResume", data: ["backgroundedMs": Int(Date().timeIntervalSince(backgroundedAt) * 1000)])')
    expect(swift).toContain('sendToWeb("craftMemoryWarning", data: [:])')
    expect(swift).toContain('name: UIApplication.didReceiveMemoryWarningNotification')
    expect(swift).toContain('name: UIApplication.didEnterBackgroundNotification')

    // The budget check runs with the other template checks.
    expect(readFileSync(join(import.meta.dir, '..', 'scripts', 'compile-templates.ts'), 'utf8')).toContain('checkRecoveryBudget(workspace, run)')
  })

  it('gives the page background time for silent pushes and scheduled refreshes', async () => {
    const output = createTempDir('craft-ios-background-')
    await init({ runtimeDir: null, name: 'Background', bundleId: 'training.hq.app', output, config: { enablePushNotifications: true, backgroundRefresh: { enabled: true, minimumIntervalMinutes: 30 } } })
    const swift = readFileSync(join(output, 'Sources', 'BackgroundApp.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')

    expect(plist).toContain('<key>BGTaskSchedulerPermittedIdentifiers</key>\n    <array>\n        <string>training.hq.app.refresh</string>\n    </array>')
    expect(plist).toContain('<string>fetch</string>')
    expect(plist).toContain('<string>remote-notification</string>')
    expect(plist).not.toContain('{{')

    expect(swift).toContain('didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler')
    expect(swift).toContain('let id = CraftBackgroundWork.shared.hold { ok in')
    expect(swift).toContain('CraftEventManager.shared.sendToWeb("craftSilentPush", data: ["id": id, "payload": CraftEventManager.pageData(userInfo)])')
    expect(swift).toContain('static let deadline: TimeInterval = 25')
    expect(swift).toContain('CraftBackgroundWork.shared.registerRefresh(config)')
    expect(swift).toContain('BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil)')
    expect(swift).toContain('CraftEventManager.shared.sendToWeb("craftBackgroundRefresh", data: ["id": id])')
    expect(swift).toContain('task.setTaskCompleted(success: ok ?? false)')
    expect(swift).toContain('case "backgroundComplete":')
    // Universal links take the same road as custom schemes, scene or not.
    expect(swift).toContain('.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)')
    expect(swift).toContain('if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {')

    // Off, nothing is declared.
    const plain = createTempDir('craft-ios-background-off-')
    await init({ runtimeDir: null, name: 'Plain', bundleId: 'org.example.plain', output: plain })
    const plainPlist = readFileSync(join(plain, 'Info.plist'), 'utf8')
    expect(plainPlist).not.toContain('BGTaskSchedulerPermittedIdentifiers')
    expect(plainPlist).not.toContain('<string>fetch</string>')
  })

  it('signs universal links with a service prefix, even when given a bare host', () => {
    expect(associatedDomainEntries(['hq.training', 'applinks:hq.training', 'webcredentials:hq.training', ' applinks:dev.hq.training?mode=developer '])).toEqual([
      'applinks:hq.training',
      'webcredentials:hq.training',
      'applinks:dev.hq.training?mode=developer',
    ])
    const entitlements = renderEntitlements({ appName: 'HQ', bundleId: 'training.hq.app', associatedDomains: ['hq.training'] })
    expect(entitlements).toContain('<key>com.apple.developer.associated-domains</key>\n    <array>\n        <string>applinks:hq.training</string>\n    </array>')
  })

  it('sizes a gradient with its view and lets a styled field drop the system box', () => {
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    // UIView.bounds is not KVO-observable in general; a frame-laid-out view never reported it.
    expect(swift).toContain('view.layer.observe(\\.bounds) { [weak layer, weak view] _, _ in if let view { layer?.follow(view) } }')
    expect(swift).not.toContain('view.observe(\\.bounds)')
    expect(swift).toContain('field.borderStyle = style["borderWidth"] != nil || style["backgroundColor"] != nil ? .none : .roundedRect')
  })

  it('keeps a labelled scroll view, picker or group a container, so VoiceOver reads what it holds', () => {
    // A tour pager labelled for VoiceOver became one element and hid its pages.
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const a11y = swift.slice(swift.indexOf('private func applyAccessibility(_ props: [String: Any], type: String, to view: UIView)'))
    expect(a11y).toContain('let container = ["ScrollView", "FlatList", "SectionList", "Picker", "SegmentedControl", "Modal", "Drawer"].contains(type)')
    expect(a11y).toContain('view.isAccessibilityElement = !container && role != "none"')
    expect(a11y).toContain('view.accessibilityContainerType = container && (view.accessibilityLabel != nil || controlledVideo) ? .semanticGroup : .none')
    expect(a11y).toContain('case "tablist": traits.insert(.tabBar)')
  })

  it('keeps the bar away for a pushed screen that hid it', () => {
    // The tour hides the bar and draws its own Back; pushed from Settings,
    // the stack's willShow showed the bar again, so it had two Backs.
    const hybrid = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftHybrid.swift'), 'utf8')
    const willShow = hybrid.slice(hybrid.indexOf('func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController'))
    expect(willShow.slice(0, willShow.indexOf("func navigationController", 5))).toContain('native?.navigationBarHidden == true')
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    expect(swift).toContain('private(set) var navigationBarHidden: Bool?')
  })

  it('lets a native popup consume Back before the route pops', () => {
    const hybrid = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftHybrid.swift'), 'utf8')
    expect(hybrid).toContain('final class CraftNativeNavigationController: UINavigationController')
    expect(hybrid).toContain('if let screen = topViewController as? CraftNativeScreenController')
    expect(hybrid).toContain('screen.handleBackForModal()')
    expect(hybrid).toContain('let nav = CraftNativeNavigationController(rootViewController: root)')
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    expect(swift).toContain('func handleBackForModal() -> Bool')
    expect(swift).toContain('modal.requestClose(reason: "back")')
  })

  it('keeps the outgoing hybrid web page visible while a web push animates', () => {
    const hybrid = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftHybrid.swift'), 'utf8')
    const slot = hybrid.slice(hybrid.indexOf('final class CraftHybridWebSlot'))
    expect(slot.indexOf('prepareWebTransition(to: self)')).toBeLessThan(slot.indexOf('adoptWeb(into: self)'))
    expect(hybrid).toContain('webHost.view.snapshotView(afterScreenUpdates: false)')
    expect(hybrid).toContain('snapshot.frame = source.view.bounds')
    expect(hybrid).toContain('for snapshot in webTransitionSnapshots { snapshot.removeFromSuperview() }')
  })

  it('lets a child that overflows its flex view take its touches, as the web does', () => {
    // A floating button absolutely positioned out of a zero-height component
    // wrapper drew but could not be tapped: UIKit never asked the wrapper.
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const flow = swift.slice(swift.indexOf('private class CraftNativeFlowView: UIStackView'))
    const hit = flow.slice(flow.indexOf('override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView?'))
    expect(hit).toContain('if let hit = super.hitTest(point, with: event) { return hit }')
    expect(hit).toContain('guard !clipsToBounds, !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }')
    expect(hit).toContain('child.hitTest(child.convert(point, from: self), with: event)')
  })

  it('stacks a flex view\'s children in tree order, so a later sibling takes the touch it draws over', () => {
    // A child inserted before its siblings was appended above them all: a
    // ScrollView re-created under a floating button took the button's taps.
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const insert = swift.slice(swift.indexOf('override func insertArrangedSubview(_ view: UIView, at stackIndex: Int)'))
    const body = insert.slice(0, insert.indexOf('invalidateMeasurements()'))
    expect(body).toContain('if let next = flowChildren[(index + 1)...].first(where: { $0.superview === self })')
    expect(body).toContain('insertSubview(view, belowSubview: next)')
  })

  it('supports leading native actions beside Back and adaptive neutral toolbar symbols', () => {
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    expect(swift).toContain('options.keys.contains("leftButtons")')
    expect(swift).toContain('navigationItem.leftItemsSupplementBackButton = true')
    expect(swift).toContain('navigationItem.leftBarButtonItems = buttons.compactMap(navigationButton)')
    expect(swift).toContain('if spec["variant"] as? String == "neutral" { item.tintColor = .label }')
    expect(swift).toContain('if let value = craftNativeNumber(spec["badge"]), value.intValue > 0 {')
  })

  it('floats a native bar\'s round buttons, as the tab bar floats: glass, else the thin material', () => {
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    const button = swift.slice(swift.indexOf('private func accountNavigationButton'))
    expect(button).toContain('let surface = Self.floatingSurface(diameter: 44)')
    expect(button).toContain('button.widthAnchor.constraint(equalToConstant: 44)')
    expect(button).toContain('button.heightAnchor.constraint(equalToConstant: 44)')
    expect(button).toContain('button.tintColor = .systemBlue')
    // No flat fill under the glass.
    expect(button).not.toContain('.tertiarySystemFill')
    // The surface stays under the symbol, the initials, the picture and the badge.
    expect(button.split('button.sendSubviewToBack(surface)').length - 1).toBe(2)
    const surface = swift.slice(swift.indexOf('private static func floatingSurface'))
    expect(surface).toContain('if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemUltraThinMaterial) }')
    expect(surface).toContain('surface.isUserInteractionEnabled = false')
    // Pinned to its 44-point button, never resized with it: a button that
    // starts at zero size grew a flexible 44-point surface to 88 points.
    expect(surface).toContain('surface.translatesAutoresizingMaskIntoConstraints = false')
    expect(surface.slice(0, surface.indexOf('return surface'))).not.toContain('.autoresizingMask')
    expect(button).toContain('surface.leadingAnchor.constraint(equalTo: button.leadingAnchor)')
    expect(button).toContain('surface.bottomAnchor.constraint(equalTo: button.bottomAnchor)')
  })

  it('signs in with Apple natively: the entitlement, a page nonce, and the code for the server', () => {
    // Without the entitlement ASAuthorizationController fails before any
    // sheet shows. The nonce ties Apple's identity token to the page that
    // asked, and the authorizationCode is what a server redeems at Apple.
    expect(renderEntitlements({ appName: 'HQ', bundleId: 'training.hq.app', enableSocialAuth: true }))
      .toContain('<key>com.apple.developer.applesignin</key>\n    <array>\n        <string>Default</string>\n    </array>')
    expect(renderEntitlements({ appName: 'HQ', bundleId: 'training.hq.app' })).not.toContain('applesignin')
    const swift = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftApp.swift'), 'utf8')
    // One sheet for a page and a native screen alike (CraftNativeUI.swift).
    const service = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeUI.swift'), 'utf8')
    expect(swift).toContain(`return this._invoke('signInWithApple', nonce ? {nonce: nonce} : {});`)
    expect(swift).toContain('signInWithApple(nonce: body["nonce"] as? String, callbackId: callbackId)')
    expect(swift).toContain('CraftSignInWithApple.shared.signIn(nonce: nonce)')
    expect(swift).not.toContain('extension CraftWebView.Coordinator: ASAuthorizationControllerDelegate')
    expect(service).toContain('if let nonce, !nonce.isEmpty { request.nonce = nonce }')
    expect(service).toContain('result["authorizationCode"] = code')
    expect(service).toContain('code: cancelled ? "CANCELLED" : "SIGN_IN_FAILED"')
  })

  it('gates native passkeys on an explicit webcredentials domain', async () => {
    const output = createTempDir('craft-ios-passkeys-')
    await init({
      runtimeDir: null,
      name: 'Passkeys',
      bundleId: 'com.example.passkeys',
      output,
      config: {
        enablePasskeys: true,
        associatedDomains: ['webcredentials:login.example.com'],
        nativeScreens: { '/m/login': 'Login' },
      } as any,
    })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')) as Record<string, unknown>
    expect(config.enablePasskeys).toBe(true)
    expect(config.associatedDomains).toEqual(['webcredentials:login.example.com'])
    expect(actions).toContain('if config.enablePasskeys && !CraftNativePasskeys.domains(in: config).isEmpty { values.append("passkeys") }')
    expect(actions).toContain('request = provider.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userID)')
    expect(actions).toContain('assertion.allowedCredentials = allowCredentials.compactMap')
    expect(actions).toContain('guard let attestationObject = registration.rawAttestationObject else')
    expect(actions).toContain('"attestationObject": Self.base64url(attestationObject)')
    expect(actions).toContain('controllers[requestToken] = controller')
    expect(actions).toContain('controllers.removeValue(forKey: requestToken)')
    expect(actions).toContain('guard let candidate, domains.contains(candidate)')
  })

  it('tells every native screen and the page when the signed-in account changes', async () => {
    const output = createTempDir('craft-ios-session-')
    await init({ runtimeDir: null, name: 'Session', bundleId: 'com.example.session', output, config: { nativeScreens: { '/m/login': 'Login' }, shareStorage: { auth_token: 'hq.token' }, sessionTokenKey: 'hq.token' } as any })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.sessionTokenKey).toBe('hq.token')
    const app = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftApp.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(app).toContain('var sessionTokenKey: String? = nil')
    // One writer funnel: a screen's set, remove, delete or clear, with the
    // shared copy written before the after-value is read.
    expect(actions).toContain('enum CraftSession {')
    expect(actions).toContain('static let changed = Notification.Name("craftSessionChanged")')
    expect(actions).toContain('static let defaultKey = "auth.token"')
    expect(actions).toContain('let isWrite = ["set", "remove", "delete", "clear"].contains(method)')
    // Off the main thread, in order: a Keychain call took up to 900ms on a simulator.
    expect(actions).toContain('CraftKeychain.queue.async {')
    expect(actions).toContain('let result = isWrite ? CraftSession.observe(key: method == "clear" ? nil : args.first as? String, config: config, write) : write()')
    expect(actions.indexOf('CraftHybrid.shared.nativeWroteShared(nativeKey: key')).toBeLessThan(actions.indexOf('CraftSession.observe(key: method == "clear"'))
    expect(actions).toContain('let info: [String: Any] = ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()]')
    // The page's own sign-in moves it too, and the page script learns its key.
    expect(hybrid).toContain('CraftSession.observe(key: nativeKey, config: config) { CraftHybridKeychain.set(nativeKey, value: value) }')
    expect(hybrid).toContain('.replacingOccurrences(of: "__CRAFT_HYBRID_SESSION__", with: session.map { json([$0]) } ?? "[]")')
    expect(hybrid).toContain("window.dispatchEvent(new CustomEvent('craftsession', { detail: change }))")
    // Every screen: the bridge field, the message, and craft.session's listeners.
    expect(screen).toContain('sessionTokenKey: \\(sessionTokenKey),')
    expect(screen).toContain('forName: CraftSession.changed,')
    expect(screen).toContain('self.send(type: "SESSION_CHANGED", payload: ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()])')
    expect(screen).toContain('CraftNativeScriptThread.run(label: "session \\(self.routeName ?? "screen")") { context.objectForKeyedSubscript("__craftSessionChanged")?.call(withArguments: [token ?? NSNull(), previous ?? NSNull()]) }')
    expect(screen).toContain("keep('session', {")
  })

  it('lets a native screen sign in: Apple, the web sign-in sheet, a session the page shares, and crypto', async () => {
    const output = createTempDir('craft-ios-native-sign-in-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableSocialAuth: true, nativeScreens: { '/m/login': 'Login' }, shareStorage: { auth_token: 'auth.token' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')

    expect(actions).toContain('values.append("browser")')
    expect(actions).toContain('if config.enableSocialAuth { values.append("appleSignIn") }')
    expect(actions).toContain('case ("Browser", "open"):')
    expect(actions).toContain('CraftBrowser.shared.open(url, mode: options["mode"] as? String ?? "safari"')
    expect(actions).toContain('case ("Auth", "signInWithApple"):')
    // A native screen writing a shared key hands it to the page.
    expect(actions).toContain('CraftHybrid.shared.nativeWroteShared(nativeKey: key')
    expect(hybrid).toContain('func nativeWroteShared(nativeKey: String, value: String?)')
    expect(hybrid).toContain('window.__craftHybrid.adopt(')
    expect(hybrid).toContain("window.dispatchEvent(new CustomEvent('craftsharedstorage'")
    // Kept until the page reports the write back as its own, then dropped.
    expect(hybrid).toContain('pendingShared.removeValue(forKey: key)')
    expect(hybrid).toContain('if direction == "load" { flushShared() }')
    // crypto, which JavaScriptCore lacks: the system's random bytes, CryptoKit's digests.
    expect(screen).toContain('SecRandomCopyBytes(kSecRandomDefault, count, &bytes)')
    expect(screen).toContain('case "SHA-256": bytes = Array(SHA256.hash(data: data))')
    expect(screen).toContain('cryptoObject.getRandomValues = function(array)')
    expect(screen).toContain('cryptoObject.subtle = Object.assign(')
  })

  it('gives native screens speech, sound, push, links, sharing and streaming responses', async () => {
    const output = createTempDir('craft-ios-native-services-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enablePushNotifications: true, enableShare: true, nativeScreens: { '/m': 'Today', '/m/messages': 'Messages' }, tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max' }] } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const services = readFileSync(join(output, 'Sources', 'CraftNativeServices.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')

    expect(actions).toContain('"speech", "audio", "eventStream", "linking", "badge", "animation", "viewFocus", "viewMeasure", "viewReparent", "viewNonModalPresentation", "nativePlatformControls"]')
    expect(actions).toContain('if config.enablePushNotifications { values.append("push") }')
    expect(actions).toContain('if config.enableShare { values.append("share") }')
    for (const call of ['case ("Speech", "speak"):', 'case ("Push", _):', 'case ("Linking", "openURL"), ("Linking", "canOpenURL"):', 'case ("Share", "share"):'])
      expect(actions).toContain(call)
    // Sounds and streams belong to the screen and end with it.
    expect(screen).toContain('case ("Network", "stream"):')
    expect(screen).toContain('case ("Audio", "play"):')
    expect(screen).toContain('sounds.close()\n        streams.close()')
    expect(screen).toContain('self?.send(type: "PUSH_TOKEN", payload: ["token": token])')
    expect(services).toContain('try session.setCategory(category, mode: .default, options: [.mixWithOthers])')
    expect(services).toContain('AVPlayerLooper(player: player, templateItem: item)')
    expect(services).toContain('URLSession(configuration: configuration, delegate: self, delegateQueue: .main)')
    expect(services).toContain('UIApplication.shared.registerForRemoteNotifications()')
    // A screen shown again, or opened again with other params.
    expect(screen).toContain('send(type: "SCREEN_FOCUS", payload: ["focused": visible])')
    expect(screen).toContain('send(type: "ROUTE_PARAMS", payload: ["params": params, "props": props])')
    // A finished task closes to the first screen of its stack.
    // A screen can ask the tab bar away while it shows; the next one says again.
    expect(screen).toContain('if let hidden = options["tabBarHidden"] as? Bool {')
    expect(screen).toContain('CraftChrome.shared.setHiddenByScreen(tabBarHidden)')
    // Going away hands the accessory on; the next screen keeps it until it says.
    expect(screen).toContain('CraftChrome.shared.releaseTabAccessory(ownedBy: self)')
    expect(screen).toContain('if tabAccessoryDeclared { CraftChrome.shared.updateTabAccessory(tabAccessory, owner: self) }')
    expect(screen).toContain('if let contentSwipeBack = options["contentSwipeBack"] as? Bool {')
    expect(screen).toContain('private(set) var contentSwipeBack = true')
    expect(screen).toContain('if let tabSwipeEnabled = options["tabSwipeEnabled"] as? Bool {')
    expect(screen).toContain('private(set) var tabSwipeEnabled = true')
    // A screen's own colour reaches under the status bar and home indicator,
    // and survives a change of appearance.
    expect(screen).toContain('screenBackgroundColor = color(options["backgroundColor"])')
    expect(screen).toContain('view.backgroundColor = screenBackgroundColor ?? config.resolvedBackgroundColor')
    expect(screen).toContain('if let document = mutationDocument.node("root")')
    expect(screen).toContain('if let solid = options["navigationBarSolid"] as? Bool {')
    expect(screen).toContain('appearance.configureWithOpaqueBackground()')
    expect(screen).toContain('appearance.backgroundColor = screenBackgroundColor ?? config.resolvedBackgroundColor')
    expect(screen).toContain('appearance.shadowColor = .clear')
    expect(screen).toContain('navigationItem.standardAppearance = appearance')
    expect(screen).toContain('navigationItem.scrollEdgeAppearance = appearance')
    expect(screen).toContain('navigationItem.compactAppearance = appearance')
    expect(screen).toContain('navigationItem.compactScrollEdgeAppearance = appearance')
    expect(screen).toContain('navigationItem.standardAppearance = nil')
    expect(screen).toContain('override func viewWillAppear(_ animated: Bool)')
    expect(screen).toContain('        applyNavigationBarAppearance()\n        // Each screen says whether it wants the tab bar')
    expect(readFileSync(join(import.meta.dir, '..', 'fixtures/native-screen/NativeLayoutUnitTests.swift'), 'utf8')).toContain('try assertColor(light, red: 1, green: 1, blue: 1)')
    // A screen that starts with its scroll view runs edge to edge, so what
    // scrolls up goes under the bar, not over its back button; the bottom
    // stays unclipped, under the floating tab bar.
    expect(screen).toContain('let edgeToEdge = scroll != nil && (prefersLargeTitle == true || scroll === leadingScroll?.view)')
    expect(screen).toContain('view is UIScrollView && overflow != "visible"')
    expect(screen).toContain('leadingScroll.style["overflow"] as? String != "hidden"')
    // Speech: an interrupting cue speaks on a fresh synthesizer (one handed an
    // utterance right after stopSpeaking can drop it), the session lingers a
    // moment after the last word, and claiming it never blocks the main thread.
    expect(services).toContain('if interrupt, cancelPending() { retireSynthesizer() }')
    expect(services).toContain('static let releaseAfterSilence: TimeInterval = 1.5')
    expect(services).toContain('sessionQueue.async {\n            self.claimSession()')
    expect(services).toContain('DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)')
    // Each cue's pitch and quiet before it, in the best voice installed for
    // its language (premium, then enhanced), the page's speech included.
    expect(services).toContain('utterance.pitchMultiplier = Float(min(max(wantedPitch, 0.5), 2))')
    expect(services).toContain('utterance.preUtteranceDelay = min(max(quiet, 0), 5)')
    expect(services).toContain('let left = (lhs.quality.rawValue, Self.baseName(lhs.name) == name ? 1 : 0, lhs.identifier == standard.identifier ? 1 : 0)')
    expect(services).toContain('voice.voiceTraits.contains(.isNoveltyVoice)')
    expect(app).toContain('let utterance = CraftNativeSpeech.utterance(')
    // A sound or video starting while speech holds the session leaves it to
    // speech, which hands it over when it lets go.
    expect(services).toContain('if CraftNativeSpeech.shared.holdsSession {')
    expect(services).toContain('CraftNativeSounds.reclaimSessionIfPlaying(handedBack: previous)')
    // A video with sound mixes with the music, and may float in Picture in Picture.
    expect(screen).toContain('CraftNativeSounds.claimSession(respectSilentSwitch: false)')
    expect(screen).toContain('playerController.canStartPictureInPictureAutomaticallyFromInline = floating')
    expect(screen).toContain('pictureInPicture: (props["pictureInPicture"] as? Bool) == true')
    // craft.animation.next: the next change animates, shared elements by transitionID.
    expect(screen).toContain('case "ANIMATE_NEXT":')
    expect(screen).toContain('transitionIDs[ObjectIdentifier(result)] = transitionID')
    expect(screen).toContain('UIAccessibility.isReduceMotionEnabled')
    // Live views animate on their layers only, from how they were: a value
    // the screen sets meanwhile (the next second, a style patch) is kept.
    expect(screen).toContain('animation.fromValue = from')
    expect(screen).toContain('for (layer, key) in layers { layer.removeAnimation(forKey: key) }')
    // A view that faded in the overlay goes back as it was.
    expect(screen).toContain('going.alpha = record.alpha')
    expect(app).toContain('if body["interrupt"] as? Bool ?? true, self.cancelPendingSpeech() {')
    expect(app).toContain('private static let speechReleaseAfterSilence: TimeInterval = 1.5')
    expect(hybrid).toContain('!native.contentSwipeBack')
    // Both iOS pop recognizers yield to a native horizontal pager that can
    // still scroll back (the edge's included); at its first page the swipe is
    // Back again. `swipeBack: false` turns both off.
    expect(hybrid).toContain('if horizontalScrollCanScrollBack(at: nav.view.convert(start, to: view), in: native.view) { return false }')
    expect(hybrid).toContain('scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1')
    expect(hybrid).toContain('if !native.swipeBack { return false }')
    expect(hybrid).not.toContain('nativeScreenContainsHorizontalScroll')
    expect(screen).toContain('if let swipeBack = options["swipeBack"] as? Bool {')
    // Tabs swipe only between their first screens, and not under a screen that put the bar away.
    expect(hybrid).toContain('guard nav.viewControllers.count == 1, nav.transitionCoordinator == nil,\n                  !CraftChrome.shared.hiddenByScreen else { return false }')
    expect(hybrid).toContain('!native.tabSwipeEnabled || !native.contentSwipeBack')
    expect(hybrid).toContain('private var tabSwipeRecognizers: [UIGestureRecognizer] = []')
    expect(hybrid).toContain('@objc private func tabSwipeRecognized(_ recognizer: UIPanGestureRecognizer)')
    expect(hybrid).toContain('case .began, .changed:')
    expect(hybrid).toContain('guard shouldCompleteTabSwipe(progress: translation * sign, speed: velocity * sign) else { return }')
    expect(hybrid).toContain('guard abs(velocity.x) > abs(velocity.y) else { return false }')
    expect(hybrid).toContain('return !horizontalScrollAt(gestureRecognizer.location(in: view), in: top.view)')
    expect(hybrid).toContain('hit.isDescendant(of: webView) || webView.isDescendant(of: hit)')
    expect(hybrid).toContain('adoptWeb(into: slot, allowHiddenStack: true)')
    expect(hybrid).toContain('hybrid.navigatePage(slot.path)')
    expect(hybrid).toContain('tabSwipeFrom = -direction * width')
    expect(hybrid).toContain('target.view.frame.origin.x = tabSwipeFrom + offset')
    expect(hybrid).toContain('current.topViewController is CraftNativeScreenController')
    expect(hybrid).toContain('scroll.contentSize.width > scroll.bounds.width + 1')
    expect(app).toContain('func swipe(to id: String)')
    expect(app).toContain('private let selectionFeedback = UISelectionFeedbackGenerator()')
    expect(app).toContain('selectionFeedback.selectionChanged()')
    expect(app).toContain('selectionFeedback.prepare()')
    expect(app).toContain('func setHiddenByScreen(_ hidden: Bool) {')
    expect(screen).toContain('case "NAVIGATE_POP_TO_ROOT":')
    expect(screen).toContain('navigationController?.popToRootViewController(animated: true)')
    expect(hybrid).toContain('(stacks[tab]?.viewControllers.first as? CraftNativeScreenController)?.receiveRouteParams(params(for: raw, match), props: props)')
    expect(hybrid).toContain('(existing as? CraftNativeScreenController)?.receiveRouteParams(params(for: raw, match), props: props)')
    expect(hybrid).toContain('(nav.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)')
  })

  it('lends native screens the page\'s GPS recorder, keep awake, brightness and status bar', async () => {
    const output = createTempDir('craft-ios-native-workout-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableGeolocation: true, enableBackgroundLocation: true, enableKeepAwake: true, nativeScreens: { '/m/go/:id': 'Go' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(actions).toContain('if config.enableGeolocation {')
    expect(actions).toContain('values.append("geolocation")')
    expect(actions).toContain('if CraftZigRuntime.supportsRecordingOwnership { values.append("locationRecordingOwnership") }')
    expect(actions).toContain('if config.enableKeepAwake { values.append("keepAwake") }')
    expect(actions).toContain('"startRecording": "startLocationRecording"')
    expect(actions).toContain('CraftWebServices.perform(action: action, body: args.first as? [String: Any] ?? [:])')
    expect(actions).toContain('UIApplication.shared.isIdleTimerDisabled = enabled')
    expect(actions).toContain('CraftStatusBar.setStyle(')
    // A native screen's call is answered in Swift, never in the page.
    expect(app).toContain('if CraftWebServices.resolve(id, result: result) { return }')
    expect(app).toContain('if CraftWebServices.reject(id, message: error, code: code) { return }')
    expect(app).toContain('CraftWebServices.forward(event, data: data)')
    expect(app).toContain('static let forwardedEvents: Set<String> = ["craftNetworkChange", "craftLocationUpdate", "craftLocationError", "craftHealthHeartRate", "craftHealthWorkout", "craftMusicChange", "craftHeartRate"]')
    expect(screen).toContain('self?.send(type: "CRAFT_EVENT", payload: ["event": name')
  })

  it('gives native screens Web Audio, rendered on the screen\'s AVAudioEngine', async () => {
    const output = createTempDir('craft-ios-native-web-audio-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { nativeScreens: { '/m/relax/class/:id': 'BreathClass' } } as any })
    const audio = readFileSync(join(output, 'Sources', 'CraftWebAudio.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    const services = readFileSync(join(output, 'Sources', 'CraftNativeServices.swift'), 'utf8')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    // Installed before the bundle runs, and torn down with the screen.
    expect(screen).toContain('private let audio = CraftWebAudio()')
    expect(screen).toContain('audio.install(in: jsContext)')
    expect(screen).toContain('audio.close()')
    // The old oscillator-only stand-in (and its unreadable AUDIO messages) is gone.
    expect(screen).not.toContain("type: 'AUDIO'")
    expect(screen).not.toContain('class CraftNativeAudio')
    // The graph renders in one source node per context, in 128-frame quanta.
    expect(audio).toContain('let craftAudioQuantum = 128')
    expect(audio).toContain('let source = AVAudioSourceNode(format: format)')
    expect(audio).toContain('engine.connect(source, to: engine.mainMixerNode, format: format)')
    for (const node of ['CraftAudioGain', 'CraftAudioOscillator', 'CraftAudioBufferSource', 'CraftAudioBiquad', 'CraftAudioDelay', 'CraftAudioCompressor', 'CraftAudioConvolver'])
      expect(audio).toContain(`final class ${node}: `)
    for (const call of ['createDynamicsCompressor', 'createConvolver', 'createBuffer', 'createBufferSource', 'createBiquadFilter', 'createDelay', 'exponentialRampToValueAtTime', 'setTargetAtTime', 'cancelScheduledValues', 'cancelAndHoldAtTime', 'setValueCurveAtTime'])
      expect(audio).toContain(call)
    // The render thread never blocks on the main thread.
    expect(audio).toContain('guard os_unfair_lock_trylock(lock) else { return }')
    // Ambient, as a web view's Web Audio is: mixes with music, the silent
    // switch mutes it, and no background audio mode is added for it.
    expect(audio).toContain('CraftNativeSounds.claimSession(respectSilentSwitch: true)')
    expect(audio).toContain('CraftNativeSounds.releaseSession()')
    expect(services).toContain('category = respectSilentSwitch && (playing == 1 || category == .ambient) ? .ambient : .playback')
    expect(services).toContain('try session.setCategory(category, mode: .default, options: [.mixWithOthers])')
    expect(services).toContain('AVAudioSession.interruptionNotification')
    expect(services).toContain('sound.interrupted = true')
    expect(services).toContain('AVAudioSession.InterruptionOptions.shouldResume')
    expect(screen).toContain('reply(.success(sounds.pause(id: id)))')
    expect(screen).toContain('reply(.success(sounds.resume(id: id)))')
    expect(screen).toContain('reply(.success(sounds.stop(id: id, fadeOut: number(1, "fadeOut") / 1000)))')
    expect(plist).not.toContain('<string>audio</string>')
    // A route change or an interruption stops AVAudioEngine; it starts again.
    expect(audio).toContain('forName: .AVAudioEngineConfigurationChange, object: engine')
    expect(audio).toContain('AVAudioSession.interruptionNotification')
  })

  it('cleans failed native photo writes instead of leaving staging folders behind', async () => {
    const output = createTempDir('craft-ios-native-file-cleanup-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { nativeScreens: { '/m/import': 'Import' } } as any })
    const files = readFileSync(join(output, 'Sources', 'CraftNativeFiles.swift'), 'utf8')
    const encoder = files.slice(files.indexOf('static func writeJPEG(_ image: CGImage'), files.indexOf('static func jpegName('))
    expect(encoder).toContain('CGImageDestinationCreateWithURL')
    expect(encoder).toContain('CGImageDestinationFinalize(destination) else {')
    expect(encoder.match(/removeItem\(at: url\.deletingLastPathComponent\(\)\)/g)?.length).toBe(2)
  })

  it('generates bounded file deletion with truthful failure reporting', async () => {
    const output = createTempDir('craft-ios-native-file-removal-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { renderer: 'native' } })
    const files = readFileSync(join(output, 'Sources', 'CraftNativeFiles.swift'), 'utf8')
    const removal = files.slice(files.indexOf('static func remove(_ path: String)'), files.indexOf('private static func sweepOnce()'))
    expect(files).toContain('import Darwin')
    expect(removal).toContain('guard url.path.withCString({ unlink($0) }) == 0 else { return false }')
    expect(removal).toContain('if parent.path != base.path')
    expect(removal).toContain('parent.path.withCString { rmdir($0) }')
    expect(removal).not.toContain('removeItem')
  })

  it('runs an all-native app with the shell\'s tabs and paths, an app script and the web view\'s services', async () => {
    const output = createTempDir('craft-ios-native-app-')
    const bundle = join(output, 'bundle.js')
    writeFileSync(bundle, '// screens\n')
    await init({
      runtimeDir: null,
      name: 'Gate',
      bundleId: 'com.example.gate',
      output,
      config: {
        renderer: 'native',
        devServerURL: 'https://example.com/m',
        nativeScreens: { '/m': 'Today' },
        tabs: [{ id: '/m', title: 'Today' }],
        nativeApp: '__app',
        nativeBundle: bundle,
        enablePushNotifications: true,
        backgroundRefresh: { enabled: true },
      },
    })
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')
    const hybrid = readFileSync(join(output, 'Sources', 'CraftHybrid.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')

    // The routed shell for either renderer, ahead of the single-stack screen.
    expect(app.indexOf('if CraftHybrid.shared.isEnabled {')).toBeLessThan(app.indexOf('} else if appState.config.renderer == "native" {'))
    expect(hybrid).toContain('hasWeb = config.renderer != "native"')
    expect(hybrid).toContain('let wanted = !routes.isEmpty')
    // No web view is ever made without a page.
    expect(hybrid).toContain('webHost = CraftHybrid.shared.hasWeb')
    expect(hybrid).toContain('hybrid.openOutside(raw)')
    // The web view's services, from a coordinator with no web view.
    expect(hybrid).toContain('let coordinator = CraftWebView.Coordinator(config: config)')
    expect(hybrid).toContain('CraftSwiftShim.coordinator = coordinator')
    expect(app).toContain('CraftHybrid.shared.configure(config)')

    // The app script: headless, kept, after the first frame; the app's events go to it.
    expect(hybrid).toContain('CraftNativeScreenController(config: config, routeName: route, isAppScript: true)')
    expect(hybrid).toContain('script.loadViewIfNeeded()')
    expect(hybrid).toContain('self?.hybrid.startAppScript()')
    expect(hybrid).toContain('CraftEventManager.shared.configure(appScript: appScriptRoute != nil, page: hasWeb)')
    expect(screen).toContain('CraftEventManager.shared.appScriptReady { [weak self] event, detail in')
    expect(screen).toContain('self?.send(type: "CRAFT_EVENT", payload: ["event": event, "detail": detail])')
    expect(screen).toContain('guard isAppScript || navigationController?.topViewController === self else { return }')
    expect(app).toContain('appScriptSink(event, data)')
    // Every app event is still spelled at a sendToWeb call.
    for (const event of ['craftNotificationResponse', 'craftNotificationReceived', 'craftSilentPush', 'craftBackgroundRefresh', 'craftShortcut', 'craftSiriShortcut'])
      expect(app).toContain(`sendToWeb("${event}"`)

    // What the app script and the screens know of the app, and its answer to background work.
    expect(screen).toContain('appURL: \\(appURL),')
    expect(screen).toContain('appVersion: \\(appVersion),')
    expect(screen).toContain('appBuild: \\(appBuild),')
    expect(actions).toContain('case ("Background", "complete"):')
    expect(actions).toContain('CraftBackgroundWork.shared.complete(id: id, ok: ok)')
    expect(actions).toContain('if config.backgroundRefresh?.enabled == true || config.enablePushNotifications { values.append("background") }')
    // Every snapshot but the kept ones, from a native screen (a sign-out).
    expect(screen).toContain('craftNativeSnapshotClear(names, function(ok) {')
    expect(actions).toContain('static func clear(keeping keep: Set<String> = [], completion: ((Bool) -> Void)? = nil)')
  })

  it('lends native screens the page\'s Music app bridge', async () => {
    const output = createTempDir('craft-ios-native-music-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableAppleMusic: true, nativeScreens: { '/m/go/:id': 'Go' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')
    expect(actions).toContain('if config.enableAppleMusic { values.append("music") }')
    expect(actions).toContain('"getNowPlaying": "musicGetNowPlaying", "control": "musicControl", "observe": "musicObserve"')
    // Its changes reach every native screen, as the page hears them.
    expect(app).toContain('"craftMusicChange", "craftHeartRate"]')
    expect(app).toContain('self?.sendToWeb("craftMusicChange", data: snapshot)')
  })

  it('schedules Apple Watch workouts on the page and on native screens, linking WorkoutKit only when asked', async () => {
    const output = createTempDir('craft-ios-scheduled-workouts-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableScheduledWorkouts: true, nativeScreens: { '/m/plan': 'Plan' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')
    expect(existsSync(join(output, 'Sources', 'CraftScheduledWorkouts.swift'))).toBe(true)
    // The app's own service: a native-only app has it too.
    expect(actions).toContain('if config.enableScheduledWorkouts { values.append("scheduledWorkouts") }')
    expect(actions).toContain('case ("ScheduledWorkouts", _):')
    expect(actions).toContain('CraftScheduledWorkouts.shared.perform(method: method, args: args)')
    expect(app).toContain('case "scheduledWorkouts", "scheduledWorkoutsRequestAuthorization":')
    expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).enableScheduledWorkouts).toBe(true)
    // WorkoutKit is compiled in for this app only.
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toContain('      SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CRAFT_SCHEDULED_WORKOUTS"')

    const plain = createTempDir('craft-ios-no-scheduled-workouts-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output: plain })
    // Still copied, compiled to the stub that answers unsupported.
    expect(existsSync(join(plain, 'Sources', 'CraftScheduledWorkouts.swift'))).toBe(true)
    expect(readFileSync(join(plain, 'project.yml'), 'utf8')).not.toContain('CRAFT_SCHEDULED_WORKOUTS')
  })

  it('adds the scheduled-workouts build condition only for the apps that schedule', () => {
    expect(renderFeatureSettings({})).toBe('')
    expect(renderFeatureSettings({ enableScheduledWorkouts: false })).toBe('')
    expect(renderFeatureSettings({ enableScheduledWorkouts: true })).toBe('      SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CRAFT_SCHEDULED_WORKOUTS"')
  })

  it('reads a heart-rate strap on the page and on native screens alike, with no web view needed', async () => {
    const output = createTempDir('craft-ios-heart-rate-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableHeartRate: true, nativeScreens: { '/m/go/:id': 'Go' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const heartRate = readFileSync(join(output, 'Sources', 'CraftHeartRate.swift'), 'utf8')
    const app = readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')
    expect(existsSync(join(output, 'Sources', 'CraftHeartRate.swift'))).toBe(true)
    // The app's own service: a native-only app has it too.
    expect(actions).toContain('if config.enableHeartRate { values.append(contentsOf: ["heartRate", "heartRateRecordingOwnership", "heartRateRecordingIntentIdentity"]) }')
    expect(actions).toContain('case ("HeartRate", _):')
    expect(actions).toContain('CraftHeartRate.shared.perform(method: method, args: args)')
    expect(heartRate).toContain('craftNativeNumber(options["timeout"]).map { $0.doubleValue }')
    expect(heartRate).toContain('craftNativeNumber(options["since"]).map { $0.doubleValue }')
    expect(app).toContain('case "heartRate", "heartRateRequestAuthorization":')
    expect(app).toContain('CraftHeartRate.shared.pageSink = { [weak self] detail in')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    expect(plist).toContain('<string>bluetooth-central</string>')
    expect(plist).toContain('<string>Gate connects to your heart-rate monitor over Bluetooth to show and record your heart rate during a workout.</string>')
  })

  it('keeps video on the phone for offline and plays the kept copy in a native Video', async () => {
    const output = createTempDir('craft-ios-media-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { nativeScreens: { '/m/workout/:id': 'Workout' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const files = readFileSync(join(output, 'Sources', 'CraftNativeFiles.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    expect(actions).toContain('values.append("media")')
    for (const call of ['case ("Media", "keep"):', 'case ("Media", "path"):', 'case ("Media", "prune"):', 'case ("Media", "usage"):'])
      expect(actions).toContain(call)
    // Kept where iOS does not empty it, out of backups, named by the address.
    expect(files).toContain('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)')
    expect(files).toContain('values.isExcludedFromBackup = true')
    expect(files).toContain('SHA256.hash(data: Data(address.utf8))')
    // Moved into place whole, never played half-written; a refusal keeps nothing.
    expect(files).toContain('try fm.moveItem(at: staging, to: target)')
    expect(files).toContain('return .success(["ok": false, "url": address, "status": response.statusCode])')
    // Wi-Fi only: iOS refuses a metered connection, and that answer is a wait, not a failure.
    expect(actions).toContain('request.allowsExpensiveNetworkAccess = false')
    expect(actions).toContain('request.allowsConstrainedNetworkAccess = false')
    expect(files).toContain('CraftNativeMedia.finish(transfer.address, flight: flight, .success(["ok": false, "url": transfer.address, "reason": "cellular"]))')
    // Two screens asking for the same address share one download.
    expect(actions).toContain('guard let flight = CraftNativeMedia.begin(address, answer) else { return }')
    // On a background session: it carries on while the app is suspended or
    // closed, a keep it cannot fetch now is answered as queued, and iOS's
    // relaunch for finished transfers reaches the session.
    expect(actions).toContain('CraftNativeMediaTransfers.shared.start(request, address: address, flight: flight, wifiOnly: wifiOnly)')
    expect(files).toContain('URLSessionConfiguration.background(withIdentifier: Self.identifier)')
    expect(files).toContain('configuration.sessionSendsLaunchEvents = true')
    expect(files).toContain('"reason": reason, "queued": true')
    expect(readFileSync(join(output, 'Sources', 'GateApp.swift'), 'utf8')).toContain('handleEventsForBackgroundURLSession identifier: String')
    // A sign-out stops every transfer, and one started before it never lands.
    expect(files).toContain('CraftNativeMediaTransfers.shared.cancelAll()')
    expect(files).toContain('stillWanted: { [weak self] in self?.isCurrent(started) ?? false }')
    // The Video element plays the kept copy, and says so when an address cannot load.
    expect(screen).toContain('let kept = CraftNativeMedia.local(uri)')
    expect(screen).toContain('self.fire("onError", ["message": "The video address is not a full URL: \\(uri)"])')
  })

  it('picks a photo, downloads a file and posts a form from a native screen, the bytes kept off the bridge', async () => {
    const output = createTempDir('craft-ios-files-')
    await init({ runtimeDir: null, name: 'Gate', bundleId: 'com.example.gate', output, config: { enableShare: true, nativeScreens: { '/m/workout/:id/share': 'WorkoutShare' } } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const files = readFileSync(join(output, 'Sources', 'CraftNativeFiles.swift'), 'utf8')
    const screen = readFileSync(join(output, 'Sources', 'CraftNativeScreen.swift'), 'utf8')
    // Always there: the library picker asks no permission; the camera is the app's choice.
    expect(actions).toContain('values.append("files")')
    expect(actions).toContain('if config.enableCamera { values.append("camera") }')
    for (const call of ['case ("Files", "pickImage"):', 'case ("Files", "pickFile"):', 'case ("Files", "download"):', 'case ("Files", "write"):', 'case ("Files", "remove"):'])
      expect(actions).toContain(call)
    expect(actions).toContain('CraftNativeFiles.pickImage(options, cameraEnabled: config.enableCamera)')
    expect(actions).toContain('CraftNativeFiles.pickFile(options)')
    // Every operation producing a new owned file uses cancellation cleanup,
    // not just callback suppression. Persistent media keeps its separate path.
    for (const picker of ['pickImage(options, cameraEnabled: config.enableCamera)', 'pickVideo(options)', 'pickFile(options)'])
      expect(actions).toContain(`CraftNativeFiles.${picker} { completeFile(requestToken, $0, completion) }`)
    expect(actions).toContain('completeFile(requestToken, CraftNativeFiles.write(name: name, data: data, options: options), completion)')
    expect(actions).toContain('completeFile(requestToken, CraftNativeFiles.keepDownload(at: location, response: http, name: name), completion)')
    expect(actions).toContain('if cancelled { onCancel?() }')
    expect(actions).toContain('if let path = file["path"] as? String { CraftNativeFiles.remove(path) }')
    // The library picker, decoded once at the size wanted, upright, as JPEG.
    expect(files).toContain('let picker = PHPickerViewController(configuration: configuration)')
    expect(files).toContain('configuration.filter = .images')
    expect(files).toContain('kCGImageSourceCreateThumbnailWithTransform: true')
    expect(files).toContain('kCGImageSourceThumbnailMaxPixelSize: maxPixels')
    expect(files).toContain('CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)')
    expect(files).toContain('picker.sourceType = .camera')
    expect(files).toContain('done(.success(NSNull()))')
    // General documents use the same owned-file contract without the video allowlist.
    expect(files).toContain('UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)')
    expect(files).toContain('static func copyFile(_ source: URL, limit: Int)')
    expect(files).toContain('UTType(filenameExtension: source.pathExtension)?.preferredMIMEType')
    expect(files).toContain('picker.allowsMultipleSelection = selectionLimit > 1')
    // A form's files are read natively, and only files made here.
    expect(actions).toContain('if let form = options["form"] as? [Any] {')
    expect(actions).toContain('request.setValue("multipart/form-data; boundary=\\(boundary)", forHTTPHeaderField: "Content-Type")')
    expect(files).toContain('guard let url = owned(path) else {')
    expect(files).toContain('Content-Disposition: form-data; name=\\"\\(quoted(name))\\"; filename=\\"\\(quoted(filename))\\"')
    // A download goes to disk; a refused one keeps no file and says why.
    expect(actions).toContain('let task = fetchSession.downloadTask(with: request) { location, response, error in')
    expect(files).toContain('return ["ok": false, "status": response.statusCode, "body": text]')
    expect(files).toContain('response.suggestedFilename')
    // What the screen made itself (a CSV export) as text, or bytes as base64.
    expect(files).toContain('static func write(name: String, data: Any?, options: [String: Any])')
    expect(files).toContain('case "base64":')
    // The share sheet takes a file craft.files made as it is.
    const services = readFileSync(join(output, 'Sources', 'CraftNativeServices.swift'), 'utf8')
    expect(services).toContain('item as? String ?? (item as? [String: Any])?["path"] as? String')
    // A request a person answers is never cut off by the host's deadline.
    expect(screen).toContain('if payload["untimed"] as? Bool != true {')
  })

  it('ships connected-peripheral discovery alongside advertised GATT devices', async () => {
    const output = createTempDir('craft-ios-connected-gatt-')
    await init({ name: 'Gatt', bundleId: 'dev.craft.gatt', output, config: { renderer: 'native', enableBluetooth: true } })
    const bluetooth = readFileSync(join(output, 'Sources', 'CraftBluetooth.swift'), 'utf8')
    // The published builder must ship the native lookup for a connected watch
    // that has stopped advertising, as well as the normal service-filtered scan.
    expect(bluetooth).toContain('central.retrieveConnectedPeripherals(withServices: scanServices)')
    expect(bluetooth).toContain('central.scanForPeripherals(withServices: scanServices')
    expect(bluetooth).toContain('devices[id] != nil || devices.count < 64')
  })

  it('keeps a strap\'s readings coming with the screen locked only when the app reads one', () => {
    const config = { appName: 'HQ.training', bundleId: 'training.hq.app' }
    expect(renderBackgroundModes(config)).toBe('')
    expect(renderBackgroundModes({ ...config, enableHeartRate: true })).toContain('<string>bluetooth-central</string>')
    expect(renderBackgroundModes({ ...config, enableBluetooth: true })).toBe('')
    expect(renderUsageDescriptions(config)).not.toContain('NSBluetoothAlwaysUsageDescription')
    expect(renderUsageDescriptions({ ...config, enableBluetooth: true })).toContain('<string>HQ.training uses Bluetooth to connect to nearby devices.</string>')
    expect(renderUsageDescriptions({ ...config, enableHeartRate: true, usageDescriptions: { NSBluetoothAlwaysUsageDescription: 'Shows your heart rate from your strap.' } }))
      .toContain('<key>NSBluetoothAlwaysUsageDescription</key>\n    <string>Shows your heart rate from your strap.</string>')
  })

  it('draws the inputs a native sign-in screen needs: autofill, padding, the next field, a date picker', () => {
    const screen = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftNativeScreen.swift'), 'utf8')
    expect(screen).toContain('case "password", "currentpassword": return .password')
    expect(screen).toContain('case "onetimecode": return .oneTimeCode')
    expect(screen).toContain('applyAutofill(to: field, props: props)')
    expect(screen).toContain('(field as? CraftNativeTextField)?.padding = paddingInsets(style)')
    expect(screen).toContain('func textFieldShouldReturn(_ textField: UITextField) -> Bool {')
    expect(screen).toContain('scroll.contentInset.bottom = overlap')
    expect(screen).toContain('case "DatePicker":\n            let picker = UIDatePicker()')
    expect(screen).toContain('case "datepicker", "date-picker", "date": return "DatePicker"')
    expect(screen).toContain('"Picker", "DatePicker", "Switch"')
    expect(screen).toContain('picker.addTarget(self, action: #selector(datePicked(_:)), for: .valueChanged)')
    expect(screen).toContain('source: props["source"] ?? props["src"],')
    expect(screen).toContain('if let url = imageURL(for: uri) {')
  })

  it('gives every Swift-only call that waits on a framework callback a deadline', async () => {
    // #224: each of these is answered only by Swift, on both runtimes, and
    // only by a framework callback no person is waiting on. Nothing settled
    // the page's promise if it never came — the shape #211 hit twice on CI.
    const output = createTempDir('craft-ios-swift-deadlines-')
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })

    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')

    // One mechanism, and both halves of it: arming alone would never answer,
    // claiming alone would let both paths answer.
    expect(swift).toContain('private func armDeadline(')
    expect(swift).toContain('private func claimDeadline(_ token: UUID) -> Bool')
    expect(swift).toContain('guard let work = pendingDeadlines.removeValue(forKey: token) else { return false }')
    // It reports a timeout, never the work having happened.
    expect(swift).toContain('self.rejectCallback(callbackId, error: error, code: "TIMEOUT")')

    // Four call sites, each with its own budget, all well under the 30s the
    // page's own _invoke allows so the caller hears the native answer.
    for (const [constant, uses] of [
      ['notificationSettingsDeadline', 1],
      ['pushRegistrationDeadline', 1],
      ['storeKitDeadline', 1],
      // Live Activities share one budget across update and end.
      ['liveActivityDeadline', 1],
    ] as const) {
      expect(swift).toContain(`private static let ${constant}: TimeInterval =`)
      expect(swift.match(new RegExp(`Coordinator\\.${constant},`, 'g'))?.length).toBe(uses)
    }
    // Every arm has a claim. Four sites arm; the claims are those four plus
    // the push helper's own and the two places it is reached through.
    expect(swift.match(/armDeadline\(/g)?.length).toBe(5)
    expect(swift.match(/claimDeadline\(/g)?.length).toBe(7)

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
    const output = createTempDir('craft-ios-load-failure-')
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
    expect(recovery).toContain('webView.load(config.request(for: remote))')
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
    const output = createTempDir('craft-ios-notification-tap-')
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
    const output = createTempDir('craft-ios-notification-received-')
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

  it('updates badges without replacing full notification authorization with a badge-only request', async () => {
    const output = createTempDir('craft-ios-badge-authorization-')
    await init({ name: 'WildLoop', bundleId: 'org.wildloop.app', output })
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const badge = swift.slice(swift.indexOf('private func setBadgeCount('), swift.indexOf('// MARK: - App Review'))
    expect(badge).not.toContain('requestAuthorization')
    expect(badge).toContain('UNUserNotificationCenter.current().setBadgeCount(count)')
    const registration = swift.slice(swift.indexOf('private func registerPushNotifications('), swift.indexOf('@objc private func receivePushToken('))
    expect(registration).toContain('requestAuthorization(options: [.alert, .badge, .sound])')
  })

  it('gives native screens permission-free app badge controls', async () => {
    const output = createTempDir('craft-ios-native-badge-')
    await init({ name: 'NativeBadge', bundleId: 'org.example.nativebadge', output, config: { renderer: 'native' } as any })
    const actions = readFileSync(join(output, 'Sources', 'CraftNativeActions.swift'), 'utf8')
    const badge = actions.slice(actions.indexOf('private static func setBadgeCount('))
    expect(actions).toContain('"linking", "badge", "animation", "viewFocus", "viewMeasure", "viewReparent", "viewNonModalPresentation", "nativePlatformControls"]')
    expect(actions).toContain('case ("Badge", "set"):')
    expect(actions).toContain('case ("Badge", "clear"):')
    expect(badge).toContain('UNUserNotificationCenter.current().setBadgeCount(count)')
    expect(badge).not.toContain('requestAuthorization')
  })

  it('schedules a local notification with the data the page gave it', async () => {
    // #258: `data` never reached userInfo, so a tap on a scheduled
    // notification handed the page {} and it had nothing to route on.
    const output = createTempDir('craft-ios-notification-data-')
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
    const output = createTempDir('craft-ios-location-no-fix-')
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
    expect(body).toContain('guard let self, self.singleLocationCallbackId == waiting, self.singleLocationAcquisitionStarted else { return }')
    expect(body).toContain('self.locationManager?.requestLocation()')
  })

  it('settles calendar callbacks only after a real EventKit operation', async () => {
    const output = createTempDir('craft-ios-calendar-')
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
    const output = createTempDir('craft-ios-contacts-')
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
    const output = createTempDir('craft-ios-watch-')
    const iosOutput = createTempDir('craft-ios-watch-sibling-')
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { deviceFamilies: ['iphone'], enableWatchApp: true, enableHealthKit: true, watchosVersion: '9.0' },
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
    const watchEntitlements = readFileSync(join(output, 'WatchExtension', 'Watch.entitlements'), 'utf8')
    expect(project).toContain('WildLoopWatch:')
    expect(project).toContain('type: application.watchapp2')
    expect(project).toContain('WildLoopWatchExtension:')
    expect(project).toContain('type: watchkit2-extension')
    expect(project).toContain('target: WildLoopWatchExtension')
    expect(project).toContain('platform: watchOS')
    expect(project).toContain('embed: true')
    expect(project.match(/PRODUCT_NAME: "\$\(TARGET_NAME\)"/g)).toHaveLength(3)
    expect(project).toContain('TARGETED_DEVICE_FAMILY: "1"')
    expect(swift).toContain('setupWatchConnectivity()')
    expect(swift).toBe(readFileSync(join(iosOutput, 'Sources', 'WildLoopApp.swift'), 'utf8'))
    expect(watch).toContain('recording-control')
    expect(watch).toContain('protocolVersion')
    expect(watch).toContain('requestId')
    expect(watch).toContain('stateVersion')
    expect(watch).toContain('guard incomingVersion >= stateVersion else { return }')
    expect(watch).toContain('stateVersion = incomingVersion')
    expect(watch).toContain('planned-session')
    expect(watch).toContain('craft.watch.state.v1')
    expect(watch).toContain('updateApplicationContext(state)')
    expect(watch).toContain('restoreState()')
    expect(watch).toContain('private static let healthKitEnabled = true')
    expect(watch).toContain('HKLiveWorkoutBuilder')
    expect(watch).toContain('heartRateZone')
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
    expect(watchExtensionInfo).toContain('NSHealthShareUsageDescription')
    expect(watchExtensionInfo).toContain('NSHealthUpdateUsageDescription')
    expect(watchEntitlements).toContain('com.apple.developer.healthkit')
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

  it('never chooses a booted runtime newer than the selected Xcode SDK', () => {
    const chosen = orderSimulators([
      device('iPhone 17 Pro', 'iOS-26-2', 'Booted'),
      device('iPhone 16', 'iOS-18-5'),
    ], '18.5')[0]
    expect(chosen?.runtime).toBe('iOS-18-5')
  })

  it('compares runtime versions numerically and respects SDK minor versions', () => {
    const devices = [
      device('iPhone', 'iOS-9-3'),
      device('iPhone', 'iOS-26-3'),
      device('iPhone', 'iOS-26-2-1'),
      device('iPhone', 'iOS-18-5'),
    ]
    expect(orderSimulators(devices, '26.2')[0]?.runtime).toBe('iOS-26-2-1')
    expect(orderSimulators(devices)[0]?.runtime).toBe('iOS-26-3')
  })

  it('reports no compatible simulator instead of using a newer runtime', () => {
    expect(orderSimulators([device('iPhone 17', 'iOS-26-2')], '18.5')).toEqual([])
    expect(() => orderSimulators([], 'unknown')).toThrow('Invalid iOS Simulator SDK version')
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
    const dir = createTempDir('craft-rt-')
    for (const a of archives) writeFileSync(join(dir, a), 'stand-in for an archive')
    profileFixture(dir, archives)
    return dir
  }

  it('refuses unprofiled archives and verifies installed identity before restoring any sources', async () => {
    const output = createTempDir('craft-profile-restore-')
    const directory = fakeRuntime()
    await init({ name: 'ProfileRestore', output, runtimeDir: directory })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    const runtime = join(output, 'Runtime')
    expect(() => verifyInstalledProfile(runtime, config)).not.toThrow()
    expect(() => verifyInstalledProfile(runtime, { ...config, enableContacts: true })).toThrow('stale')
    const source = join(output, 'Sources', 'ProfileRestoreApp.swift')
    writeFileSync(source, 'preserve until validation succeeds')
    writeFileSync(join(runtime, 'device/libcraft-ios.a'), 'tampered')
    expect(() => restoreShell(output)).toThrow('identity mismatch')
    expect(readFileSync(source, 'utf8')).toBe('preserve until validation succeeds')
    rmSync(join(directory, 'ios-permissions.json'))
    expect(() => verifyRuntimeProfile(directory, config)).toThrow('Unprofiled')
    const plist = readFileSync(join(output, 'Info.plist'), 'utf8')
    await expect(init({ name: 'ProfileRestore', output, runtimeDir: directory, config: { enableCamera: true } })).rejects.toThrow('Unprofiled')
    expect(readFileSync(join(output, 'Info.plist'), 'utf8')).toBe(plist)
    expect(readFileSync(source, 'utf8')).toBe('preserve until validation succeeds')
    await expect(installRuntime(output, directory, config)).rejects.toThrow('Unprofiled')
    expect(readFileSync(join(runtime, 'device/libcraft-ios.a'), 'utf8')).toBe('tampered')
  })

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
    const output = createTempDir('craft-out-')
    expect(await installRuntime(output, fakeRuntime())).toBe(true)
    expect(existsSync(join(output, 'Runtime', 'device', 'libcraft-ios.a'))).toBe(true)
    expect(existsSync(join(output, 'Runtime', 'simulator', 'libcraft-ios.a'))).toBe(true)
  })

  it('keeps installed archives when merging replacement simulator slices fails', async () => {
    const output = createTempDir('craft-runtime-rollback-')
    await installRuntime(output, fakeRuntime())
    const installed = join(output, 'Runtime/device/libcraft-ios.a')
    const before = readFileSync(installed, 'utf8')
    const malformed = fakeRuntime(['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a'])
    await expect(installRuntime(output, malformed)).rejects.toThrow()
    expect(readFileSync(installed, 'utf8')).toBe(before)
  })

  it('warns when only one simulator slice is present, rather than shipping it silently', async () => {
    const warnings: string[] = []
    const saved = console.warn
    console.warn = (...args: unknown[]) => void warnings.push(args.join(' '))
    try {
      await installRuntime(createTempDir('craft-out-'), fakeRuntime())
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
    const output = createTempDir('craft-out-')
    await installRuntime(output, fakeRuntime())
    const installed = join(output, 'Runtime', 'device', 'libcraft-ios.a')
    expect(existsSync(installed)).toBe(true)

    const empty = createTempDir('craft-rt-empty-')
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
    const output = createTempDir('craft-app-')
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
    const dir = createTempDir('craft-rt-')
    for (const a of ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a']) {
      writeFileSync(join(dir, a), marker)
    }
    profileFixture(dir, ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a'])
    return dir
  }

  it('build picks up a rebuilt runtime instead of relinking the one init copied', async () => {
    const output = createTempDir('craft-app-')
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
    const output = createTempDir('craft-app-')
    await init({ runtimeDir: null, name: 'NoRuntime', output })
    expect(existsSync(join(output, 'Runtime'))).toBe(false)

    // A runtime is available, but this project does not link one: its
    // project.yml has no link settings, so archives here would be dead weight.
    await build({ output, runtimeDir: runtimeWith('ignored'), generateProject: false })
    expect(existsSync(join(output, 'Runtime'))).toBe(false)
  })

  it('build keeps the installed runtime when no runtime directory is configured', async () => {
    const output = createTempDir('craft-app-')
    await init({ runtimeDir: runtimeWith('from init'), name: 'Keep', output })
    // A shell that forgot the variable must not quietly turn the runtime off.
    await build({ output, runtimeDir: null, generateProject: false })
    expect(readFileSync(join(output, 'Runtime', 'device', 'libcraft-ios.a'), 'utf8')).toBe('from init')
  })
})

describe('crash reporting (CraftCrashReporter.swift)', () => {
  it('copies the reporter into every shell, versioned, and starts it first at launch', async () => {
    const output = createTempDir('craft-ios-crash-')
    await init({ name: 'Crash', bundleId: 'dev.craft.crash', output, runtimeDir: null, config: { crashReporting: { key: 'bughq_k' } } })
    const reporter = readFileSync(join(output, 'Sources', 'CraftCrashReporter.swift'), 'utf8')
    expect(reporter).not.toContain('{{CRAFT_VERSION}}')
    expect(reporter).toContain(`"${resolveCraftVersion()}"`)
    const app = readFileSync(join(output, 'Sources', 'CrashApp.swift'), 'utf8')
    const launch = app.indexOf('func application(_ application: UIApplication, didFinishLaunchingWithOptions')
    expect(app.indexOf('CraftCrashReporter.shared.start(config)', launch)).toBeGreaterThan(launch)
    expect(app.indexOf('CraftCrashReporter.shared.start(config)', launch)).toBeLessThan(app.indexOf('CraftHybrid.shared.configure(config)', launch))
    expect(JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8')).crashReporting).toEqual({ key: 'bughq_k' })
  })

  it('declares crash data in the privacy manifest only when reporting is on', () => {
    const base = { appName: 'Crash', bundleId: 'dev.craft.crash' }
    expect(renderPrivacyManifest(base)).not.toContain('NSPrivacyCollectedDataTypeCrashData')
    const manifest = renderPrivacyManifest({ ...base, crashReporting: { key: 'bughq_k' } })
    expect(manifest).toContain('NSPrivacyCollectedDataTypeCrashData')
    expect(manifest).toContain('NSPrivacyCollectedDataTypePurposeAppFunctionality')
    // Not twice when the app already declared it.
    const declared = renderPrivacyManifest({
      ...base,
      crashReporting: { key: 'bughq_k' },
      privacy: { collectedDataTypes: [{ type: 'NSPrivacyCollectedDataTypeCrashData', purposes: ['NSPrivacyCollectedDataTypePurposeAnalytics'] }] },
    })
    expect(declared.match(/NSPrivacyCollectedDataTypeCrashData/g)?.length).toBe(1)
  })

  it('keeps the signal handler to async-signal-safe calls', () => {
    // The handler runs with the process in an unknown state: no Swift
    // collections, strings or allocation between its first and last line.
    const source = readFileSync(join(import.meta.dir, '../templates/CraftCrashReporter.swift'), 'utf8')
    const start = source.indexOf('private func craftSignalHandler(')
    const end = source.indexOf('\n}\n', start)
    const handler = source.slice(start, end)
    expect(handler).not.toMatch(/\[[A-Za-z]+\]\(|String\(|"\\\(|\.append\(|JSONSerialization|NSLog|print\(/)
    expect(handler).toContain('raise(signal)')
    // The test crash exists only in Debug builds.
    expect(source).toMatch(/#if DEBUG\n {4}\/\/\/ `-CraftCrashTest/)
  })
})

it('packs large native sources losslessly and idempotently without touching small assets', () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-source-compression-'))
  try {
    const source = 'globalThis.ready = true;\n'.repeat(5000)
    const file = join(root, 'screen.js')
    writeFileSync(file, source)
    writeFileSync(join(root, 'config.json'), '{}')
    compressNativeSources(root)
    const packed = readFileSync(file)
    expect(packed.length).toBeLessThan(source.length / 5)
    expect(gunzipSync(packed).toString()).toBe(source)
    expect(readFileSync(join(root, 'config.json'), 'utf8')).toBe('{}')
    compressNativeSources(root)
    expect(readFileSync(file)).toEqual(packed)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})
