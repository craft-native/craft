import SwiftUI
import WebKit
import Speech
import AVFoundation
import LocalAuthentication
import Security
import UserNotifications
import Photos
import CoreLocation
import Contacts
import ContactsUI
import EventKit
import StoreKit
import Network
import CoreMotion
import CoreBluetooth
import CoreNFC
import HealthKit
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import SQLite3
import AuthenticationServices
import BackgroundTasks
import ARKit
import RealityKit
import SceneKit
import Vision
import WidgetKit
import Intents
import WatchConnectivity
import ActivityKit

extension Notification.Name {
    static let craftPushToken = Notification.Name("craftPushToken")
    static let craftPushRegistrationError = Notification.Name("craftPushRegistrationError")
    static let craftNotificationResponse = Notification.Name("craftNotificationResponse")
}

final class CraftAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .craftPushToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .craftPushRegistrationError, object: error.localizedDescription)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        NotificationCenter.default.post(name: .craftNotificationResponse, object: response.notification.request.content.userInfo)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }
}

// MARK: - App Entry Point
@main
struct CraftApp: App {
    @UIApplicationDelegateAdaptor(CraftAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some SwiftUI.Scene {
        WindowGroup {
            CraftWebView(config: appState.config)
                .ignoresSafeArea()
                .preferredColorScheme(appState.config.darkMode ? .dark : .light)
                .environmentObject(appState)
                .onOpenURL { url in
                    // Handle deep links and universal links
                    DeepLinkManager.shared.handleURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        DeepLinkManager.shared.handleURL(url)
                    }
                }
        }
    }
}

// MARK: - Deep Link Manager
class DeepLinkManager {
    static let shared = DeepLinkManager()

    private var initialURL: URL?
    private var pendingURL: URL?
    private weak var webView: WKWebView?
    private var isReady = false

    private init() {}

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func setReady() {
        isReady = true
        // If there's a pending URL, dispatch it now
        if let url = pendingURL {
            dispatchDeepLink(url)
            pendingURL = nil
        }
    }

    func handleURL(_ url: URL) {
        // Store as initial URL if this is the first one
        if initialURL == nil {
            initialURL = url
        }

        if isReady, let webView = webView {
            dispatchDeepLink(url)
        } else {
            // Store for later when web view is ready
            pendingURL = url
        }
    }

    func getInitialURL() -> URL? {
        return initialURL
    }

    private func dispatchDeepLink(_ url: URL) {
        guard let webView = webView else { return }

        // Parse URL components
        var params: [String: Any] = [
            "url": url.absoluteString,
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": url.path,
            "query": url.query ?? ""
        ]

        // Parse query parameters
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            var queryParams: [String: String] = [:]
            for item in queryItems {
                queryParams[item.name] = item.value ?? ""
            }
            params["queryParams"] = queryParams
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: params)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
            let script = "window.dispatchEvent(new CustomEvent('craftDeepLink', {detail: \(jsonStr)}));"
            DispatchQueue.main.async {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        } catch {
            print("Deep link JSON error: \(error)")
        }
    }
}

// MARK: - App State
class AppState: ObservableObject {
    @Published var config: CraftConfig

    init() {
        // Load config from craft.config.json if available
        if let configURL = Bundle.main.url(forResource: "craft.config", withExtension: "json"),
           let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(CraftConfig.self, from: data) {
            self.config = config
        } else {
            self.config = CraftConfig()
        }
    }
}

// MARK: - Configuration
struct CraftConfig: Codable {
    var appName: String = "Craft App"
    var bundleId: String = "com.craft.app"
    var darkMode: Bool = true
    var backgroundColor: String = "#1a1a2e"
    var enableSpeechRecognition: Bool = false
    var enableHaptics: Bool = false
    var enableShare: Bool = false
    var enableCamera: Bool = false
    var enableBiometric: Bool = false
    var enablePushNotifications: Bool = false
    var enableSecureStorage: Bool = false
    var enableGeolocation: Bool = false
    var enableClipboard: Bool = false
    var enableContacts: Bool = false
    var enableCalendar: Bool = false
    var enableLocalNotifications: Bool = false
    var enableInAppPurchase: Bool = false
    var enableKeepAwake: Bool = false
    var enableOrientationLock: Bool = false
    var enableDeepLinks: Bool = false
    var enableQRScanner: Bool = false
    var enableFilePicker: Bool = false
    var enableFileDownload: Bool = false
    var enableSocialAuth: Bool = false
    var enableAudioRecording: Bool = false
    var enableVideoRecording: Bool = false
    var enableMotionSensors: Bool = false
    var enableLocalDatabase: Bool = false
    var enableBluetooth: Bool = false
    var enableNFC: Bool = false
    var enableHealthKit: Bool = false
    var enableLiveActivities: Bool = false
    var enableWatchApp: Bool = false
    var enableBackgroundLocation: Bool = false
    var enableBackgroundTasks: Bool = false
    var enableScreenCapture: Bool = false
    var enablePDFViewer: Bool = false
    var enableAR: Bool = false
    var enableMLKit: Bool = false
    var devServerURL: String? = nil
    var trustedOrigins: [String] = []
}

// MARK: - WebView
final class BundledAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootURL: URL?

    override init() {
        rootURL = Self.findBundledRoot()
        super.init()
    }

    private static func findBundledRoot() -> URL? {
        let bundle = Bundle.main
        let directCandidates = [
            bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist"),
            bundle.url(forResource: "index", withExtension: "html")
        ]
        if let indexURL = directCandidates.compactMap({ $0 }).first {
            return indexURL.deletingLastPathComponent()
        }

        // Folder references, synchronized folders, and different Xcode
        // versions can materialize resources at different bundle depths.
        // Search the app resources once so a valid bundle never becomes a
        // silent blank screen merely because its generated layout changed.
        guard let resources = bundle.resourceURL,
              let files = FileManager.default.enumerator(
                at: resources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }

        for case let fileURL as URL in files where fileURL.lastPathComponent == "index.html" {
            return fileURL.deletingLastPathComponent()
        }
        return nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == "craft",
              requestURL.host == "app" else {
            fail(urlSchemeTask, code: .badURL)
            return
        }
        guard let rootURL = rootURL else {
            fail(urlSchemeTask, code: .fileDoesNotExist)
            return
        }

        let path = requestURL.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard !path.split(separator: "/").contains("..") else {
            fail(urlSchemeTask, code: .noPermissionsToReadFile)
            return
        }

        let candidates: [String]
        if path.isEmpty {
            candidates = ["index.html"]
        } else if path.hasSuffix("/") {
            candidates = ["\(path)index.html"]
        } else if URL(fileURLWithPath: path).pathExtension.isEmpty {
            candidates = ["\(path).html", "\(path)/index.html"]
        } else {
            candidates = [path]
        }

        let standardizedRoot = rootURL.standardizedFileURL
        for candidate in candidates {
            let fileURL = rootURL.appendingPathComponent(candidate).standardizedFileURL
            guard fileURL.path.hasPrefix(standardizedRoot.path + "/") else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let encoding = mimeType.hasPrefix("text/") || mimeType.contains("javascript") || mimeType.contains("json") ? "utf-8" : nil
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: encoding
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        fail(urlSchemeTask, code: .fileDoesNotExist)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }
}

struct CraftWebView: UIViewRepresentable {
    let config: CraftConfig

    func makeUIView(context: Context) -> WKWebView {
        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.setURLSchemeHandler(BundledAssetSchemeHandler(), forURLScheme: "craft")

        // Add native bridge
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "craft")
        webConfig.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false

        // Register with DeepLinkManager
        DeepLinkManager.shared.setWebView(webView)

        // Parse background color
        let bgColor = UIColor(hex: config.backgroundColor) ?? .black
        webView.backgroundColor = bgColor
        webView.scrollView.backgroundColor = bgColor

        // Load content
        if let devURL = config.devServerURL, !devURL.isEmpty {
            // Development mode - connect to server
            if let url = URL(string: devURL) {
                webView.load(URLRequest(url: url))
            }
        } else if let bundledURL = URL(string: "craft://app/index.html") {
            // A route-aware local origin keeps root-relative STX assets and
            // clean links working without granting arbitrary file access.
            webView.load(URLRequest(url: bundledURL))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config)
    }

    // MARK: - Coordinator (Native Bridge)
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIImagePickerControllerDelegate, UINavigationControllerDelegate, CLLocationManagerDelegate, ARSCNViewDelegate {
        let config: CraftConfig
        private var speechRecognizer: SFSpeechRecognizer?
        private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        private var recognitionTask: SFSpeechRecognitionTask?
        private var audioEngine = AVAudioEngine()
        private weak var webView: WKWebView?
        private var pendingCallbackId: String?
        private var pendingPushCallbackId: String?
        private var loadedBundledFallback = false

        // Location
        private var locationManager: CLLocationManager?
        private var singleLocationCallbackId: String?
        private var locationPermissionCallbackId: String?
        private var isWatchingLocation = false
        private var isRecordingLocation = false
        private var isLocationRecordingPaused = false
        private var locationRecordingId: String?
        private var locationRecordingStartedAt: TimeInterval?

        // Network monitoring
        private var networkMonitor: NWPathMonitor?
        private var isConnected = true
        private var connectionType = "unknown"

        // Contacts
        private var contactStore: CNContactStore?

        // Calendar
        private var eventStore: EKEventStore?

        // Keep awake
        private var isKeepingAwake = false

        // Orientation lock
        private var lockedOrientation: UIInterfaceOrientationMask?

        // Deep links pending
        private var pendingDeepLink: URL?

        // Motion sensors
        private var motionManager: CMMotionManager?
        private var isMotionUpdating = false

        // Bluetooth
        private var centralManager: CBCentralManager?
        private var peripheralManager: CBPeripheralManager?
        private var discoveredPeripherals: [CBPeripheral] = []

        // Audio recording
        private var audioRecorder: AVAudioRecorder?
        private var recordingURL: URL?

        // Health
        private var healthStore: HKHealthStore?

        // SQLite database
        private var db: OpaquePointer?

        init(config: CraftConfig) {
            self.config = config
            super.init()
            if config.enableSpeechRecognition {
                speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            }
            if config.enableGeolocation {
                locationManager = CLLocationManager()
                locationManager?.desiredAccuracy = kCLLocationAccuracyBest
                locationManager?.activityType = .fitness
                locationManager?.pausesLocationUpdatesAutomatically = false
                restoreLocationRecordingState()
            }
            if config.enableContacts {
                contactStore = CNContactStore()
            }
            if config.enableCalendar {
                eventStore = EKEventStore()
            }
            if config.enableMotionSensors {
                motionManager = CMMotionManager()
            }
            if config.enableHealthKit && HKHealthStore.isHealthDataAvailable() {
                healthStore = HKHealthStore()
            }
            if config.enableWatchApp {
                setupWatchConnectivity()
            }
            if config.enableLocalDatabase {
                setupDatabase()
            }
            NotificationCenter.default.addObserver(self, selector: #selector(receivePushToken(_:)), name: .craftPushToken, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(receivePushRegistrationError(_:)), name: .craftPushRegistrationError, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(receiveNotificationResponse(_:)), name: .craftNotificationResponse, object: nil)
            setupNetworkMonitoring()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            networkMonitor?.cancel()
        }

        private func setupDatabase() {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dbPath = documentsPath.appendingPathComponent("craft.db").path

            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                print("Database opened at \(dbPath)")
            } else {
                print("Failed to open database")
            }
        }

        private func setupNetworkMonitoring() {
            networkMonitor = NWPathMonitor()
            networkMonitor?.pathUpdateHandler = { [weak self] path in
                self?.isConnected = path.status == .satisfied
                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = "cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self?.connectionType = "ethernet"
                } else {
                    self?.connectionType = "unknown"
                }
                self?.sendToWeb("craftNetworkChange", data: [
                    "isConnected": self?.isConnected ?? false,
                    "type": self?.connectionType ?? "unknown"
                ])
            }
            networkMonitor?.start(queue: DispatchQueue.global())
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let securityOrigin = message.frameInfo.securityOrigin
            guard isTrustedOrigin(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port) else {
                print("Blocked Craft bridge message from untrusted origin: \(securityOrigin.protocol)://\(securityOrigin.host)")
                return
            }
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            let callbackId = body["callbackId"] as? String

            switch action {
            case "startListening":
                if config.enableSpeechRecognition { startSpeechRecognition() }
            case "stopListening":
                stopSpeechRecognition()
            case "haptic":
                if config.enableHaptics {
                    let style = body["style"] as? String ?? "medium"
                    triggerHaptic(style: style)
                }
            case "share":
                if config.enableShare {
                    if let options = body["options"] as? [String: Any] {
                        share(options: options, callbackId: callbackId)
                    } else if let text = body["text"] as? String {
                        share(options: ["text": text], callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "Nothing to share", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Sharing is disabled", code: "CAPABILITY_DISABLED")
                }
            case "openCamera":
                if config.enableCamera {
                    pendingCallbackId = callbackId
                    openCamera()
                }
            case "pickImage":
                if config.enableCamera {
                    pendingCallbackId = callbackId
                    pickImage()
                }
            case "authenticate":
                if config.enableBiometric {
                    let reason = body["reason"] as? String ?? "Authenticate to continue"
                    authenticate(reason: reason, callbackId: callbackId)
                }
            case "registerPush":
                if config.enablePushNotifications {
                    registerPushNotifications(callbackId: callbackId)
                }
            case "secureSet":
                if config.enableSecureStorage,
                   let key = body["key"] as? String,
                   let value = body["value"] as? String {
                    let success = secureStore(key: key, value: value)
                    resolveCallback(callbackId, result: success)
                }
            case "secureGet":
                if config.enableSecureStorage,
                   let key = body["key"] as? String {
                    let value = secureRetrieve(key: key)
                    resolveCallback(callbackId, result: value as Any)
                }
            case "secureRemove":
                if config.enableSecureStorage,
                   let key = body["key"] as? String {
                    let success = secureRemove(key: key)
                    resolveCallback(callbackId, result: success)
                }
            case "secureClear":
                if config.enableSecureStorage {
                    resolveCallback(callbackId, result: secureClear())
                } else {
                    rejectCallback(callbackId, error: "Secure storage is disabled", code: "CAPABILITY_DISABLED")
                }
            case "checkPermission":
                checkPermission(body["permission"] as? String, callbackId: callbackId)
            case "requestPermission":
                requestPermission(body["permission"] as? String, callbackId: callbackId)
            case "openSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url) { opened in
                        self.resolveCallback(callbackId, result: opened)
                    }
                } else {
                    rejectCallback(callbackId, error: "Settings URL is unavailable")
                }
            case "log":
                if let msg = body["message"] as? String {
                    print("[Craft Web] \(msg)")
                }

            // Memory Usage (for profiling)
            case "getMemoryUsage":
                getMemoryUsage(callbackId: callbackId)

            // Geolocation
            case "getCurrentPosition":
                if config.enableGeolocation {
                    getCurrentPosition(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Geolocation is disabled", code: "CAPABILITY_DISABLED")
                }
            case "watchPosition":
                if config.enableGeolocation {
                    watchPosition(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Geolocation is disabled", code: "CAPABILITY_DISABLED")
                }
            case "clearWatch":
                stopWatchingPosition()
                resolveCallback(callbackId, result: true)
            case "startLocationRecording":
                if config.enableGeolocation {
                    startLocationRecording(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Geolocation is disabled", code: "CAPABILITY_DISABLED")
                }
            case "pauseLocationRecording":
                pauseLocationRecording(callbackId: callbackId)
            case "resumeLocationRecording":
                resumeLocationRecording(callbackId: callbackId)
            case "stopLocationRecording":
                stopLocationRecording(callbackId: callbackId)
            case "getLocationRecordingState":
                getLocationRecordingState(callbackId: callbackId)
            case "readLocationRecording":
                readLocationRecording(callbackId: callbackId)
            // Clipboard
            case "clipboardWrite":
                if config.enableClipboard, let text = body["text"] as? String {
                    UIPasteboard.general.string = text
                    resolveCallback(callbackId, result: true)
                }
            case "clipboardRead":
                if config.enableClipboard {
                    let text = UIPasteboard.general.string ?? ""
                    resolveCallback(callbackId, result: text)
                }
            // Device Info
            case "getDeviceInfo":
                getDeviceInfo(callbackId: callbackId)
            // App Badge
            case "setBadge":
                if let count = body["count"] as? Int {
                    setBadgeCount(count, callbackId: callbackId)
                }
            case "clearBadge":
                setBadgeCount(0, callbackId: callbackId)
            // Network Status
            case "getNetworkStatus":
                resolveCallback(callbackId, result: ["isConnected": isConnected, "type": connectionType])
            // App Review
            case "requestReview":
                requestAppReview()
                resolveCallback(callbackId, result: true)
            // Flashlight/Torch
            case "setFlashlight":
                if let enabled = body["enabled"] as? Bool {
                    setFlashlight(enabled: enabled, callbackId: callbackId)
                }
            // Vibrate pattern
            case "vibrate":
                if let pattern = body["pattern"] as? [Int] {
                    vibratePattern(pattern)
                } else {
                    triggerHaptic(style: "medium")
                }
                resolveCallback(callbackId, result: true)
            // Open URL
            case "openURL":
                if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                    resolveCallback(callbackId, result: true)
                }
            // App state
            case "getAppState":
                let state = UIApplication.shared.applicationState
                let stateStr = state == .active ? "active" : (state == .background ? "background" : "inactive")
                resolveCallback(callbackId, result: stateStr)

            // MARK: - Contacts
            case "getContacts":
                if config.enableContacts {
                    getContacts(callbackId: callbackId)
                }
            case "addContact":
                if config.enableContacts,
                   let contactData = body["contact"] as? [String: Any] {
                    addContact(contactData, callbackId: callbackId)
                }

            // MARK: - Calendar
            case "getCalendarEvents":
                if config.enableCalendar {
                    let startDate = body["startDate"] as? Double
                    let endDate = body["endDate"] as? Double
                    getCalendarEvents(startDate: startDate, endDate: endDate, callbackId: callbackId)
                }
            case "createCalendarEvent":
                if config.enableCalendar,
                   let eventData = body["event"] as? [String: Any] {
                    createCalendarEvent(eventData, callbackId: callbackId)
                }
            case "deleteCalendarEvent":
                if config.enableCalendar,
                   let eventId = body["eventId"] as? String {
                    deleteCalendarEvent(eventId, callbackId: callbackId)
                }

            // MARK: - Local Notifications
            case "scheduleNotification":
                if config.enableLocalNotifications,
                   let notifData = body["notification"] as? [String: Any] {
                    scheduleLocalNotification(notifData, callbackId: callbackId)
                }
            case "cancelNotification":
                if config.enableLocalNotifications,
                   let notifId = body["id"] as? String {
                    cancelLocalNotification(notifId, callbackId: callbackId)
                }
            case "cancelAllNotifications":
                if config.enableLocalNotifications {
                    cancelAllLocalNotifications(callbackId: callbackId)
                }
            case "getPendingNotifications":
                if config.enableLocalNotifications {
                    getPendingNotifications(callbackId: callbackId)
                }

            // MARK: - Deep Links
            case "registerDeepLinkHandler":
                if config.enableDeepLinks {
                    // Handler is registered in JS
                    resolveCallback(callbackId, result: true)
                }
            case "getInitialURL":
                if config.enableDeepLinks {
                    if let url = DeepLinkManager.shared.getInitialURL() {
                        resolveCallbackJSON(callbackId, json: [
                            "url": url.absoluteString,
                            "scheme": url.scheme ?? "",
                            "host": url.host ?? "",
                            "path": url.path,
                            "query": url.query ?? ""
                        ])
                    } else {
                        resolveCallback(callbackId, result: NSNull())
                    }
                }

            // MARK: - In-App Purchase
            case "getProducts":
                if config.enableInAppPurchase,
                   let productIds = body["productIds"] as? [String] {
                    getProducts(productIds, callbackId: callbackId)
                }
            case "purchase":
                if config.enableInAppPurchase,
                   let productId = body["productId"] as? String {
                    purchaseProduct(productId, callbackId: callbackId)
                }
            case "restorePurchases":
                if config.enableInAppPurchase {
                    restorePurchases(callbackId: callbackId)
                }

            // MARK: - Keep Awake
            case "setKeepAwake":
                if config.enableKeepAwake,
                   let enabled = body["enabled"] as? Bool {
                    setKeepAwake(enabled, callbackId: callbackId)
                }

            // MARK: - Orientation Lock
            case "lockOrientation":
                if config.enableOrientationLock,
                   let orientation = body["orientation"] as? String {
                    lockOrientation(orientation, callbackId: callbackId)
                }
            case "unlockOrientation":
                if config.enableOrientationLock {
                    unlockOrientation(callbackId: callbackId)
                }

            // MARK: - QR/Barcode Scanner
            case "scanQRCode":
                if config.enableQRScanner {
                    scanQRCode(callbackId: callbackId)
                }

            // MARK: - File Picker
            case "pickFile":
                if config.enableFilePicker {
                    let types = body["types"] as? [String]
                    pickFile(types: types, callbackId: callbackId)
                }

            // MARK: - File Download
            case "downloadFile":
                if config.enableFileDownload,
                   let url = body["url"] as? String,
                   let filename = body["filename"] as? String {
                    downloadFile(url: url, filename: filename, callbackId: callbackId)
                }
            case "saveFile":
                if config.enableFileDownload,
                   let data = body["data"] as? String,
                   let filename = body["filename"] as? String {
                    saveFile(data: data, filename: filename, callbackId: callbackId)
                }

            // MARK: - Social Auth
            case "signInWithApple":
                if config.enableSocialAuth {
                    signInWithApple(callbackId: callbackId)
                }

            // MARK: - Audio Recording
            case "startAudioRecording":
                if config.enableAudioRecording {
                    startAudioRecording(callbackId: callbackId)
                }
            case "stopAudioRecording":
                if config.enableAudioRecording {
                    stopAudioRecording(callbackId: callbackId)
                }

            // MARK: - Video Recording
            case "startVideoRecording":
                if config.enableVideoRecording {
                    startVideoRecording(callbackId: callbackId)
                }

            // MARK: - Motion Sensors
            case "startMotionUpdates":
                if config.enableMotionSensors {
                    let interval = body["interval"] as? Double ?? 100
                    startMotionUpdates(interval: interval, callbackId: callbackId)
                }
            case "stopMotionUpdates":
                stopMotionUpdates()
                resolveCallback(callbackId, result: true)

            // MARK: - Local Database
            case "dbExecute":
                if config.enableLocalDatabase,
                   let sql = body["sql"] as? String {
                    let params = body["params"] as? [Any]
                    dbExecute(sql: sql, params: params, callbackId: callbackId)
                }
            case "dbQuery":
                if config.enableLocalDatabase,
                   let sql = body["sql"] as? String {
                    let params = body["params"] as? [Any]
                    dbQuery(sql: sql, params: params, callbackId: callbackId)
                }

            // MARK: - Bluetooth
            case "startBluetoothScan":
                if config.enableBluetooth {
                    startBluetoothScan(callbackId: callbackId)
                }
            case "stopBluetoothScan":
                stopBluetoothScan()
                resolveCallback(callbackId, result: true)

            // MARK: - NFC
            case "scanNFC":
                if config.enableNFC {
                    scanNFC(callbackId: callbackId)
                }

            // MARK: - Health
            case "requestHealthAuthorization":
                if config.enableHealthKit {
                    let types = body["types"] as? [String] ?? []
                    requestHealthAuthorization(types: types, callbackId: callbackId)
                }
            case "getHealthData":
                if config.enableHealthKit,
                   let dataType = body["type"] as? String {
                    let startDate = body["startDate"] as? Double
                    let endDate = body["endDate"] as? Double
                    getHealthData(type: dataType, startDate: startDate, endDate: endDate, callbackId: callbackId)
                }
            case "saveHealthWorkout":
                if config.enableHealthKit {
                    saveHealthWorkout(body: body, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled")
                }

            // MARK: - Live Activities
            case "startLiveActivity":
                if config.enableLiveActivities {
                    startLiveActivity(body: body, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Live Activities are disabled")
                }
            case "updateLiveActivity":
                updateLiveActivity(body: body, callbackId: callbackId)
            case "endLiveActivity":
                endLiveActivity(callbackId: callbackId)

            // MARK: - Screen Capture
            case "takeScreenshot":
                if config.enableScreenCapture {
                    takeScreenshot(callbackId: callbackId)
                }

            // MARK: - Background Tasks
            case "registerBackgroundTask":
                if config.enableBackgroundTasks,
                   let taskId = body["taskId"] as? String {
                    registerBackgroundTask(taskId: taskId, callbackId: callbackId)
                }
            case "scheduleBackgroundTask":
                if config.enableBackgroundTasks,
                   let taskId = body["taskId"] as? String {
                    let delay = body["delay"] as? Double ?? 900 // 15 minutes default
                    let requiresNetwork = body["requiresNetwork"] as? Bool ?? false
                    let requiresCharging = body["requiresCharging"] as? Bool ?? false
                    scheduleBackgroundTask(taskId: taskId, delay: delay, requiresNetwork: requiresNetwork, requiresCharging: requiresCharging, callbackId: callbackId)
                }
            case "cancelBackgroundTask":
                if config.enableBackgroundTasks,
                   let taskId = body["taskId"] as? String {
                    cancelBackgroundTask(taskId: taskId, callbackId: callbackId)
                }
            case "cancelAllBackgroundTasks":
                if config.enableBackgroundTasks {
                    cancelAllBackgroundTasks(callbackId: callbackId)
                }

            // MARK: - PDF Viewer
            case "openPDF":
                if config.enablePDFViewer,
                   let source = body["source"] as? String {
                    let page = body["page"] as? Int ?? 0
                    openPDF(source: source, page: page, callbackId: callbackId)
                }
            case "closePDF":
                closePDF(callbackId: callbackId)

            // MARK: - Contacts Picker
            case "pickContact":
                if config.enableContacts {
                    let multiple = body["multiple"] as? Bool ?? false
                    pickContact(multiple: multiple, callbackId: callbackId)
                }

            // MARK: - App Shortcuts
            case "setShortcuts":
                if let shortcuts = body["shortcuts"] as? [[String: Any]] {
                    setAppShortcuts(shortcuts: shortcuts, callbackId: callbackId)
                }
            case "clearShortcuts":
                clearAppShortcuts(callbackId: callbackId)

            // MARK: - Keychain Sharing
            case "setSharedItem":
                if let key = body["key"] as? String,
                   let value = body["value"] as? String {
                    let group = body["group"] as? String
                    setSharedKeychainItem(key: key, value: value, group: group, callbackId: callbackId)
                }
            case "getSharedItem":
                if let key = body["key"] as? String {
                    let group = body["group"] as? String
                    getSharedKeychainItem(key: key, group: group, callbackId: callbackId)
                }
            case "removeSharedItem":
                if let key = body["key"] as? String {
                    let group = body["group"] as? String
                    removeSharedKeychainItem(key: key, group: group, callbackId: callbackId)
                }

            // MARK: - Local Auth Persistence
            case "setBiometricPersistence":
                if let enabled = body["enabled"] as? Bool {
                    let duration = body["duration"] as? Double ?? 300 // 5 min default
                    setBiometricPersistence(enabled: enabled, duration: duration, callbackId: callbackId)
                }
            case "checkBiometricPersistence":
                checkBiometricPersistence(callbackId: callbackId)
            case "clearBiometricPersistence":
                clearBiometricPersistence(callbackId: callbackId)

            // MARK: - AR (ARKit)
            case "startAR":
                if config.enableAR {
                    let options = body["options"] as? [String: Any] ?? [:]
                    startAR(options: options, callbackId: callbackId)
                }
            case "stopAR":
                if config.enableAR {
                    stopAR(callbackId: callbackId)
                }
            case "placeARObject":
                if config.enableAR,
                   let model = body["model"] as? String {
                    let position = body["position"] as? [String: Double]
                    placeARObject(model: model, position: position, callbackId: callbackId)
                }
            case "removeARObject":
                if config.enableAR,
                   let objectId = body["objectId"] as? String {
                    removeARObject(objectId: objectId, callbackId: callbackId)
                }
            case "getARPlanes":
                if config.enableAR {
                    getARPlanes(callbackId: callbackId)
                }

            // MARK: - ML (Core ML / Vision)
            case "classifyImage":
                if config.enableMLKit,
                   let imageBase64 = body["image"] as? String {
                    classifyImage(imageBase64: imageBase64, callbackId: callbackId)
                }
            case "detectObjects":
                if config.enableMLKit,
                   let imageBase64 = body["image"] as? String {
                    detectObjects(imageBase64: imageBase64, callbackId: callbackId)
                }
            case "recognizeText":
                if config.enableMLKit,
                   let imageBase64 = body["image"] as? String {
                    recognizeText(imageBase64: imageBase64, callbackId: callbackId)
                }

            // MARK: - Widget
            case "updateWidget":
                if let data = body["data"] as? [String: Any] {
                    updateWidget(data: data, callbackId: callbackId)
                }
            case "reloadWidgets":
                reloadAllWidgets(callbackId: callbackId)

            // MARK: - Siri Shortcuts
            case "registerSiriShortcut":
                if let phrase = body["phrase"] as? String,
                   let action = body["action"] as? String {
                    registerSiriShortcut(phrase: phrase, action: action, callbackId: callbackId)
                }
            case "removeSiriShortcut":
                if let action = body["action"] as? String {
                    removeSiriShortcut(action: action, callbackId: callbackId)
                }

            // MARK: - Watch Connectivity
            case "sendToWatch":
                if let message = body["message"] as? [String: Any] {
                    sendMessageToWatch(message: message, callbackId: callbackId)
                }
            case "updateWatchContext":
                if let context = body["context"] as? [String: Any] {
                    updateWatchContext(context: context, callbackId: callbackId)
                }
            case "isWatchReachable":
                isWatchReachable(callbackId: callbackId)

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            guard isTrustedURL(webView.url) else { return }
            injectNativeBridge()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if isTrustedURL(url) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadBundledFallback(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadBundledFallback(in: webView)
        }

        private func loadBundledFallback(in webView: WKWebView) {
            guard !loadedBundledFallback,
                  config.devServerURL != nil,
                  let bundledURL = URL(string: "craft://app/index.html") else { return }
            loadedBundledFallback = true
            webView.load(URLRequest(url: bundledURL))
        }

        private func isTrustedURL(_ url: URL?) -> Bool {
            guard let url = url else { return false }
            if url.scheme == "craft" && url.host == "app" { return true }
            return isTrustedOrigin(scheme: url.scheme ?? "", host: url.host ?? "", port: url.port ?? 0)
        }

        private func isTrustedOrigin(scheme: String, host: String, port: Int) -> Bool {
            if scheme == "file" { return true }
            guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return false }
            let defaultPort = scheme == "https" ? 443 : 80
            let normalizedPort = port == 0 ? defaultPort : port
            let origin = "\(scheme)://\(host)\(normalizedPort == defaultPort ? "" : ":\(normalizedPort)")"
            var allowed = Set(config.trustedOrigins)
            if let devServerURL = config.devServerURL,
               let components = URLComponents(string: devServerURL),
               let configuredHost = components.host,
               let configuredScheme = components.scheme {
                let configuredPort = components.port ?? (configuredScheme == "https" ? 443 : 80)
                allowed.insert("\(configuredScheme)://\(configuredHost)\(configuredPort == (configuredScheme == "https" ? 443 : 80) ? "" : ":\(configuredPort)")")
            }
            return allowed.contains(origin)
        }

        private func injectNativeBridge() {
            let laContext = LAContext()
            var biometricAvailable = false
            if laContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                biometricAvailable = true
            }

            let script = """
            window.craft = {
                platform: 'ios',
                capabilities: {
                    haptics: \(config.enableHaptics),
                    speechRecognition: \(config.enableSpeechRecognition),
                    share: \(config.enableShare),
                    camera: \(config.enableCamera),
                    biometric: \(biometricAvailable && config.enableBiometric),
                    pushNotifications: \(config.enablePushNotifications),
                    secureStorage: \(config.enableSecureStorage),
                    geolocation: \(config.enableGeolocation),
                    backgroundLocation: \(config.enableBackgroundLocation),
                    healthKit: \(config.enableHealthKit),
                    liveActivities: \(config.enableLiveActivities),
                    watchConnectivity: true,
                    clipboard: \(config.enableClipboard),
                    contacts: \(config.enableContacts),
                    calendar: \(config.enableCalendar),
                    localNotifications: \(config.enableLocalNotifications),
                    inAppPurchase: \(config.enableInAppPurchase),
                    keepAwake: \(config.enableKeepAwake),
                    orientationLock: \(config.enableOrientationLock),
                    deepLinks: \(config.enableDeepLinks),
                    flashlight: true,
                    network: true,
                    deviceInfo: true,
                    badge: true,
                    appReview: true
                },

                _callbacks: {},
                _callbackId: 0,

                _createCallback: function() {
                    var id = 'cb_' + (++this._callbackId);
                    var self = this;
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                        setTimeout(function() {
                            if (self._callbacks[id]) {
                                reject(new Error('Timeout'));
                                delete self._callbacks[id];
                            }
                        }, 30000);
                    }).finally(function() {
                        return id;
                    });
                },

                _resolveCallback: function(id, result) {
                    if (this._callbacks[id]) {
                        this._callbacks[id].resolve(result);
                        delete this._callbacks[id];
                    }
                },

                _rejectCallback: function(id, error, code) {
                    if (this._callbacks[id]) {
                        var err = new Error(error);
                        err.code = code || 'CRAFT_ERROR';
                        err.bridge = true;
                        this._callbacks[id].reject(err);
                        delete this._callbacks[id];
                        // Store last error for debugging
                        this._lastError = {
                            message: error,
                            code: code || 'CRAFT_ERROR',
                            timestamp: Date.now(),
                            stack: null
                        };
                        // Dispatch global error event if debug mode
                        if (this._debug) {
                            window.dispatchEvent(new CustomEvent('craftError', {detail: this._lastError}));
                        }
                        // Store in error history
                        this._errorHistory.push(this._lastError);
                        if (this._errorHistory.length > 50) this._errorHistory.shift();
                    }
                },

                // Enhanced reject with native stack trace
                _rejectCallbackWithStack: function(id, error, code, nativeStack) {
                    if (this._callbacks[id]) {
                        var err = new Error(error);
                        err.code = code || 'CRAFT_ERROR';
                        err.bridge = true;
                        err.nativeStack = nativeStack;
                        this._callbacks[id].reject(err);
                        delete this._callbacks[id];
                        // Store last error with native stack
                        this._lastError = {
                            message: error,
                            code: code || 'CRAFT_ERROR',
                            timestamp: Date.now(),
                            nativeStack: nativeStack,
                            jsStack: new Error().stack
                        };
                        if (this._debug) {
                            window.dispatchEvent(new CustomEvent('craftError', {detail: this._lastError}));
                            console.error('[Craft Error]', code, error, '\\nNative:', nativeStack);
                        }
                        this._errorHistory.push(this._lastError);
                        if (this._errorHistory.length > 50) this._errorHistory.shift();
                    }
                },

                // Debug mode
                _debug: false,
                _lastError: null,
                _errorHistory: [],
                _callLog: [],
                _networkLog: [],
                _consoleLog: [],
                _originalConsole: null,

                // Error code mappings for user-friendly messages
                _errorMessages: {
                    'PERMISSION_DENIED': 'Permission was denied. Please grant access in Settings.',
                    'NOT_AVAILABLE': 'This feature is not available on this device.',
                    'CANCELLED': 'The operation was cancelled by the user.',
                    'NETWORK_ERROR': 'A network error occurred. Please check your connection.',
                    'TIMEOUT': 'The operation timed out. Please try again.',
                    'INVALID_PARAMS': 'Invalid parameters provided.',
                    'NOT_FOUND': 'The requested resource was not found.',
                    'AUTH_FAILED': 'Authentication failed.',
                    'STORAGE_FULL': 'Storage is full. Please free up space.',
                    'CRAFT_ERROR': 'An unexpected error occurred.'
                },

                // Get user-friendly error message
                getErrorMessage: function(code) {
                    return this._errorMessages[code] || this._errorMessages['CRAFT_ERROR'];
                },

                // Get error history
                getErrorHistory: function() {
                    return this._errorHistory.slice();
                },

                // Clear error history
                clearErrorHistory: function() {
                    this._errorHistory = [];
                    this._lastError = null;
                },

                // Enable/disable debug mode
                setDebugMode: function(enabled) {
                    this._debug = enabled;
                    if (enabled) {
                        this._callLog = [];
                        this._networkLog = [];
                        this._setupConsoleCapture();
                        this._setupNetworkInspector();
                        console.log('[Craft] Debug mode enabled');
                    } else {
                        this._restoreConsole();
                    }
                },

                // Setup console capture
                _setupConsoleCapture: function() {
                    if (this._originalConsole) return; // Already setup
                    var self = this;
                    this._originalConsole = {
                        log: console.log,
                        warn: console.warn,
                        error: console.error,
                        info: console.info,
                        debug: console.debug
                    };
                    ['log', 'warn', 'error', 'info', 'debug'].forEach(function(level) {
                        console[level] = function() {
                            var args = Array.prototype.slice.call(arguments);
                            self._consoleLog.push({
                                level: level,
                                args: args.map(function(a) {
                                    try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                                    catch(e) { return String(a); }
                                }),
                                timestamp: Date.now()
                            });
                            if (self._consoleLog.length > 200) self._consoleLog.shift();
                            self._originalConsole[level].apply(console, arguments);
                        };
                    });
                },

                // Restore original console
                _restoreConsole: function() {
                    if (!this._originalConsole) return;
                    console.log = this._originalConsole.log;
                    console.warn = this._originalConsole.warn;
                    console.error = this._originalConsole.error;
                    console.info = this._originalConsole.info;
                    console.debug = this._originalConsole.debug;
                    this._originalConsole = null;
                },

                // Setup network inspector
                _setupNetworkInspector: function() {
                    var self = this;
                    if (window._craftNetworkSetup) return;
                    window._craftNetworkSetup = true;

                    // Intercept fetch
                    var originalFetch = window.fetch;
                    window.fetch = function(url, options) {
                        var startTime = Date.now();
                        var entry = {
                            type: 'fetch',
                            url: typeof url === 'string' ? url : url.url,
                            method: (options && options.method) || 'GET',
                            startTime: startTime,
                            status: null,
                            duration: null
                        };
                        self._networkLog.push(entry);
                        if (self._networkLog.length > 100) self._networkLog.shift();

                        return originalFetch.apply(window, arguments).then(function(response) {
                            entry.status = response.status;
                            entry.duration = Date.now() - startTime;
                            return response;
                        }).catch(function(err) {
                            entry.status = 'error';
                            entry.error = err.message;
                            entry.duration = Date.now() - startTime;
                            throw err;
                        });
                    };

                    // Intercept XMLHttpRequest
                    var OriginalXHR = window.XMLHttpRequest;
                    window.XMLHttpRequest = function() {
                        var xhr = new OriginalXHR();
                        var entry = { type: 'xhr', url: '', method: '', startTime: null, status: null, duration: null };

                        var originalOpen = xhr.open;
                        xhr.open = function(method, url) {
                            entry.method = method;
                            entry.url = url;
                            return originalOpen.apply(xhr, arguments);
                        };

                        var originalSend = xhr.send;
                        xhr.send = function() {
                            entry.startTime = Date.now();
                            self._networkLog.push(entry);
                            if (self._networkLog.length > 100) self._networkLog.shift();

                            xhr.addEventListener('loadend', function() {
                                entry.status = xhr.status;
                                entry.duration = Date.now() - entry.startTime;
                            });
                            return originalSend.apply(xhr, arguments);
                        };
                        return xhr;
                    };
                },

                // Get console log
                getConsoleLog: function() {
                    return this._consoleLog.slice();
                },

                // Clear console log
                clearConsoleLog: function() {
                    this._consoleLog = [];
                },

                // Get network log
                getNetworkLog: function() {
                    return this._networkLog.slice();
                },

                // Clear network log
                clearNetworkLog: function() {
                    this._networkLog = [];
                },

                // Get last error details
                getLastError: function() {
                    return this._lastError;
                },

                // Get call log (when debug mode is on)
                getCallLog: function() {
                    return this._callLog;
                },

                // Clear call log
                clearCallLog: function() {
                    this._callLog = [];
                },

                // Get full debug report
                getDebugReport: function() {
                    return {
                        enabled: this._debug,
                        lastError: this._lastError,
                        errorHistory: this._errorHistory.slice(-10),
                        callLog: this._callLog.slice(-20),
                        networkLog: this._networkLog.slice(-20),
                        consoleLog: this._consoleLog.slice(-50),
                        timestamp: Date.now()
                    };
                },

                // Internal: log bridge call
                _logCall: function(action, params) {
                    if (this._debug) {
                        var entry = {
                            action: action,
                            params: params,
                            timestamp: Date.now()
                        };
                        this._callLog.push(entry);
                        if (this._callLog.length > 100) this._callLog.shift();
                        console.log('[Craft] ' + action, params);
                    }
                },

                // Performance Profiling
                _profiling: false,
                _profilingData: null,
                _profilingCallTimings: [],

                startProfiling: function() {
                    this._profiling = true;
                    this._profilingData = {
                        startTime: Date.now(),
                        startMemory: null,
                        callTimings: [],
                        bridgeCalls: 0
                    };
                    this._profilingCallTimings = [];
                    // Request memory info from native
                    window.webkit.messageHandlers.craft.postMessage({action: 'getMemoryUsage', callbackId: '_profiling_start'});
                    console.log('[Craft] Profiling started');
                    return { started: true, timestamp: this._profilingData.startTime };
                },

                stopProfiling: function() {
                    var self = this;
                    if (!this._profiling || !this._profilingData) {
                        return Promise.resolve(null);
                    }
                    this._profiling = false;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'getMemoryUsage', callbackId: id});
                    return new Promise(function(resolve) {
                        self._callbacks[id] = {
                            resolve: function(memory) {
                                var report = {
                                    duration: Date.now() - self._profilingData.startTime,
                                    bridgeCalls: self._profilingCallTimings.length,
                                    callTimings: self._profilingCallTimings,
                                    memory: {
                                        start: self._profilingData.startMemory,
                                        end: memory
                                    },
                                    avgCallTime: self._profilingCallTimings.length > 0
                                        ? self._profilingCallTimings.reduce(function(a, b) { return a + b.duration; }, 0) / self._profilingCallTimings.length
                                        : 0
                                };
                                self._profilingData = null;
                                console.log('[Craft] Profiling stopped', report);
                                resolve(report);
                            },
                            reject: function() { resolve(null); }
                        };
                    });
                },

                _recordCallTiming: function(action, startTime, endTime) {
                    if (this._profiling) {
                        this._profilingCallTimings.push({
                            action: action,
                            startTime: startTime,
                            endTime: endTime,
                            duration: endTime - startTime
                        });
                    }
                },

                getProfilingData: function() {
                    if (!this._profilingData) return null;
                    return {
                        running: this._profiling,
                        duration: Date.now() - this._profilingData.startTime,
                        bridgeCalls: this._profilingCallTimings.length,
                        callTimings: this._profilingCallTimings
                    };
                },

                haptic: function(style) {
                    window.webkit.messageHandlers.craft.postMessage({action: 'haptic', style: style || 'medium'});
                },

                startListening: function() {
                    window.webkit.messageHandlers.craft.postMessage({action: 'startListening'});
                },

                stopListening: function() {
                    window.webkit.messageHandlers.craft.postMessage({action: 'stopListening'});
                },

                share: function(text) {
                    window.webkit.messageHandlers.craft.postMessage({action: 'share', text: text});
                },

                openCamera: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'openCamera', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                pickImage: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'pickImage', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                authenticate: function(reason) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'authenticate', reason: reason, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                registerPush: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'registerPush', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                secureStore: {
                    set: function(key, value) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'secureSet', key: key, value: value, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    get: function(key) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'secureGet', key: key, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    remove: function(key) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'secureRemove', key: key, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Geolocation
                geolocation: {
                    getCurrentPosition: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getCurrentPosition', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    watchPosition: function(callback) {
                        window.addEventListener('craftLocationUpdate', function(e) { callback(e.detail); });
                        window.webkit.messageHandlers.craft.postMessage({action: 'watchPosition'});
                    },
                    clearWatch: function() {
                        window.webkit.messageHandlers.craft.postMessage({action: 'clearWatch'});
                    }
                },

                // Clipboard
                clipboard: {
                    write: function(text) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'clipboardWrite', text: text, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    read: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'clipboardRead', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Device info
                getDeviceInfo: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'getDeviceInfo', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // App badge
                setBadge: function(count) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'setBadge', count: count, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },
                clearBadge: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'clearBadge', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Network
                getNetworkStatus: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'getNetworkStatus', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },
                onNetworkChange: function(callback) {
                    window.addEventListener('craftNetworkChange', function(e) { callback(e.detail); });
                },

                // App review
                requestReview: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'requestReview', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Flashlight
                setFlashlight: function(enabled) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'setFlashlight', enabled: enabled, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Vibrate
                vibrate: function(pattern) {
                    window.webkit.messageHandlers.craft.postMessage({action: 'vibrate', pattern: pattern});
                },

                // Open URL
                openURL: function(url) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'openURL', url: url, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // App state
                getAppState: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'getAppState', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Contacts
                contacts: {
                    getAll: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getContacts', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    add: function(contact) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'addContact', contact: contact, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Calendar
                calendar: {
                    getEvents: function(startDate, endDate) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getCalendarEvents', startDate: startDate, endDate: endDate, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    createEvent: function(event) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'createCalendarEvent', event: event, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    deleteEvent: function(eventId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'deleteCalendarEvent', eventId: eventId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Local Notifications
                notifications: {
                    schedule: function(notification) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'scheduleNotification', notification: notification, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    cancel: function(notificationId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'cancelNotification', id: notificationId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    cancelAll: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'cancelAllNotifications', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    getPending: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getPendingNotifications', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // In-App Purchase
                iap: {
                    getProducts: function(productIds) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getProducts', productIds: productIds, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    purchase: function(productId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'purchase', productId: productId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    restore: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'restorePurchases', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Keep Awake
                setKeepAwake: function(enabled) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'setKeepAwake', enabled: enabled, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Orientation Lock
                lockOrientation: function(orientation) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'lockOrientation', orientation: orientation, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },
                unlockOrientation: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'unlockOrientation', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Deep Links
                onDeepLink: function(callback) {
                    window.addEventListener('craftDeepLink', function(e) { callback(e.detail); });
                },

                // Background Tasks
                backgroundTask: {
                    register: function(taskId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'registerBackgroundTask', taskId: taskId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    schedule: function(taskId, options) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        options = options || {};
                        window.webkit.messageHandlers.craft.postMessage({
                            action: 'scheduleBackgroundTask',
                            taskId: taskId,
                            delay: options.delay || 900,
                            requiresNetwork: options.requiresNetwork || false,
                            requiresCharging: options.requiresCharging || false,
                            callbackId: id
                        });
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    cancel: function(taskId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'cancelBackgroundTask', taskId: taskId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    cancelAll: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'cancelAllBackgroundTasks', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // PDF Viewer
                openPDF: function(source, page) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'openPDF', source: source, page: page || 0, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },
                closePDF: function() {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'closePDF', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Contacts Picker
                pickContact: function(options) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    options = options || {};
                    window.webkit.messageHandlers.craft.postMessage({action: 'pickContact', multiple: options.multiple || false, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // App Shortcuts
                shortcuts: {
                    set: function(shortcuts) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'setShortcuts', shortcuts: shortcuts, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    clear: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'clearShortcuts', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onShortcut: function(callback) {
                        window.addEventListener('craftShortcut', function(e) { callback(e.detail); });
                    }
                },

                // Keychain Sharing
                sharedKeychain: {
                    set: function(key, value, group) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'setSharedItem', key: key, value: value, group: group || null, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    get: function(key, group) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getSharedItem', key: key, group: group || null, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    remove: function(key, group) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'removeSharedItem', key: key, group: group || null, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Local Auth Persistence
                authPersistence: {
                    enable: function(duration) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'setBiometricPersistence', enabled: true, duration: duration || 300, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    disable: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'setBiometricPersistence', enabled: false, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    check: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'checkBiometricPersistence', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    clear: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'clearBiometricPersistence', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // AR (ARKit)
                ar: {
                    start: function(options) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'startAR', options: options || {}, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    stop: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'stopAR', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    placeObject: function(model, position) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'placeARObject', model: model, position: position, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    removeObject: function(objectId) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'removeARObject', objectId: objectId, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    getPlanes: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getARPlanes', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onPlaneDetected: function(callback) {
                        window.addEventListener('craftARPlane', function(e) { callback(e.detail); });
                    }
                },

                // ML (Core ML / Vision)
                ml: {
                    classifyImage: function(imageBase64) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'classifyImage', image: imageBase64, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    detectObjects: function(imageBase64) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'detectObjects', image: imageBase64, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    recognizeText: function(imageBase64) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'recognizeText', image: imageBase64, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Widgets (WidgetKit)
                widget: {
                    update: function(data) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'updateWidget', data: data, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    reload: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'reloadWidgets', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Siri Shortcuts
                siri: {
                    register: function(phrase, action) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'registerSiriShortcut', phrase: phrase, action: action, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    remove: function(action) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'removeSiriShortcut', action: action, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onInvoke: function(callback) {
                        window.addEventListener('craftSiriShortcut', function(e) { callback(e.detail); });
                    }
                },

                // Watch Connectivity
                watch: {
                    send: function(message) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'sendToWatch', message: message, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    updateContext: function(context) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'updateWatchContext', context: context, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onMessage: function(callback) {
                        window.addEventListener('craftWatchMessage', function(e) { callback(e.detail); });
                    },
                    onReachabilityChange: function(callback) {
                        window.addEventListener('craftWatchReachability', function(e) { callback(e.detail); });
                    },
                    isReachable: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'isWatchReachable', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
                },

                // Deep Links
                deepLinks: {
                    getInitialURL: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getInitialURL', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onLink: function(callback) {
                        window.addEventListener('craftDeepLink', function(e) { callback(e.detail); });
                    }
                },

                // OTA Updates
                ota: {
                    _config: null,
                    _status: 'idle',
                    _progressCallbacks: [],
                    _statusCallbacks: [],

                    // OTA is not implemented natively. These five used to post
                    // to actions the switch below does not handle, and register
                    // a resolve/reject pair that nothing would ever call — they
                    // also bypassed _createCallback, which is what owns the 30s
                    // timeout, so the promises hung forever rather than
                    // rejecting. An immediate rejection is the honest answer:
                    // an app can catch it, where it could never catch a hang.
                    _unavailable: function(name) {
                        return Promise.reject(new Error(
                            'craft.ota.' + name + ' is not implemented on this platform'
                        ));
                    },
                    configure: function(options) {
                        this._config = options;
                        console.warn('[craft] ota.configure stored locally; OTA is not implemented natively');
                    },
                    checkForUpdate: function() {
                        return window.craft.ota._unavailable('checkForUpdate');
                    },
                    downloadUpdate: function(options) {
                        return window.craft.ota._unavailable('downloadUpdate');
                    },
                    applyUpdate: function() {
                        return window.craft.ota._unavailable('applyUpdate');
                    },
                    rollback: function() {
                        return window.craft.ota._unavailable('rollback');
                    },
                    getCurrentBundle: function() {
                        // This returns synchronously from stored data
                        return window.craft.ota._currentBundle || {
                            version: '1.0.0',
                            buildNumber: 1,
                            hash: '',
                            isOriginal: true,
                            installedAt: ''
                        };
                    },
                    onProgress: function(callback) {
                        this._progressCallbacks.push(callback);
                        window.addEventListener('craftOTAProgress', function(e) { callback(e.detail); });
                    },
                    onStatusChange: function(callback) {
                        this._statusCallbacks.push(callback);
                        window.addEventListener('craftOTAStatus', function(e) { callback(e.detail.status); });
                    }
                },

                log: function(msg) {
                    window.webkit.messageHandlers.craft.postMessage({action: 'log', message: msg});
                }
            };

            // Stable, versioned mobile contract consumed by craft-native/mobile.
            // Legacy flat methods remain available while every public SDK method
            // is routed through this nested contract.
            (function installCraftMobileContract(craft) {
                var legacyShare = craft.share.bind(craft);
                var legacyOpenCamera = craft.openCamera.bind(craft);
                var legacyPickImage = craft.pickImage.bind(craft);
                var legacyAuthenticate = craft.authenticate.bind(craft);
                var legacySecureStore = craft.secureStore;
                var legacyGeolocation = craft.geolocation;
                var legacyNotifications = craft.notifications;

                craft.contractVersion = '1.0.0';
                craft._invoke = function(action, payload) {
                    var self = craft;
                    var id = 'cb_' + (++self._callbackId);
                    var message = Object.assign({}, payload || {}, {action: action, callbackId: id});
                    window.webkit.messageHandlers.craft.postMessage(message);
                    return new Promise(function(resolve, reject) {
                        var timeout = setTimeout(function() {
                            delete self._callbacks[id];
                            reject(new Error('Craft bridge timed out: ' + action));
                        }, 30000);
                        self._callbacks[id] = {
                            resolve: function(value) { clearTimeout(timeout); resolve(value); },
                            reject: function(error) { clearTimeout(timeout); reject(error); }
                        };
                    });
                };

                craft.device = {
                    getInfo: function() { return craft.getDeviceInfo(); },
                    getCapabilities: function() { return Promise.resolve(Object.assign({}, craft.capabilities)); }
                };
                craft.haptics = {
                    impact: function(style) { craft.haptic(style || 'medium'); return Promise.resolve(); },
                    notification: function(type) {
                        craft.haptic(type === 'error' ? 'heavy' : type === 'warning' ? 'medium' : 'light');
                        return Promise.resolve();
                    },
                    selection: function() { craft.haptic('soft'); return Promise.resolve(); },
                    vibrate: function(pattern) { craft.vibrate(pattern || []); return Promise.resolve(); }
                };
                craft.permissions = {
                    check: function(permission) { return craft._invoke('checkPermission', {permission: permission}); },
                    request: function(permission) { return craft._invoke('requestPermission', {permission: permission}); },
                    openSettings: function() { return craft._invoke('openSettings'); }
                };
                craft.camera = {
                    takePicture: function() { return legacyOpenCamera().then(normalizePhoto); },
                    pickImage: function() { return legacyPickImage().then(normalizePhoto); },
                    pickMultiple: function() { return legacyPickImage().then(function(photo) { return [normalizePhoto(photo)]; }); },
                    isAvailable: function() { return Promise.resolve(!!craft.capabilities.camera); }
                };
                craft.biometrics = {
                    isAvailable: function() { return Promise.resolve(!!craft.capabilities.biometric); },
                    getBiometricType: function() { return Promise.resolve(craft.capabilities.biometric ? 'faceId' : null); },
                    authenticate: function(reason) { return legacyAuthenticate(reason); }
                };
                craft.secureStorage = {
                    set: function(key, value) { return legacySecureStore.set(key, value).then(function() {}); },
                    get: function(key) { return legacySecureStore.get(key); },
                    delete: function(key) { return legacySecureStore.remove(key).then(function() {}); },
                    clear: function() { return craft._invoke('secureClear').then(function() {}); }
                };

                var locationWatchCallbacks = new Map();
                var nextLocationWatchId = 0;
                window.addEventListener('craftLocationUpdate', function(event) {
                    locationWatchCallbacks.forEach(function(callback) { callback(event.detail); });
                });
                craft.location = {
                    getCurrentPosition: function(options) { return legacyGeolocation.getCurrentPosition(options || {}); },
                    watchPosition: function(callback) {
                        var id = ++nextLocationWatchId;
                        locationWatchCallbacks.set(id, callback);
                        if (locationWatchCallbacks.size === 1) void craft._invoke('watchPosition');
                        return id;
                    },
                    clearWatch: function(id) {
                        locationWatchCallbacks.delete(id);
                        if (locationWatchCallbacks.size === 0) {
                            window.webkit.messageHandlers.craft.postMessage({action: 'clearWatch'});
                        }
                    },
                    startRecording: function() { return craft._invoke('startLocationRecording'); },
                    pauseRecording: function() { return craft._invoke('pauseLocationRecording'); },
                    resumeRecording: function() { return craft._invoke('resumeLocationRecording'); },
                    stopRecording: function() { return craft._invoke('stopLocationRecording'); },
                    getRecordingState: function() { return craft._invoke('getLocationRecordingState'); },
                    readRecording: function() { return craft._invoke('readLocationRecording'); }
                };
                craft.health = {
                    requestAuthorization: function(types) { return craft._invoke('requestHealthAuthorization', {types: types || []}); },
                    getData: function(type, options) {
                        options = options || {};
                        return craft._invoke('getHealthData', {type: type, startDate: options.startDate, endDate: options.endDate});
                    },
                    saveWorkout: function(workout) { return craft._invoke('saveHealthWorkout', workout || {}); }
                };
                craft.liveActivity = {
                    start: function(options) { return craft._invoke('startLiveActivity', options || {}); },
                    update: function(options) { return craft._invoke('updateLiveActivity', options || {}); },
                    end: function() { return craft._invoke('endLiveActivity'); }
                };
                var shareApi = function(text) { return legacyShare(text); };
                shareApi.share = function(options) { return craft._invoke('share', {options: options || {}}); };
                craft.share = shareApi;
                craft.lifecycle = {
                    getState: function() { return document.visibilityState === 'visible' ? 'active' : 'background'; },
                    onStateChange: function(callback) {
                        var handler = function() { callback(document.visibilityState === 'visible' ? 'active' : 'background'); };
                        document.addEventListener('visibilitychange', handler);
                        return function() { document.removeEventListener('visibilitychange', handler); };
                    }
                };
                craft.notifications = Object.assign({}, legacyNotifications, {
                    show: function(options) {
                        return legacyNotifications.schedule(Object.assign({}, options || {}, {scheduleAt: Date.now()}));
                    },
                    setBadge: function(count) { return craft.setBadge(count).then(function() {}); }
                });

                function normalizePhoto(photo) {
                    if (photo && typeof photo === 'object') return photo;
                    var base64 = String(photo || '');
                    return {base64: base64, uri: 'data:image/jpeg;base64,' + base64, width: 0, height: 0, mimeType: 'image/jpeg'};
                }
            })(window.craft);

            // Dispatch ready event
            window.dispatchEvent(new CustomEvent('craftReady', {detail: window.craft}));
            console.log('Craft iOS bridge initialized');
            """
            webView?.evaluateJavaScript(script)

            // Mark DeepLinkManager as ready
            DeepLinkManager.shared.setReady()
        }

        // MARK: - Callback Helpers
        private func resolveCallback(_ callbackId: String?, result: Any) {
            guard let id = callbackId else { return }
            let resultStr: String
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                resultStr = String(data: data, encoding: .utf8) ?? "null"
            } catch {
                rejectCallback(callbackId, error: "Native result could not be serialized", code: "SERIALIZATION_ERROR")
                return
            }
            let script = "window.craft._resolveCallback('\(id)', \(resultStr));"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(script, completionHandler: nil) }
        }

        private func resolveCallbackJSON(_ callbackId: String?, json: [String: Any]) {
            resolveCallback(callbackId, result: json)
        }

        private func rejectCallback(_ callbackId: String?, error: String, code: String = "CRAFT_ERROR") {
            guard let id = callbackId else { return }
            let escapedError = error.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
            let script = "window.craft._rejectCallback('\(id)', '\(escapedError)', '\(code)');"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(script, completionHandler: nil) }
        }

        /// Enhanced reject with native stack trace (for debug mode)
        private func rejectCallbackWithStack(_ callbackId: String?, error: String, code: String = "CRAFT_ERROR", file: String = #file, function: String = #function, line: Int = #line) {
            guard let id = callbackId else { return }
            let escapedError = error.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
            let fileName = (file as NSString).lastPathComponent
            let stackTrace = "\(fileName):\(line) in \(function)"
            let escapedStack = stackTrace.replacingOccurrences(of: "'", with: "\\'")
            let script = "window.craft._rejectCallbackWithStack('\(id)', '\(escapedError)', '\(code)', '\(escapedStack)');"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(script, completionHandler: nil) }
        }

        // MARK: - Speech Recognition
        private func startSpeechRecognition() {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard status == .authorized else {
                    self?.sendToWeb("craftSpeechError", data: ["error": "Not authorized"])
                    return
                }
                DispatchQueue.main.async { self?.beginRecording() }
            }
        }

        private func beginRecording() {
            if recognitionTask != nil {
                recognitionTask?.cancel()
                recognitionTask = nil
            }

            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                sendToWeb("craftSpeechError", data: ["error": "Audio session failed"])
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest,
                  let speechRecognizer = speechRecognizer,
                  speechRecognizer.isAvailable else {
                sendToWeb("craftSpeechError", data: ["error": "Speech recognizer unavailable"])
                return
            }

            recognitionRequest.shouldReportPartialResults = true
            let inputNode = audioEngine.inputNode

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    let transcript = result.bestTranscription.formattedString
                    self?.sendToWeb("craftSpeechResult", data: [
                        "transcript": transcript,
                        "isFinal": result.isFinal
                    ])
                }
                if error != nil || result?.isFinal == true {
                    self?.stopSpeechRecognition()
                }
            }

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
                sendToWeb("craftSpeechStart", data: [:])
                triggerHaptic(style: "light")
            } catch {
                sendToWeb("craftSpeechError", data: ["error": "Audio engine failed"])
            }
        }

        private func stopSpeechRecognition() {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            sendToWeb("craftSpeechEnd", data: [:])
            triggerHaptic(style: "light")
        }

        // MARK: - Haptics
        private func triggerHaptic(style: String) {
            switch style {
            case "light":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "heavy":
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error":
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection":
                UISelectionFeedbackGenerator().selectionChanged()
            default:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        // MARK: - Share
        private func share(options: [String: Any], callbackId: String?) {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                rejectCallback(callbackId, error: "Unable to present the share sheet")
                return
            }
            var items: [Any] = []
            if let title = options["title"] as? String, !title.isEmpty { items.append(title) }
            if let text = options["text"] as? String, !text.isEmpty { items.append(text) }
            if let urlString = options["url"] as? String, let url = URL(string: urlString) { items.append(url) }
            if let files = options["files"] as? [String] {
                for file in files {
                    if let url = URL(string: file), url.isFileURL { items.append(url) }
                    else if FileManager.default.fileExists(atPath: file) { items.append(URL(fileURLWithPath: file)) }
                }
            }
            guard !items.isEmpty else {
                rejectCallback(callbackId, error: "Nothing to share", code: "INVALID_ARGUMENT")
                return
            }
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, completed, _, error in
                if let error = error {
                    self.rejectCallback(callbackId, error: error.localizedDescription, code: "SHARE_ERROR")
                } else {
                    self.resolveCallback(callbackId, result: completed)
                }
            }
            rootVC.present(activityVC, animated: true)
        }

        // MARK: - Camera & Photo Library
        private func openCamera() {
            DispatchQueue.main.async {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    self.rejectCallback(self.pendingCallbackId, error: "Camera not available")
                    return
                }
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }

                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.delegate = self
                rootVC.present(picker, animated: true)
            }
        }

        private func pickImage() {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }

                let picker = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.delegate = self
                rootVC.present(picker, animated: true)
            }
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true)

            if let image = info[.originalImage] as? UIImage,
               let imageData = image.jpegData(compressionQuality: 0.8) {
                let base64 = imageData.base64EncodedString()
                resolveCallback(pendingCallbackId, result: [
                    "base64": base64,
                    "uri": "data:image/jpeg;base64," + base64,
                    "width": image.size.width,
                    "height": image.size.height,
                    "mimeType": "image/jpeg",
                ])
            } else {
                rejectCallback(pendingCallbackId, error: "Failed to process image")
            }
            pendingCallbackId = nil
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            rejectCallback(pendingCallbackId, error: "Cancelled")
            pendingCallbackId = nil
        }

        // MARK: - Biometric Authentication
        private func authenticate(reason: String, callbackId: String?) {
            let context = LAContext()
            var error: NSError?

            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, authError in
                    DispatchQueue.main.async {
                        if success {
                            self?.resolveCallback(callbackId, result: true)
                        } else {
                            self?.rejectCallback(callbackId, error: authError?.localizedDescription ?? "Authentication failed")
                        }
                    }
                }
            } else {
                rejectCallback(callbackId, error: error?.localizedDescription ?? "Biometric not available")
            }
        }

        // MARK: - Push Notifications
        private func registerPushNotifications(callbackId: String?) {
            pendingPushCallbackId = callbackId
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                } else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    self?.pendingPushCallbackId = nil
                }
            }
        }

        @objc private func receivePushToken(_ notification: Notification) {
            guard let token = notification.object as? String else { return }
            resolveCallback(pendingPushCallbackId, result: token)
            pendingPushCallbackId = nil
            sendToWeb("craftPushToken", data: ["token": token])
        }

        @objc private func receivePushRegistrationError(_ notification: Notification) {
            let message = notification.object as? String ?? "Push registration failed"
            rejectCallback(pendingPushCallbackId, error: message, code: "PUSH_REGISTRATION_ERROR")
            pendingPushCallbackId = nil
        }

        @objc private func receiveNotificationResponse(_ notification: Notification) {
            let data = notification.object as? [String: Any] ?? [:]
            sendToWeb("craftNotificationResponse", data: data)
        }

        // MARK: - Secure Storage (Keychain)
        private func secureStore(key: String, value: String) -> Bool {
            let data = value.data(using: .utf8)!
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            SecItemDelete(query as CFDictionary)
            let status = SecItemAdd(query as CFDictionary, nil)
            return status == errSecSuccess
        }

        private func secureRetrieve(key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }

        private func secureRemove(key: String) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key
            ]
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        private func secureClear() -> Bool {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        // MARK: - Permissions
        private func permissionStatus(_ granted: Bool?, denied: Bool = false, restricted: Bool = false) -> String {
            if restricted { return "restricted" }
            if denied { return "denied" }
            guard let granted = granted else { return "undetermined" }
            return granted ? "granted" : "undetermined"
        }

        private func checkPermission(_ permission: String?, callbackId: String?) {
            guard let permission = permission else {
                rejectCallback(callbackId, error: "Missing permission", code: "INVALID_ARGUMENT")
                return
            }
            switch permission {
            case "location", "locationAlways":
                let status = CLLocationManager.authorizationStatus()
                let granted = status == .authorizedAlways || (permission == "location" && status == .authorizedWhenInUse)
                resolveCallback(callbackId, result: permissionStatus(granted, denied: status == .denied, restricted: status == .restricted))
            case "camera":
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                resolveCallback(callbackId, result: permissionStatus(status == .authorized, denied: status == .denied, restricted: status == .restricted))
            case "microphone":
                let status = AVAudioSession.sharedInstance().recordPermission
                resolveCallback(callbackId, result: permissionStatus(status == .granted, denied: status == .denied))
            case "photos":
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                resolveCallback(callbackId, result: permissionStatus(status == .authorized || status == .limited, denied: status == .denied, restricted: status == .restricted))
            case "contacts":
                let status = CNContactStore.authorizationStatus(for: .contacts)
                resolveCallback(callbackId, result: permissionStatus(status == .authorized, denied: status == .denied, restricted: status == .restricted))
            case "calendar", "reminders":
                let entity: EKEntityType = permission == "calendar" ? .event : .reminder
                let status = EKEventStore.authorizationStatus(for: entity)
                resolveCallback(callbackId, result: permissionStatus(status == .authorized || status.rawValue >= 4, denied: status == .denied, restricted: status == .restricted))
            case "motion":
                let status = CMMotionActivityManager.authorizationStatus()
                resolveCallback(callbackId, result: permissionStatus(status == .authorized, denied: status == .denied, restricted: status == .restricted))
            case "bluetooth":
                let status = CBManager.authorization
                resolveCallback(callbackId, result: permissionStatus(status == .allowedAlways, denied: status == .denied, restricted: status == .restricted))
            case "notifications":
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let status: String
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral: status = "granted"
                    case .denied: status = "denied"
                    case .notDetermined: status = "undetermined"
                    @unknown default: status = "undetermined"
                    }
                    self.resolveCallback(callbackId, result: status)
                }
            default:
                resolveCallback(callbackId, result: "undetermined")
            }
        }

        private func requestPermission(_ permission: String?, callbackId: String?) {
            guard let permission = permission else {
                rejectCallback(callbackId, error: "Missing permission", code: "INVALID_ARGUMENT")
                return
            }
            switch permission {
            case "location", "locationAlways":
                locationPermissionCallbackId = callbackId
                if permission == "locationAlways" || config.enableBackgroundLocation {
                    locationManager?.requestAlwaysAuthorization()
                } else {
                    locationManager?.requestWhenInUseAuthorization()
                }
            case "camera":
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                }
            case "microphone":
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                }
            case "photos":
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    self.resolveCallback(callbackId, result: status == .authorized || status == .limited ? "granted" : "denied")
                }
            case "contacts":
                (contactStore ?? CNContactStore()).requestAccess(for: .contacts) { granted, _ in
                    self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                }
            case "calendar", "reminders":
                let store = eventStore ?? EKEventStore()
                let entity: EKEntityType = permission == "calendar" ? .event : .reminder
                if #available(iOS 17.0, *) {
                    if permission == "calendar" {
                        store.requestFullAccessToEvents { granted, _ in
                            self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                        }
                    } else {
                        store.requestFullAccessToReminders { granted, _ in
                            self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                        }
                    }
                } else {
                    store.requestAccess(to: entity) { granted, _ in
                        self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                    }
                }
            case "notifications":
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    self.resolveCallback(callbackId, result: granted ? "granted" : "denied")
                }
            default:
                resolveCallback(callbackId, result: "undetermined")
            }
        }

        // MARK: - Geolocation
        private func getCurrentPosition(callbackId: String?) {
            locationManager?.delegate = self
            singleLocationCallbackId = callbackId
            requestLocationAuthorization()
            locationManager?.requestLocation()
        }

        private func watchPosition(callbackId: String?) {
            locationManager?.delegate = self
            isWatchingLocation = true
            requestLocationAuthorization()
            configureBackgroundLocationIfNeeded()
            locationManager?.startUpdatingLocation()
            resolveCallback(callbackId, result: true)
        }

        private func stopWatchingPosition() {
            isWatchingLocation = false
            if !isRecordingLocation {
                locationManager?.stopUpdatingLocation()
                locationManager?.allowsBackgroundLocationUpdates = false
            }
        }

        private var locationRecordingStateURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("craft-location-recording-state.json")
        }

        private var locationRecordingTrackURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("craft-location-recording.jsonl")
        }

        private func requestLocationAuthorization() {
            if config.enableBackgroundLocation {
                locationManager?.requestAlwaysAuthorization()
            } else {
                locationManager?.requestWhenInUseAuthorization()
            }
        }

        private func configureBackgroundLocationIfNeeded() {
            locationManager?.allowsBackgroundLocationUpdates = config.enableBackgroundLocation
            locationManager?.showsBackgroundLocationIndicator = config.enableBackgroundLocation
        }

        private func persistLocationRecordingState() {
            let state: [String: Any] = [
                "active": isRecordingLocation,
                "paused": isLocationRecordingPaused,
                "id": locationRecordingId ?? NSNull(),
                "startedAt": locationRecordingStartedAt ?? NSNull(),
            ]
            do {
                let directory = locationRecordingStateURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: state)
                try data.write(to: locationRecordingStateURL, options: .atomic)
                protectLocationFile(locationRecordingStateURL)
            } catch {
                print("Unable to persist location recording state: \(error)")
            }
        }

        private func restoreLocationRecordingState() {
            guard let data = try? Data(contentsOf: locationRecordingStateURL),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  state["active"] as? Bool == true else { return }
            isRecordingLocation = true
            isLocationRecordingPaused = state["paused"] as? Bool ?? false
            locationRecordingId = state["id"] as? String
            locationRecordingStartedAt = state["startedAt"] as? TimeInterval
            if !isLocationRecordingPaused {
                locationManager?.delegate = self
                configureBackgroundLocationIfNeeded()
                locationManager?.startUpdatingLocation()
            }
        }

        private func startLocationRecording(callbackId: String?) {
            let directory = locationRecordingTrackURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: locationRecordingTrackURL, options: .atomic)
                protectLocationFile(locationRecordingTrackURL)
            } catch {
                rejectCallback(callbackId, error: "Unable to create the location recording", code: "RECORDING_STORAGE_ERROR")
                return
            }
            locationRecordingId = UUID().uuidString
            locationRecordingStartedAt = Date().timeIntervalSince1970 * 1000
            isRecordingLocation = true
            isLocationRecordingPaused = false
            persistLocationRecordingState()
            locationManager?.delegate = self
            requestLocationAuthorization()
            configureBackgroundLocationIfNeeded()
            locationManager?.startUpdatingLocation()
            resolveCallback(callbackId, result: locationRecordingSummary())
        }

        private func pauseLocationRecording(callbackId: String?) {
            guard isRecordingLocation else {
                rejectCallback(callbackId, error: "No active location recording", code: "NO_ACTIVE_RECORDING")
                return
            }
            isLocationRecordingPaused = true
            persistLocationRecordingState()
            if !isWatchingLocation { locationManager?.stopUpdatingLocation() }
            resolveCallback(callbackId, result: locationRecordingSummary())
        }

        private func resumeLocationRecording(callbackId: String?) {
            guard isRecordingLocation else {
                rejectCallback(callbackId, error: "No active location recording", code: "NO_ACTIVE_RECORDING")
                return
            }
            isLocationRecordingPaused = false
            persistLocationRecordingState()
            requestLocationAuthorization()
            configureBackgroundLocationIfNeeded()
            locationManager?.startUpdatingLocation()
            resolveCallback(callbackId, result: locationRecordingSummary())
        }

        private func stopLocationRecording(callbackId: String?) {
            isRecordingLocation = false
            isLocationRecordingPaused = false
            persistLocationRecordingState()
            if !isWatchingLocation {
                locationManager?.stopUpdatingLocation()
                locationManager?.allowsBackgroundLocationUpdates = false
            }
            let locations = loadRecordedLocations()
            var summary = locationRecordingSummary()
            summary["locations"] = locations
            resolveCallback(callbackId, result: summary)
        }

        private func getLocationRecordingState(callbackId: String?) {
            var summary = locationRecordingSummary()
            summary["sampleCount"] = loadRecordedLocations().count
            resolveCallback(callbackId, result: summary)
        }

        private func readLocationRecording(callbackId: String?) {
            resolveCallback(callbackId, result: loadRecordedLocations())
        }

        private func locationRecordingSummary() -> [String: Any] {
            [
                "id": locationRecordingId ?? NSNull(),
                "active": isRecordingLocation,
                "paused": isLocationRecordingPaused,
                "startedAt": locationRecordingStartedAt ?? NSNull(),
            ]
        }

        private func appendRecordedLocation(_ data: [String: Any]) {
            guard isRecordingLocation && !isLocationRecordingPaused,
                  let json = try? JSONSerialization.data(withJSONObject: data) else { return }
            var line = json
            line.append(0x0A)
            do {
                let handle = try FileHandle(forWritingTo: locationRecordingTrackURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch {
                print("Unable to append location sample: \(error)")
            }
        }

        private func protectLocationFile(_ url: URL) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = url
            try? protectedURL.setResourceValues(values)
        }

        private func loadRecordedLocations() -> [[String: Any]] {
            guard let text = try? String(contentsOf: locationRecordingTrackURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last else { return }
            let data: [String: Any] = [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "altitude": location.altitude,
                "accuracy": location.horizontalAccuracy,
                "altitudeAccuracy": location.verticalAccuracy,
                "heading": location.course,
                "speed": location.speed,
                "timestamp": location.timestamp.timeIntervalSince1970 * 1000
            ]

            if let callbackId = singleLocationCallbackId {
                resolveCallback(callbackId, result: data)
                singleLocationCallbackId = nil
            }

            appendRecordedLocation(data)
            if isWatchingLocation || isRecordingLocation {
                sendToWeb("craftLocationUpdate", data: data)
            }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            rejectCallback(singleLocationCallbackId, error: error.localizedDescription)
            singleLocationCallbackId = nil
            sendToWeb("craftLocationError", data: ["message": error.localizedDescription])
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard let callbackId = locationPermissionCallbackId else { return }
            let status = manager.authorizationStatus
            if status == .notDetermined { return }
            let granted = status == .authorizedAlways || status == .authorizedWhenInUse
            resolveCallback(callbackId, result: permissionStatus(granted, denied: status == .denied, restricted: status == .restricted))
            locationPermissionCallbackId = nil
        }

        // MARK: - Memory Usage (for Profiling)
        private func getMemoryUsage(callbackId: String?) {
            var taskInfo = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }

            if kerr == KERN_SUCCESS {
                let usedMB = Double(taskInfo.resident_size) / 1024.0 / 1024.0
                let info: [String: Any] = [
                    "usedMB": round(usedMB * 100) / 100,
                    "residentSize": taskInfo.resident_size,
                    "virtualSize": taskInfo.virtual_size
                ]
                resolveCallbackJSON(callbackId, json: info)
            } else {
                resolveCallbackJSON(callbackId, json: ["usedMB": 0, "error": "Failed to get memory info"])
            }
        }

        // MARK: - Device Info
        private func getDeviceInfo(callbackId: String?) {
            let device = UIDevice.current
            let screen = UIScreen.main
            #if targetEnvironment(simulator)
            let isSimulator = true
            #else
            let isSimulator = false
            #endif
            let info: [String: Any] = [
                "platform": "ios",
                "model": device.model,
                "name": device.name,
                "systemName": device.systemName,
                "systemVersion": device.systemVersion,
                "identifierForVendor": device.identifierForVendor?.uuidString ?? "",
                "isSimulator": isSimulator,
                "screenWidth": screen.bounds.width,
                "screenHeight": screen.bounds.height,
                "screenScale": screen.scale,
                "batteryLevel": device.batteryLevel,
                "batteryState": getBatteryState(device.batteryState),
                "locale": Locale.current.identifier,
                "timezone": TimeZone.current.identifier
            ]
            resolveCallback(callbackId, result: info)
        }

        private func getBatteryState(_ state: UIDevice.BatteryState) -> String {
            switch state {
            case .charging: return "charging"
            case .full: return "full"
            case .unplugged: return "unplugged"
            default: return "unknown"
            }
        }

        // MARK: - App Badge
        private func setBadgeCount(_ count: Int, callbackId: String?) {
            UNUserNotificationCenter.current().requestAuthorization(options: .badge) { granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.applicationIconBadgeNumber = count
                        self.resolveCallback(callbackId, result: true)
                    }
                } else {
                    self.rejectCallback(callbackId, error: "Badge permission denied")
                }
            }
        }

        // MARK: - App Review
        private func requestAppReview() {
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    SKStoreReviewController.requestReview(in: windowScene)
                }
            }
        }

        // MARK: - Flashlight
        private func setFlashlight(enabled: Bool, callbackId: String?) {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
                rejectCallback(callbackId, error: "Flashlight not available")
                return
            }

            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                resolveCallback(callbackId, result: true)
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        // MARK: - Vibration Pattern
        private func vibratePattern(_ pattern: [Int]) {
            // iOS doesn't support custom vibration patterns like Android
            // We'll use haptic feedback instead
            for (index, duration) in pattern.enumerated() {
                if index % 2 == 0 && duration > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration) / 1000.0) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
            }
        }

        // MARK: - Contacts
        private func getContacts(callbackId: String?) {
            contactStore?.requestAccess(for: .contacts) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    return
                }

                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactIdentifierKey] as [CNKeyDescriptor]
                let request = CNContactFetchRequest(keysToFetch: keys)

                var contacts: [[String: Any]] = []
                do {
                    try self?.contactStore?.enumerateContacts(with: request) { contact, _ in
                        var phones: [String] = []
                        for phone in contact.phoneNumbers {
                            phones.append(phone.value.stringValue)
                        }
                        var emails: [String] = []
                        for email in contact.emailAddresses {
                            emails.append(email.value as String)
                        }
                        contacts.append([
                            "id": contact.identifier,
                            "givenName": contact.givenName,
                            "familyName": contact.familyName,
                            "displayName": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
                            "phoneNumbers": phones,
                            "emailAddresses": emails
                        ])
                    }
                    self?.resolveCallback(callbackId, result: contacts)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func addContact(_ data: [String: Any], callbackId: String?) {
            contactStore?.requestAccess(for: .contacts) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: "Permission denied")
                    return
                }

                let contact = CNMutableContact()
                if let givenName = data["givenName"] as? String { contact.givenName = givenName }
                if let familyName = data["familyName"] as? String { contact.familyName = familyName }
                if let phone = data["phone"] as? String {
                    contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
                }
                if let email = data["email"] as? String {
                    contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
                }

                let saveRequest = CNSaveRequest()
                saveRequest.add(contact, toContainerWithIdentifier: nil)

                do {
                    try self?.contactStore?.execute(saveRequest)
                    self?.resolveCallback(callbackId, result: contact.identifier)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        // MARK: - Calendar
        private func getCalendarEvents(startDate: Double?, endDate: Double?, callbackId: String?) {
            eventStore?.requestAccess(to: .event) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    return
                }

                let start = startDate != nil ? Date(timeIntervalSince1970: startDate! / 1000) : Date()
                let end = endDate != nil ? Date(timeIntervalSince1970: endDate! / 1000) : Calendar.current.date(byAdding: .month, value: 1, to: Date())!

                let predicate = self?.eventStore?.predicateForEvents(withStart: start, end: end, calendars: nil)
                let events = self?.eventStore?.events(matching: predicate!) ?? []

                let eventData: [[String: Any]] = events.map { event in
                    return [
                        "id": event.eventIdentifier ?? "",
                        "title": event.title ?? "",
                        "location": event.location ?? "",
                        "notes": event.notes ?? "",
                        "startDate": event.startDate.timeIntervalSince1970 * 1000,
                        "endDate": event.endDate.timeIntervalSince1970 * 1000,
                        "isAllDay": event.isAllDay
                    ]
                }

                self?.resolveCallback(callbackId, result: eventData)
            }
        }

        private func createCalendarEvent(_ data: [String: Any], callbackId: String?) {
            eventStore?.requestAccess(to: .event) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: "Permission denied")
                    return
                }

                let event = EKEvent(eventStore: self!.eventStore!)
                event.title = data["title"] as? String ?? ""
                event.location = data["location"] as? String
                event.notes = data["notes"] as? String

                if let start = data["startDate"] as? Double {
                    event.startDate = Date(timeIntervalSince1970: start / 1000)
                }
                if let end = data["endDate"] as? Double {
                    event.endDate = Date(timeIntervalSince1970: end / 1000)
                }
                event.isAllDay = data["isAllDay"] as? Bool ?? false
                event.calendar = self?.eventStore?.defaultCalendarForNewEvents

                do {
                    try self?.eventStore?.save(event, span: .thisEvent)
                    self?.resolveCallback(callbackId, result: event.eventIdentifier)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func deleteCalendarEvent(_ eventId: String, callbackId: String?) {
            guard let event = eventStore?.event(withIdentifier: eventId) else {
                rejectCallback(callbackId, error: "Event not found")
                return
            }

            do {
                try eventStore?.remove(event, span: .thisEvent)
                resolveCallback(callbackId, result: true)
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        // MARK: - Local Notifications
        private func scheduleLocalNotification(_ data: [String: Any], callbackId: String?) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: "Permission denied")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = data["title"] as? String ?? ""
                content.body = data["body"] as? String ?? ""
                if let subtitle = data["subtitle"] as? String { content.subtitle = subtitle }
                if let badge = data["badge"] as? Int { content.badge = NSNumber(value: badge) }
                content.sound = .default

                let id = data["id"] as? String ?? UUID().uuidString
                var trigger: UNNotificationTrigger?

                if let timestamp = data["timestamp"] as? Double {
                    let date = Date(timeIntervalSince1970: timestamp / 1000)
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                } else if let delay = data["delay"] as? Double {
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay / 1000, repeats: false)
                }

                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        self?.rejectCallback(callbackId, error: error.localizedDescription)
                    } else {
                        self?.resolveCallback(callbackId, result: id)
                    }
                }
            }
        }

        private func cancelLocalNotification(_ id: String, callbackId: String?) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
            resolveCallback(callbackId, result: true)
        }

        private func cancelAllLocalNotifications(callbackId: String?) {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            resolveCallback(callbackId, result: true)
        }

        private func getPendingNotifications(callbackId: String?) {
            UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
                let notifications: [[String: Any]] = requests.map { request in
                    return [
                        "id": request.identifier,
                        "title": request.content.title,
                        "body": request.content.body,
                        "subtitle": request.content.subtitle
                    ]
                }
                self?.resolveCallback(callbackId, result: notifications)
            }
        }

        // MARK: - In-App Purchase
        private func getProducts(_ productIds: [String], callbackId: String?) {
            Task {
                do {
                    let products = try await Product.products(for: Set(productIds))
                    let productData: [[String: Any]] = products.map { product in
                        return [
                            "id": product.id,
                            "displayName": product.displayName,
                            "description": product.description,
                            "price": product.price.description,
                            "displayPrice": product.displayPrice
                        ]
                    }
                    resolveCallback(callbackId, result: productData)
                } catch {
                    rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func purchaseProduct(_ productId: String, callbackId: String?) {
            Task {
                do {
                    let products = try await Product.products(for: [productId])
                    guard let product = products.first else {
                        rejectCallback(callbackId, error: "Product not found")
                        return
                    }

                    let result = try await product.purchase()
                    switch result {
                    case .success(let verification):
                        switch verification {
                        case .verified(let transaction):
                            await transaction.finish()
                            resolveCallback(callbackId, result: ["transactionId": String(transaction.id), "productId": transaction.productID])
                        case .unverified(_, let error):
                            rejectCallback(callbackId, error: error.localizedDescription)
                        }
                    case .userCancelled:
                        rejectCallback(callbackId, error: "User cancelled")
                    case .pending:
                        rejectCallback(callbackId, error: "Purchase pending")
                    @unknown default:
                        rejectCallback(callbackId, error: "Unknown result")
                    }
                } catch {
                    rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func restorePurchases(callbackId: String?) {
            Task {
                do {
                    try await AppStore.sync()
                    var restored: [[String: Any]] = []
                    for await result in Transaction.currentEntitlements {
                        if case .verified(let transaction) = result {
                            restored.append([
                                "transactionId": String(transaction.id),
                                "productId": transaction.productID
                            ])
                        }
                    }
                    resolveCallback(callbackId, result: restored)
                } catch {
                    rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        // MARK: - Keep Awake
        private func setKeepAwake(_ enabled: Bool, callbackId: String?) {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = enabled
                self.isKeepingAwake = enabled
                self.resolveCallback(callbackId, result: enabled)
            }
        }

        // MARK: - Orientation Lock
        private func lockOrientation(_ orientation: String, callbackId: String?) {
            var mask: UIInterfaceOrientationMask = .all
            var uiOrientation: UIInterfaceOrientation = .unknown

            switch orientation {
            case "portrait":
                mask = .portrait
                uiOrientation = .portrait
            case "portraitUpsideDown":
                mask = .portraitUpsideDown
                uiOrientation = .portraitUpsideDown
            case "landscapeLeft":
                mask = .landscapeLeft
                uiOrientation = .landscapeLeft
            case "landscapeRight":
                mask = .landscapeRight
                uiOrientation = .landscapeRight
            case "landscape":
                mask = .landscape
                uiOrientation = .landscapeLeft
            default:
                mask = .all
            }

            lockedOrientation = mask

            DispatchQueue.main.async {
                if #available(iOS 16.0, *) {
                    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                } else {
                    UIDevice.current.setValue(uiOrientation.rawValue, forKey: "orientation")
                }
                self.resolveCallback(callbackId, result: true)
            }
        }

        private func unlockOrientation(callbackId: String?) {
            lockedOrientation = nil
            DispatchQueue.main.async {
                if #available(iOS 16.0, *) {
                    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
                }
                self.resolveCallback(callbackId, result: true)
            }
        }

        // MARK: - Deep Links
        func handleDeepLink(_ url: URL) {
            pendingDeepLink = url
            sendToWeb("craftDeepLink", data: [
                "url": url.absoluteString,
                "scheme": url.scheme ?? "",
                "host": url.host ?? "",
                "path": url.path,
                "query": url.query ?? ""
            ])
        }

        // MARK: - QR/Barcode Scanner
        private func scanQRCode(callbackId: String?) {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }

                if #available(iOS 16.0, *) {
                    let scannerVC = DataScannerViewController(
                        recognizedDataTypes: [.barcode()],
                        qualityLevel: .balanced,
                        isHighlightingEnabled: true
                    )
                    scannerVC.delegate = self
                    self.pendingCallbackId = callbackId
                    rootVC.present(scannerVC, animated: true) {
                        try? scannerVC.startScanning()
                    }
                } else {
                    self.rejectCallback(callbackId, error: "QR scanning requires iOS 16+")
                }
            }
        }

        // MARK: - File Picker
        private func pickFile(types: [String]?, callbackId: String?) {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }

                var allowedTypes: [UTType] = [.item]
                if let types = types {
                    allowedTypes = types.compactMap { UTType(mimeType: $0) ?? UTType(filenameExtension: $0) }
                }

                let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
                picker.delegate = self
                picker.allowsMultipleSelection = false
                self.pendingCallbackId = callbackId
                rootVC.present(picker, animated: true)
            }
        }

        // MARK: - File Download
        private func downloadFile(url: String, filename: String, callbackId: String?) {
            guard let downloadURL = URL(string: url) else {
                rejectCallback(callbackId, error: "Invalid URL")
                return
            }

            let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] localURL, response, error in
                if let error = error {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                guard let localURL = localURL else {
                    self?.rejectCallback(callbackId, error: "Download failed")
                    return
                }

                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = documentsPath.appendingPathComponent(filename)

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: localURL, to: destinationURL)
                    self?.resolveCallback(callbackId, result: destinationURL.path)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
            task.resume()
        }

        private func saveFile(data: String, filename: String, callbackId: String?) {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsPath.appendingPathComponent(filename)

            do {
                if data.hasPrefix("data:") {
                    // Base64 data URL
                    let parts = data.components(separatedBy: ",")
                    if parts.count == 2, let fileData = Data(base64Encoded: parts[1]) {
                        try fileData.write(to: fileURL)
                    }
                } else {
                    // Plain text
                    try data.write(to: fileURL, atomically: true, encoding: .utf8)
                }
                resolveCallback(callbackId, result: fileURL.path)
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        // MARK: - Social Auth (Apple Sign In)
        private func signInWithApple(callbackId: String?) {
            DispatchQueue.main.async {
                self.pendingCallbackId = callbackId
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                request.requestedScopes = [.fullName, .email]

                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }

        // MARK: - Audio Recording
        private func startAudioRecording(callbackId: String?) {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard granted else {
                    self?.rejectCallback(callbackId, error: "Microphone permission denied")
                    return
                }

                DispatchQueue.main.async {
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
                    self?.recordingURL = audioFilename

                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]

                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
                        try AVAudioSession.sharedInstance().setActive(true)

                        self?.audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
                        self?.audioRecorder?.record()
                        self?.resolveCallback(callbackId, result: true)
                    } catch {
                        self?.rejectCallback(callbackId, error: error.localizedDescription)
                    }
                }
            }
        }

        private func stopAudioRecording(callbackId: String?) {
            audioRecorder?.stop()
            audioRecorder = nil

            if let url = recordingURL, FileManager.default.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url) {
                    let base64 = "data:audio/m4a;base64," + data.base64EncodedString()
                    resolveCallback(callbackId, result: base64)
                } else {
                    resolveCallback(callbackId, result: url.path)
                }
            } else {
                rejectCallback(callbackId, error: "No recording found")
            }
            recordingURL = nil
        }

        // MARK: - Video Recording
        private func startVideoRecording(callbackId: String?) {
            DispatchQueue.main.async {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    self.rejectCallback(callbackId, error: "Camera not available")
                    return
                }

                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }

                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.mediaTypes = ["public.movie"]
                picker.videoQuality = .typeMedium
                picker.delegate = self
                self.pendingCallbackId = callbackId
                rootVC.present(picker, animated: true)
            }
        }

        // MARK: - Motion Sensors
        private func startMotionUpdates(interval: Double, callbackId: String?) {
            guard let motionManager = motionManager, motionManager.isDeviceMotionAvailable else {
                rejectCallback(callbackId, error: "Motion sensors not available")
                return
            }

            let updateInterval = interval / 1000.0 // Convert ms to seconds
            motionManager.deviceMotionUpdateInterval = updateInterval

            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let motion = motion else { return }

                self?.sendToWeb("craftMotionUpdate", data: [
                    "acceleration": [
                        "x": motion.userAcceleration.x,
                        "y": motion.userAcceleration.y,
                        "z": motion.userAcceleration.z
                    ],
                    "rotation": [
                        "alpha": motion.attitude.yaw,
                        "beta": motion.attitude.pitch,
                        "gamma": motion.attitude.roll
                    ],
                    "gravity": [
                        "x": motion.gravity.x,
                        "y": motion.gravity.y,
                        "z": motion.gravity.z
                    ]
                ])
            }

            isMotionUpdating = true
            resolveCallback(callbackId, result: true)
        }

        private func stopMotionUpdates() {
            motionManager?.stopDeviceMotionUpdates()
            isMotionUpdating = false
        }

        // MARK: - Local Database (SQLite)
        private func dbExecute(sql: String, params: [Any]?, callbackId: String?) {
            guard let db = db else {
                rejectCallback(callbackId, error: "Database not initialized")
                return
            }

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                // Bind parameters
                if let params = params {
                    for (index, param) in params.enumerated() {
                        let idx = Int32(index + 1)
                        if let str = param as? String {
                            sqlite3_bind_text(statement, idx, str, -1, nil)
                        } else if let int = param as? Int {
                            sqlite3_bind_int(statement, idx, Int32(int))
                        } else if let double = param as? Double {
                            sqlite3_bind_double(statement, idx, double)
                        } else {
                            sqlite3_bind_null(statement, idx)
                        }
                    }
                }

                if sqlite3_step(statement) == SQLITE_DONE {
                    let rowsAffected = sqlite3_changes(db)
                    let lastInsertId = sqlite3_last_insert_rowid(db)
                    resolveCallback(callbackId, result: ["rowsAffected": rowsAffected, "lastInsertId": lastInsertId])
                } else {
                    let error = String(cString: sqlite3_errmsg(db))
                    rejectCallback(callbackId, error: error)
                }
            } else {
                let error = String(cString: sqlite3_errmsg(db))
                rejectCallback(callbackId, error: error)
            }
            sqlite3_finalize(statement)
        }

        private func dbQuery(sql: String, params: [Any]?, callbackId: String?) {
            guard let db = db else {
                rejectCallback(callbackId, error: "Database not initialized")
                return
            }

            var statement: OpaquePointer?
            var results: [[String: Any]] = []

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                // Bind parameters
                if let params = params {
                    for (index, param) in params.enumerated() {
                        let idx = Int32(index + 1)
                        if let str = param as? String {
                            sqlite3_bind_text(statement, idx, str, -1, nil)
                        } else if let int = param as? Int {
                            sqlite3_bind_int(statement, idx, Int32(int))
                        } else if let double = param as? Double {
                            sqlite3_bind_double(statement, idx, double)
                        } else {
                            sqlite3_bind_null(statement, idx)
                        }
                    }
                }

                let columnCount = sqlite3_column_count(statement)

                while sqlite3_step(statement) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    for i in 0..<columnCount {
                        let columnName = String(cString: sqlite3_column_name(statement, i))
                        let type = sqlite3_column_type(statement, i)

                        switch type {
                        case SQLITE_INTEGER:
                            row[columnName] = sqlite3_column_int(statement, i)
                        case SQLITE_FLOAT:
                            row[columnName] = sqlite3_column_double(statement, i)
                        case SQLITE_TEXT:
                            if let text = sqlite3_column_text(statement, i) {
                                row[columnName] = String(cString: text)
                            }
                        case SQLITE_NULL:
                            row[columnName] = NSNull()
                        default:
                            break
                        }
                    }
                    results.append(row)
                }

                resolveCallback(callbackId, result: results)
            } else {
                let error = String(cString: sqlite3_errmsg(db))
                rejectCallback(callbackId, error: error)
            }
            sqlite3_finalize(statement)
        }

        // MARK: - Bluetooth
        private func startBluetoothScan(callbackId: String?) {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            pendingCallbackId = callbackId
            // Scanning starts in centralManagerDidUpdateState
        }

        private func stopBluetoothScan() {
            centralManager?.stopScan()
            centralManager = nil
            discoveredPeripherals.removeAll()
        }

        // MARK: - NFC
        private func scanNFC(callbackId: String?) {
            guard NFCNDEFReaderSession.readingAvailable else {
                rejectCallback(callbackId, error: "NFC not available")
                return
            }

            pendingCallbackId = callbackId
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
            session.alertMessage = "Hold your iPhone near the NFC tag"
            session.begin()
        }

        // MARK: - Health
        private func requestHealthAuthorization(types: [String], callbackId: String?) {
            guard let healthStore = healthStore else {
                rejectCallback(callbackId, error: "HealthKit not available")
                return
            }

            var readTypes: Set<HKObjectType> = []
            var shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
            if let routeType = HKSeriesType.workoutRoute() as? HKSampleType {
                shareTypes.insert(routeType)
            }

            for type in types {
                switch type {
                case "steps":
                    if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                        readTypes.insert(stepType)
                    }
                case "heartRate":
                    if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                        readTypes.insert(heartType)
                    }
                case "activeEnergy":
                    if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                        readTypes.insert(energyType)
                        shareTypes.insert(energyType)
                    }
                case "distance":
                    if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
                        readTypes.insert(distanceType)
                        shareTypes.insert(distanceType)
                    }
                case "workouts":
                    readTypes.insert(HKObjectType.workoutType())
                default:
                    break
                }
            }

            healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] success, error in
                if success {
                    self?.resolveCallback(callbackId, result: true)
                } else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Authorization failed")
                }
            }
        }

        private func getHealthData(type: String, startDate: Double?, endDate: Double?, callbackId: String?) {
            guard let healthStore = healthStore else {
                rejectCallback(callbackId, error: "HealthKit not available")
                return
            }

            var quantityType: HKQuantityType?
            var unit: HKUnit?

            switch type {
            case "steps":
                quantityType = HKQuantityType.quantityType(forIdentifier: .stepCount)
                unit = .count()
            case "heartRate":
                quantityType = HKQuantityType.quantityType(forIdentifier: .heartRate)
                unit = HKUnit(from: "count/min")
            case "activeEnergy":
                quantityType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
                unit = .kilocalorie()
            case "distance":
                quantityType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
                unit = .meter()
            default:
                rejectCallback(callbackId, error: "Unknown health data type")
                return
            }

            guard let qType = quantityType, let qUnit = unit else {
                rejectCallback(callbackId, error: "Invalid health data type")
                return
            }

            let start = startDate != nil ? Date(timeIntervalSince1970: startDate! / 1000) : Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let end = endDate != nil ? Date(timeIntervalSince1970: endDate! / 1000) : Date()

            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: .cumulativeSum) { [weak self] _, result, error in
                if let error = error {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                let value = result?.sumQuantity()?.doubleValue(for: qUnit) ?? 0
                self?.resolveCallback(callbackId, result: ["value": value, "unit": qUnit.unitString])
            }

            healthStore.execute(query)
        }

        private func saveHealthWorkout(body: [String: Any], callbackId: String?) {
            guard let healthStore = healthStore else {
                rejectCallback(callbackId, error: "HealthKit not available")
                return
            }
            guard let activityId = body["activityId"] as? String,
                  let type = body["type"] as? String,
                  let startValue = body["startDate"] as? Double,
                  let endValue = body["endDate"] as? Double,
                  endValue > startValue else {
                rejectCallback(callbackId, error: "A valid activityId, type, startDate, and endDate are required")
                return
            }

            let activityType: HKWorkoutActivityType
            switch type {
            case "running": activityType = .running
            case "walking": activityType = .walking
            case "hiking": activityType = .hiking
            case "cycling": activityType = .cycling
            default:
                rejectCallback(callbackId, error: "Unsupported workout type")
                return
            }

            let distance = (body["distanceMeters"] as? Double).flatMap { value in
                value > 0 ? HKQuantity(unit: .meter(), doubleValue: value) : nil
            }
            let energy = (body["activeEnergyCalories"] as? Double).flatMap { value in
                value > 0 ? HKQuantity(unit: .kilocalorie(), doubleValue: value) : nil
            }
            let start = Date(timeIntervalSince1970: startValue / 1000)
            let end = Date(timeIntervalSince1970: endValue / 1000)
            let workout = HKWorkout(
                activityType: activityType,
                start: start,
                end: end,
                workoutEvents: nil,
                totalEnergyBurned: energy,
                totalDistance: distance,
                metadata: [HKMetadataKeyExternalUUID: activityId, HKMetadataKeyIndoorWorkout: false]
            )

            healthStore.save(workout) { [weak self] success, error in
                guard let self = self else { return }
                guard success else {
                    self.rejectCallback(callbackId, error: error?.localizedDescription ?? "Workout could not be saved")
                    return
                }

                let locations = (body["locations"] as? [[String: Any]] ?? []).compactMap { item -> CLLocation? in
                    guard let latitude = item["latitude"] as? Double,
                          let longitude = item["longitude"] as? Double,
                          let timestamp = item["timestamp"] as? Double else { return nil }
                    return CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        altitude: item["altitude"] as? Double ?? 0,
                        horizontalAccuracy: item["accuracy"] as? Double ?? 10,
                        verticalAccuracy: -1,
                        timestamp: Date(timeIntervalSince1970: timestamp / 1000)
                    )
                }.filter { $0.timestamp >= start && $0.timestamp <= end }

                guard !locations.isEmpty else {
                    self.resolveCallback(callbackId, result: ["id": workout.uuid.uuidString])
                    return
                }

                let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
                routeBuilder.insertRouteData(locations) { inserted, routeError in
                    guard inserted else {
                        self.rejectCallback(callbackId, error: routeError?.localizedDescription ?? "Workout route could not be saved")
                        return
                    }
                    routeBuilder.finishRoute(with: workout, metadata: [HKMetadataKeyExternalUUID: activityId]) { route, finishError in
                        if let finishError = finishError {
                            self.rejectCallback(callbackId, error: finishError.localizedDescription)
                        } else {
                            self.resolveCallback(callbackId, result: [
                                "id": workout.uuid.uuidString,
                                "routeId": route?.uuid.uuidString ?? ""
                            ])
                        }
                    }
                }
            }
        }

        // MARK: - Live Activities
        private func startLiveActivity(body: [String: Any], callbackId: String?) {
            guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
                rejectCallback(callbackId, error: "Live Activities are unavailable")
                return
            }
            let attributes = CraftActivityAttributes(
                activityId: body["activityId"] as? String ?? UUID().uuidString,
                title: body["title"] as? String ?? config.appName
            )
            let state = CraftActivityAttributes.ContentState(
                status: body["status"] as? String ?? "Recording",
                distanceMeters: body["distanceMeters"] as? Double ?? 0,
                durationSeconds: body["durationSeconds"] as? Double ?? 0,
                progress: min(max(body["progress"] as? Double ?? 0, 0), 1)
            )
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                resolveCallback(callbackId, result: ["id": activity.id])
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        private func updateLiveActivity(body: [String: Any], callbackId: String?) {
            guard #available(iOS 16.2, *), let activity = Activity<CraftActivityAttributes>.activities.first else {
                rejectCallback(callbackId, error: "No Live Activity is running")
                return
            }
            let current = activity.content.state
            let state = CraftActivityAttributes.ContentState(
                status: body["status"] as? String ?? current.status,
                distanceMeters: body["distanceMeters"] as? Double ?? current.distanceMeters,
                durationSeconds: body["durationSeconds"] as? Double ?? current.durationSeconds,
                progress: min(max(body["progress"] as? Double ?? current.progress, 0), 1)
            )
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
                resolveCallback(callbackId, result: ["updated": true])
            }
        }

        private func endLiveActivity(callbackId: String?) {
            guard #available(iOS 16.2, *), let activity = Activity<CraftActivityAttributes>.activities.first else {
                resolveCallback(callbackId, result: ["ended": false])
                return
            }
            Task {
                await activity.end(nil, dismissalPolicy: .default)
                resolveCallback(callbackId, result: ["ended": true])
            }
        }

        // MARK: - Screen Capture
        private func takeScreenshot(callbackId: String?) {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = windowScene.windows.first else {
                    self.rejectCallback(callbackId, error: "No window available")
                    return
                }

                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { context in
                    window.layer.render(in: context.cgContext)
                }

                if let imageData = image.pngData() {
                    let base64 = "data:image/png;base64," + imageData.base64EncodedString()
                    self.resolveCallback(callbackId, result: base64)
                } else {
                    self.rejectCallback(callbackId, error: "Failed to capture screenshot")
                }
            }
        }

        // MARK: - Background Tasks
        private var registeredBackgroundTasks: Set<String> = []

        private func registerBackgroundTask(taskId: String, callbackId: String?) {
            let fullTaskId = "\(Bundle.main.bundleIdentifier ?? "com.craft.app").\(taskId)"
            registeredBackgroundTasks.insert(fullTaskId)
            resolveCallback(callbackId, result: ["taskId": fullTaskId, "registered": true])
        }

        private func scheduleBackgroundTask(taskId: String, delay: Double, requiresNetwork: Bool, requiresCharging: Bool, callbackId: String?) {
            let fullTaskId = "\(Bundle.main.bundleIdentifier ?? "com.craft.app").\(taskId)"

            // Use BGAppRefreshTaskRequest for short tasks (default)
            let request = BGAppRefreshTaskRequest(identifier: fullTaskId)
            request.earliestBeginDate = Date(timeIntervalSinceNow: delay)

            do {
                try BGTaskScheduler.shared.submit(request)
                resolveCallback(callbackId, result: ["taskId": fullTaskId, "scheduled": true])
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        private func cancelBackgroundTask(taskId: String, callbackId: String?) {
            let fullTaskId = "\(Bundle.main.bundleIdentifier ?? "com.craft.app").\(taskId)"
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: fullTaskId)
            resolveCallback(callbackId, result: ["taskId": fullTaskId, "cancelled": true])
        }

        private func cancelAllBackgroundTasks(callbackId: String?) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            resolveCallback(callbackId, result: ["cancelled": true])
        }

        // MARK: - PDF Viewer
        private var pdfViewController: UIViewController?

        private func openPDF(source: String, page: Int, callbackId: String?) {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else {
                    self.rejectCallback(callbackId, error: "No root view controller")
                    return
                }

                var pdfDocument: PDFDocument?

                // Check if source is a URL or base64 data
                if source.hasPrefix("data:") {
                    // Base64 encoded PDF
                    let base64String = source.replacingOccurrences(of: "data:application/pdf;base64,", with: "")
                    if let data = Data(base64Encoded: base64String) {
                        pdfDocument = PDFDocument(data: data)
                    }
                } else if let url = URL(string: source) {
                    // URL - could be remote or local
                    pdfDocument = PDFDocument(url: url)
                }

                guard let document = pdfDocument else {
                    self.rejectCallback(callbackId, error: "Failed to load PDF")
                    return
                }

                let pdfView = PDFView(frame: .zero)
                pdfView.document = document
                pdfView.autoScales = true
                pdfView.displayMode = .singlePageContinuous
                pdfView.displayDirection = .vertical

                // Go to specific page if requested
                if page > 0, let targetPage = document.page(at: page) {
                    pdfView.go(to: targetPage)
                }

                let vc = UIViewController()
                vc.view = pdfView
                vc.view.backgroundColor = .systemBackground
                vc.modalPresentationStyle = .fullScreen

                // Add close button
                let closeButton = UIButton(type: .system)
                closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
                closeButton.tintColor = .systemGray
                closeButton.addTarget(self, action: #selector(self.dismissPDF), for: .touchUpInside)
                closeButton.translatesAutoresizingMaskIntoConstraints = false
                vc.view.addSubview(closeButton)

                NSLayoutConstraint.activate([
                    closeButton.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                    closeButton.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
                    closeButton.widthAnchor.constraint(equalToConstant: 32),
                    closeButton.heightAnchor.constraint(equalToConstant: 32)
                ])

                self.pdfViewController = vc
                rootVC.present(vc, animated: true)
                self.resolveCallback(callbackId, result: ["opened": true, "pageCount": document.pageCount])
            }
        }

        @objc private func dismissPDF() {
            pdfViewController?.dismiss(animated: true)
            pdfViewController = nil
        }

        private func closePDF(callbackId: String?) {
            DispatchQueue.main.async {
                self.pdfViewController?.dismiss(animated: true)
                self.pdfViewController = nil
                self.resolveCallback(callbackId, result: true)
            }
        }

        // MARK: - Contacts Picker
        private func pickContact(multiple: Bool, callbackId: String?) {
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else {
                    self.rejectCallback(callbackId, error: "No root view controller")
                    return
                }

                self.pendingCallbackId = callbackId

                let picker = CNContactPickerViewController()
                picker.delegate = self
                picker.predicateForEnablingContact = NSPredicate(value: true)

                if multiple {
                    picker.predicateForSelectionOfContact = nil
                } else {
                    picker.predicateForSelectionOfContact = NSPredicate(value: true)
                }

                rootVC.present(picker, animated: true)
            }
        }

        // MARK: - App Shortcuts
        private func setAppShortcuts(shortcuts: [[String: Any]], callbackId: String?) {
            var shortcutItems: [UIApplicationShortcutItem] = []

            for shortcut in shortcuts {
                guard let type = shortcut["type"] as? String,
                      let title = shortcut["title"] as? String else { continue }

                let subtitle = shortcut["subtitle"] as? String
                let iconName = shortcut["iconName"] as? String

                var icon: UIApplicationShortcutIcon?
                if let name = iconName {
                    icon = UIApplicationShortcutIcon(systemImageName: name)
                }

                let item = UIApplicationShortcutItem(
                    type: type,
                    localizedTitle: title,
                    localizedSubtitle: subtitle,
                    icon: icon,
                    userInfo: shortcut["userInfo"] as? [String: NSSecureCoding]
                )
                shortcutItems.append(item)
            }

            DispatchQueue.main.async {
                UIApplication.shared.shortcutItems = shortcutItems
                self.resolveCallback(callbackId, result: ["count": shortcutItems.count])
            }
        }

        private func clearAppShortcuts(callbackId: String?) {
            DispatchQueue.main.async {
                UIApplication.shared.shortcutItems = nil
                self.resolveCallback(callbackId, result: true)
            }
        }

        // MARK: - Keychain Sharing
        private func setSharedKeychainItem(key: String, value: String, group: String?, callbackId: String?) {
            let data = value.data(using: .utf8)!

            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]

            // Add access group if specified (requires Keychain Sharing entitlement)
            if let accessGroup = group {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            // Delete existing item first
            SecItemDelete(query as CFDictionary)

            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess {
                resolveCallback(callbackId, result: ["success": true, "key": key])
            } else {
                rejectCallback(callbackId, error: "Keychain error: \(status)")
            }
        }

        private func getSharedKeychainItem(key: String, group: String?, callbackId: String?) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            if let accessGroup = group {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                resolveCallback(callbackId, result: ["value": value, "key": key])
            } else if status == errSecItemNotFound {
                resolveCallback(callbackId, result: ["value": NSNull(), "key": key])
            } else {
                rejectCallback(callbackId, error: "Keychain error: \(status)")
            }
        }

        private func removeSharedKeychainItem(key: String, group: String?, callbackId: String?) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key
            ]

            if let accessGroup = group {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                resolveCallback(callbackId, result: ["success": true, "key": key])
            } else {
                rejectCallback(callbackId, error: "Keychain error: \(status)")
            }
        }

        // MARK: - Local Auth Persistence
        private var biometricSessionExpiry: Date?
        private var biometricSessionDuration: TimeInterval = 300 // 5 minutes default

        private func setBiometricPersistence(enabled: Bool, duration: Double, callbackId: String?) {
            if enabled {
                biometricSessionDuration = duration
                biometricSessionExpiry = Date(timeIntervalSinceNow: duration)
                resolveCallback(callbackId, result: ["enabled": true, "duration": duration, "expiresAt": biometricSessionExpiry!.timeIntervalSince1970 * 1000])
            } else {
                biometricSessionExpiry = nil
                resolveCallback(callbackId, result: ["enabled": false])
            }
        }

        private func checkBiometricPersistence(callbackId: String?) {
            if let expiry = biometricSessionExpiry {
                let isValid = Date() < expiry
                let remaining = isValid ? expiry.timeIntervalSince(Date()) : 0
                resolveCallback(callbackId, result: ["isValid": isValid, "remainingSeconds": remaining])
            } else {
                resolveCallback(callbackId, result: ["isValid": false, "remainingSeconds": 0])
            }
        }

        private func clearBiometricPersistence(callbackId: String?) {
            biometricSessionExpiry = nil
            resolveCallback(callbackId, result: ["cleared": true])
        }

        // MARK: - AR (ARKit)
        private var arSession: ARSession?
        private var arView: ARSCNView?
        private var arObjects: [String: SCNNode] = [:]
        private var detectedPlanes: [UUID: ARPlaneAnchor] = [:]

        private func startAR(options: [String: Any], callbackId: String?) {
            guard ARWorldTrackingConfiguration.isSupported else {
                rejectCallback(callbackId, error: "AR not supported on this device")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Create AR view
                let arView = ARSCNView(frame: UIScreen.main.bounds)
                arView.delegate = self
                arView.autoenablesDefaultLighting = true
                arView.tag = 9999 // For removal later

                // Configure AR session
                let configuration = ARWorldTrackingConfiguration()
                configuration.planeDetection = [.horizontal, .vertical]
                configuration.environmentTexturing = .automatic

                self.arView = arView
                self.arSession = arView.session

                // Add AR view to window
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.addSubview(arView)
                }

                arView.session.run(configuration)
                self.resolveCallback(callbackId, result: ["started": true])
            }
        }

        private func stopAR(callbackId: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.arSession?.pause()
                self.arView?.removeFromSuperview()
                self.arView = nil
                self.arSession = nil
                self.arObjects.removeAll()
                self.detectedPlanes.removeAll()

                self.resolveCallback(callbackId, result: ["stopped": true])
            }
        }

        private func placeARObject(model: String, position: [String: Double]?, callbackId: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let arView = self.arView else {
                    self?.rejectCallback(callbackId, error: "AR not started")
                    return
                }

                let objectId = UUID().uuidString

                // Create a simple box if no model URL
                let node: SCNNode
                if model.hasSuffix(".usdz") || model.hasSuffix(".scn") {
                    // Load from URL/bundle
                    if let url = URL(string: model) {
                        do {
                            let scene = try SCNScene(url: url, options: nil)
                            node = SCNNode()
                            for child in scene.rootNode.childNodes {
                                node.addChildNode(child)
                            }
                        } catch {
                            self.rejectCallback(callbackId, error: "Failed to load model: \\(error.localizedDescription)")
                            return
                        }
                    } else {
                        self.rejectCallback(callbackId, error: "Invalid model URL")
                        return
                    }
                } else {
                    // Create a simple geometry based on model name
                    let geometry: SCNGeometry
                    switch model {
                    case "box":
                        geometry = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01)
                    case "sphere":
                        geometry = SCNSphere(radius: 0.05)
                    case "cylinder":
                        geometry = SCNCylinder(radius: 0.05, height: 0.1)
                    case "cone":
                        geometry = SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.1)
                    default:
                        geometry = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01)
                    }
                    geometry.firstMaterial?.diffuse.contents = UIColor.systemBlue
                    node = SCNNode(geometry: geometry)
                }

                // Set position
                if let pos = position {
                    node.position = SCNVector3(
                        Float(pos["x"] ?? 0),
                        Float(pos["y"] ?? 0),
                        Float(pos["z"] ?? -0.5)
                    )
                } else {
                    node.position = SCNVector3(0, 0, -0.5)
                }

                node.name = objectId
                arView.scene.rootNode.addChildNode(node)
                self.arObjects[objectId] = node

                self.resolveCallback(callbackId, result: ["objectId": objectId, "placed": true])
            }
        }

        private func removeARObject(objectId: String, callbackId: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if let node = self.arObjects[objectId] {
                    node.removeFromParentNode()
                    self.arObjects.removeValue(forKey: objectId)
                    self.resolveCallback(callbackId, result: ["removed": true])
                } else {
                    self.rejectCallback(callbackId, error: "Object not found")
                }
            }
        }

        private func getARPlanes(callbackId: String?) {
            var planes: [[String: Any]] = []
            for (_, anchor) in detectedPlanes {
                planes.append([
                    "id": anchor.identifier.uuidString,
                    "alignment": anchor.alignment == .horizontal ? "horizontal" : "vertical",
                    "center": ["x": anchor.center.x, "y": anchor.center.y, "z": anchor.center.z],
                    "extent": ["width": anchor.extent.x, "height": anchor.extent.z]
                ])
            }
            resolveCallback(callbackId, result: planes)
        }

        // MARK: - ML (Core ML / Vision)
        private func classifyImage(imageBase64: String, callbackId: String?) {
            guard let imageData = Data(base64Encoded: imageBase64),
                  let image = UIImage(data: imageData),
                  let cgImage = image.cgImage else {
                rejectCallback(callbackId, error: "Invalid image data")
                return
            }

            // Use Vision for image classification
            let request = VNClassifyImageRequest { [weak self] request, error in
                if let error = error {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                guard let observations = request.results as? [VNClassificationObservation] else {
                    self?.rejectCallback(callbackId, error: "No classification results")
                    return
                }

                let classifications = observations.prefix(10).map { obs in
                    ["label": obs.identifier, "confidence": obs.confidence]
                }
                self?.resolveCallback(callbackId, result: classifications)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    self.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func detectObjects(imageBase64: String, callbackId: String?) {
            guard let imageData = Data(base64Encoded: imageBase64),
                  let image = UIImage(data: imageData),
                  let cgImage = image.cgImage else {
                rejectCallback(callbackId, error: "Invalid image data")
                return
            }

            // Use Vision for object detection
            let request = VNRecognizeAnimalsRequest { [weak self] request, error in
                if let error = error {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                    self?.rejectCallback(callbackId, error: "No detection results")
                    return
                }

                let detections = observations.map { obs in
                    [
                        "labels": obs.labels.map { ["label": $0.identifier, "confidence": $0.confidence] },
                        "boundingBox": [
                            "x": obs.boundingBox.origin.x,
                            "y": obs.boundingBox.origin.y,
                            "width": obs.boundingBox.width,
                            "height": obs.boundingBox.height
                        ],
                        "confidence": obs.confidence
                    ] as [String : Any]
                }
                self?.resolveCallback(callbackId, result: detections)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    self.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func recognizeText(imageBase64: String, callbackId: String?) {
            guard let imageData = Data(base64Encoded: imageBase64),
                  let image = UIImage(data: imageData),
                  let cgImage = image.cgImage else {
                rejectCallback(callbackId, error: "Invalid image data")
                return
            }

            let request = VNRecognizeTextRequest { [weak self] request, error in
                if let error = error {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    self?.rejectCallback(callbackId, error: "No text results")
                    return
                }

                var textResults: [[String: Any]] = []
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        textResults.append([
                            "text": candidate.string,
                            "confidence": candidate.confidence,
                            "boundingBox": [
                                "x": observation.boundingBox.origin.x,
                                "y": observation.boundingBox.origin.y,
                                "width": observation.boundingBox.width,
                                "height": observation.boundingBox.height
                            ]
                        ])
                    }
                }
                self?.resolveCallback(callbackId, result: textResults)
            }
            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    self.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        // MARK: - Widget
        private let widgetDefaults = UserDefaults(suiteName: "group.{{BUNDLE_ID}}.widget")

        private func updateWidget(data: [String: Any], callbackId: String?) {
            if let title = data["title"] as? String {
                widgetDefaults?.set(title, forKey: "widget_title")
            }
            if let subtitle = data["subtitle"] as? String {
                widgetDefaults?.set(subtitle, forKey: "widget_subtitle")
            }
            if let value = data["value"] as? String {
                widgetDefaults?.set(value, forKey: "widget_value")
            }
            if let icon = data["icon"] as? String {
                widgetDefaults?.set(icon, forKey: "widget_icon")
            }

            // Reload widgets
            WidgetCenter.shared.reloadAllTimelines()
            resolveCallback(callbackId, result: ["updated": true])
        }

        private func reloadAllWidgets(callbackId: String?) {
            WidgetCenter.shared.reloadAllTimelines()
            resolveCallback(callbackId, result: ["reloaded": true])
        }

        // MARK: - Siri Shortcuts
        private func registerSiriShortcut(phrase: String, action: String, callbackId: String?) {
            let activity = NSUserActivity(activityType: "{{BUNDLE_ID}}.\(action)")
            activity.title = phrase
            activity.isEligibleForSearch = true
            activity.isEligibleForPrediction = true
            activity.persistentIdentifier = NSUserActivityPersistentIdentifier(action)
            activity.suggestedInvocationPhrase = phrase

            activity.userInfo = ["action": action]

            // Donate the shortcut
            activity.becomeCurrent()

            resolveCallback(callbackId, result: ["registered": true, "action": action, "phrase": phrase])
        }

        private func removeSiriShortcut(action: String, callbackId: String?) {
            NSUserActivity.deleteSavedUserActivities(withPersistentIdentifiers: [action]) {
                self.resolveCallback(callbackId, result: ["removed": true, "action": action])
            }
        }

        // MARK: - Watch Connectivity
        private var wcSession: WCSession?

        private func setupWatchConnectivity() {
            if WCSession.isSupported() {
                wcSession = WCSession.default
                wcSession?.delegate = self
                wcSession?.activate()
            }
        }

        private func sendMessageToWatch(message: [String: Any], callbackId: String?) {
            guard let session = wcSession, session.isReachable else {
                rejectCallback(callbackId, error: "Watch not reachable")
                return
            }

            session.sendMessage(message, replyHandler: { reply in
                self.resolveCallback(callbackId, result: reply)
            }, errorHandler: { error in
                self.rejectCallback(callbackId, error: error.localizedDescription)
            })
        }

        private func updateWatchContext(context: [String: Any], callbackId: String?) {
            guard let session = wcSession else {
                rejectCallback(callbackId, error: "Watch session not available")
                return
            }

            do {
                try session.updateApplicationContext(context)
                resolveCallback(callbackId, result: ["updated": true])
            } catch {
                rejectCallback(callbackId, error: error.localizedDescription)
            }
        }

        private func isWatchReachable(callbackId: String?) {
            let reachable = wcSession?.isReachable ?? false
            resolveCallback(callbackId, result: ["reachable": reachable])
        }

        // MARK: - Web Communication
        private func sendToWeb(_ event: String, data: [String: Any]) {
            guard let webView = webView else { return }
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: data)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    let script = "window.dispatchEvent(new CustomEvent('\(event)', {detail: \(jsonString)}));"
                    DispatchQueue.main.async { webView.evaluateJavaScript(script, completionHandler: nil) }
                }
            } catch {
                print("Failed to serialize: \(error)")
            }
        }
    }
}

// MARK: - UIColor Extension
extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - DataScanner Delegate (QR/Barcode)
@available(iOS 16.0, *)
extension CraftWebView.Coordinator: DataScannerViewControllerDelegate {
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        switch item {
        case .barcode(let barcode):
            dataScanner.dismiss(animated: true)
            resolveCallback(pendingCallbackId, result: [
                "type": barcode.observation.symbology.rawValue,
                "data": barcode.payloadStringValue ?? ""
            ])
            pendingCallbackId = nil
        default:
            break
        }
    }
}

// MARK: - Document Picker Delegate
extension CraftWebView.Coordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            rejectCallback(pendingCallbackId, error: "No file selected")
            return
        }

        // Get file data as base64
        if let data = try? Data(contentsOf: url) {
            let mimeType = url.mimeType
            let base64 = "data:\(mimeType);base64," + data.base64EncodedString()
            resolveCallback(pendingCallbackId, result: [
                "name": url.lastPathComponent,
                "path": url.path,
                "data": base64,
                "mimeType": mimeType
            ])
        } else {
            resolveCallback(pendingCallbackId, result: [
                "name": url.lastPathComponent,
                "path": url.path
            ])
        }
        pendingCallbackId = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        rejectCallback(pendingCallbackId, error: "Cancelled")
        pendingCallbackId = nil
    }
}

// MARK: - Apple Sign In Delegate
extension CraftWebView.Coordinator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let userId = appleIDCredential.user
            let email = appleIDCredential.email
            let fullName = appleIDCredential.fullName

            var name = ""
            if let givenName = fullName?.givenName {
                name = givenName
            }
            if let familyName = fullName?.familyName {
                name += (name.isEmpty ? "" : " ") + familyName
            }

            var result: [String: Any] = ["userId": userId]
            if let email = email { result["email"] = email }
            if !name.isEmpty { result["name"] = name }

            if let identityToken = appleIDCredential.identityToken,
               let tokenString = String(data: identityToken, encoding: .utf8) {
                result["identityToken"] = tokenString
            }

            resolveCallback(pendingCallbackId, result: result)
        }
        pendingCallbackId = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        rejectCallback(pendingCallbackId, error: error.localizedDescription)
        pendingCallbackId = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return UIWindow()
        }
        return window
    }
}

// MARK: - Bluetooth Delegate
extension CraftWebView.Coordinator: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            resolveCallback(pendingCallbackId, result: true)
        } else {
            rejectCallback(pendingCallbackId, error: "Bluetooth not available")
        }
        pendingCallbackId = nil
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(peripheral) {
            discoveredPeripherals.append(peripheral)
            sendToWeb("craftBluetoothDevice", data: [
                "id": peripheral.identifier.uuidString,
                "name": peripheral.name ?? "Unknown",
                "rssi": RSSI.intValue
            ])
        }
    }
}

// MARK: - NFC Delegate
extension CraftWebView.Coordinator: NFCNDEFReaderSessionDelegate {
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        var records: [[String: Any]] = []
        for message in messages {
            for record in message.records {
                var recordData: [String: Any] = [
                    "typeNameFormat": record.typeNameFormat.rawValue,
                    "type": String(data: record.type, encoding: .utf8) ?? "",
                    "identifier": String(data: record.identifier, encoding: .utf8) ?? ""
                ]
                if let payload = String(data: record.payload, encoding: .utf8) {
                    recordData["payload"] = payload
                } else {
                    recordData["payload"] = record.payload.base64EncodedString()
                }
                records.append(recordData)
            }
        }
        resolveCallback(pendingCallbackId, result: records)
        pendingCallbackId = nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        if (error as NSError).code != 200 { // 200 is user cancelled
            rejectCallback(pendingCallbackId, error: error.localizedDescription)
        }
        pendingCallbackId = nil
    }
}

// MARK: - ARSCNViewDelegate Extension
extension CraftWebView.Coordinator {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }

        // Store plane
        detectedPlanes[anchor.identifier] = planeAnchor

        // Create plane visualization
        let plane = SCNPlane(width: CGFloat(planeAnchor.extent.x), height: CGFloat(planeAnchor.extent.z))
        plane.firstMaterial?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3(planeAnchor.center.x, 0, planeAnchor.center.z)
        planeNode.eulerAngles.x = -.pi / 2

        node.addChildNode(planeNode)

        // Dispatch plane detected event
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftARPlane", data: [
                "type": "added",
                "id": anchor.identifier.uuidString,
                "alignment": planeAnchor.alignment == .horizontal ? "horizontal" : "vertical",
                "center": ["x": planeAnchor.center.x, "y": planeAnchor.center.y, "z": planeAnchor.center.z],
                "extent": ["width": planeAnchor.extent.x, "height": planeAnchor.extent.z]
            ])
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }

        // Update stored plane
        detectedPlanes[anchor.identifier] = planeAnchor

        // Update plane visualization
        if let planeNode = node.childNodes.first,
           let plane = planeNode.geometry as? SCNPlane {
            plane.width = CGFloat(planeAnchor.extent.x)
            plane.height = CGFloat(planeAnchor.extent.z)
            planeNode.position = SCNVector3(planeAnchor.center.x, 0, planeAnchor.center.z)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARPlaneAnchor else { return }

        // Remove from stored planes
        detectedPlanes.removeValue(forKey: anchor.identifier)

        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftARPlane", data: [
                "type": "removed",
                "id": anchor.identifier.uuidString
            ])
        }
    }
}

// MARK: - URL Extension for MIME types
extension URL {
    var mimeType: String {
        if let utType = UTType(filenameExtension: pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

// MARK: - Contact Picker Delegate
extension CraftWebView.Coordinator: CNContactPickerDelegate {
    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let contactData = formatContact(contact)
        resolveCallback(pendingCallbackId, result: contactData)
        pendingCallbackId = nil
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
        let contactsData = contacts.map { formatContact($0) }
        resolveCallback(pendingCallbackId, result: contactsData)
        pendingCallbackId = nil
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        rejectCallback(pendingCallbackId, error: "Cancelled")
        pendingCallbackId = nil
    }

    private func formatContact(_ contact: CNContact) -> [String: Any] {
        var data: [String: Any] = [
            "id": contact.identifier,
            "givenName": contact.givenName,
            "familyName": contact.familyName,
            "displayName": CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        ]

        // Phone numbers
        var phones: [[String: String]] = []
        for phone in contact.phoneNumbers {
            phones.append([
                "label": CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? ""),
                "number": phone.value.stringValue
            ])
        }
        data["phoneNumbers"] = phones

        // Email addresses
        var emails: [[String: String]] = []
        for email in contact.emailAddresses {
            emails.append([
                "label": CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? ""),
                "address": email.value as String
            ])
        }
        data["emailAddresses"] = emails

        return data
    }
}

// MARK: - Watch Connectivity Delegate
extension CraftWebView.Coordinator: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("WCSession activated with state: \(activationState.rawValue)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate session on new paired device
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftWatchReachability", data: [
                "reachable": session.isReachable
            ])
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftWatchMessage", data: message)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftWatchMessage", data: message)
        }
        // Default reply - apps can customize this behavior
        replyHandler(["received": true])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftWatchContext", data: applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.sendToWeb("craftWatchUserInfo", data: userInfo)
            self?.sendToWeb("craftWatchMessage", data: userInfo)
        }
    }
}
