import Foundation
import AuthenticationServices
import LocalAuthentication
import PassKit
import SQLite3
import Security
import UIKit
import UserNotifications

let craftNativeCapabilityProtocolVersion = 1
/// URLSession's own request timeout, matching the bridge's 30-second deadline.
let craftNativeFetchTimeoutSeconds: TimeInterval = 30
/// A response body larger than this rejects with RESPONSE_TOO_LARGE rather
/// than being copied into JavaScriptCore as one string.
let craftNativeFetchMaxResponseBytes = 8 * 1024 * 1024

struct CraftNativeActionError: Error {
    let code: String
    let message: String
}

/// Process-wide capability services used by every retained native route.
/// Database work is serialized so transactions cannot be interleaved by two
/// JavaScript contexts, while completions return to JavaScriptCore on main.
enum CraftNativeActions {
    private static let storagePrefix = "craft.native.storage."
    private static let databaseQueue = DispatchQueue(label: "dev.craft.native.database")
    private static let cancellationLock = NSLock()
    private static var cancelledRequests = Set<String>()
    private static var biometricContexts = [String: LAContext]()
    private static var fetchTasks = [String: URLSessionTask]()
    private static let fetchSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = craftNativeFetchTimeoutSeconds
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    private static var initialDeepLinkClaimed = false
    private static var database: OpaquePointer?
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func capabilities(config: CraftConfig) -> [String] {
        // `speech`, `audio` (background sound) and `eventStream` (a fetch read
        // as it arrives) need nothing the app has to declare.
        var values = ["device", "clipboard", "haptics", "storage", "lifecycle", "fetch", "dialog", "speech", "audio", "eventStream", "linking", "badge", "animation", "viewFocus", "viewMeasure", "viewReparent", "viewNonModalPresentation", "nativePlatformControls"]
        values.append("network")
        values.append("nativePager")
        values.append("storageCompareAndSet")
        values.append("storageSetIfAbsent")
        values.append("viewScroll")
        values.append("crypto")
        values.append("shortcuts")
        if config.enableBiometric { values.append("biometric") }
        if config.enableSecureStorage { values.append("secureStorage") }
        if config.enableLocalDatabase { values.append("database") }
        if config.enableDeepLinks { values.append("deepLinks") }
        if config.enableLocalNotifications { values.append("notifications") }
        if config.enableHealthKit { values.append("health") }
        if config.enableWallet { values.append("wallet") }
        if config.enableLiveActivities { values.append("liveActivities") }
        // The in-app browser and the system's web sign-in sheet (CraftBrowser).
        values.append("browser")
        if config.enableSocialAuth { values.append("appleSignIn") }
        if config.enablePasskeys && !CraftNativePasskeys.domains(in: config).isEmpty { values.append("passkeys") }
        if config.enablePushNotifications { values.append("push") }
        if config.enableShare { values.append("share") }
        // The screen's brightness and the status bar's style need nothing
        // declared; keeping the screen awake is the app's choice.
        values.append(contentsOf: ["brightness", "statusBar"])
        if config.enableKeepAwake { values.append("keepAwake") }
        // GPS and the route recording are the web view's coordinator's
        // (CraftWebServices); an app with no web view has the coordinator
        // all the same (CraftHybrid.configure).
        if config.enableGeolocation {
            values.append("geolocation")
            if CraftZigRuntime.supportsRecordingOwnership { values.append("locationRecordingOwnership") }
            if CraftZigRuntime.supportsRecordingIntentIdentity { values.append("locationRecordingIntentIdentity") }
        }
        // The Music app's song and transport are the coordinator's too.
        if config.enableAppleMusic { values.append("music") }
        // `craft.background.complete(ok, id)`: the answer to a silent push or
        // a background refresh, which the app script (`nativeApp`) hears.
        if config.backgroundRefresh?.enabled == true || config.enablePushNotifications { values.append("background") }
        // A heart-rate strap is the app's own service (CraftHeartRate.swift),
        // so it needs no web view.
        if config.enableHeartRate { values.append(contentsOf: ["heartRate", "heartRateRecordingOwnership", "heartRateRecordingIntentIdentity"]) }
        if config.enableBluetooth { values.append("bluetooth") }
        // Workouts on the paired Apple Watch (CraftScheduledWorkouts.swift),
        // also the app's own service.
        if config.enableScheduledWorkouts { values.append("scheduledWorkouts") }
        // Photos picked from the library, files downloaded for the share
        // sheet and sent in a form (CraftNativeFiles.swift): the photo picker
        // runs out of process and asks no permission. Taking a photo needs
        // the camera, which the app declares.
        values.append("files")
        // Video and audio kept on the phone for offline (CraftNativeMedia),
        // which the native Video element plays in place of the address.
        values.append("media")
        if config.enableCamera { values.append("camera") }
        if config.enableAudioRecording { values.append("audioRecording") }
        // craft.crashReporter: the app's crash and error reporter (bughq).
        if config.crashReporting?.key.isEmpty == false { values.append("crashReporter") }
        return values
    }

    /// Nil means this small shared router does not own the action.
    static func perform(action: String, body: [String: Any], config: CraftConfig) -> Result<Any, CraftNativeActionError>? {
        switch action {
        case "cryptoRandomUUID":
            return .success(UUID().uuidString.lowercased())
        case "getDeviceInfo":
            return .success(deviceInfo())
        case "haptic":
            guard config.enableHaptics else { return failure("CAPABILITY_DISABLED", "Haptics is disabled") }
            triggerHaptic(style: body["style"] as? String ?? "medium")
            return .success(true)
        case "hapticPrepare":
            guard config.enableHaptics else { return failure("CAPABILITY_DISABLED", "Haptics is disabled") }
            CraftHaptics.prepare(body["kind"] as? String)
            return .success(true)
        case "clipboardWrite":
            guard config.enableClipboard else { return failure("CAPABILITY_DISABLED", "Clipboard is disabled") }
            guard let text = body["text"] as? String else {
                return failure("INVALID_ARGUMENT", "clipboardWrite was called without the values it needs")
            }
            UIPasteboard.general.string = text
            return .success(true)
        case "clipboardRead":
            guard config.enableClipboard else { return failure("CAPABILITY_DISABLED", "Clipboard is disabled") }
            return .success(UIPasteboard.general.string ?? "")
        // Crash reporting (CraftCrashReporter.swift): on when the config names
        // a bughq key. Each answers at once; delivery is the outbox's job.
        case "crashReporterCapture":
            guard CraftCrashReporter.shared.enabled else { return failure("CAPABILITY_DISABLED", "Crash reporting is not configured") }
            guard let event = body["event"] as? [String: Any] else {
                return failure("INVALID_ARGUMENT", "crashReporterCapture was called without the values it needs")
            }
            CraftCrashReporter.shared.capture(event)
            return .success(true)
        case "crashReporterSetUser":
            guard CraftCrashReporter.shared.enabled else { return failure("CAPABILITY_DISABLED", "Crash reporting is not configured") }
            CraftCrashReporter.shared.setUser(body["id"] as? String)
            return .success(true)
        case "crashReporterAddBreadcrumb":
            guard CraftCrashReporter.shared.enabled else { return failure("CAPABILITY_DISABLED", "Crash reporting is not configured") }
            guard let crumb = body["breadcrumb"] as? [String: Any] else {
                return failure("INVALID_ARGUMENT", "crashReporterAddBreadcrumb was called without the values it needs")
            }
            CraftCrashReporter.shared.addBreadcrumb(crumb)
            return .success(true)
        case "crashReporterFlush":
            guard CraftCrashReporter.shared.enabled else { return failure("CAPABILITY_DISABLED", "Crash reporting is not configured") }
            CraftCrashReporter.shared.requestFlush()
            return .success(true)
        case "crashReporterContext":
            return .success(CraftCrashReporter.shared.context())
        default:
            return nil
        }
    }

    static func perform(
        requestToken: String,
        version: Int,
        module: String,
        method: String,
        args: [Any],
        config: CraftConfig,
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        cancellationLock.lock()
        cancelledRequests.remove(requestToken)
        cancellationLock.unlock()
        guard version == craftNativeCapabilityProtocolVersion else {
            complete(requestToken, failure("UNSUPPORTED_VERSION", "Unsupported native capability protocol version"), completion)
            return
        }

        let sync: Result<Any, CraftNativeActionError>?
        switch (module, method) {
        case ("Crypto", "randomUUID"):
            sync = .success(UUID().uuidString.lowercased())
        case ("Device", "getInfo"):
            sync = perform(action: "getDeviceInfo", body: [:], config: config)
        case ("CrashReporter", "capture"):
            sync = perform(action: "crashReporterCapture", body: ["event": args.first ?? NSNull()], config: config)
        case ("CrashReporter", "setUser"):
            sync = perform(action: "crashReporterSetUser", body: ["id": args.first ?? NSNull()], config: config)
        case ("CrashReporter", "addBreadcrumb"):
            sync = perform(action: "crashReporterAddBreadcrumb", body: ["breadcrumb": args.first ?? NSNull()], config: config)
        case ("CrashReporter", "flush"):
            sync = perform(action: "crashReporterFlush", body: [:], config: config)
        case ("CrashReporter", "context"):
            sync = perform(action: "crashReporterContext", body: [:], config: config)
        case ("Haptics", "impact"):
            sync = perform(action: "haptic", body: ["style": args.first ?? NSNull()], config: config)
        case ("Haptics", "notification"):
            sync = perform(action: "haptic", body: ["style": (args.first as? String) ?? "success"], config: config)
        case ("Haptics", "selection"):
            sync = perform(action: "haptic", body: ["style": "selection"], config: config)
        case ("Haptics", "prepare"):
            sync = perform(action: "hapticPrepare", body: ["kind": args.first ?? NSNull()], config: config)
        case ("Clipboard", "write"):
            sync = perform(action: "clipboardWrite", body: ["text": args.first ?? NSNull()], config: config)
        case ("Clipboard", "read"):
            sync = perform(action: "clipboardRead", body: [:], config: config)
        case ("Storage", _):
            DispatchQueue.main.async {
                cancellationLock.lock()
                let cancelled = cancelledRequests.remove(requestToken) != nil
                cancellationLock.unlock()
                guard !cancelled else { return }
                complete(requestToken, storage(method: method, args: args), completion)
            }
            return
        case ("Shortcuts", _):
            // UIKit quick actions belong to the app, not the calling route.
            // A queued call from a disposed screen must not change that menu.
            DispatchQueue.main.async {
                cancellationLock.lock()
                let cancelled = cancelledRequests.remove(requestToken) != nil
                cancellationLock.unlock()
                guard !cancelled else { return }
                complete(requestToken, shortcuts(method: method, args: args), completion)
            }
            return
        case ("SecureStorage", _):
            guard config.enableSecureStorage else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Secure storage is disabled"), completion)
                return
            }
            let write = { () -> Result<Any, CraftNativeActionError> in
                let result = secureStorage(method: method, args: args)
                // A key the web page shares (`shareStorage`): the page gets it too,
                // so a sign-in on a native screen signs the page in.
                if case .success = result, ["set", "remove", "delete"].contains(method), let key = args.first as? String {
                    CraftHybrid.shared.nativeWroteShared(nativeKey: key, value: method == "set" ? args.count > 1 ? args[1] as? String : nil : nil)
                }
                return result
            }
            // A write that moves the sign-in token is the account's change:
            // every screen hears it (CraftSession). Reads skip the check.
            // Off the main thread, in order (CraftKeychain.queue).
            let isWrite = ["set", "remove", "delete", "clear"].contains(method)
            CraftKeychain.queue.async {
                let result = isWrite ? CraftSession.observe(key: method == "clear" ? nil : args.first as? String, config: config, write) : write()
                complete(requestToken, result, completion)
            }
            return
        case ("Biometrics", "isAvailable"):
            sync = config.enableBiometric ? .success(biometricContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)) : failure("CAPABILITY_DISABLED", "Biometric authentication is disabled")
        case ("Biometrics", "getBiometricType"):
            sync = config.enableBiometric ? .success(biometricType()) : failure("CAPABILITY_DISABLED", "Biometric authentication is disabled")
        case ("Biometrics", "authenticate"):
            guard config.enableBiometric else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Biometric authentication is disabled"), completion)
                return
            }
            authenticate(requestToken: requestToken, args: args, completion: completion)
            return
        case ("Network", "getStatus"):
            CraftWebServices.perform(action: "getNetworkStatus", body: [:]) { complete(requestToken, $0, completion) }
            return
        case ("Network", "fetch"):
            fetch(requestToken: requestToken, args: args, completion: completion)
            return
        case ("Files", "pickImage"):
            // A person picks, so the bridge never times it out.
            let options = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                CraftNativeFiles.pickImage(options, cameraEnabled: config.enableCamera) { completeFile(requestToken, $0, completion) }
            }
            return
        case ("Files", "pickVideo"):
            let options = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                CraftNativeFiles.pickVideo(options) { completeFile(requestToken, $0, completion) }
            }
            return
        case ("Files", "pickFile"):
            let options = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                CraftNativeFiles.pickFile(options) { completeFile(requestToken, $0, completion) }
            }
            return
        case ("Files", "download"):
            download(requestToken: requestToken, args: args, completion: completion)
            return
        case ("Files", "write"):
            // Something the screen made (a CSV export) as a file for the
            // share sheet; the disk work is off the main thread.
            let name = args.first as? String ?? ""
            let data = args.count > 1 ? args[1] : nil
            let options = args.count > 2 ? args[2] as? [String: Any] ?? [:] : [:]
            DispatchQueue.global(qos: .userInitiated).async {
                completeFile(requestToken, CraftNativeFiles.write(name: name, data: data, options: options), completion)
            }
            return
        case ("Files", "remove"):
            sync = .success(CraftNativeFiles.remove(args.first as? String ?? ""))
        case ("Media", "keep"):
            keepMedia(requestToken: requestToken, args: args, completion: completion)
            return
        case ("Media", "path"):
            sync = .success(CraftNativeMedia.local(args.first as? String ?? "")?.path ?? NSNull())
        case ("Media", "prune"):
            let keep = (args.first as? [Any] ?? []).compactMap { $0 as? String }
            DispatchQueue.global(qos: .utility).async {
                complete(requestToken, .success(CraftNativeMedia.prune(keep: keep)), completion)
            }
            return
        case ("Media", "usage"):
            sync = .success(CraftNativeMedia.usage())
        case ("Media", "clear"):
            DispatchQueue.global(qos: .utility).async {
                do { complete(requestToken, .success(try CraftNativeMedia.clear()), completion) }
                catch { complete(requestToken, failure("IO_ERROR", "The video cache could not be cleared"), completion) }
            }
            return
        case ("Lifecycle", "getState"):
            sync = .success(currentAppState())
        case ("DeepLinks", "getInitialURL"):
            if config.enableDeepLinks {
                DeepLinkManager.shared.resolveInitialURL { url in
                    complete(requestToken, .success(claimInitialDeepLink(url).map(deepLinkData) ?? NSNull()), completion)
                }
                return
            } else {
                sync = failure("CAPABILITY_DISABLED", "Deep links are disabled")
            }
        case ("Database", _):
            guard config.enableLocalDatabase else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Local database is disabled"), completion)
                return
            }
            databaseQueue.async { complete(requestToken, database(method: method, args: args), completion) }
            return
        case ("Browser", "open"):
            // SFSafariViewController, or for `mode: 'auth'` the system's web
            // sign-in sheet, the same as a page's `craft.browser.open`.
            guard let address = args.first as? String, let url = URL(string: address) else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Browser.open needs a URL it can parse"), completion)
                return
            }
            let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            DispatchQueue.main.async {
                CraftBrowser.shared.open(url, mode: options["mode"] as? String ?? "safari", callbackScheme: options["callbackScheme"] as? String, from: nil) { answer in
                    complete(requestToken, .success(answer), completion)
                }
            }
            return
        case ("Auth", "signInWithApple"):
            guard config.enableSocialAuth else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Social sign-in is disabled"), completion)
                return
            }
            let options = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                CraftSignInWithApple.shared.signIn(nonce: options["nonce"] as? String) { result in
                    complete(requestToken, result.mapError { CraftNativeActionError(code: $0.code, message: $0.message) }.map { $0 as Any }, completion)
                }
            }
            return
        case ("Passkeys", "isAvailable"):
            sync = .success(CraftNativePasskeys.isAvailable(config: config))
        case ("Passkeys", "create"), ("Passkeys", "get"):
            guard config.enablePasskeys else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Passkeys are disabled"), completion)
                return
            }
            DispatchQueue.main.async {
                CraftNativePasskeys.shared.perform(
                    requestToken: requestToken,
                    method: method,
                    options: args.first as? [String: Any] ?? [:],
                    config: config,
                    completion: completion
                )
            }
            return
        case ("Dialog", _):
            // The system's own alert, confirmation and action sheet, the same
            // ones a page gets (CraftNativeUI.swift), over the native screen.
            let body = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                switch method {
                case "alert":
                    CraftDialogs.alert(body, from: nil) { complete(requestToken, .success(NSNull()), completion) }
                case "confirm":
                    CraftDialogs.confirm(body, from: nil) { complete(requestToken, .success($0), completion) }
                case "actionSheet":
                    CraftDialogs.actionSheet(body, from: nil) { complete(requestToken, .success($0 ?? NSNull()), completion) }
                default:
                    complete(requestToken, failure("UNKNOWN_ACTION", "Unsupported Dialog method"), completion)
                }
            }
            return
        case ("LiveActivities", _):
            CraftLiveActivities.perform(method: method, args: args, enabled: config.enableLiveActivities, appName: config.appName, healthEnabled: config.enableHealthKit) { result in
                complete(requestToken, result, completion)
            }
            return
        case ("Health", _):
            // Apple Health, the same as a page's `craft.health` (CraftHealth.swift).
            guard config.enableHealthKit else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "HealthKit is disabled"), completion)
                return
            }
            CraftHealth.shared.perform(method: method, args: args) { result in
                complete(requestToken, result.mapError { CraftNativeActionError(code: $0.code, message: $0.message) }, completion)
            }
            return
        case ("Wallet", "isAvailable"):
            sync = config.enableWallet ? .success(PKPassLibrary.isPassLibraryAvailable()) : failure("CAPABILITY_DISABLED", "Wallet is disabled")
        case ("Wallet", "has"):
            guard config.enableWallet else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Wallet is disabled"), completion)
                return
            }
            guard let serialNumber = args.first as? String, !serialNumber.isEmpty else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Wallet.has needs a serial number"), completion)
                return
            }
            sync = .success(PKPassLibrary().passes().contains { $0.serialNumber == serialNumber })
        case ("Wallet", "add"):
            guard config.enableWallet else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Wallet is disabled"), completion)
                return
            }
            let options = args.first as? [String: Any] ?? [:]
            if let encoded = options["data"] as? String {
                guard let data = Data(base64Encoded: encoded), let pass = try? PKPass(data: data) else {
                    complete(requestToken, failure("INVALID_ARGUMENT", "Wallet.add needs a valid base64 pkpass"), completion)
                    return
                }
                presentWalletPass(pass, requestToken: requestToken, completion: completion)
                return
            }
            guard let address = options["url"] as? String, let url = URL(string: address), url.scheme == "https" else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Wallet.add needs base64 data or an https URL"), completion)
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, error in
                guard let data, error == nil, let pass = try? PKPass(data: data) else {
                    complete(requestToken, failure("WALLET_PASS_INVALID", "The Wallet pass could not be downloaded or parsed"), completion)
                    return
                }
                DispatchQueue.main.async { self.presentWalletPass(pass, requestToken: requestToken, completion: completion) }
            }.resume()
            return
        case ("KeepAwake", "set"):
            guard config.enableKeepAwake else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Keep awake is disabled"), completion)
                return
            }
            let enabled = args.first as? Bool ?? true
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = enabled
                complete(requestToken, .success(enabled), completion)
            }
            return
        case ("Brightness", "get"):
            DispatchQueue.main.async { complete(requestToken, .success(Double(UIScreen.main.brightness)), completion) }
            return
        case ("Brightness", "set"):
            // The device's backlight, system-wide: a screen that dims it reads
            // it first and puts it back, as @stacksjs/mobile's brightness does.
            guard let level = craftNativeNumber(args.first)?.doubleValue, level.isFinite else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Brightness.set needs a level from 0 to 1"), completion)
                return
            }
            DispatchQueue.main.async {
                UIScreen.main.brightness = CGFloat(min(max(level, 0), 1))
                complete(requestToken, .success(Double(UIScreen.main.brightness)), completion)
            }
            return
        case ("StatusBar", "setStyle"):
            let style = args.first as? String ?? "default"
            DispatchQueue.main.async {
                complete(requestToken, .success(CraftStatusBar.setStyle(style == "light" || style == "dark" ? style : "default")), completion)
            }
            return
        case ("Location", _):
            // The page's own GPS and route recorder, in the web view's
            // coordinator: one recorder, which keeps recording in the
            // background and survives a relaunch, whichever side started it.
            guard config.enableGeolocation else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Geolocation is disabled"), completion)
                return
            }
            let actions = [
                "getCurrentPosition": "getCurrentPosition", "watchPosition": "watchPosition", "clearWatch": "clearWatch",
                "startRecording": "startLocationRecording", "pauseRecording": "pauseLocationRecording",
                "resumeRecording": "resumeLocationRecording", "stopRecording": "stopLocationRecording",
                "getRecordingState": "getLocationRecordingState", "readRecording": "readLocationRecording",
                "acknowledgeRecording": "acknowledgeLocationRecording",
            ]
            guard let action = actions[method] else {
                complete(requestToken, failure("UNKNOWN_ACTION", "Unsupported Location method"), completion)
                return
            }
            CraftWebServices.perform(action: action, body: args.first as? [String: Any] ?? [:]) { complete(requestToken, $0, completion) }
            return
        case ("Music", _):
            // The page's own Music app bridge (CraftMusic.swift), in the web
            // view's coordinator: one observer, whose changes reach the page
            // and every native screen as `craftMusicChange`.
            guard config.enableAppleMusic else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Apple Music is disabled"), completion)
                return
            }
            let actions = [
                "getAuthorizationStatus": "musicGetAuthorization", "requestAuthorization": "musicRequestAuthorization",
                "getNowPlaying": "musicGetNowPlaying", "control": "musicControl", "observe": "musicObserve",
            ]
            guard let action = actions[method] else {
                complete(requestToken, failure("UNKNOWN_ACTION", "Unsupported Music method"), completion)
                return
            }
            CraftWebServices.perform(action: action, body: args.first as? [String: Any] ?? [:]) { complete(requestToken, $0, completion) }
            return
        case ("Bluetooth", _):
            guard config.enableBluetooth else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Bluetooth is disabled"), completion)
                return
            }
            CraftBluetooth.shared.perform(method: method, args: args) { result in
                complete(requestToken, result.mapError { CraftNativeActionError(code: $0.code, message: $0.message) }, completion)
            }
            return
        case ("HeartRate", _):
            // A Bluetooth heart-rate strap, the same service as a page's
            // `craft.heartRate`: one connection and one recording, whichever
            // side started them. Its events reach every screen as
            // `craftHeartRate`.
            guard config.enableHeartRate else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Heart rate is disabled"), completion)
                return
            }
            CraftHeartRate.shared.perform(method: method, args: args) { result in
                complete(requestToken, result.mapError { CraftNativeActionError(code: $0.code, message: $0.message) }, completion)
            }
            return
        case ("ScheduledWorkouts", _):
            // Workouts on the paired Apple Watch, the same service as a
            // page's `craft.scheduledWorkouts` (WorkoutKit's scheduler).
            guard config.enableScheduledWorkouts else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Scheduled workouts are disabled"), completion)
                return
            }
            CraftScheduledWorkouts.shared.perform(method: method, args: args) { result in
                complete(requestToken, result.mapError { CraftNativeActionError(code: $0.code, message: $0.message) }, completion)
            }
            return
        case ("Linking", "openURL"), ("Linking", "canOpenURL"):
            // Another app or the system: `webcal:` subscriptions, `mailto:`,
            // `tel:`, the App Store, this app's page in Settings
            // (`UIApplication.openSettingsURLString`, which is `app-settings:`).
            guard let address = args.first as? String, let url = URL(string: address), url.scheme != nil else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Linking.\(method) needs a URL it can parse"), completion)
                return
            }
            DispatchQueue.main.async {
                if method == "canOpenURL" {
                    complete(requestToken, .success(UIApplication.shared.canOpenURL(url)), completion)
                } else {
                    UIApplication.shared.open(url) { complete(requestToken, .success($0), completion) }
                }
            }
            return
        case ("Share", "share"):
            guard config.enableShare else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Sharing is disabled"), completion)
                return
            }
            let options = args.first as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                CraftNativeShare.share(options) { complete(requestToken, $0, completion) }
            }
            return
        case ("AudioRecording", _):
            guard config.enableAudioRecording else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Audio recording is disabled"), completion)
                return
            }
            CraftVoiceRecording.shared.perform(method: method, args: args) { result in complete(requestToken, result, completion) }
            return
        case ("Speech", "speak"):
            // Settles when the words have been said (true) or were cut off
            // (false), as the page's `craft.speech.speak` does.
            guard let text = args.first as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                complete(requestToken, failure("INVALID_ARGUMENT", "speech.speak needs some text to say"), completion)
                return
            }
            let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            DispatchQueue.main.async {
                CraftNativeSpeech.shared.speak(
                    text,
                    language: options["language"] as? String,
                    rate: craftNativeNumber(options["rate"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil },
                    pitch: craftNativeNumber(options["pitch"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil },
                    preDelay: craftNativeNumber(options["preDelay"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil },
                    interrupt: options["interrupt"] as? Bool ?? true
                ) { spoken in complete(requestToken, .success(spoken), completion) }
            }
            return
        case ("Speech", "stop"):
            DispatchQueue.main.async {
                CraftNativeSpeech.shared.stop()
                complete(requestToken, .success(true), completion)
            }
            return
        case ("Push", _):
            guard config.enablePushNotifications else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Push notifications are disabled"), completion)
                return
            }
            switch method {
            case "getPermissionStatus":
                CraftNativePush.status { complete(requestToken, .success($0), completion) }
            case "requestPermission":
                CraftNativePush.requestPermission { complete(requestToken, .success($0), completion) }
            case "register":
                CraftNativePush.register { complete(requestToken, $0, completion) }
            case "openSettings":
                DispatchQueue.main.async {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        complete(requestToken, .success(false), completion)
                        return
                    }
                    UIApplication.shared.open(url) { complete(requestToken, .success($0), completion) }
                }
            default:
                complete(requestToken, failure("UNKNOWN_ACTION", "Unsupported Push method"), completion)
            }
            return
        case ("Background", "complete"):
            // The app script's answer to `craftSilentPush` or
            // `craftBackgroundRefresh`: args `[ok, id?]`, with no id for
            // everything still pending, as a page's `craft.background.complete`.
            guard config.backgroundRefresh?.enabled == true || config.enablePushNotifications else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Background work is disabled"), completion)
                return
            }
            let ok = args.first as? Bool ?? true
            let id = args.count > 1 ? args[1] as? String : nil
            DispatchQueue.main.async {
                CraftBackgroundWork.shared.complete(id: id, ok: ok)
                complete(requestToken, .success(true), completion)
            }
            return
        case ("Badge", "set"):
            guard let value = craftNativeNumber(args.first),
                  value.doubleValue.isFinite,
                  value.doubleValue >= 0,
                  value.doubleValue.rounded() == value.doubleValue else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Badge.set needs a non-negative whole number"), completion)
                return
            }
            setBadgeCount(value.intValue) { complete(requestToken, $0, completion) }
            return
        case ("Badge", "clear"):
            setBadgeCount(0) { complete(requestToken, $0, completion) }
            return
        case ("Notifications", _):
            guard config.enableLocalNotifications else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Local notifications are disabled"), completion)
                return
            }
            notifications(requestToken: requestToken, method: method, args: args, completion: completion)
            return
        default:
            sync = failure("UNKNOWN_ACTION", "Unsupported native API")
        }
        complete(requestToken, sync ?? failure("UNKNOWN_ACTION", "Unsupported native API"), completion)
    }

    private static var walletPresenters: [String: CraftWalletPresenter] = [:]

    private static func presentWalletPass(
        _ pass: PKPass,
        requestToken: String,
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        DispatchQueue.main.async {
            let presenter = CraftWalletPresenter { result in
                walletPresenters.removeValue(forKey: requestToken)
                completion(result)
            }
            guard let controller = PKAddPassesViewController(pass: pass), CraftPresenter.present(controller, from: nil) else {
                completion(failure("PRESENTATION_FAILED", "Wallet could not present its add-pass sheet"))
                return
            }
            controller.delegate = presenter
            walletPresenters[requestToken] = presenter
        }
    }

    static func cancel(requestToken: String) {
        cancellationLock.lock()
        cancelledRequests.insert(requestToken)
        let context = biometricContexts.removeValue(forKey: requestToken)
        let task = fetchTasks.removeValue(forKey: requestToken)
        cancellationLock.unlock()
        context?.invalidate()
        task?.cancel()
        CraftNativePasskeys.shared.cancel(requestToken: requestToken)
    }

    /// `fetch` for native screens: one URLSession data task per request, keyed
    /// by the request token so the bridge deadline, `API_CANCEL` and route
    /// teardown all cancel the transfer. Bodies are UTF-8 text both ways.
    private static func fetch(
        requestToken: String,
        args: [Any],
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        guard let options = args.first as? [String: Any],
              let address = options["url"] as? String,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            complete(requestToken, failure("INVALID_ARGUMENT", "fetch needs an absolute http or https URL"), completion)
            return
        }
        let method = ((options["method"] as? String) ?? "GET").uppercased()
        guard !method.isEmpty, method.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            complete(requestToken, failure("INVALID_ARGUMENT", "fetch method must be an HTTP token"), completion)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: craftNativeFetchTimeoutSeconds)
        request.httpMethod = method
        if let headers = options["headers"] as? [String: Any] {
            for (name, value) in headers {
                guard let value = value as? String else {
                    complete(requestToken, failure("INVALID_ARGUMENT", "fetch header values must be strings"), completion)
                    return
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        var uploadFile: URL?
        if let form = options["form"] as? [Any] {
            // A screen's FormData: text fields, and files craft.files made.
            guard method != "GET", method != "HEAD" else {
                complete(requestToken, failure("INVALID_ARGUMENT", "A GET or HEAD request cannot have a body"), completion)
                return
            }
            switch CraftNativeFiles.multipart(form) {
            case .failure(let error):
                complete(requestToken, .failure(error), completion)
                return
            case .success(let (file, boundary)):
                uploadFile = file
                request.timeoutInterval = 600
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = options["body"] as? String {
            guard method != "GET", method != "HEAD" else {
                complete(requestToken, failure("INVALID_ARGUMENT", "A GET or HEAD request cannot have a body"), completion)
                return
            }
            request.httpBody = Data(body.utf8)
        } else if let body = options["body"], !(body is NSNull) {
            complete(requestToken, failure("INVALID_ARGUMENT", "fetch body must be a string"), completion)
            return
        }

        let responseHandler: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            if let uploadFile { CraftNativeFiles.remove(uploadFile.path) }
            cancellationLock.lock()
            fetchTasks.removeValue(forKey: requestToken)
            cancellationLock.unlock()
            if let error = error {
                let code = (error as? URLError)?.code == .timedOut ? "TIMEOUT" : "NETWORK_ERROR"
                if (error as? URLError)?.code != .cancelled {
                    CraftCrashReporter.shared.requestFailed(method: method, url: url, status: nil, error: code)
                }
                complete(requestToken, failure(code, error.localizedDescription), completion)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                CraftCrashReporter.shared.requestFailed(method: method, url: url, status: http.statusCode, error: nil)
            }
            guard let http = response as? HTTPURLResponse else {
                complete(requestToken, failure("NETWORK_ERROR", "fetch received a response that is not HTTP"), completion)
                return
            }
            let body = data ?? Data()
            guard body.count <= craftNativeFetchMaxResponseBytes else {
                complete(requestToken, failure("RESPONSE_TOO_LARGE", "fetch responses are limited to \(craftNativeFetchMaxResponseBytes) bytes"), completion)
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                headers[String(describing: name).lowercased()] = String(describing: value)
            }
            complete(requestToken, .success([
                "url": http.url?.absoluteString ?? address,
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "headers": headers,
                "redirected": http.url.map { $0 != url } ?? false,
                "body": String(decoding: body, as: UTF8.self),
            ]), completion)
        }
        let task: URLSessionTask = uploadFile.map { fetchSession.uploadTask(with: request, fromFile: $0, completionHandler: responseHandler) }
            ?? fetchSession.dataTask(with: request, completionHandler: responseHandler)
        cancellationLock.lock()
        let alreadyCancelled = cancelledRequests.contains(requestToken)
        if !alreadyCancelled { fetchTasks[requestToken] = task }
        cancellationLock.unlock()
        if !alreadyCancelled { task.resume() }
        else if let uploadFile { CraftNativeFiles.remove(uploadFile.path) }
    }

    /// `craft.files.download`: a GET straight to a file made here (for the
    /// share sheet), with the screen's headers, so a large file never passes
    /// through JavaScriptCore. A refused answer (not 2xx) keeps no file and
    /// hands back its status and the start of its body. Cancelled like fetch.
    private static func download(
        requestToken: String,
        args: [Any],
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        guard let address = args.first as? String,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            complete(requestToken, failure("INVALID_ARGUMENT", "files.download needs an absolute http or https URL"), completion)
            return
        }
        let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
        var request = URLRequest(url: url, timeoutInterval: craftNativeFetchTimeoutSeconds)
        request.httpMethod = "GET"
        if let headers = options["headers"] as? [String: Any] {
            for (name, value) in headers {
                guard let value = value as? String else {
                    complete(requestToken, failure("INVALID_ARGUMENT", "files.download header values must be strings"), completion)
                    return
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let name = options["name"] as? String
        let task = fetchSession.downloadTask(with: request) { location, response, error in
            cancellationLock.lock()
            fetchTasks.removeValue(forKey: requestToken)
            cancellationLock.unlock()
            if let error = error {
                let code = (error as? URLError)?.code == .timedOut ? "TIMEOUT" : "NETWORK_ERROR"
                complete(requestToken, failure(code, error.localizedDescription), completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                complete(requestToken, failure("NETWORK_ERROR", "files.download received a response that is not HTTP"), completion)
                return
            }
            // The system deletes `location` once this returns: keep or read it now.
            guard (200..<300).contains(http.statusCode), let location else {
                complete(requestToken, .success(CraftNativeFiles.refusedDownload(at: location, response: http)), completion)
                return
            }
            completeFile(requestToken, CraftNativeFiles.keepDownload(at: location, response: http, name: name), completion)
        }
        cancellationLock.lock()
        let alreadyCancelled = cancelledRequests.contains(requestToken)
        if !alreadyCancelled { fetchTasks[requestToken] = task }
        cancellationLock.unlock()
        if !alreadyCancelled { task.resume() }
    }

    /// `craft.media.keep`: the file at an address kept on the phone for
    /// offline, fetched once (a copy already there answers at once, and two
    /// screens asking at the same time share one download). A refused answer
    /// (not 2xx) keeps nothing and says its status. Cancelled like fetch.
    ///
    /// `cellular: false` keeps it off a metered connection (cellular, a
    /// personal hotspot, Low Data Mode). The download runs on a background
    /// session (CraftNativeMediaTransfers), so it carries on while the app is
    /// suspended or closed. When the phone cannot fetch it now (no
    /// connection, or only a metered one for a Wi-Fi-only keep) the answer is
    /// `{ ok: false, reason: "offline" | "cellular", queued: true }` straight
    /// away, so the screen can say it is waiting rather than failing, and the
    /// transfer finishes with iOS when it can. A copy already kept still
    /// answers, whatever the connection.
    private static func keepMedia(
        requestToken: String,
        args: [Any],
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        guard let address = args.first as? String,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            complete(requestToken, failure("INVALID_ARGUMENT", "media.keep needs an absolute http or https URL"), completion)
            return
        }
        if let kept = CraftNativeMedia.local(address) {
            complete(requestToken, .success(CraftNativeMedia.describe(address, kept)), completion)
            return
        }
        let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
        var request = URLRequest(url: url, timeoutInterval: craftNativeFetchTimeoutSeconds)
        request.httpMethod = "GET"
        if let headers = options["headers"] as? [String: Any] {
            for (name, value) in headers {
                guard let value = value as? String else {
                    complete(requestToken, failure("INVALID_ARGUMENT", "media.keep header values must be strings"), completion)
                    return
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let wifiOnly = options["cellular"] as? Bool == false
        if wifiOnly {
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        let answer: (Result<Any, CraftNativeActionError>) -> Void = { result in
            cancellationLock.lock()
            fetchTasks.removeValue(forKey: requestToken)
            cancellationLock.unlock()
            complete(requestToken, result, completion)
        }
        guard let flight = CraftNativeMedia.begin(address, answer) else { return }
        cancellationLock.lock()
        let alreadyCancelled = cancelledRequests.contains(requestToken)
        cancellationLock.unlock()
        if alreadyCancelled {
            CraftNativeMedia.finish(address, flight: flight, failure("CANCELLED", "media.keep was cancelled"))
            return
        }
        // On the app's background session (CraftNativeMediaTransfers): it
        // carries on while the app is suspended, and a keep the phone cannot
        // fetch now is answered at once while its transfer waits with iOS.
        let task = CraftNativeMediaTransfers.shared.start(request, address: address, flight: flight, wifiOnly: wifiOnly)
        cancellationLock.lock()
        // Unless it answered already (a queued transfer, or an instant failure).
        if CraftNativeMedia.isWaiting(address, flight: flight) { fetchTasks[requestToken] = task }
        cancellationLock.unlock()
    }

    private static func claimInitialDeepLink(_ url: URL?) -> URL? {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        guard !initialDeepLinkClaimed else { return nil }
        initialDeepLinkClaimed = true
        return url
    }

    /// Delivery boundary for newly owned files from pickers, writes and downloads.
    static func completeFile(
        _ requestToken: String,
        _ result: Result<Any, CraftNativeActionError>,
        _ completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        complete(requestToken, result, completion, onCancel: {
            // A cancelled caller never receives these descriptors and cannot
            // remove them itself. Only discard newly created, app-owned files;
            // persistent media-cache results use the ordinary completion path.
            guard case .success(let value) = result else { return }
            let files = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            for file in files {
                if let path = file["path"] as? String { CraftNativeFiles.remove(path) }
            }
        })
    }

    private static func complete(
        _ requestToken: String,
        _ result: Result<Any, CraftNativeActionError>,
        _ completion: @escaping (Result<Any, CraftNativeActionError>) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            cancellationLock.lock()
            let cancelled = cancelledRequests.remove(requestToken) != nil
            cancellationLock.unlock()
            if cancelled { onCancel?() }
            else { completion(result) }
        }
    }

    private static func shortcuts(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        if method == "clear" {
            guard args.isEmpty else { return failure("INVALID_ARGUMENT", "Shortcuts.clear takes no arguments") }
            UIApplication.shared.shortcutItems = nil
            return .success(true)
        }
        guard method == "set" else { return failure("UNSUPPORTED_METHOD", "Unknown Shortcuts method") }
        guard args.count == 1, let items = args.first as? [[String: Any]], items.count <= 4 else {
            return failure("INVALID_ARGUMENT", "Shortcuts.set needs a list of at most four shortcuts")
        }
        var types = Set<String>()
        var shortcuts: [UIApplicationShortcutItem] = []
        for item in items {
            guard let type = item["type"] as? String, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  types.insert(type).inserted else {
                return failure("INVALID_ARGUMENT", "Every shortcut needs a unique type and a non-empty title")
            }
            for name in ["subtitle", "iconName"] where item[name] != nil {
                guard item[name] is String else { return failure("INVALID_ARGUMENT", "Shortcut \(name) must be a string") }
            }
            var userInfo: [String: NSSecureCoding]?
            if let raw = item["userInfo"] {
                guard let info = raw as? [String: Any], PropertyListSerialization.propertyList(info, isValidFor: .binary),
                      let secure = info as? [String: NSSecureCoding] else {
                    return failure("INVALID_ARGUMENT", "Shortcut userInfo must contain property-list values")
                }
                userInfo = secure
            }
            shortcuts.append(UIApplicationShortcutItem(type: type, localizedTitle: title,
                localizedSubtitle: item["subtitle"] as? String,
                icon: (item["iconName"] as? String).map { UIApplicationShortcutIcon(systemImageName: $0) }, userInfo: userInfo))
        }
        // Validate the whole list before replacing the previously valid menu.
        UIApplication.shared.shortcutItems = shortcuts
        return .success(["count": shortcuts.count])
    }

    private static func storage(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        do {
            if method == "clear" { try CraftPersistentStorage.clear(prefix: storagePrefix); return .success(true) }
            if method == "keys" { return .success(try CraftPersistentStorage.keys(prefix: storagePrefix)) }
            guard let key = validKey(args.first) else { return failure("INVALID_ARGUMENT", "Storage needs a non-empty key") }
            switch method {
            case "get":
                guard let data = try CraftPersistentStorage.get(key, prefix: storagePrefix) else { return .success(NSNull()) }
                return .success(try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
            case "set":
                guard args.count == 2 else { return failure("INVALID_ARGUMENT", "Storage.set needs a key and value") }
                let data = try JSONSerialization.data(withJSONObject: args[1], options: .fragmentsAllowed)
                try CraftPersistentStorage.set(key, data: data, prefix: storagePrefix)
                return .success(true)
            case "compareAndSet":
                guard args.count == 3 else { return failure("INVALID_ARGUMENT", "Storage.compareAndSet needs a key, expected value and next value") }
                return .success(try CraftPersistentStorage.compareAndSet(key, expected: args[1], value: args[2], prefix: storagePrefix))
            case "setIfAbsent":
                guard args.count == 2 else { return failure("INVALID_ARGUMENT", "Storage.setIfAbsent needs a key and value") }
                return .success(try CraftPersistentStorage.setIfAbsent(key, value: args[1], prefix: storagePrefix))
            case "remove":
                try CraftPersistentStorage.set(key, data: nil, prefix: storagePrefix)
                return .success(true)
            default: return failure("UNKNOWN_ACTION", "Unsupported Storage method")
            }
        } catch let error as CraftNativeActionError { return .failure(error) }
        catch { return failure("STORAGE_ERROR", "Storage could not persist or read its value") }
    }

    private static func secureStorage(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        let service = "dev.craft.native.secure"
        if method == "clear" {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            let status = SecItemDelete(query as CFDictionary)
            CraftKeychain.forget(account: nil)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                return failure("SECURE_STORAGE_ERROR", "Secure storage could not be cleared")
            }
            return .success(true)
        }
        guard let key = validKey(args.first) else { return failure("INVALID_ARGUMENT", "Secure storage needs a non-empty key") }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        switch method {
        case "set":
            guard args.count == 2, let value = args[1] as? String else {
                return failure("INVALID_ARGUMENT", "SecureStorage.set needs a key and string value")
            }
            var query = base
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let removed = SecItemDelete(base as CFDictionary)
            CraftKeychain.forget(account: key)
            guard removed == errSecSuccess || removed == errSecItemNotFound else {
                return failure("SECURE_STORAGE_ERROR", "Secure storage could not be replaced (\(removed))")
            }
            let status = SecItemAdd(query as CFDictionary, nil)
            CraftKeychain.forget(account: key)
            return status == errSecSuccess ? .success(true) : failure("SECURE_STORAGE_ERROR", "Secure storage could not be written (\(status))")
        case "get":
            // A failed read is not remembered: it is answered as a failure,
            // and the next read asks the Keychain again.
            var failed = false
            let value = CraftKeychain.value(account: key, service: service) { () -> String? in
                var query = base
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = result as? Data else {
                    failed = true
                    return nil
                }
                return String(decoding: data, as: UTF8.self)
            }
            if failed {
                CraftKeychain.forget(account: key)
                return failure("SECURE_STORAGE_ERROR", "Secure storage could not be read")
            }
            return .success(value.map { $0 as Any } ?? NSNull())
        case "remove":
            let status = SecItemDelete(base as CFDictionary)
            CraftKeychain.forget(account: key)
            return status == errSecSuccess || status == errSecItemNotFound ? .success(true) : failure("SECURE_STORAGE_ERROR", "Secure storage could not be removed")
        default:
            return failure("UNKNOWN_ACTION", "Unsupported SecureStorage method")
        }
    }

    private static func biometricContext() -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        return context
    }

    private static func biometricType() -> String {
        let context = biometricContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceId"
        case .touchID: return "touchId"
        default: return "none"
        }
    }

    private static func authenticate(
        requestToken: String,
        args: [Any],
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        let reason = (args.first as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Authenticate to continue"
        let context = biometricContext()
        cancellationLock.lock()
        biometricContexts[requestToken] = context
        cancellationLock.unlock()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { result, error in
            cancellationLock.lock()
            biometricContexts.removeValue(forKey: requestToken)
            cancellationLock.unlock()
            if result { complete(requestToken, .success(true), completion) }
            else { complete(requestToken, failure("AUTHENTICATION_FAILED", error?.localizedDescription ?? "Biometric authentication failed"), completion) }
        }
    }

    private static func database(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        guard openDatabase() else { return failure("DATABASE_ERROR", "Could not open the local database") }
        switch method {
        case "execute":
            guard let sql = args.first as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure("INVALID_ARGUMENT", "Database.execute needs a SQL statement")
            }
            return execute(sql: sql, params: args.count > 1 ? args[1] as? [Any] ?? [] : [])
        case "query":
            guard let sql = args.first as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure("INVALID_ARGUMENT", "Database.query needs a SQL statement")
            }
            return query(sql: sql, params: args.count > 1 ? args[1] as? [Any] ?? [] : [])
        case "beginTransaction": return transaction(sql: "BEGIN TRANSACTION")
        case "commit": return transaction(sql: "COMMIT")
        case "rollback": return transaction(sql: "ROLLBACK")
        default: return failure("UNKNOWN_ACTION", "Unsupported Database method")
        }
    }

    private static func transaction(sql: String) -> Result<Any, CraftNativeActionError> {
        switch execute(sql: sql, params: []) {
        case .success: return .success(true)
        case .failure(let error): return .failure(error)
        }
    }

    private static func openDatabase() -> Bool {
        if database != nil { return true }
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        let path = directory.appendingPathComponent("craft-native.sqlite").path
        if sqlite3_open(path, &database) != SQLITE_OK {
            if database != nil { sqlite3_close(database) }
            database = nil
            return false
        }
        sqlite3_busy_timeout(database, 5_000)
        return true
    }

    private static func bind(_ params: [Any], to statement: OpaquePointer?) -> Bool {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case is NSNull: code = sqlite3_bind_null(statement, index)
            case let string as String: code = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    code = sqlite3_bind_int64(statement, index, number.boolValue ? 1 : 0)
                } else if number.doubleValue.rounded() == number.doubleValue {
                    code = sqlite3_bind_int64(statement, index, number.int64Value)
                } else {
                    code = sqlite3_bind_double(statement, index, number.doubleValue)
                }
            default: return false
            }
            if code != SQLITE_OK { return false }
        }
        return true
    }

    private static func execute(sql: String, params: [Any]) -> Result<Any, CraftNativeActionError> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return databaseFailure() }
        defer { sqlite3_finalize(statement) }
        guard bind(params, to: statement) else { return failure("INVALID_ARGUMENT", "Database parameters must be strings, numbers, booleans, or null") }
        guard sqlite3_step(statement) == SQLITE_DONE else { return databaseFailure() }
        return .success(["rowsAffected": Int(sqlite3_changes(database)), "lastInsertId": Int(sqlite3_last_insert_rowid(database))])
    }

    private static func query(sql: String, params: [Any]) -> Result<Any, CraftNativeActionError> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return databaseFailure() }
        defer { sqlite3_finalize(statement) }
        guard bind(params, to: statement) else { return failure("INVALID_ARGUMENT", "Database parameters must be strings, numbers, booleans, or null") }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return .success(rows) }
            guard step == SQLITE_ROW else { return databaseFailure() }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    row[name] = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: length).base64EncodedString() } ?? ""
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
    }

    private static func databaseFailure() -> Result<Any, CraftNativeActionError> {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"
        return failure("DATABASE_ERROR", message)
    }

    private static func notifications(
        requestToken: String,
        method: String,
        args: [Any],
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        switch method {
        case "cancel":
            guard let id = validKey(args.first) else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Notifications.cancel needs an id"), completion)
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [id])
            complete(requestToken, .success(true), completion)
        case "cancelAll":
            center.removeAllPendingNotificationRequests()
            complete(requestToken, .success(true), completion)
        case "pending":
            center.getPendingNotificationRequests { requests in
                complete(requestToken, .success(requests.map { request in
                    ["id": request.identifier, "title": request.content.title, "body": request.content.body]
                }), completion)
            }
        case "schedule":
            guard let value = args.first as? [String: Any], let title = value["title"] as? String, !title.isEmpty else {
                complete(requestToken, failure("INVALID_ARGUMENT", "Notifications.schedule needs a title"), completion)
                return
            }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, authorizationError in
                guard authorizationError == nil, granted else {
                    complete(requestToken, failure("PERMISSION_DENIED", authorizationError?.localizedDescription ?? "Notification permission denied"), completion)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = value["body"] as? String ?? ""
                content.sound = .default
                if let data = value["data"] as? [String: Any] { content.userInfo = data }
                if let badge = craftNativeNumber(value["badge"]),
                   badge.doubleValue.isFinite,
                   badge.doubleValue >= 0,
                   badge.doubleValue.rounded() == badge.doubleValue {
                    content.badge = badge
                }
                let id = (value["id"] as? String).flatMap { validKey($0) } ?? UUID().uuidString
                let delay = craftNativeNumber(value["delay"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil }
                let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0 / 1_000, 1), repeats: false) }
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { addError in
                    if let addError = addError {
                        complete(requestToken, failure("NOTIFICATION_ERROR", addError.localizedDescription), completion)
                    } else {
                        complete(requestToken, .success(id), completion)
                    }
                }
            }
        default:
            complete(requestToken, failure("UNKNOWN_ACTION", "Unsupported Notifications method"), completion)
        }
    }

    /// Set the app icon badge without requesting notification authorization.
    /// Native screens use this same permission-free path as the page bridge.
    private static func setBadgeCount(
        _ count: Int,
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(count) { error in
                    DispatchQueue.main.async {
                        if let error {
                            completion(.failure(CraftNativeActionError(code: "NATIVE_CALL_FAILED", message: error.localizedDescription)))
                        } else {
                            completion(.success(true))
                        }
                    }
                }
            } else {
                UIApplication.shared.applicationIconBadgeNumber = count
                completion(.success(true))
            }
        }
    }

    static func deepLinkData(_ url: URL) -> [String: Any] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return [
            "url": url.absoluteString,
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": url.path,
            "query": url.query ?? "",
            "queryParams": Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
        ]
    }

    static func triggerHaptic(style: String) {
        CraftHaptics.play(style)
    }

    static func currentAppState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "inactive"
        }
    }

    private static func validKey(_ value: Any?) -> String? {
        guard let key = value as? String, !key.isEmpty, key.count <= 512, !key.contains("\0") else { return nil }
        return key
    }

    private static func error(_ code: String, _ message: String) -> CraftNativeActionError {
        CraftNativeActionError(code: code, message: message)
    }

    private static func failure(_ code: String, _ message: String) -> Result<Any, CraftNativeActionError> {
        .failure(error(code, message))
    }

    private static func deviceInfo() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        return [
            "platform": "ios",
            "osVersion": device.systemVersion,
            "model": device.model,
            "manufacturer": "Apple",
            "deviceId": device.identifierForVendor?.uuidString ?? "",
            "isTablet": device.userInterfaceIdiom == .pad,
            "screen": ["width": screen.bounds.width, "height": screen.bounds.height, "scale": screen.scale],
            "battery": ["level": device.batteryLevel, "isCharging": device.batteryState == .charging || device.batteryState == .full],
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "isSimulator": isSimulator,
            "name": device.name,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "identifierForVendor": device.identifierForVendor?.uuidString ?? "",
            "screenWidth": screen.bounds.width,
            "screenHeight": screen.bounds.height,
            "screenScale": screen.scale,
            "batteryLevel": device.batteryLevel,
            "batteryState": batteryState,
        ]
    }
}

private final class CraftWalletPresenter: NSObject, PKAddPassesViewControllerDelegate {
    private let completion: (Result<Any, CraftNativeActionError>) -> Void

    init(completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        self.completion = completion
    }

    func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
        controller.dismiss(animated: true) { [completion] in completion(.success(true)) }
    }
}

/// The native WebAuthn half for screens without a browser context. The
/// server still owns challenges and verifies the returned client data; this
/// class only translates WebAuthn options into Apple's passkey sheet and
/// returns the authenticator response as base64url strings.
final class CraftNativePasskeys: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = CraftNativePasskeys()

    private struct Pending {
        let requestToken: String
        let completion: (Result<Any, CraftNativeActionError>) -> Void
    }

    private var pending: [ObjectIdentifier: Pending] = [:]
    private var controllers: [String: ASAuthorizationController] = [:]

    static func domains(in config: CraftConfig) -> Set<String> {
        Set(config.associatedDomains.compactMap { entry in
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.lowercased().hasPrefix("webcredentials:") else { return nil }
            let domain = String(value.dropFirst("webcredentials:".count)).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    static func isAvailable(config: CraftConfig) -> Bool {
        if #available(iOS 15.0, *) {
            return config.enablePasskeys && !domains(in: config).isEmpty
        }
        return false
    }

    func perform(
        requestToken: String,
        method: String,
        options: [String: Any],
        config: CraftConfig,
        completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        guard #available(iOS 15.0, *) else {
            completion(.failure(CraftNativeActionError(code: "UNAVAILABLE", message: "Passkeys require iOS 15 or later")))
            return
        }
        guard Self.isAvailable(config: config) else {
            completion(.failure(CraftNativeActionError(code: "UNAVAILABLE", message: "Passkeys need a matching webcredentials associated domain")))
            return
        }
        guard let relyingParty = relyingPartyID(options: options, config: config),
              let challenge = data(options["challenge"]) else {
            completion(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "Passkeys need a base64url challenge and an associated relying-party id")))
            return
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request: ASAuthorizationRequest
        if method == "create" {
            guard let user = options["user"] as? [String: Any],
                  let name = user["name"] as? String, !name.isEmpty,
                  let userID = data(user["id"]) else {
                completion(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "Passkeys.create needs user.name and a base64url user.id")))
                return
            }
            request = provider.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userID)
        } else {
            let assertion = provider.createCredentialAssertionRequest(challenge: challenge)
            if let allowCredentials = options["allowCredentials"] as? [[String: Any]] {
                assertion.allowedCredentials = allowCredentials.compactMap { descriptor in
                    guard let credentialID = data(descriptor["id"]) else { return nil }
                    return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)
                }
            }
            request = assertion
        }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        let key = ObjectIdentifier(controller)
        pending[key] = Pending(requestToken: requestToken, completion: completion)
        controllers[requestToken] = controller
        controller.performRequests()
    }

    func cancel(requestToken: String) {
        controllers.removeValue(forKey: requestToken)
        pending = pending.filter { $0.value.requestToken != requestToken }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let key = ObjectIdentifier(controller)
        guard let request = pending.removeValue(forKey: key) else { return }
        controllers.removeValue(forKey: request.requestToken)
        if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            guard let attestationObject = registration.rawAttestationObject else {
                request.completion(.failure(CraftNativeActionError(code: "PASSKEY_FAILED", message: "Apple returned a registration without an attestation object")))
                return
            }
            request.completion(.success([
                "id": Self.base64url(registration.credentialID),
                "rawId": Self.base64url(registration.credentialID),
                "type": "public-key",
                "response": [
                    "clientDataJSON": Self.base64url(registration.rawClientDataJSON),
                    "attestationObject": Self.base64url(attestationObject),
                ],
            ]))
            return
        }
        if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            var response: [String: Any] = [
                "clientDataJSON": Self.base64url(assertion.rawClientDataJSON),
                "authenticatorData": Self.base64url(assertion.rawAuthenticatorData),
                "signature": Self.base64url(assertion.signature),
            ]
            if let userID = assertion.userID { response["userHandle"] = Self.base64url(userID) }
            request.completion(.success([
                "id": Self.base64url(assertion.credentialID),
                "rawId": Self.base64url(assertion.credentialID),
                "type": "public-key",
                "response": response,
            ]))
            return
        }
        request.completion(.failure(CraftNativeActionError(code: "PASSKEY_FAILED", message: "Apple returned an unsupported passkey credential")))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let key = ObjectIdentifier(controller)
        guard let request = pending.removeValue(forKey: key) else { return }
        controllers.removeValue(forKey: request.requestToken)
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        request.completion(.failure(CraftNativeActionError(code: cancelled ? "CANCELLED" : "PASSKEY_FAILED", message: error.localizedDescription)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        CraftPresenter.keyWindow() ?? ASPresentationAnchor()
    }

    private func relyingPartyID(options: [String: Any], config: CraftConfig) -> String? {
        let value = (options["rpId"] as? String) ?? (options["rp"] as? [String: Any])?["id"] as? String
        let domains = Self.domains(in: config)
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? (domains.count == 1 ? domains.first : nil)
        guard let candidate, domains.contains(candidate), candidate.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        return candidate
    }

    private func data(_ value: Any?) -> Data? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        var encoded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Synchronous reads for a screen's first frame

extension CraftNativeActions {
    /// The JSON text `craft.storage` keeps under `key`, or nil. The same store
    /// as the asynchronous Storage module, read without a bridge round trip.
    static func storageJSON(forKey key: String) throws -> String? {
        guard let key = validKey(key) else { return nil }
        guard let data = try CraftPersistentStorage.get(key, prefix: storagePrefix) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores JSON text under `key` (nil removes it). False for an invalid key
    /// or text that is not JSON, which the asynchronous `get` could not read.
    @discardableResult
    static func setStorageJSON(_ json: String?, forKey key: String) -> Bool {
        guard let key = validKey(key) else { return false }
        do {
            try CraftPersistentStorage.set(key, data: json.map { Data($0.utf8) }, prefix: storagePrefix)
            return true
        } catch { return false }
    }

    /// The Keychain item the web page's `craft.secureStorage` wrote under
    /// `key`: a generic password whose account is the key, as CraftApp's
    /// `secureStore` writes it. Nil when there is none.
    static func webSecureValue(forKey key: String) -> String? {
        guard let key = validKey(key) else { return nil }
        return CraftKeychain.value(account: key, service: nil) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

/// The app's own Keychain items, read once and then remembered.
///
/// A Keychain read is `SecItemCopyMatching`, which took 100-900ms a read on a
/// simulator and is not free on a phone, and every screen reads the sign-in
/// token and the account beside it when it opens. They ran on the main
/// thread, one after another, so a sign-in that made each open screen check
/// the account again held the interface for seconds.
///
/// This process is the only writer of these items, through `secureStorage`,
/// `CraftHybridKeychain` and the web bridge's secure storage, and each of
/// them forgets what it changed. An item another process could write (a
/// shared access group, an extension) is not remembered, and coming back to
/// the foreground forgets everything, so a value written while the app was
/// away is read fresh.
enum CraftKeychain {
    /// Where native screens' secure storage runs: off the main thread, one
    /// call at a time, so a write is always seen by the read after it.
    static let queue = DispatchQueue(label: "craft.keychain", qos: .userInitiated)
    private static let lock = NSLock()
    private static var values: [String: String?] = [:]
    /// Moves on every forget, so a read that raced a write is not kept.
    private static var generation = 0
    private static var observing: NSObjectProtocol?

    private static func cacheKey(_ account: String, _ service: String?) -> String {
        "\(service ?? "*")\u{1F}\(account)"
    }

    /// `account`'s value under `service` (nil: whichever service holds it),
    /// from memory when it was read before, else from `read`.
    static func value(account: String, service: String?, read: () -> String?) -> String? {
        let key = cacheKey(account, service)
        lock.lock()
        if observing == nil { observeForeground() }
        if let known = values[key] {
            lock.unlock()
            return known
        }
        let started = generation
        lock.unlock()
        let value = read()
        lock.lock()
        if generation == started { values[key] = .some(value) }
        lock.unlock()
        return value
    }

    /// Drop what is remembered for `account`, under every service; nil drops all.
    static func forget(account: String?) {
        lock.lock()
        generation += 1
        if let account {
            let suffix = "\u{1F}\(account)"
            values = values.filter { !$0.key.hasSuffix(suffix) }
        } else {
            values.removeAll()
        }
        lock.unlock()
    }

    /// Called with `lock` held.
    private static func observeForeground() {
        observing = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            forget(account: nil)
        }
    }
}

/// The signed-in account: the token kept in secure storage under
/// `sessionTokenKey` (default `auth.token`). Whoever moves it, a native
/// screen's `craft.secureStorage`, the page's own sign-in through a
/// `shareStorage` key, or a sign-out's clear, posts `changed` once with
/// `key`, `token` and `previous` (NSNull when signed out), after the Keychain
/// holds the new value. Each native screen hands it to its script as
/// `SESSION_CHANGED` and to `craft.session.onChange` (CraftNativeScreen).
enum CraftSession {
    static let changed = Notification.Name("craftSessionChanged")
    static let defaultKey = "auth.token"
    /// One write and its before and after at a time, so two quick writes
    /// from different queues are two changes, never one reported twice.
    private static let lock = NSLock()

    static func tokenKey(_ config: CraftConfig) -> String {
        guard let key = config.sessionTokenKey, !key.isEmpty else { return defaultKey }
        return key
    }

    /// The token now, as `craft.secureStorage.getSync` reads it; nil when
    /// signed out (an empty token is no account either).
    static func token(_ config: CraftConfig) -> String? {
        guard config.enableSecureStorage,
              let value = CraftNativeActions.webSecureValue(forKey: tokenKey(config)), !value.isEmpty else { return nil }
        return value
    }

    /// Run `write`, and post `changed` when it moved the token. `key` is the
    /// key written; nil for a clear, which can remove every key.
    static func observe<T>(key: String?, config: CraftConfig, _ write: () -> T) -> T {
        let name = tokenKey(config)
        guard key == nil || key == name else { return write() }
        lock.lock()
        let before = token(config)
        let result = write()
        let after = token(config)
        lock.unlock()
        if before != after { post(key: name, token: after, previous: before) }
        return result
    }

    static func post(key: String, token: String?, previous: String?) {
        let info: [String: Any] = ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()]
        let send = { NotificationCenter.default.post(name: changed, object: nil, userInfo: info) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }
}

/// Last-known data for a screen's first frame: one JSON file per name in
/// `Application Support/craft-snapshots/<name>.json`. A web page writes them
/// (`snapshots.set` in the mobile API) and a native screen reads them
/// synchronously before its first render, or writes its own.
enum CraftSnapshots {
    static let changed = Notification.Name("craftSnapshotChanged")
    private static let queue = DispatchQueue(label: "dev.craft.snapshots", qos: .utility)
    private static let lock = NSLock()
    /// Writes not on disk yet, so a read right after a write sees it.
    private static var pending: [String: String?] = [:]
    private static var revisions: [String: UInt64] = [:]
    private static var revision: UInt64 = 0
    // Screens read shared headers many times while evaluating bindings. Keep
    // settled JSON in memory instead of reopening the same file on the UI thread.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 32
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("craft-snapshots", isDirectory: true)
    }

    /// Letters, digits, `-`, `_`, `.` and account namespace `:`, not starting with a dot: a file
    /// name, never a path.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) }
    }

    static func url(for name: String) -> URL? {
        guard isValidName(name) else { return nil }
        return directory?.appendingPathComponent("\(name).json", isDirectory: false)
    }

    /// The snapshot's JSON text, or nil.
    static func read(_ name: String) -> String? {
        guard let url = url(for: name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let waiting = pending[name] { return waiting }
        if let cached = cache.object(forKey: name as NSString) { return cached as String }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let json = String(decoding: data, as: UTF8.self)
        cache.setObject(json as NSString, forKey: name as NSString, cost: data.count)
        return json
    }

    /// Replaces the snapshot with JSON text (nil deletes it) off the main
    /// thread, atomically. `completion` runs on the main queue.
    static func write(_ name: String, json: String?, completion: ((Bool) -> Void)? = nil) {
        guard let url = url(for: name), let directory else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        if let json, (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) == nil {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        lock.lock()
        revision &+= 1
        let mine = revision
        revisions[name] = mine
        pending[name] = .some(json)
        cache.removeObject(forKey: name as NSString)
        lock.unlock()
        queue.async {
            var ok = true
            do {
                if let json {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data(json.utf8).write(to: url, options: [.atomic])
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                ok = false
            }
            lock.lock()
            if revisions[name] == mine {
                revisions.removeValue(forKey: name)
                pending.removeValue(forKey: name)
                if ok, let json {
                    cache.setObject(json as NSString, forKey: name as NSString, cost: json.utf8.count)
                }
            }
            lock.unlock()
            DispatchQueue.main.async {
                if ok { NotificationCenter.default.post(name: changed, object: nil, userInfo: ["name": name]) }
                completion?(ok)
            }
        }
    }

    /// Every snapshot there is: on disk, and written but not on disk yet.
    static func names() -> [String] {
        var names = Set(directory
            .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) } ?? [])
        lock.lock()
        for (name, json) in pending {
            if json == nil { names.remove(name) } else { names.insert(name) }
        }
        lock.unlock()
        return names.filter(isValidName).sorted()
    }

    /// Deletes every snapshot but the ones named in `keep` (a sign-out), each
    /// as `write(name, json: nil)` does, so each posts `changed`.
    /// `completion` runs on the main queue: true when every one went.
    static func clear(keeping keep: Set<String> = [], completion: ((Bool) -> Void)? = nil) {
        let doomed = names().filter { !keep.contains($0) }
        guard !doomed.isEmpty else {
            DispatchQueue.main.async { completion?(true) }
            return
        }
        let group = DispatchGroup()
        var allRemoved = true
        for name in doomed {
            group.enter()
            write(name, json: nil) { ok in
                if !ok { allRemoved = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion?(allRemoved) }
    }
}

/// The Taptic Engine's generators, held for the life of the process.
///
/// Each haptic used to make a fresh generator at the moment of the tap. A new
/// generator has to wake the engine before it can play, which is the tens of
/// milliseconds between a finger landing and the feel that makes web haptics
/// read as late. These are made once, prepared again after every use, and
/// `prepare` lets a page warm one before a gesture it knows is coming (the
/// start of a drag, a long press about to complete).
///
/// The three kinds are the three UIKit has, and they are not interchangeable:
/// a notification is the success, warning or error pattern, a selection is the
/// detent a picker plays, and an impact is a single tap at one of five weights.
/// The page used to get impacts for all of them.
///
/// Main thread only, like every UIFeedbackGenerator. Every caller is.
enum CraftHaptics {
    private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static var notifier: UINotificationFeedbackGenerator?
    private static var selector: UISelectionFeedbackGenerator?

    /// An impact weight by name, or nil for a name that is not one.
    static func impactStyle(_ name: String) -> UIImpactFeedbackGenerator.FeedbackStyle? {
        switch name {
        case "light": return .light
        case "medium": return .medium
        case "heavy": return .heavy
        case "soft": return .soft
        case "rigid": return .rigid
        default: return nil
        }
    }

    /// Play one haptic: an impact weight, a notification type, or `selection`.
    /// Anything else plays a medium impact, as an unknown style always has.
    static func play(_ style: String) {
        switch style {
        case "success": notification().notificationOccurred(.success); notification().prepare()
        case "warning": notification().notificationOccurred(.warning); notification().prepare()
        case "error": notification().notificationOccurred(.error); notification().prepare()
        case "selection": selection().selectionChanged(); selection().prepare()
        default:
            let generator = impact(impactStyle(style) ?? .medium)
            generator.impactOccurred()
            generator.prepare()
        }
    }

    /// Warm a generator so the next haptic plays without the engine's wake-up
    /// delay. `impact`, `notification` or `selection` for one kind, an impact
    /// weight or notification type for that one, nothing for all of them.
    /// UIKit keeps a prepared engine awake for a few seconds only.
    static func prepare(_ kind: String?) {
        switch kind {
        case "impact": impact(.medium).prepare()
        case "notification", "success", "warning", "error": notification().prepare()
        case "selection": selection().prepare()
        case let name? where impactStyle(name) != nil: impact(impactStyle(name)!).prepare()
        default:
            impact(.medium).prepare()
            notification().prepare()
            selection().prepare()
        }
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let generator = impacts[style] { return generator }
        let generator = UIImpactFeedbackGenerator(style: style)
        impacts[style] = generator
        return generator
    }

    private static func notification() -> UINotificationFeedbackGenerator {
        if let notifier { return notifier }
        let generator = UINotificationFeedbackGenerator()
        notifier = generator
        return generator
    }

    private static func selection() -> UISelectionFeedbackGenerator {
        if let selector { return selector }
        let generator = UISelectionFeedbackGenerator()
        selector = generator
        return generator
    }
}
