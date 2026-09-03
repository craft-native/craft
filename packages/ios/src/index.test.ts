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
  renderBackgroundModes,
  renderEntitlements,
  renderOrientations,
  renderPrivacyManifest,
  renderUsageDescriptions,
  renderUrlTypes,
  renderWatchEntitlements,
  syncWebAssets,
} from './index'

describe('Craft iOS builder', () => {
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
    expect(renderUsageDescriptions(config)).not.toContain('NSCameraUsageDescription')
    expect(renderOrientations(config)).toContain('UIInterfaceOrientationPortrait')
    expect(renderUrlTypes(config)).toContain('<string>wildloop</string>')
    expect(renderBackgroundModes(config)).toContain('<string>location</string>')
  })

  it('generates entitlements and privacy declarations from explicit configuration', () => {
    const config = {
      appName: 'WildLoop',
      bundleId: 'org.wildloop.app',
      associatedDomains: ['applinks:wildloop.org'],
      enableHealthKit: true,
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

    expect(renderEntitlements(config)).toContain('applinks:wildloop.org')
    expect(renderEntitlements(config)).toContain('com.apple.developer.healthkit')
    expect(renderWatchEntitlements({ ...config, appGroups: ['group.org.wildloop.app'] })).toContain('group.org.wildloop.app')
    expect(renderPrivacyManifest(config)).toContain('NSPrivacyCollectedDataTypePreciseLocation')
    expect(renderPrivacyManifest(config)).toContain('CA92.1')
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
    expect(swift).toContain('BundledAssetSchemeHandler')
    expect(swift).toContain('craft://app/index.html')
    expect(swift).toContain('bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist")')
    expect(swift).toContain('.skipsPackageDescendants')
    expect(swift).not.toContain('loadFileURL')
    expect(swift).toContain("craft.contractVersion = '1.0.0'")
    expect(swift).toContain('craft.location = {')
    expect(swift.match(/private var pendingCallbackId/g)?.length).toBe(1)
    expect(plist).toContain('NSLocationWhenInUseUsageDescription')
    expect(plist).toContain('<string>wildloop</string>')
    expect(project).not.toContain('    resources:')
    expect(project).toContain('      - path: dist\n        type: folder\n        buildPhase: resources')
    expect(plist).toContain('<string>location</string>')
    expect(existsSync(join(output, 'Craft.entitlements'))).toBe(true)
    expect(existsSync(join(output, 'PrivacyInfo.xcprivacy'))).toBe(true)
    expect(existsSync(join(output, 'Assets.xcassets', 'AppIcon.appiconset', 'Contents.json'))).toBe(true)
    expect(generatedConfig.enableHaptics).toBe(true)
    expect(generatedConfig.enableSecureStorage).toBe(false)
    expect(generatedConfig.enableScreenCapture).toBe(false)
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
    expect(swift).toContain('saveHealthWorkout')
    expect(swift).toContain('HKWorkoutRouteBuilder')
    expect(plist).toContain('NSSupportsLiveActivities')
    expect(existsSync(join(output, 'Shared', 'CraftActivityAttributes.swift'))).toBe(true)
    expect(existsSync(join(output, 'WidgetExtension', 'WildLoopLiveActivity.swift'))).toBe(true)
  })

  it('generates an embedded watchOS companion when enabled', async () => {
    const output = mkdtempSync(join(tmpdir(), 'craft-ios-watch-'))
    await init({
      runtimeDir: null,
      name: 'WildLoop',
      bundleId: 'org.wildloop.app',
      output,
      config: { deviceFamilies: ['iphone'], enableWatchApp: true, watchosVersion: '9.0' },
    })

    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const swift = readFileSync(join(output, 'Sources', 'WildLoopApp.swift'), 'utf8')
    const watch = readFileSync(join(output, 'WatchApp', 'WildLoopWatchApp.swift'), 'utf8')
    const watchInfo = readFileSync(join(output, 'WatchApp', 'Info.plist'), 'utf8')
    expect(project).toContain('WildLoopWatch:')
    expect(project).toContain('type: application')
    expect(project).toContain('platform: watchOS')
    expect(project).toContain('embed: true')
    expect(project).toContain('TARGETED_DEVICE_FAMILY: "1"')
    expect(swift).toContain('setupWatchConnectivity()')
    expect(watch).toContain('recording-control')
    expect(watch).toContain('WCSessionDelegate')
    expect(watchInfo).toContain('<key>CFBundleIdentifier</key>')
    expect(watchInfo).toContain('<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>')
    expect(watchInfo).toContain('<key>CFBundleExecutable</key>')
    expect(watchInfo).toContain('<key>CFBundleShortVersionString</key>')
    expect(watchInfo).toContain('<string>org.wildloop.app</string>')
    expect(watchInfo).not.toContain('<key>WKWatchKitApp</key>')
    expect(existsSync(join(output, 'WatchApp', 'Info.plist'))).toBe(true)
    expect(existsSync(join(output, 'WatchApp', 'Watch.entitlements'))).toBe(true)
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
