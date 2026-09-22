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
      enablePushNotifications: true,
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
    expect(entitlements).not.toContain('<string>development</string>')
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

    // No longer one-way: two ways back to the remote origin.
    expect(swift).toContain('private func returnFromBundledFallback(because reason: String)')
    expect(swift).toContain('loadedBundledFallback = false')
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
