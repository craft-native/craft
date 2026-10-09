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
import SafariServices

extension Notification.Name {
    static let craftPushToken = Notification.Name("craftPushToken")
    static let craftPushRegistrationError = Notification.Name("craftPushRegistrationError")
}

/// Which failed page loads mean the remote origin is out of reach (#252).
///
/// That is the only failure the bundled copy stands in for. Anything else
/// either is not a failure at all or is one the bundle would hide: a TLS error
/// or a bad response means the server *was* reached, and swapping in a local
/// copy would bury a real fault under a page that half-works.
///
/// Written against NSError's domain and code rather than WebKit's types, so it
/// compiles with Foundation alone — which is how `compile-templates` runs it on
/// its own, on the CI host, rather than only reading its text.
enum CraftLoadFailure {
    static func isUnreachable(_ error: Error) -> Bool {
        let error = error as NSError
        // Everything outside NSURLErrorDomain is excluded, WebKit's own
        // frame-load-interrupted (WebKitErrorDomain 102) among them: a load
        // replaced by a newer one is not a load that failed.
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return true
        default:
            // NSURLErrorCancelled (-999) lands here. WebKit reports it for two
            // quick taps, a redirect, or a `location.assign` while a load is in
            // flight — and it used to end the session on the bundled copy.
            return false
        }
    }
}

final class CraftAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            CraftEventManager.shared.handleShortcut(shortcut)
            // Returning false tells UIKit the launch-time item was handled and
            // prevents a second performActionFor callback for the same tap.
            return false
        }
        return true
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        CraftEventManager.shared.handleShortcut(shortcutItem)
        completionHandler(true)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        CraftEventManager.shared.handleSiriActivity(userActivity)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .craftPushToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .craftPushRegistrationError, object: error.localizedDescription)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Through the manager, not NotificationCenter. A tap that launches a
        // killed app arrives here before SwiftUI has built the Coordinator, and
        // NotificationCenter keeps nothing for an observer that does not exist
        // yet — so the tap was dropped, and the page opened wherever it opens
        // rather than where the notification pointed. The manager exists from
        // process start and holds the tap until the page is ready, the way it
        // already does for a home-screen shortcut.
        CraftEventManager.shared.handleNotificationResponse(response.notification.request.content.userInfo)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Told to the page as well as shown. A page that is open when a push
        // lands used to hear about it only if someone tapped the banner, so it
        // could not refresh what the push was about while it was on screen.
        // The banner still shows: the page is told, not asked.
        CraftEventManager.shared.handleNotificationReceived(notification.request.content.userInfo)
        completionHandler([.banner, .badge, .sound])
    }
}

// MARK: - Native Event Manager
class CraftEventManager {
    static let shared = CraftEventManager()

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingEvents: [(name: String, data: [String: Any])] = []

    private init() {}

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func setLoading() {
        isReady = false
    }

    func setReady() {
        isReady = true
        let events = pendingEvents
        pendingEvents.removeAll()
        for event in events {
            dispatch(event.name, data: event.data)
        }
    }

    func handleShortcut(_ shortcut: UIApplicationShortcutItem) {
        sendToWeb("craftShortcut", data: ["type": shortcut.type])
    }

    /// A tap on a notification, carrying the payload it was sent with.
    ///
    /// Keys that are not strings are dropped rather than failing the whole
    /// event: an APNs payload's keys always are, and the page could not index
    /// by anything else anyway.
    func handleNotificationResponse(_ userInfo: [AnyHashable: Any]) {
        sendToWeb("craftNotificationResponse", data: Self.pageData(userInfo))
    }

    /// A notification that arrived while the app was in front, in the same
    /// shape as a tap so one handler can read both.
    func handleNotificationReceived(_ userInfo: [AnyHashable: Any]) {
        sendToWeb("craftNotificationReceived", data: Self.pageData(userInfo))
    }

    private static func pageData(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        var data: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String else { continue }
            data[key] = value
        }
        return data
    }

    func handleSiriActivity(_ activity: NSUserActivity) -> Bool {
        let prefix = "\(Bundle.main.bundleIdentifier ?? "{{BUNDLE_ID}}")."
        guard activity.activityType.hasPrefix(prefix) else { return false }

        let action = activity.userInfo?["action"] as? String
            ?? String(activity.activityType.dropFirst(prefix.count))
        var data: [String: Any] = [:]
        for (key, value) in activity.userInfo ?? [:] {
            guard let key = key as? String, key != "action" else { continue }
            data[key] = value
        }
        sendToWeb("craftSiriShortcut", data: ["action": action, "data": data])
        return true
    }

    private func sendToWeb(_ event: String, data: [String: Any]) {
        guard isReady, webView != nil else {
            pendingEvents.append((event, data))
            return
        }
        dispatch(event, data: data)
    }

    private func dispatch(_ event: String, data: [String: Any]) {
        guard let webView = webView,
              let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let script = "window.dispatchEvent(new CustomEvent('\(event)', {detail: \(json)}));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

// MARK: - App Entry Point
@main
struct CraftApp: App {
    @UIApplicationDelegateAdaptor(CraftAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some SwiftUI.Scene {
        WindowGroup {
            Group {
                if appState.config.renderer == "native" {
                    CraftNativeScreen(config: appState.config)
                } else {
                    // The page's own chrome, drawn natively over it: the tab
                    // bar the page asks for, and the splash until it is ready.
                    ZStack(alignment: .bottom) {
                        CraftWebView(config: appState.config)
                            .ignoresSafeArea()
                        CraftTabBarView()
                        CraftSplashView(background: appState.config.resolvedBackgroundColor)
                    }
                }
            }
                .preferredColorScheme(appState.config.colorScheme)
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

// MARK: - Native chrome: the tab bar and the launch splash
//
// Both belong to the screen rather than to the page, so they are drawn here in
// SwiftUI and the page only describes them. The page reaches them through the
// `craftChrome` message handler, which exists from the first byte of the
// document; `window.craft` arrives only once the page has finished loading,
// images and all, and a tab bar or a splash that waited for it would be late
// on every launch.

final class CraftChrome: ObservableObject {
    static let shared = CraftChrome()

    struct Tab: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let badge: String?
    }

    @Published var tabs: [Tab] = []
    @Published var selected: String?
    @Published var tabBarVisible = false
    @Published var splashVisible = true
    @Published var tint: UIColor?

    weak var webView: WKWebView?
    /// What the tab bar covers at the bottom of the screen, in points.
    private var occupied: CGFloat = 0
    private var pendingHide: DispatchWorkItem?
    private var splashDeadline: DispatchWorkItem?

    private init() {}

    /// However the page behaves, the splash is gone after `seconds`
    /// (`splashMaxSeconds`, three by default). It used to be ten: a page that
    /// never painted held a logo on screen for ten seconds, which reads as a
    /// hang rather than a launch.
    func holdSplash(atMost seconds: Double) {
        splashDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.hideSplash() }
        splashDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, seconds), execute: deadline)
    }

    func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "tabBar":
            pendingHide?.cancel()
            tabs = (body["tabs"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
                let badge = (item["badge"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Tab(id: id, title: title, symbol: item["symbol"] as? String ?? "circle", badge: badge)
            }
            if let selected = body["selected"] as? String { self.selected = selected }
            if let hex = body["tint"] as? String {
                let light = UIColor(hex: hex)
                let dark = (body["tintDark"] as? String).flatMap { UIColor(hex: $0) }
                tint = light.map { light in dark.map { dark in UIColor { $0.userInterfaceStyle == .dark ? dark : light } } ?? light }
            }
            withAnimation(.easeOut(duration: 0.2)) { tabBarVisible = !tabs.isEmpty }
            publishLayout()
        case "selectTab":
            if let id = body["id"] as? String, id != selected {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selected = id }
            }
        case "hideTabBar":
            // Later, and only if no screen asks for the bar meanwhile: moving
            // between two screens that both have it unmounts one bar and
            // mounts the next, and the bar must not blink in between.
            pendingHide?.cancel()
            let hide = DispatchWorkItem { [weak self] in
                withAnimation(.easeIn(duration: 0.18)) { self?.tabBarVisible = false }
                self?.occupied = 0
                self?.publishLayout()
            }
            pendingHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: hide)
        case "ready":
            hideSplash()
        case "painted":
            // The page's first contentful paint, two frames on: something of
            // the page is on screen, so the launch screen has done its job
            // even if the page never says `ready`.
            hideSplash()
        default:
            break
        }
    }

    /// A tap on a tab: the page navigates, and says which tab is current.
    ///
    /// No haptic. UITabBar plays none, and a tab bar that ticks on every tap is
    /// one of the small things that gives a web shell away.
    func tap(_ tab: Tab) {
        if tab.id != selected {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selected = tab.id }
        }
        emit("craftTabSelect", ["id": tab.id])
    }

    func hideSplash() {
        splashDeadline?.cancel()
        splashDeadline = nil
        guard splashVisible else { return }
        withAnimation(.easeOut(duration: 0.28)) { splashVisible = false }
    }

    /// The paint half of "until the page is ready or has painted": tells the
    /// shell once the document's first contentful paint is on screen.
    static let paintScript = """
    (function() {
        try {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craftChrome;
            if (!handler || typeof PerformanceObserver !== 'function') return;
            var sent = false;
            var send = function() {
                if (sent) return;
                sent = true;
                requestAnimationFrame(function() { requestAnimationFrame(function() { handler.postMessage({type: 'painted'}); }); });
            };
            var observer = new PerformanceObserver(function(list) {
                list.getEntries().forEach(function(entry) {
                    if (entry.name === 'first-contentful-paint') { send(); observer.disconnect(); }
                });
            });
            observer.observe({type: 'paint', buffered: true});
        } catch (e) {}
    })();
    """

    /// A page that loaded and never said it was ready still gets shown.
    func pageFinished() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.hideSplash() }
    }

    func layoutChanged(_ height: CGFloat) {
        let rounded = height.rounded()
        guard rounded != occupied else { return }
        occupied = rounded
        publishLayout()
    }

    /// The bar's height as `--craft-tab-bar-height`, so the page leaves room
    /// for it, and as an event for anything that measures.
    func publishLayout() {
        let height = tabBarVisible ? Int(occupied) : 0
        let script = "document.documentElement.style.setProperty('--craft-tab-bar-height','\(height)px');window.dispatchEvent(new CustomEvent('craftTabBarLayout',{detail:{height:\(height)}}));"
        DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(script, completionHandler: nil) }
    }

    private func emit(_ event: String, _ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.dispatchEvent(new CustomEvent('\(event)',{detail:\(json)}));"
        DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(script, completionHandler: nil) }
    }
}

/// Receives the page's chrome messages. Only from a trusted origin, like the bridge.
final class CraftChromeRelay: NSObject, WKScriptMessageHandler {
    private let trusts: (WKSecurityOrigin) -> Bool

    init(trusts: @escaping (WKSecurityOrigin) -> Bool) {
        self.trusts = trusts
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusts(message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any] else { return }
        DispatchQueue.main.async { CraftChrome.shared.handle(body) }
    }
}

/// The floating tab bar: Liquid Glass on iOS 26 and later, a material capsule before.
struct CraftTabBarView: View {
    @ObservedObject private var chrome = CraftChrome.shared
    @Namespace private var selection

    var body: some View {
        if chrome.tabBarVisible && !chrome.tabs.isEmpty {
            bar
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { report(proxy) }
                        .onChange(of: proxy.frame(in: .global)) { _ in report(proxy) }
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .ignoresSafeArea(.keyboard)
        }
    }

    private func report(_ proxy: GeometryProxy) {
        let screen = UIScreen.main.bounds.height
        chrome.layoutChanged(max(0, screen - proxy.frame(in: .global).minY))
    }

    @ViewBuilder private var bar: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                items
                    .padding(4)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            items
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
#else
        items
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
#endif
    }

    private var items: some View {
        HStack(spacing: 0) {
            ForEach(chrome.tabs) { tab in
                let isSelected = tab.id == chrome.selected
                Button { chrome.tap(tab) } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: symbol(tab.symbol, selected: isSelected))
                                .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                                .frame(height: 26)
                            if let badge = tab.badge {
                                Text(badge)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(Color.red))
                                    .offset(x: 10, y: -4)
                            }
                        }
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? selectedColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.primary.opacity(0.09))
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.badge.map { "\(tab.title), \($0)" } ?? tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    private var selectedColor: Color {
        chrome.tint.map { Color($0) } ?? Color.primary
    }

    /// The filled variant for the current tab, when the symbol has one.
    private func symbol(_ name: String, selected: Bool) -> String {
        guard selected, !name.hasSuffix(".fill"), UIImage(systemName: "\(name).fill") != nil else { return name }
        return "\(name).fill"
    }
}

/// The launch screen, held until the page is ready: the same colour and the
/// same logo at the same place, so the hand-over from the system's launch
/// screen cannot be seen.
struct CraftSplashView: View {
    @ObservedObject private var chrome = CraftChrome.shared
    let background: UIColor

    var body: some View {
        if chrome.splashVisible {
            ZStack {
                Color(background)
                if let logo = UIImage(named: "LaunchLogo") {
                    Image(uiImage: logo)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(true)
            .transition(.opacity)
        }
    }
}

// MARK: - Deep Link Manager
class DeepLinkManager {
    static let shared = DeepLinkManager()

    private var initialURL: URL?
    // Every link that arrived while no page could receive it, in order. This
    // was a single slot, so a second link before the bridge was ready replaced
    // the first; on a cold start, that could be the link that launched the app.
    private var pendingURLs: [URL] = []
    private weak var webView: WKWebView?
    private var isReady = false
    // Whether a page has ever become ready. A link that arrives before that is
    // the one the app was opened with; a link that arrives later is not, and
    // is no answer to getInitialURL.
    private var hasBeenReady = false
    private var nativeListeners: [UUID: (URL, Bool) -> Void] = [:]

    private init() {}

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    // A navigation started, so the page that would have received a link is
    // going away. Without this a link arriving during a reload was dispatched
    // into the page being torn down and lost.
    func setLoading() {
        isReady = false
    }

    func setReady() {
        isReady = true
        let firstPage = !hasBeenReady
        hasBeenReady = true
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            dispatchDeepLink(url, initial: firstPage && url == initialURL)
        }
    }

    func handleURL(_ url: URL) {
        if initialURL == nil && !hasBeenReady {
            initialURL = url
        }

        if !nativeListeners.isEmpty {
            dispatchNative(url, initial: false)
        } else if isReady && webView != nil {
            dispatchDeepLink(url, initial: false)
        } else {
            pendingURLs.append(url)
        }
    }

    func getInitialURL() -> URL? {
        return initialURL
    }

    @discardableResult
    func addNativeListener(_ listener: @escaping (URL, Bool) -> Void) -> UUID {
        let token = UUID()
        nativeListeners[token] = listener
        let firstNativeScreen = !hasBeenReady
        hasBeenReady = true
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            listener(url, firstNativeScreen && url == initialURL)
        }
        return token
    }

    func removeNativeListener(_ token: UUID) {
        nativeListeners.removeValue(forKey: token)
    }

    private func dispatchNative(_ url: URL, initial: Bool) {
        for listener in nativeListeners.values { listener(url, initial) }
    }

    private func dispatchDeepLink(_ url: URL, initial: Bool) {
        guard let webView = webView else { return }

        // Parse URL components
        var params: [String: Any] = [
            "url": url.absoluteString,
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": url.path,
            "query": url.query ?? "",
            // Lets the page tell the launch link apart from later ones, so a
            // page that reads getInitialURL is not also handed it again.
            "initial": initial
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
        if let configURL = Bundle.main.url(forResource: "craft.config", withExtension: "json"),
           let data = try? Data(contentsOf: configURL) {
            self.config = CraftConfig.load(from: data)
        } else {
            self.config = CraftConfig()
        }
    }
}

extension CraftConfig {
    /// The bundled config laid over the defaults, key by key.
    ///
    /// Decoded whole, one missing or mistyped key failed the entire file and
    /// the app ran on `CraftConfig()` — every capability off, silently: the
    /// network bridge refused, the page read that as offline, and nothing said
    /// why. A key the file leaves out now keeps its default, and a file that
    /// still cannot be read says so in the log.
    static func load(from data: Data) -> CraftConfig {
        let defaults = (try? JSONEncoder().encode(CraftConfig()))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("[craft] craft.config.json is not a JSON object; running on defaults")
            return CraftConfig()
        }
        let merged = defaults.merging(given.filter { !($0.value is NSNull) }) { _, bundled in bundled }
        do {
            return try JSONDecoder().decode(CraftConfig.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            NSLog("[craft] craft.config.json could not be read, running on defaults: %@", String(describing: error))
            return CraftConfig()
        }
    }
}

// MARK: - Configuration
struct CraftConfig: Codable {
    var appName: String = "Craft App"
    var bundleId: String = "com.craft.app"
    /// Opt-in UIKit + JavaScriptCore screen; existing apps keep WKWebView.
    var renderer: String = "web"
    var darkMode: Bool = true
    /// "light", "dark" or "system". Absent in configs older than the field,
    /// which keep what `darkMode` pinned.
    var appearance: String? = nil
    var backgroundColor: String = "#1a1a2e"
    /// The background while the phone is in Dark Mode; the light one if unset.
    var backgroundColorDark: String? = nil
    /// Edge-swipe back and forward through the page's history.
    var swipeNavigation: Bool? = nil
    /// Refuse to load anything but the Info.plist's WKAppBoundDomains.
    var limitNavigationsToAppBoundDomains: Bool? = nil
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
    /// The longest the launch splash stays up when the page neither says it is
    /// ready nor paints.
    var splashMaxSeconds: Double = 3
    /// How long the app's own page may take to answer before the load counts
    /// as unreachable and the bundled copy stands in.
    var requestTimeoutSeconds: Double = 10
}

extension CraftConfig {
    /// The scheme SwiftUI pins, or nil to follow the phone's setting.
    var colorScheme: ColorScheme? {
        switch appearance {
        case "system": return nil
        case "light": return .light
        case "dark": return .dark
        default: return darkMode ? .dark : .light
        }
    }

    /// A request for the app's own page, given up on after
    /// `requestTimeoutSeconds`. URLRequest's default is sixty seconds, and a
    /// first launch on a dead connection sat on the splash and then a blank
    /// page for that long before the offline page could show.
    func request(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: max(1, requestTimeoutSeconds))
    }

    /// The webview's background, resolved per trait so a Dark Mode switch
    /// repaints it without a reload.
    var resolvedBackgroundColor: UIColor {
        let light = UIColor(hex: backgroundColor) ?? .black
        guard let darkHex = backgroundColorDark, let dark = UIColor(hex: darkHex) else { return light }
        return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }
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

#if DEBUG
/// Relays the page's console and uncaught errors to NSLog in debug builds.
final class PageConsoleRelay: NSObject, WKScriptMessageHandler {
    static let script = """
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craftLog;
        if (!handler) return;
        function text(value) {
            try { return typeof value === 'string' ? value : (value && value.stack) || JSON.stringify(value); }
            catch (e) { return String(value); }
        }
        function send(level, message) { try { handler.postMessage({ level: level, message: String(message).slice(0, 4000) }); } catch (e) {} }
        ['error', 'warn', 'log', 'info'].forEach(function(level) {
            var original = console[level];
            console[level] = function() {
                send(level, Array.prototype.map.call(arguments, text).join(' '));
                return original.apply(console, arguments);
            };
        });
        // Capture phase: a script or stylesheet that fails to load fires its
        // error on the element, which never bubbles to window.
        window.addEventListener('error', function(event) {
            var target = event.target;
            if (target && target !== window && (target.src || target.href)) {
                send('error', 'failed to load ' + (target.src || target.href));
                return;
            }
            send('error', 'uncaught ' + event.message + ' at ' + event.filename + ':' + event.lineno + ':' + event.colno);
        }, true);
        window.addEventListener('unhandledrejection', function(event) {
            send('error', 'unhandled rejection ' + text(event.reason));
        });
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        NSLog("[craft page] %@: %@", body["level"] as? String ?? "log", body["message"] as? String ?? "")
    }
}
#endif

struct CraftWebView: UIViewRepresentable {
    let config: CraftConfig

    func makeUIView(context: Context) -> WKWebView {
        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.setURLSchemeHandler(BundledAssetSchemeHandler(), forURLScheme: "craft")
        // The app's own domains (WKAppBoundDomains in Info.plist) get what an
        // iOS web view reserves for them, service workers among them, so a
        // site that works offline in Safari works offline here. This only
        // narrows loading further when the app asks for it.
        if config.limitNavigationsToAppBoundDomains == true {
            webConfig.limitsNavigationsToAppBoundDomains = true
        }

        // Add native bridge
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "craft")
        // The tab bar and the splash, outside the bridge's action dispatch:
        // they are the screen's, not a device API.
        let coordinator = context.coordinator
        contentController.add(CraftChromeRelay(trusts: { [weak coordinator] origin in coordinator?.trusts(origin) ?? false }), name: "craftChrome")
        #if DEBUG
        // The page's errors and console, in the device log, so a debug build
        // can be diagnosed from `log stream` or `simctl spawn … log show`
        // without attaching Safari. A separate handler, outside the bridge's
        // action dispatch. Never in a release build.
        contentController.add(PageConsoleRelay(), name: "craftLog")
        #endif
        // The bridge and everything else the page gets from the first byte.
        coordinator.installUserScripts(into: contentController)
        webConfig.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = context.coordinator
        // alert(), confirm() and prompt() as the system's own alerts, and
        // target=_blank and window.open somewhere they can actually open.
        // Without a UI delegate WebKit drops all of them silently.
        webView.uiDelegate = context.coordinator
        // Now, not when the first page finishes loading. Everything the
        // coordinator sends the page goes through this reference, and a
        // network change, a push token or a location fix that arrived before
        // the first didFinish used to be dropped on a nil.
        coordinator.attach(webView)
        webView.isOpaque = false
        // An edge swipe goes back (and forward) through the page's history,
        // pushState entries included, the way every iOS app's stack does.
        webView.allowsBackForwardNavigationGestures = config.swipeNavigation ?? false
        #if DEBUG
        // Safari's Develop menu can attach to a debug build; never a release.
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        // Before any message can be offered. Zig evaluates every reply against
        // this webview, and without it an action would run, succeed, and reach
        // `error.NoWebView` on the way back — the page hearing nothing while
        // the work happened.
        CraftZigRuntime.attach(webView)

        // Register with DeepLinkManager
        DeepLinkManager.shared.setWebView(webView)
        CraftEventManager.shared.setWebView(webView)
        CraftChrome.shared.webView = webView
        CraftChrome.shared.holdSplash(atMost: config.splashMaxSeconds)

        // Parse background color
        let bgColor = config.resolvedBackgroundColor
        webView.backgroundColor = bgColor
        webView.scrollView.backgroundColor = bgColor

        // Load content
        if let devURL = config.devServerURL, !devURL.isEmpty {
            // Development mode - connect to server
            if let url = URL(string: devURL) {
                webView.load(config.request(for: url))
            }
        } else if let bundledURL = URL(string: "craft://app/index.html") {
            // A route-aware local origin keeps root-relative STX assets and
            // clean links working without granting arbitrary file access.
            webView.load(URLRequest(url: bundledURL))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// The teardown half of `CraftZigRuntime.attach`, called by SwiftUI when
    /// this representable goes away. Without it Zig keeps an unretained
    /// pointer to a deallocated webview and answers into freed memory.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        CraftZigRuntime.detach(uiView)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(config: config)
        // The Zig dispatcher finds CraftSwiftShim by class name; the shim finds
        // its way back to the live coordinator through this. Weak, because
        // SwiftUI owns the coordinator's lifetime.
        CraftSwiftShim.coordinator = coordinator
        return coordinator
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
        /// Whether the current document's bridge has announced itself.
        private var documentReady = false

        /// The highest `cb_<n>` this process has seen the page hand out.
        ///
        /// The page's own counter restarts at 0 on every injection, which is
        /// every reload, navigation and web-content crash recovery, and
        /// nothing native records which load a call came from. So an answer
        /// to a call made before a reload was delivered to whichever call on
        /// the new page drew the same number: `getDeviceInfo` settled with a
        /// Siri result, or rejected with the earlier call's TIMEOUT (#226).
        ///
        /// Seeding each injection above everything already handed out makes
        /// an id unique for the life of the process. A late answer then names
        /// a callback no page has, and is dropped where it lands — on either
        /// runtime, and without native having to track page loads at all.
        private var highestCallbackId = 0

        // Location
        private var locationManager: CLLocationManager?
        private var singleLocationCallbackId: String?
        private var singleLocationTimeoutWorkItem: DispatchWorkItem?
        private var locationPermissionCallbackId: String?
        private var locationPermissionRequiresAlways = false
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

        // Speech synthesis. One synthesizer for the life of the web view, so a
        // cue can interrupt the one before it; each utterance it has not
        // finished yet is held beside the call waiting on it.
        private lazy var speechSynthesizer: AVSpeechSynthesizer = {
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            return synthesizer
        }()
        private var pendingUtterances: [(utterance: AVSpeechUtterance, callbackId: String?)] = []
        /// What the session was before speech claimed it; nil while speech
        /// does not hold it.
        private var speechAudioSessionToRestore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
        /// Activating and deactivating the audio session blocks until the
        /// audio hardware answers, which iOS flags as a hang risk on the main
        /// thread. They run here instead, in order, and the session state
        /// above is only touched here.
        private let speechAudioQueue = DispatchQueue(label: "craft.speech.audio")

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
                // Zig owns the recorder when it is linked, including the
                // relaunch restore — see `CraftZigRuntime.adoptLocationRecording`.
                // Running both would leave two managers appending to one track.
                if !CraftZigRuntime.adoptLocationRecording() {
                    restoreLocationRecordingState()
                }
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
            NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
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
                // Read before it is overwritten: the retry below wants the
                // transition, not the state.
                let wasConnected = self?.isConnected ?? true
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
                // Only on false → true. Retrying whenever the path is merely
                // satisfied would loop: a server that is down on a network
                // that is up leaves the path satisfied throughout, so every
                // update would retry, fail, fall back and retry again. That
                // case recovers on the next foreground instead.
                if !wasConnected, self?.isConnected == true {
                    DispatchQueue.main.async {
                        self?.returnFromBundledFallback(because: "the network came back")
                    }
                }
            }
            networkMonitor?.start(queue: DispatchQueue.global())
        }

        // CRAFT_IOS_PAGE_BRIDGE_DISPATCHER
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let securityOrigin = message.frameInfo.securityOrigin
            guard isTrustedOrigin(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port) else {
                print("Blocked Craft bridge message from untrusted origin: \(securityOrigin.protocol)://\(securityOrigin.host)")
                return
            }
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            // The page's own signal that the bridge has announced itself, not
            // a device API: it is never offered to Zig and nothing answers it.
            if action == "__craftReady" {
                pageBecameReady()
                return
            }

            let callbackId = body["callbackId"] as? String
            // Before Zig is offered the call, because the seed has to cover
            // every id the page drew, not only the ones Swift went on to serve.
            noteCallbackId(callbackId)

            // The Zig runtime first, when there is one.
            //
            // `offer` returns true when Zig has taken responsibility for the
            // call — served it, or refused it and settled the page's promise
            // on the way. Either way the answer is on its way and this method
            // must not produce a second one. False means no Zig module
            // recognised the action, which is every action still listed in the
            // switch below and nothing else.
            //
            // In an app with no Zig runtime linked, `offer` is a `dlsym` miss
            // that answers false for everything, and the switch serves the
            // whole surface exactly as it did before. That is why this is one
            // line and not a build flag.
            if CraftZigRuntime.offer(action: action, body: body, callbackId: callbackId) { return }

            dispatch(action: action, body: body, callbackId: callbackId)
        }

        /// The action switch, reachable from two directions: the
        /// WKScriptMessageHandler above, and `CraftSwiftShim.handleAction` when
        /// the Zig dispatcher hands over an action it has not migrated yet.
        ///
        /// A hand-off call arrives with a synthetic callbackId of the form
        /// "zig:<requestId>". The reply helpers recognise that prefix and route
        /// the answer back through the Zig runtime's exported
        /// `craft_ios_deliver_result` instead of evaluating JavaScript here —
        /// one reply path, owned by whichever side received the page's message.
        func dispatch(action: String, body: [String: Any], callbackId: String?) {
            if let answer = CraftNativeActions.perform(action: action, body: body, config: config) {
                switch answer {
                case .success(let value): resolveCallback(callbackId, result: value)
                case .failure(let error): rejectCallback(callbackId, error: error.message, code: error.code)
                }
                return
            }
            switch action {
            case "startListening":
                if config.enableSpeechRecognition {
                    // Answers that the request was taken. Authorization and the
                    // recognizer answer later, as craftSpeech* events; waiting
                    // for them here would leave the promise open on every path
                    // that ends without one.
                    startSpeechRecognition()
                    resolveCallback(callbackId, result: true)
                } else {
                    rejectCallback(callbackId, error: "Speech recognition is disabled", code: "CAPABILITY_DISABLED")
                }
            case "stopListening":
                stopSpeechRecognition()
                resolveCallback(callbackId, result: true)
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
                } else {
                    rejectCallback(callbackId, error: "Camera is disabled", code: "CAPABILITY_DISABLED")
                }
            case "pickImage":
                if config.enableCamera {
                    pendingCallbackId = callbackId
                    pickImage()
                } else {
                    rejectCallback(callbackId, error: "Camera is disabled", code: "CAPABILITY_DISABLED")
                }
            case "authenticate":
                if config.enableBiometric {
                    let reason = body["reason"] as? String ?? "Authenticate to continue"
                    authenticate(reason: reason, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Biometric authentication is disabled", code: "CAPABILITY_DISABLED")
                }
            case "registerPush":
                if config.enablePushNotifications {
                    registerPushNotifications(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Push notifications are disabled", code: "CAPABILITY_DISABLED")
                }
            case "secureSet":
                if config.enableSecureStorage {
                    if let key = body["key"] as? String,
                       let value = body["value"] as? String {
                        let success = secureStore(key: key, value: value)
                        resolveCallback(callbackId, result: success)
                    } else {
                        rejectCallback(callbackId, error: "secureSet was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Secure storage is disabled", code: "CAPABILITY_DISABLED")
                }
            case "secureGet":
                if config.enableSecureStorage {
                    if let key = body["key"] as? String {
                        let value = secureRetrieve(key: key)
                        resolveCallback(callbackId, result: value as Any)
                    } else {
                        rejectCallback(callbackId, error: "secureGet was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Secure storage is disabled", code: "CAPABILITY_DISABLED")
                }
            case "secureRemove":
                if config.enableSecureStorage {
                    if let key = body["key"] as? String {
                        let success = secureRemove(key: key)
                        resolveCallback(callbackId, result: success)
                    } else {
                        rejectCallback(callbackId, error: "secureRemove was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Secure storage is disabled", code: "CAPABILITY_DISABLED")
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
            // The offline page's Retry button, and anything else that wants
            // the app's own page back after the bundled copy stood in.
            case "retryRemote":
                retryRemote()
                resolveCallback(callbackId, result: true)
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
                    getCurrentPosition(body: body, callbackId: callbackId)
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
            // App Badge
            case "setBadge":
                if let count = body["count"] as? Int {
                    setBadgeCount(count, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "setBadge needs a whole number of badges", code: "INVALID_ARGUMENT")
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
                } else {
                    rejectCallback(callbackId, error: "setFlashlight needs true or false", code: "INVALID_ARGUMENT")
                }
            // Speech synthesis. Ungated, like the flashlight: speaking needs no
            // permission and no entitlement.
            case "speak":
                if let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speak(text, body: body, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "speak needs some text to say", code: "INVALID_ARGUMENT")
                }
            case "stopSpeaking":
                stopSpeaking(callbackId: callbackId)
            // Vibrate pattern
            case "vibrate":
                if let pattern = body["pattern"] as? [Int] {
                    vibratePattern(pattern)
                } else {
                    CraftNativeActions.triggerHaptic(style: "medium")
                }
                resolveCallback(callbackId, result: true)
            // Open URL
            case "openURL":
                if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                    resolveCallback(callbackId, result: true)
                } else {
                    rejectCallback(callbackId, error: "openURL needs a URL it can parse", code: "INVALID_ARGUMENT")
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
                } else {
                    rejectCallback(callbackId, error: "Contacts access is disabled", code: "CAPABILITY_DISABLED")
                }
            case "addContact":
                if config.enableContacts {
                    if let contactData = body["contact"] as? [String: Any] {
                        addContact(contactData, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "addContact was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Contacts access is disabled", code: "CAPABILITY_DISABLED")
                }
            // MARK: - Calendar
            case "getCalendarEvents":
                if config.enableCalendar {
                    let startDate = body["startDate"] as? Double
                    let endDate = body["endDate"] as? Double
                    getCalendarEvents(startDate: startDate, endDate: endDate, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                }
            case "createCalendarEvent":
                if config.enableCalendar {
                    if let eventData = body["event"] as? [String: Any] {
                        createCalendarEvent(eventData, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "createCalendarEvent was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                }
            case "deleteCalendarEvent":
                if config.enableCalendar {
                    if let eventId = body["eventId"] as? String {
                        deleteCalendarEvent(eventId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "deleteCalendarEvent was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                }
            // MARK: - Local Notifications
            case "scheduleNotification":
                if config.enableLocalNotifications {
                    if let notifData = body["notification"] as? [String: Any] {
                        scheduleLocalNotification(notifData, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "scheduleNotification was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Local notifications are disabled", code: "CAPABILITY_DISABLED")
                }
            case "cancelNotification":
                if config.enableLocalNotifications {
                    if let notifId = body["id"] as? String {
                        cancelLocalNotification(notifId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "cancelNotification was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Local notifications are disabled", code: "CAPABILITY_DISABLED")
                }
            case "cancelAllNotifications":
                if config.enableLocalNotifications {
                    cancelAllLocalNotifications(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Local notifications are disabled", code: "CAPABILITY_DISABLED")
                }
            case "getPendingNotifications":
                if config.enableLocalNotifications {
                    getPendingNotifications(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Local notifications are disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Deep Links
            case "registerDeepLinkHandler":
                if config.enableDeepLinks {
                    // Handler is registered in JS
                    resolveCallback(callbackId, result: true)
                } else {
                    rejectCallback(callbackId, error: "Deep links are disabled", code: "CAPABILITY_DISABLED")
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
                } else {
                    rejectCallback(callbackId, error: "Deep links are disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - In-App Purchase
            case "getProducts":
                if config.enableInAppPurchase {
                    if let productIds = body["productIds"] as? [String] {
                        getProducts(productIds, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "getProducts was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "In-app purchase is disabled", code: "CAPABILITY_DISABLED")
                }
            case "purchase":
                if config.enableInAppPurchase {
                    if let productId = body["productId"] as? String {
                        purchaseProduct(productId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "purchase was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "In-app purchase is disabled", code: "CAPABILITY_DISABLED")
                }
            case "restorePurchases":
                if config.enableInAppPurchase {
                    restorePurchases(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "In-app purchase is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Keep Awake
            case "setKeepAwake":
                if config.enableKeepAwake {
                    if let enabled = body["enabled"] as? Bool {
                        setKeepAwake(enabled, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "setKeepAwake was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Keep awake is disabled", code: "CAPABILITY_DISABLED")
                }
            // MARK: - Orientation Lock
            case "lockOrientation":
                if config.enableOrientationLock {
                    if let orientation = body["orientation"] as? String {
                        lockOrientation(orientation, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "lockOrientation was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Orientation lock is disabled", code: "CAPABILITY_DISABLED")
                }
            case "unlockOrientation":
                if config.enableOrientationLock {
                    unlockOrientation(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Orientation lock is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - QR/Barcode Scanner
            case "scanQRCode":
                if config.enableQRScanner {
                    scanQRCode(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "QR scanning is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - File Picker
            case "pickFile":
                if config.enableFilePicker {
                    let types = body["types"] as? [String]
                    pickFile(types: types, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "File picker is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - File Download
            case "downloadFile":
            if config.enableFileDownload {
                    if let url = body["url"] as? String, let filename = body["filename"] as? String {
                            downloadFile(url: url, filename: filename, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "downloadFile was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
            } else {
                rejectCallback(callbackId, error: "File download is disabled", code: "CAPABILITY_DISABLED")
            }
            case "saveFile":
            if config.enableFileDownload {
                    if let data = body["data"] as? String, let filename = body["filename"] as? String {
                            saveFile(data: data, filename: filename, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "saveFile was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
            } else {
                rejectCallback(callbackId, error: "File download is disabled", code: "CAPABILITY_DISABLED")
            }
            // MARK: - Social Auth
            case "signInWithApple":
                if config.enableSocialAuth {
                    signInWithApple(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Social sign-in is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Audio Recording
            case "startAudioRecording":
                if config.enableAudioRecording {
                    startAudioRecording(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Audio recording is disabled", code: "CAPABILITY_DISABLED")
                }
            case "stopAudioRecording":
                if config.enableAudioRecording {
                    stopAudioRecording(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Audio recording is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Video Recording
            case "startVideoRecording":
                if config.enableVideoRecording {
                    startVideoRecording(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Video recording is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Motion Sensors
            case "startMotionUpdates":
                if config.enableMotionSensors {
                    let interval = body["interval"] as? Double ?? 100
                    startMotionUpdates(interval: interval, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Motion sensors are disabled", code: "CAPABILITY_DISABLED")
                }
            case "stopMotionUpdates":
                stopMotionUpdates()
                resolveCallback(callbackId, result: true)

            // MARK: - Local Database
            case "dbExecute":
                if config.enableLocalDatabase {
                    if let sql = body["sql"] as? String {
                        let params = body["params"] as? [Any]
                        dbExecute(sql: sql, params: params, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "dbExecute was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Local database is disabled", code: "CAPABILITY_DISABLED")
                }
            case "dbQuery":
                if config.enableLocalDatabase {
                    if let sql = body["sql"] as? String {
                        let params = body["params"] as? [Any]
                        dbQuery(sql: sql, params: params, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "dbQuery was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Local database is disabled", code: "CAPABILITY_DISABLED")
                }
            // MARK: - Bluetooth
            case "startBluetoothScan":
                if config.enableBluetooth {
                    startBluetoothScan(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Bluetooth is disabled", code: "CAPABILITY_DISABLED")
                }
            case "stopBluetoothScan":
                stopBluetoothScan()
                resolveCallback(callbackId, result: true)

            // MARK: - NFC
            case "scanNFC":
                if config.enableNFC {
                    scanNFC(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "NFC is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Health
            case "requestHealthAuthorization":
                if config.enableHealthKit {
                    let types = body["types"] as? [String] ?? []
                    requestHealthAuthorization(types: types, readOnly: body["readOnly"] as? Bool ?? false, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled", code: "CAPABILITY_DISABLED")
                }
            case "getHealthData":
                if config.enableHealthKit {
                    if let dataType = body["type"] as? String {
                        let startDate = body["startDate"] as? Double
                        let endDate = body["endDate"] as? Double
                        getHealthData(type: dataType, startDate: startDate, endDate: endDate, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "getHealthData was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled", code: "CAPABILITY_DISABLED")
                }
            case "saveHealthWorkout":
                if config.enableHealthKit {
                    saveHealthWorkout(body: body, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled")
                }
            case "getHealthWorkouts":
                if config.enableHealthKit {
                    getHealthWorkouts(
                        startDate: body["startDate"] as? Double,
                        endDate: body["endDate"] as? Double,
                        limit: body["limit"] as? Int,
                        callbackId: callbackId
                    )
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled", code: "CAPABILITY_DISABLED")
                }
            case "getHealthDailyStatistics":
                if config.enableHealthKit {
                    if let dataType = body["type"] as? String {
                        getHealthDailyStatistics(
                            type: dataType,
                            startDate: body["startDate"] as? Double,
                            endDate: body["endDate"] as? Double,
                            callbackId: callbackId
                        )
                    } else {
                        rejectCallback(callbackId, error: "getHealthDailyStatistics was called without a type", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "HealthKit is disabled", code: "CAPABILITY_DISABLED")
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
                endLiveActivity(body: body, callbackId: callbackId)

            // MARK: - Screen Capture
            case "takeScreenshot":
                if config.enableScreenCapture {
                    takeScreenshot(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Screen capture is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - Background Tasks
            case "registerBackgroundTask":
                if config.enableBackgroundTasks {
                    if let taskId = body["taskId"] as? String {
                        registerBackgroundTask(taskId: taskId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "registerBackgroundTask was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Background tasks are disabled", code: "CAPABILITY_DISABLED")
                }
            case "scheduleBackgroundTask":
                if config.enableBackgroundTasks {
                    if let taskId = body["taskId"] as? String {
                        let delay = body["delay"] as? Double ?? 900 // 15 minutes default
                        let requiresNetwork = body["requiresNetwork"] as? Bool ?? false
                        let requiresCharging = body["requiresCharging"] as? Bool ?? false
                        scheduleBackgroundTask(taskId: taskId, delay: delay, requiresNetwork: requiresNetwork, requiresCharging: requiresCharging, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "scheduleBackgroundTask was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Background tasks are disabled", code: "CAPABILITY_DISABLED")
                }
            case "cancelBackgroundTask":
                if config.enableBackgroundTasks {
                    if let taskId = body["taskId"] as? String {
                        cancelBackgroundTask(taskId: taskId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "cancelBackgroundTask was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Background tasks are disabled", code: "CAPABILITY_DISABLED")
                }
            case "cancelAllBackgroundTasks":
                if config.enableBackgroundTasks {
                    cancelAllBackgroundTasks(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Background tasks are disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - PDF Viewer
            case "openPDF":
                if config.enablePDFViewer {
                    if let source = body["source"] as? String {
                        let page = body["page"] as? Int ?? 0
                        openPDF(source: source, page: page, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "openPDF was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "PDF viewing is disabled", code: "CAPABILITY_DISABLED")
                }
            case "closePDF":
                closePDF(callbackId: callbackId)

            // MARK: - Contacts Picker
            case "pickContact":
                if config.enableContacts {
                    let multiple = body["multiple"] as? Bool ?? false
                    pickContact(multiple: multiple, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "Contacts access is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - App Shortcuts
            case "setShortcuts":
                if let shortcuts = body["shortcuts"] as? [[String: Any]] {
                    setAppShortcuts(shortcuts: shortcuts, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "setShortcuts needs a list of shortcuts", code: "INVALID_ARGUMENT")
                }
            case "clearShortcuts":
                clearAppShortcuts(callbackId: callbackId)

            // MARK: - Keychain Sharing
            case "setSharedItem":
                if let key = body["key"] as? String,
                   let value = body["value"] as? String {
                    let group = body["group"] as? String
                    setSharedKeychainItem(key: key, value: value, group: group, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "setSharedItem needs both a key and a value", code: "INVALID_ARGUMENT")
                }
            case "getSharedItem":
                if let key = body["key"] as? String {
                    let group = body["group"] as? String
                    getSharedKeychainItem(key: key, group: group, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "getSharedItem needs a key", code: "INVALID_ARGUMENT")
                }
            case "removeSharedItem":
                if let key = body["key"] as? String {
                    let group = body["group"] as? String
                    removeSharedKeychainItem(key: key, group: group, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "removeSharedItem needs a key", code: "INVALID_ARGUMENT")
                }

            // MARK: - Local Auth Persistence
            case "setBiometricPersistence":
                if let enabled = body["enabled"] as? Bool {
                    let duration = body["duration"] as? Double ?? 300 // 5 min default
                    setBiometricPersistence(enabled: enabled, duration: duration, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "setBiometricPersistence needs true or false", code: "INVALID_ARGUMENT")
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
                } else {
                    rejectCallback(callbackId, error: "AR is disabled", code: "CAPABILITY_DISABLED")
                }
            case "stopAR":
                if config.enableAR {
                    stopAR(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "AR is disabled", code: "CAPABILITY_DISABLED")
                }
            case "placeARObject":
                if config.enableAR {
                    if let model = body["model"] as? String {
                        let position = body["position"] as? [String: Double]
                        placeARObject(model: model, position: position, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "placeARObject was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "AR is disabled", code: "CAPABILITY_DISABLED")
                }
            case "removeARObject":
                if config.enableAR {
                    if let objectId = body["objectId"] as? String {
                        removeARObject(objectId: objectId, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "removeARObject was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "AR is disabled", code: "CAPABILITY_DISABLED")
                }
            case "getARPlanes":
                if config.enableAR {
                    getARPlanes(callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "AR is disabled", code: "CAPABILITY_DISABLED")
                }

            // MARK: - ML (Core ML / Vision)
            case "classifyImage":
                if config.enableMLKit {
                    if let imageBase64 = body["image"] as? String {
                        classifyImage(imageBase64: imageBase64, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "classifyImage was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Vision is disabled", code: "CAPABILITY_DISABLED")
                }
            case "detectObjects":
                if config.enableMLKit {
                    if let imageBase64 = body["image"] as? String {
                        detectObjects(imageBase64: imageBase64, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "detectObjects was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Vision is disabled", code: "CAPABILITY_DISABLED")
                }
            case "recognizeText":
                if config.enableMLKit {
                    if let imageBase64 = body["image"] as? String {
                        recognizeText(imageBase64: imageBase64, callbackId: callbackId)
                    } else {
                        rejectCallback(callbackId, error: "recognizeText was called without the values it needs", code: "INVALID_ARGUMENT")
                    }
                } else {
                    rejectCallback(callbackId, error: "Vision is disabled", code: "CAPABILITY_DISABLED")
                }
            // MARK: - Widget
            case "updateWidget":
                if let data = body["data"] as? [String: Any] {
                    updateWidget(data: data, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "updateWidget needs a data object", code: "INVALID_ARGUMENT")
                }
            case "reloadWidgets":
                reloadAllWidgets(callbackId: callbackId)

            // MARK: - Siri Shortcuts
            case "registerSiriShortcut":
                if let phrase = body["phrase"] as? String,
                   let action = body["shortcutAction"] as? String {
                    registerSiriShortcut(phrase: phrase, action: action, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "registerSiriShortcut needs both a phrase and a shortcutAction", code: "INVALID_ARGUMENT")
                }
            case "removeSiriShortcut":
                if let action = body["shortcutAction"] as? String {
                    removeSiriShortcut(action: action, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "removeSiriShortcut needs a shortcutAction", code: "INVALID_ARGUMENT")
                }

            // MARK: - Watch Connectivity
            case "sendToWatch":
                if let message = body["message"] as? [String: Any] {
                    sendMessageToWatch(message: message, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "sendToWatch needs a message object", code: "INVALID_ARGUMENT")
                }
            case "updateWatchContext":
                if let context = body["context"] as? [String: Any] {
                    updateWatchContext(context: context, callbackId: callbackId)
                } else {
                    rejectCallback(callbackId, error: "updateWatchContext needs a context object", code: "INVALID_ARGUMENT")
                }
            case "isWatchReachable":
                isWatchReachable(callbackId: callbackId)

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            CraftEventManager.shared.setLoading()
            DeepLinkManager.shared.setLoading()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // A new document: the old one's ready no longer counts.
            documentReady = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            CraftChrome.shared.pageFinished()
            CraftChrome.shared.publishLayout()
            guard isTrustedURL(webView.url) else { return }
            // The bridge is a document-start user script, so it is normally
            // here long before this. A document that came without it is given
            // it now, the way every page used to be, so no page is ever worse
            // off than before the user script.
            webView.evaluateJavaScript("!!(window.craft && window.craft._callbacks && window.craft.platform === 'ios')") { [weak self, weak webView] installed, _ in
                guard let self, let webView, (installed as? Bool) != true else { return }
                webView.evaluateJavaScript(self.bridgeScript(), completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // A link that opens a new window (target=_blank) has no frame to
            // load into. It is allowed on, so WebKit asks the UI delegate's
            // `createWebViewWith`, which decides where it goes.
            if navigationAction.targetFrame == nil {
                decisionHandler(.allow)
                return
            }
            if isTrustedURL(url) {
                // A new main-frame document gets the bridge seeded from the
                // ids handed out so far (#226), so the user scripts are
                // rebuilt before it exists rather than once per web view.
                if navigationAction.targetFrame?.isMainFrame == true {
                    installUserScripts(into: webView.configuration.userContentController)
                }
                decisionHandler(.allow)
                return
            }
            // An iframe the app's page embeds loads in place. Only the main
            // frame's navigations leave for Safari: cancelling the frame's
            // too left every embed blank, a YouTube or Vimeo player among them.
            if let frame = navigationAction.targetFrame, !frame.isMainFrame, isEmbeddableFrameURL(url) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// What an iframe inside the app's page may load: a video player, a
        /// payment form, a map. It stays inside its frame, and the bridge
        /// answers only `isTrustedOrigin`, so loading one reaches nothing
        /// native. Plain http is left to the trusted local origins.
        private func isEmbeddableFrameURL(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "https", "about", "data", "blob":
                return true
            default:
                return false
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // The navigation never replaced the page, so the page that was
            // ready still is. Without this, events stayed queued for the rest
            // of its life after one cancelled tap.
            if documentReady {
                DeepLinkManager.shared.setReady()
                CraftEventManager.shared.setReady()
            }
            fallBackIfUnreachable(webView, after: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fallBackIfUnreachable(webView, after: error)
        }

        /// Both used to fall back on *any* error, -999 included, so a second
        /// tap before the first page committed ended the session on the bundle.
        private func fallBackIfUnreachable(_ webView: WKWebView, after error: Error) {
            guard CraftLoadFailure.isUnreachable(error) else { return }
            loadBundledFallback(in: webView)
        }

        private func loadBundledFallback(in webView: WKWebView) {
            guard !loadedBundledFallback,
                  config.devServerURL != nil,
                  let bundledURL = URL(string: "craft://app/index.html") else { return }
            loadedBundledFallback = true
            webView.load(URLRequest(url: bundledURL))
        }

        /// Leave the bundled copy for the remote origin again (#252).
        ///
        /// It used to be one-way for the life of the process, and the bundle
        /// cannot reach a frontend's API by relative path — so one dropped
        /// connection meant no API until the app was killed.
        ///
        /// Called when connectivity comes back and when the app returns to the
        /// foreground, never on every path update. If the remote is still out
        /// of reach, the load fails with a connectivity error and falls back
        /// again: one round trip per trigger, not a loop.
        private func returnFromBundledFallback(because reason: String) {
            guard loadedBundledFallback,
                  let webView,
                  let remote = config.devServerURL.flatMap(URL.init(string:)) else { return }
            loadedBundledFallback = false
            print("Craft: \(reason); loading \(remote) again instead of the bundled copy")
            webView.load(config.request(for: remote))
        }

        @objc private func appWillEnterForeground(_ notification: Notification) {
            returnFromBundledFallback(because: "the app returned to the foreground")
        }

        /// Load the app's own page again, now, because someone asked.
        ///
        /// Unlike `returnFromBundledFallback` it does not wait for a trigger
        /// and works from any page. If the remote is still out of reach the
        /// load fails as unreachable and the bundled copy comes back.
        private func retryRemote() {
            guard let webView else { return }
            guard let remote = config.devServerURL.flatMap(URL.init(string:)) else {
                webView.reload()
                return
            }
            loadedBundledFallback = false
            webView.load(config.request(for: remote))
        }

        fileprivate func isTrustedURL(_ url: URL?) -> Bool {
            guard let url = url else { return false }
            return isTrustedOrigin(scheme: url.scheme ?? "", host: url.host ?? "", port: url.port ?? 0)
        }

        /// The single answer to "may this origin reach native?".
        ///
        /// The bundled app is served from craft://app by
        /// `BundledAssetSchemeHandler`, and it is the only content a generated
        /// app loads when no dev server is configured. That origin used to be
        /// trusted for *navigation* only: `isTrustedURL` carried the clause,
        /// while the `userContentController` guard called this function
        /// directly and fell through to the https/localhost check. So every
        /// bridge call from the app's own page was answered with
        ///
        ///     Blocked Craft bridge message from untrusted origin: craft://app
        ///
        /// and its promise never settled — the whole native surface was dead
        /// in the default configuration, which is the one every generated app
        /// ships with. Two guards that had to agree, and did not. There is one
        /// now, and `scripts/mobile-e2e.ts` runs a real round trip on a booted
        /// simulator so a future hardening pass cannot quietly take the bridge
        /// away again.
        /// Whether a message from this origin may drive the app's chrome.
        func trusts(_ origin: WKSecurityOrigin) -> Bool {
            isTrustedOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
        }

        private func isTrustedOrigin(scheme: String, host: String, port: Int) -> Bool {
            if scheme == "craft" && host == "app" { return true }
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

        /// Raise the seed to cover an id the page has just used.
        ///
        /// Every call the page makes arrives here first, including the ones
        /// Zig serves, so this sees the whole range a load hands out.
        private func noteCallbackId(_ callbackId: String?) {
            guard let callbackId, callbackId.hasPrefix("cb_"),
                  let drawn = Int(callbackId.dropFirst(3)) else { return }
            if drawn > highestCallbackId { highestCallbackId = drawn }
        }

        /// Hand the coordinator the web view it serves, as soon as it exists.
        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        /// Every script the page gets before its own first byte runs, in order.
        ///
        /// The bridge used to be evaluated in `didFinish`: after every image,
        /// font and script of the page had loaded, on every navigation, as
        /// some 1800 lines of fresh source each time. A page could not reach
        /// `window.craft` while it was starting, which is when it most wants
        /// to, and everything native tried to tell it before then was lost.
        /// As document-start user scripts it exists before any of the page's
        /// own code, and WebKit installs it for each document itself.
        ///
        /// Called at creation and again before each main-frame navigation,
        /// because the bridge carries the callback seed (#226) and a seed
        /// fixed at creation would repeat ids across reloads.
        func installUserScripts(into controller: WKUserContentController) {
            controller.removeAllUserScripts()
            // From the first byte, so the page's CSS knows before it paints
            // that the shell draws the tab bar, and does not draw its own for
            // a frame.
            controller.addUserScript(WKUserScript(source: "document.documentElement.setAttribute('data-craft-chrome','ios')", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            #if DEBUG
            controller.addUserScript(WKUserScript(source: PageConsoleRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            #endif
            controller.addUserScript(WKUserScript(source: CraftChrome.paintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        /// The page announced the bridge (`craftReady`): from here it can be
        /// told things. Whatever arrived while it could not be is delivered now.
        private func pageBecameReady() {
            documentReady = true
            DeepLinkManager.shared.setReady()
            CraftEventManager.shared.setReady()
        }

        /// The origins the bridge script installs itself in, as the page
        /// spells them (`location.protocol + '//' + location.host`). The same
        /// set `isTrustedOrigin` answers for; the message handlers still check
        /// every message, so this only keeps the bridge out of pages that
        /// could not use it.
        private func trustedPageOrigins() -> [String] {
            var origins = config.trustedOrigins
            if let devServerURL = config.devServerURL,
               let components = URLComponents(string: devServerURL),
               let host = components.host,
               let scheme = components.scheme {
                let defaultPort = scheme == "https" ? 443 : 80
                let port = components.port ?? defaultPort
                origins.append("\(scheme)://\(host)\(port == defaultPort ? "" : ":\(port)")")
            }
            return origins.compactMap { origin in
                guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host else { return nil }
                guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
                let defaultPort = scheme == "https" ? 443 : 80
                let port = url.port ?? defaultPort
                let shownHost = host.contains(":") ? "[\(host)]" : host
                return "\(scheme)://\(shownHost)\(port == defaultPort ? "" : ":\(port)")"
            }
        }

        /// The bridge, as the source the page runs. Only in a trusted page:
        /// the check is the first thing it does.
        func bridgeScript() -> String {
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
                    speech: true,
                    network: true,
                    deviceInfo: true,
                    badge: true,
                    appReview: true
                },

                _callbacks: {},
                // Not 0: an id must not repeat one an earlier load of this
                // page is still waiting on an answer for (#226).
                _callbackId: \(highestCallbackId),

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

                // Flat SDK compatibility methods. The native dispatcher already
                // owns these actions; keep the public CraftBridge shape callable
                // while the versioned API below provides the namespaced form.
                scanNFC: function() {
                    return this._invoke('scanNFC');
                },
                scanQRCode: function() {
                    return this._invoke('scanQRCode');
                },
                takeScreenshot: function() {
                    return this._invoke('takeScreenshot');
                },
                startAudioRecording: function() {
                    return this._invoke('startAudioRecording');
                },
                stopAudioRecording: function() {
                    return this._invoke('stopAudioRecording');
                },
                startVideoRecording: function() {
                    return this._invoke('startVideoRecording');
                },
                pickFile: function(types) {
                    return this._invoke('pickFile', {types: types || []});
                },
                downloadFile: function(url, filename) {
                    return this._invoke('downloadFile', {url: url, filename: filename});
                },
                saveFile: function(data, filename, mimeType) {
                    return this._invoke('saveFile', {data: data, filename: filename, mimeType: mimeType});
                },
                startMotionUpdates: function() {
                    return this._invoke('startMotionUpdates');
                },
                stopMotionUpdates: function() {
                    return this._invoke('stopMotionUpdates');
                },
                getCurrentPosition: function() {
                    return this.geolocation.getCurrentPosition({});
                },
                watchPosition: function(callback) {
                    return this.location.watchPosition(callback);
                },
                clearWatch: function(watchId) {
                    return this.location.clearWatch(watchId);
                },
                getContacts: function() {
                    return this._invoke('getContacts');
                },
                addContact: function(contact) {
                    return this._invoke('addContact', {contact: contact});
                },
                getCalendarEvents: function(startDate, endDate) {
                    return this._invoke('getCalendarEvents', {startDate: startDate, endDate: endDate});
                },
                createCalendarEvent: function(event) {
                    return this._invoke('createCalendarEvent', {event: event});
                },
                deleteCalendarEvent: function(eventId) {
                    return this._invoke('deleteCalendarEvent', {eventId: eventId});
                },
                scheduleNotification: function(notification) {
                    return this._invoke('scheduleNotification', {notification: notification});
                },
                cancelNotification: function(id) {
                    return this._invoke('cancelNotification', {id: id});
                },
                cancelAllNotifications: function() {
                    return this._invoke('cancelAllNotifications');
                },
                getPendingNotifications: function() {
                    return this._invoke('getPendingNotifications');
                },
                getProducts: function(productIds) {
                    return this.iap.getProducts(productIds);
                },
                purchase: function(productId) {
                    return this.iap.purchase(productId);
                },
                restorePurchases: function() {
                    return this._invoke('restorePurchases');
                },
                signInWithApple: function() {
                    return this._invoke('signInWithApple');
                },
                signInWithGoogle: function() {
                    return Promise.reject(new Error('Google Sign-In is unavailable on iOS'));
                },
                startBluetoothScan: function() {
                    return this._invoke('startBluetoothScan');
                },
                stopBluetoothScan: function() {
                    return this._invoke('stopBluetoothScan');
                },
                requestHealthAuthorization: function(types) {
                    return this._invoke('requestHealthAuthorization', {types: types || []});
                },
                getHealthData: function(type, startDate, endDate) {
                    var start = startDate instanceof Date ? startDate.getTime() : startDate;
                    var end = endDate instanceof Date ? endDate.getTime() : endDate;
                    return this._invoke('getHealthData', {type: type, startDate: start, endDate: end});
                },
                requestFitnessAuthorization: function() {
                    return Promise.reject(new Error('Android fitness APIs are unavailable on iOS'));
                },
                getFitnessData: function() {
                    return Promise.reject(new Error('Android fitness APIs are unavailable on iOS'));
                },

                // Resolves true once UIKit has taken the haptic, and rejects
                // CAPABILITY_DISABLED when enableHaptics is off.
                haptic: function(style) {
                    var self = window.craft;
                    var id = 'cb_' + (++self._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'haptic', style: style || 'medium', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                // Resolves true once native has taken the request, not once
                // audio is flowing. What happens next (a prompt declined, no
                // recognizer, a transcript) still arrives as craftSpeech*
                // events, because none of it is known when this answers.
                startListening: function() {
                    var self = window.craft;
                    var id = 'cb_' + (++self._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'startListening', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                stopListening: function() {
                    var self = window.craft;
                    var id = 'cb_' + (++self._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'stopListening', callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
                },

                share: function(text) {
                    return this._share({text: text});
                },

                // Both share entry points come through here, because the
                // native side answers them the same way: `true` when the
                // person finished an activity, `false` when they dismissed
                // the sheet, a rejection when sharing is disabled or there is
                // nothing to share. The flat `share` used to post with no
                // callbackId, so every one of those answers stopped at the nil
                // guard in resolveCallback and the page got `undefined`.
                //
                // No timeout, unlike `_invoke`'s thirty seconds. The sheet
                // waits on a person, and someone slower than that to pick an
                // app would be told the share failed while it was still on
                // screen, with the real answer then dropped.
                _share: function(payload) {
                    var self = this;
                    var id = 'cb_' + (++this._callbackId);
                    window.webkit.messageHandlers.craft.postMessage(Object.assign({}, payload, {action: 'share', callbackId: id}));
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
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
                    getCurrentPosition: function(options) {
                        options = options || {};
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        var requestedTimeout = Number(options.timeout);
                        var timeoutMs = Number.isFinite(requestedTimeout) && requestedTimeout >= 0
                            ? Math.min(requestedTimeout, 2147483647)
                            : 30000;
                        return new Promise(function(resolve, reject) {
                            var timeout;
                            self._callbacks[id] = {
                                resolve: function(value) { clearTimeout(timeout); resolve(value); },
                                reject: function(error) {
                                    clearTimeout(timeout);
                                    var locationErrorCode = error && ({
                                        'PERMISSION_DENIED': 1,
                                        'POSITION_UNAVAILABLE': 2,
                                        'NATIVE_CALL_FAILED': 2,
                                        'TIMEOUT': 3,
                                        'LOCATION_TIMEOUT': 3
                                    })[error.code];
                                    if (locationErrorCode) {
                                        error.name = 'GeolocationPositionError';
                                        error.code = locationErrorCode;
                                    }
                                    reject(error);
                                }
                            };
                            timeout = setTimeout(function() {
                                if (!self._callbacks[id]) return;
                                delete self._callbacks[id];
                                var error = new Error('Location request timed out after ' + timeoutMs + 'ms');
                                error.name = 'GeolocationPositionError';
                                error.code = 3;
                                error.bridge = true;
                                reject(error);
                            }, timeoutMs);
                            try {
                                window.webkit.messageHandlers.craft.postMessage({
                                    action: 'getCurrentPosition',
                                    callbackId: id,
                                    enableHighAccuracy: options.enableHighAccuracy === true,
                                    timeout: timeoutMs,
                                    maximumAge: Number.isFinite(Number(options.maximumAge))
                                        ? Math.max(0, Number(options.maximumAge))
                                        : 0
                                });
                            } catch (error) {
                                clearTimeout(timeout);
                                delete self._callbacks[id];
                                reject(error);
                            }
                        });
                    },
                    // Resolves true once updates have started, before any
                    // authorization answer. A later refusal arrives as a
                    // craftLocationError event.
                    watchPosition: function(callback) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.addEventListener('craftLocationUpdate', function(e) { callback(e.detail); });
                        window.webkit.messageHandlers.craft.postMessage({action: 'watchPosition', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    clearWatch: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'clearWatch', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
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
                    this.offNetworkChange();
                    this._networkChangeHandler = function(e) { callback(e.detail); };
                    window.addEventListener('craftNetworkChange', this._networkChangeHandler);
                },
                offNetworkChange: function() {
                    if (!this._networkChangeHandler) return;
                    window.removeEventListener('craftNetworkChange', this._networkChangeHandler);
                    this._networkChangeHandler = null;
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
                        self._callbacks[id] = {
                            resolve: function(value) { self._flashlightEnabled = enabled; resolve(value); },
                            reject: reject
                        };
                    });
                },
                toggleFlashlight: function() {
                    return this.setFlashlight(!this._flashlightEnabled);
                },

                // Vibrate
                vibrate: function(pattern) {
                    var self = window.craft;
                    var id = 'cb_' + (++self._callbackId);
                    window.webkit.messageHandlers.craft.postMessage({action: 'vibrate', pattern: pattern, callbackId: id});
                    return new Promise(function(resolve, reject) {
                        self._callbacks[id] = {resolve: resolve, reject: reject};
                    });
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
                onAppStateChange: function(callback) {
                    this.offAppStateChange();
                    this._appStateChangeHandler = function() {
                        callback(document.visibilityState === 'visible' ? 'active' : 'background');
                    };
                    document.addEventListener('visibilitychange', this._appStateChangeHandler);
                },
                offAppStateChange: function() {
                    if (!this._appStateChangeHandler) return;
                    document.removeEventListener('visibilitychange', this._appStateChangeHandler);
                    this._appStateChangeHandler = null;
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

                // Speech synthesis. speak() settles when the utterance ends:
                // true when it was spoken, false when something stopped it.
                // No timeout, because a long sentence at a slow rate can
                // outlast any deadline that would be fair to a short one.
                speech: {
                    speak: function(text, options) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        options = options || {};
                        window.webkit.messageHandlers.craft.postMessage({
                            action: 'speak',
                            text: text == null ? '' : String(text),
                            rate: typeof options.rate === 'number' ? options.rate : null,
                            language: typeof options.language === 'string' ? options.language : null,
                            interrupt: options.interrupt !== false,
                            callbackId: id
                        });
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    stop: function() {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'stopSpeaking', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    }
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
                    return window.craft._subscribeDeepLinks(callback);
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
                        // `shortcutAction`, not `action`. This object had two
                        // keys called `action` — the message's own, and the
                        // shortcut's — and the later one wins, so every call
                        // arrived labelled with the shortcut's identifier
                        // instead of 'registerSiriShortcut'. No switch arm
                        // matched, nothing answered, and these wrappers park in
                        // `_callbacks` with no timeout: the promise never
                        // settled at all.
                        window.webkit.messageHandlers.craft.postMessage({action: 'registerSiriShortcut', phrase: phrase, shortcutAction: action, callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    remove: function(action) {
                        var self = window.craft;
                        var id = 'cb_' + (++self._callbackId);
                        // The same duplicate key as `register` above.
                        window.webkit.messageHandlers.craft.postMessage({action: 'removeSiriShortcut', shortcutAction: action, callbackId: id});
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
                        self._claimInitialDeepLink();
                        var id = 'cb_' + (++self._callbackId);
                        window.webkit.messageHandlers.craft.postMessage({action: 'getInitialURL', callbackId: id});
                        return new Promise(function(resolve, reject) {
                            self._callbacks[id] = {resolve: resolve, reject: reject};
                        });
                    },
                    onLink: function(callback) {
                        return window.craft._subscribeDeepLinks(callback);
                    }
                },

                // OTA Updates
                ota: {
                    _config: null,
                    _status: 'idle',

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
                        throw new Error('craft.ota.onProgress is not implemented on this platform');
                    },
                    onStatusChange: function(callback) {
                        throw new Error('craft.ota.onStatusChange is not implemented on this platform');
                    }
                },

                log: function(msg) {
                    window.webkit.messageHandlers.craft.postMessage({action: 'log', message: msg});
                }
            };

            // Stable, versioned mobile contract consumed by craft-native/mobile.
            // Legacy flat methods remain available while every public SDK method
            // is routed through this nested contract.
            // Links that arrive before anything is listening (#198).
            //
            // The native side dispatches a link the moment this script has
            // run, and on a cold start that is the link the app was opened
            // with. No page code can have called onLink by then: onLink is
            // defined by this very script. So every such link was dispatched
            // to nobody, and a page that subscribes, rather than asking
            // getInitialURL, never learned how it was opened.
            //
            // Held here instead, and handed to the first subscriber on the
            // next turn, so an unsubscribe returned in the same tick still
            // applies. The launch link belongs to getInitialURL once the page
            // has called it, whether native has dispatched it yet or not, so a
            // page that does both in the same tick, in either order, gets it
            // once. That includes a craftReady handler, which runs before
            // native dispatches anything. A page that asks getInitialURL only
            // later, after an await, should skip `initial` in onLink.
            //
            // The same block runs on Android (#215), where this script can run
            // twice in one document, so its state lives on window.
            (function installDeepLinkReplay(craft) {
                var replay = window.__craftDeepLinkReplay;
                if (!replay) {
                    replay = window.__craftDeepLinkReplay = {undelivered: [], subscribed: false, initialClaimed: false};
                    window.addEventListener('craftDeepLink', function(e) {
                        if (!replay.subscribed && !claimed(e.detail)) replay.undelivered.push(e.detail);
                    });
                }
                function claimed(detail) {
                    return replay.initialClaimed && detail && detail.initial;
                }
                craft._subscribeDeepLinks = function(callback) {
                    var active = true;
                    var listener = function(e) { if (!claimed(e.detail)) callback(e.detail); };
                    window.addEventListener('craftDeepLink', listener);
                    if (!replay.subscribed) {
                        replay.subscribed = true;
                        setTimeout(function() {
                            var pending = replay.undelivered;
                            replay.undelivered = [];
                            if (!active) return;
                            pending.forEach(function(detail) { callback(detail); });
                        }, 0);
                    }
                    return function() {
                        active = false;
                        window.removeEventListener('craftDeepLink', listener);
                    };
                };
                craft._claimInitialDeepLink = function() {
                    replay.initialClaimed = true;
                    replay.undelivered = replay.undelivered.filter(function(detail) { return !(detail && detail.initial); });
                };
            })(window.craft);

            // A notification tap that arrived before anything subscribed.
            //
            // On a cold launch the tap is flushed the moment the bridge is
            // ready, and a page that wires its listener once its router has
            // hydrated — which is most single-page apps — was not listening
            // yet, so "open the thing this notification is about" opened the
            // home screen instead. Deep links hit the same wall (#198) and
            // are held the same way: state on window, so a second injection
            // into the same page does not start a fresh buffer, and the first
            // subscriber is handed whatever it missed.
            (function installNotificationTapReplay(craft) {
                var replay = window.__craftNotificationTapReplay;
                if (!replay) {
                    replay = window.__craftNotificationTapReplay = {undelivered: [], subscribed: false};
                    window.addEventListener('craftNotificationResponse', function(e) {
                        if (!replay.subscribed) replay.undelivered.push(e.detail);
                    });
                }
                craft._subscribeNotificationTaps = function(callback) {
                    var active = true;
                    var listener = function(e) { callback(e.detail); };
                    window.addEventListener('craftNotificationResponse', listener);
                    if (!replay.subscribed) {
                        replay.subscribed = true;
                        setTimeout(function() {
                            var pending = replay.undelivered;
                            replay.undelivered = [];
                            if (!active) return;
                            pending.forEach(function(detail) { callback(detail); });
                        }, 0);
                    }
                    return function() {
                        active = false;
                        window.removeEventListener('craftNotificationResponse', listener);
                    };
                };
                if (craft.notifications) {
                    craft.notifications.onTap = function(callback) {
                        return craft._subscribeNotificationTaps(callback);
                    };
                    // A notification that arrived while the page was open.
                    // Live only, with nothing held: it matters to a page that
                    // is running, and one that subscribes later has no use for
                    // an arrival it was not there to see.
                    craft.notifications.onReceive = function(callback) {
                        var listener = function(e) { callback(e.detail); };
                        window.addEventListener('craftNotificationReceived', listener);
                        return function() {
                            window.removeEventListener('craftNotificationReceived', listener);
                        };
                    };
                }
            })(window.craft);

            (function installCraftMobileContract(craft) {
                var legacyShare = craft.share.bind(craft);
                var legacyOpenCamera = craft.openCamera.bind(craft);
                var legacyPickImage = craft.pickImage.bind(craft);
                var legacyAuthenticate = craft.authenticate.bind(craft);
                var legacySecureStore = craft.secureStore;
                var legacyGeolocation = craft.geolocation;
                var legacyNotifications = craft.notifications;

                craft.contractVersion = '1.0.0';
                // Actions answered by a person, through a system sheet they
                // may take a minute to read. Thirty seconds of reading the
                // HealthKit sheet used to fail the call while the sheet was
                // still open; these wait for the answer instead.
                var personFacing = {
                    requestHealthAuthorization: true,
                    requestPermission: true,
                    signInWithApple: true
                };
                craft._invoke = function(action, payload) {
                    var self = craft;
                    var id = 'cb_' + (++self._callbackId);
                    var message = Object.assign({}, payload || {}, {action: action, callbackId: id});
                    window.webkit.messageHandlers.craft.postMessage(message);
                    return new Promise(function(resolve, reject) {
                        var timeout = personFacing[action] ? null : setTimeout(function() {
                            delete self._callbacks[id];
                            reject(new Error('Craft bridge timed out: ' + action));
                        }, 30000);
                        self._callbacks[id] = {
                            resolve: function(value) { if (timeout) clearTimeout(timeout); resolve(value); },
                            reject: function(error) { if (timeout) clearTimeout(timeout); reject(error); }
                        };
                    });
                };

                craft.device = {
                    getInfo: function() { return craft.getDeviceInfo(); },
                    getCapabilities: function() { return Promise.resolve(Object.assign({}, craft.capabilities)); }
                };
                // Feedback, as on Android and the web, where there is no
                // motor to fire: an app that left enableHaptics off gets
                // nothing played and a settled promise, so `await
                // haptics.selection()` in the middle of a flow does not stop
                // the flow. A native failure still rejects, and
                // craft.haptic() itself reports the refusal.
                function hapticFeedback(answer) {
                    return answer.then(function() {}, function(error) {
                        if (error && error.code === 'CAPABILITY_DISABLED') return;
                        throw error;
                    });
                }
                // Each kind reaches the generator UIKit has for it: a
                // notification plays the success, warning or error pattern
                // and a selection the picker's detent. Both used to be
                // impacts of some weight, which is not what either feels like.
                craft.haptics = {
                    impact: function(style) { return hapticFeedback(craft.haptic(style || 'medium')); },
                    notification: function(type) {
                        return hapticFeedback(craft.haptic(type === 'error' || type === 'warning' ? type : 'success'));
                    },
                    selection: function() { return hapticFeedback(craft.haptic('selection')); },
                    // Wakes the engine ahead of a haptic the page knows is
                    // coming, so it plays on the frame it is asked for.
                    prepare: function(kind) { return hapticFeedback(craft._invoke('hapticPrepare', {kind: kind || null})); },
                    vibrate: function(pattern) { return hapticFeedback(craft.vibrate(pattern || [])); }
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
                // The app's own SQLite database (Documents/craft.db), as on Android.
                craft.db = {
                    execute: function(sql, params) { return craft._invoke('dbExecute', { sql: sql, params: params || [] }); },
                    query: function(sql, params) { return craft._invoke('dbQuery', { sql: sql, params: params || [] }); }
                };
                craft.secureStorage = {
                    set: function(key, value) { return legacySecureStore.set(key, value).then(function() {}); },
                    get: function(key) { return legacySecureStore.get(key); },
                    // `remove` is the legacy name retained by the public Craft
                    // type declaration; keep it as an alias of `delete` so
                    // native STX callers can migrate without a feature check.
                    remove: function(key) { return legacySecureStore.remove(key).then(function() {}); },
                    delete: function(key) { return legacySecureStore.remove(key).then(function() {}); },
                    clear: function() { return craft._invoke('secureClear').then(function() {}); }
                };

                var locationWatchCallbacks = new Map();
                var legacyLocationWatchCallbacks = [];
                var nextLocationWatchId = 0;
                var locationWatchStarted = false;
                var locationWatchStart = null;
                var locationWatchGeneration = 0;

                function hasLocationWatchers() {
                    return locationWatchCallbacks.size > 0 || legacyLocationWatchCallbacks.length > 0;
                }

                function startLocationWatch() {
                    if (locationWatchStarted) return Promise.resolve(true);
                    if (locationWatchStart) return locationWatchStart;

                    var generation = locationWatchGeneration;
                    var pending = craft._invoke('watchPosition');
                    var managed = pending.then(function(result) {
                        if (generation === locationWatchGeneration) {
                            locationWatchStarted = hasLocationWatchers();
                        }
                        if (locationWatchStart === managed) locationWatchStart = null;
                        return result;
                    }, function(error) {
                        if (generation === locationWatchGeneration) {
                            locationWatchCallbacks.clear();
                            legacyLocationWatchCallbacks.length = 0;
                            locationWatchStarted = false;
                        }
                        if (locationWatchStart === managed) locationWatchStart = null;
                        throw error;
                    });
                    locationWatchStart = managed;
                    return managed;
                }

                function stopLocationWatchIfUnused() {
                    if (hasLocationWatchers()) return Promise.resolve(true);
                    if (!locationWatchStarted && !locationWatchStart) return Promise.resolve(true);

                    locationWatchGeneration += 1;
                    locationWatchStarted = false;
                    locationWatchStart = null;
                    return craft._invoke('clearWatch');
                }

                window.addEventListener('craftLocationUpdate', function(event) {
                    locationWatchCallbacks.forEach(function(callback) { callback(event.detail); });
                    legacyLocationWatchCallbacks.slice().forEach(function(callback) { callback(event.detail); });
                });
                legacyGeolocation.watchPosition = function(callback) {
                    legacyLocationWatchCallbacks.push(callback);
                    return startLocationWatch();
                };
                legacyGeolocation.clearWatch = function() {
                    legacyLocationWatchCallbacks.length = 0;
                    return stopLocationWatchIfUnused();
                };
                craft.location = {
                    getCurrentPosition: function(options) { return legacyGeolocation.getCurrentPosition(options || {}); },
                    watchPosition: function(callback) {
                        var id = ++nextLocationWatchId;
                        locationWatchCallbacks.set(id, callback);
                        void startLocationWatch().catch(function() {});
                        return id;
                    },
                    clearWatch: function(id) {
                        if (typeof id === 'undefined') {
                            locationWatchCallbacks.clear();
                            legacyLocationWatchCallbacks.length = 0;
                            void stopLocationWatchIfUnused().catch(function() {});
                            return;
                        }
                        if (!locationWatchCallbacks.delete(id)) return;
                        void stopLocationWatchIfUnused().catch(function() {});
                    },
                    startRecording: function() { return craft._invoke('startLocationRecording'); },
                    pauseRecording: function() { return craft._invoke('pauseLocationRecording'); },
                    resumeRecording: function() { return craft._invoke('resumeLocationRecording'); },
                    stopRecording: function() { return craft._invoke('stopLocationRecording'); },
                    getRecordingState: function() { return craft._invoke('getLocationRecordingState'); },
                    readRecording: function() { return craft._invoke('readLocationRecording'); }
                };
                craft.health = {
                    requestAuthorization: function(types, options) {
                        return craft._invoke('requestHealthAuthorization', {types: types || [], readOnly: Boolean(options && options.write === false)});
                    },
                    getData: function(type, options) {
                        options = options || {};
                        return craft._invoke('getHealthData', {type: type, startDate: options.startDate, endDate: options.endDate});
                    },
                    saveWorkout: function(workout) { return craft._invoke('saveHealthWorkout', workout || {}); },
                    getWorkouts: function(options) {
                        options = options || {};
                        return craft._invoke('getHealthWorkouts', {startDate: options.startDate, endDate: options.endDate, limit: options.limit});
                    },
                    getDailyStatistics: function(type, options) {
                        options = options || {};
                        return craft._invoke('getHealthDailyStatistics', {type: type, startDate: options.startDate, endDate: options.endDate});
                    }
                };
                craft.liveActivity = {
                    start: function(options) { return craft._invoke('startLiveActivity', options || {}); },
                    update: function(idOrState, state) {
                        if (typeof idOrState !== 'string') return craft._invoke('updateLiveActivity', idOrState || {});
                        return craft._invoke('updateLiveActivity', Object.assign({}, state || {}, {id: idOrState}));
                    },
                    end: function(id, finalState) {
                        if (typeof id !== 'string') return craft._invoke('endLiveActivity');
                        return craft._invoke('endLiveActivity', Object.assign({}, finalState || {}, {id: id}));
                    }
                };
                var shareApi = function(text) { return legacyShare(text); };
                shareApi.share = function(options) { return craft._share({options: options || {}}); };
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

            // The reply route for actions the Zig runtime serves.
            //
            // Zig owns one wire format and calls these two functions by name;
            // this page owns `_callbacks`, keyed by the 'cb_<n>' ids `_invoke`
            // hands out. The whole adaptation is turning the numeric id Zig
            // carries back into that key. Nothing else is translated, because
            // nothing else differs: `craftSpeechStart` and friends already
            // arrive as plain CustomEvents from both sides.
            //
            // A null id means the page sent no callback — the tray-style
            // fire-and-forget posts — so there is nothing to settle and
            // dropping it is correct rather than lossy.
            window.__craftBridgeResult = function (action, result, id) {
                if (id === null || id === undefined) return;
                window.craft._resolveCallback('cb_' + id, result);
            };
            window.__craftBridgeError = function (ctx) {
                if (!ctx || ctx.id === null || ctx.id === undefined) return;
                window.craft._rejectCallback('cb_' + ctx.id, ctx.message, ctx.code);
            };

            // craftReady, once per document, at the first moment a page can
            // be listening for it.
            //
            // The bridge itself exists from the document's first byte, before
            // any of the page's scripts, so a page that checks window.craft
            // finds it at once. An event fired then would reach nobody, and
            // pages written for the old injection only listen. So it fires
            // when the document has been parsed: every parser-inserted
            // script, module and deferred script has run by then and could
            // have subscribed, and it is still well before the load event
            // (images and all) it used to wait for. Native hears of it here
            // too, and only then delivers what it was holding.
            (function announceReady(craft) {
                function ready() {
                    if (craft.ready) return;
                    craft.ready = true;
                    window.dispatchEvent(new CustomEvent('craftReady', {detail: craft}));
                    try { window.webkit.messageHandlers.craft.postMessage({action: '__craftReady'}); } catch (e) {}
                }
                if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready);
                else ready();
            })(window.craft);
            """
            let trusted = (try? JSONSerialization.data(withJSONObject: trustedPageOrigins()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            if ((location.protocol === 'craft:' && location.host === 'app') || location.protocol === 'file:' || \(trusted).indexOf(location.protocol + '//' + location.host) !== -1) {
            \(script)
            }
            """
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
            // A hand-off from the Zig dispatcher replies through Zig, which
            // owns the wire format, the request id, and the escaping. Replying
            // by JavaScript here as well would give the page two answers.
            if CraftSwiftShim.deliverResultIfHandOff(id, json: resultStr) { return }
            let script = "window.craft._resolveCallback('\(id)', \(resultStr));"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(script, completionHandler: nil) }
        }

        private func resolveCallbackJSON(_ callbackId: String?, json: [String: Any]) {
            resolveCallback(callbackId, result: json)
        }

        private func rejectCallback(_ callbackId: String?, error: String, code: String = "CRAFT_ERROR") {
            guard let id = callbackId else { return }
            // A hand-off rejection goes back through Zig's error route, so the
            // page's promise *rejects*. Delivering it as a result would run the
            // app's then-branch with an error-shaped object — fabricated
            // success wearing a different hat.
            if CraftSwiftShim.deliverErrorIfHandOff(id, message: error, code: code) { return }
            // Backslashes first: escaping ' and \n but not \ let an error
            // message containing a backslash break out of the string literal.
            let escapedError = error
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
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
                CraftNativeActions.triggerHaptic(style: "light")
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
            CraftNativeActions.triggerHaptic(style: "light")
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

            if let movieURL = info[.mediaURL] as? URL {
                do {
                    let movieData = try Data(contentsOf: movieURL, options: .mappedIfSafe)
                    let base64 = movieData.base64EncodedString()
                    resolveCallback(pendingCallbackId, result: "data:video/quicktime;base64," + base64)
                } catch {
                    rejectCallback(pendingCallbackId, error: "Failed to process video: \(error.localizedDescription)")
                }
            } else if let image = info[.originalImage] as? UIImage,
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

        /// The deadline covering the APNs round trip, once authorization is in.
        private var pendingPushDeadline: UUID?

        private func registerPushNotifications(callbackId: String?) {
            // A second call used to overwrite the first's callbackId, and the
            // first promise then never settled at all. Displacing a call is an
            // answer the caller can act on, the way a replaced
            // getCurrentPosition request is rejected rather than dropped.
            if let displaced = pendingPushCallbackId {
                if let token = pendingPushDeadline { _ = claimDeadline(token) }
                pendingPushDeadline = nil
                rejectCallback(displaced, error: "Replaced by another push registration", code: "CANCELLED")
            }
            pendingPushCallbackId = callbackId
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
                if granted {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Armed here rather than at dispatch: until the person
                        // answers the prompt there is someone to wait for, and
                        // only the APNs round trip afterwards is unattended.
                        self.pendingPushDeadline = self.armDeadline(
                            Coordinator.pushRegistrationDeadline,
                            callbackId: callbackId,
                            error: "APNs did not call back within \(Int(Coordinator.pushRegistrationDeadline))s"
                        )
                        self.pendingPushCallbackId = callbackId
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.pendingPushCallbackId == callbackId else { return }
                        self.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                        self.pendingPushCallbackId = nil
                    }
                }
            }
        }

        /// Whether this push callback is still the one waiting, claiming it if so.
        private func claimPushRegistration() -> String?? {
            guard let callbackId = pendingPushCallbackId else { return nil }
            if let token = pendingPushDeadline, !claimDeadline(token) { return nil }
            pendingPushDeadline = nil
            pendingPushCallbackId = nil
            return .some(callbackId)
        }

        @objc private func receivePushToken(_ notification: Notification) {
            guard let token = notification.object as? String else { return }
            // The event goes out either way: a token that arrives after its
            // deadline is still this app's token, and a page listening for
            // craftPushToken is not the caller that timed out.
            if let claimed = claimPushRegistration() { resolveCallback(claimed, result: token) }
            sendToWeb("craftPushToken", data: ["token": token])
        }

        @objc private func receivePushRegistrationError(_ notification: Notification) {
            let message = notification.object as? String ?? "Push registration failed"
            guard let claimed = claimPushRegistration() else { return }
            rejectCallback(claimed, error: message, code: "PUSH_REGISTRATION_ERROR")
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
                let status = (locationManager ?? CLLocationManager()).authorizationStatus
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
                // Zig answers UnknownAction for this permission, so Swift
                // serves it on both runtimes and this is the only answer.
                let token = armDeadline(
                    Coordinator.notificationSettingsDeadline,
                    callbackId: callbackId,
                    error: "UNUserNotificationCenter.getNotificationSettings did not answer within \(Int(Coordinator.notificationSettingsDeadline))s"
                )
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let status: String
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral: status = "granted"
                    case .denied: status = "denied"
                    case .notDetermined: status = "undetermined"
                    @unknown default: status = "undetermined"
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.claimDeadline(token) else { return }
                        self.resolveCallback(callbackId, result: status)
                    }
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
                guard let manager = locationManager else {
                    rejectCallback(callbackId, error: "Geolocation is disabled", code: "CAPABILITY_DISABLED")
                    return
                }
                manager.delegate = self
                let requiresAlways = permission == "locationAlways" || config.enableBackgroundLocation
                let status = manager.authorizationStatus
                let alreadyGranted = status == .authorizedAlways || (!requiresAlways && status == .authorizedWhenInUse)
                if alreadyGranted || status == .denied || status == .restricted {
                    resolveCallback(callbackId, result: permissionStatus(alreadyGranted, denied: status == .denied, restricted: status == .restricted))
                    return
                }
                if let pendingCallbackId = locationPermissionCallbackId {
                    rejectCallback(pendingCallbackId, error: "A newer location permission request replaced this request", code: "REQUEST_REPLACED")
                }
                locationPermissionCallbackId = callbackId
                locationPermissionRequiresAlways = requiresAlways
                if requiresAlways {
                    manager.requestAlwaysAuthorization()
                } else {
                    manager.requestWhenInUseAuthorization()
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
        private func getCurrentPosition(body: [String: Any], callbackId: String?) {
            guard let manager = locationManager else {
                rejectCallback(callbackId, error: "Geolocation is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            manager.delegate = self
            manager.desiredAccuracy = body["enableHighAccuracy"] as? Bool == true
                ? kCLLocationAccuracyBest
                : kCLLocationAccuracyHundredMeters

            if let pendingCallbackId = singleLocationCallbackId {
                finishSingleLocationRequest()
                rejectCallback(pendingCallbackId, error: "A newer location request replaced this request", code: "POSITION_UNAVAILABLE")
            }
            singleLocationCallbackId = callbackId
            let maximumAge = max(0, (body["maximumAge"] as? NSNumber)?.doubleValue ?? 0)
            if maximumAge > 0,
               let cachedLocation = manager.location,
               max(0, Date().timeIntervalSince(cachedLocation.timestamp) * 1000) <= maximumAge {
                finishSingleLocationRequest()
                resolveCallback(callbackId, result: locationData(cachedLocation))
                return
            }

            let timeoutMs = max(0, (body["timeout"] as? NSNumber)?.doubleValue ?? 30_000)
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self, self.singleLocationCallbackId == callbackId else { return }
                self.finishSingleLocationRequest()
                self.rejectCallback(callbackId, error: "Location request timed out", code: "LOCATION_TIMEOUT")
            }
            singleLocationTimeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(min(timeoutMs + 100, Double(Int.max)))), execute: timeoutWorkItem)
            requestLocationAuthorization()
            manager.requestLocation()
        }

        private func finishSingleLocationRequest() {
            singleLocationTimeoutWorkItem?.cancel()
            singleLocationTimeoutWorkItem = nil
            singleLocationCallbackId = nil
            locationManager?.desiredAccuracy = kCLLocationAccuracyBest
        }

        private func locationData(_ location: CLLocation) -> [String: Any] {
            [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "altitude": location.altitude,
                "accuracy": location.horizontalAccuracy,
                "altitudeAccuracy": location.verticalAccuracy,
                "heading": location.course,
                "speed": location.speed,
                "timestamp": location.timestamp.timeIntervalSince1970 * 1000
            ]
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
            // Set here too: a recording restored at launch while paused never
            // got a delegate, so resuming it started updates nobody received
            // and the route stopped at the pause.
            locationManager?.delegate = self
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
            let data = locationData(location)

            if let callbackId = singleLocationCallbackId {
                finishSingleLocationRequest()
                resolveCallback(callbackId, result: data)
            }

            appendRecordedLocation(data)
            if isWatchingLocation || isRecordingLocation {
                sendToWeb("craftLocationUpdate", data: data)
            }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            let nativeError = error as NSError
            // kCLErrorLocationUnknown is Core Location saying it has no fix
            // *yet*, not that it failed. requestLocation gives up on it, so a
            // one-shot asks again shortly instead of failing a caller whose
            // fix was seconds off; its timeout still bounds the wait (#260).
            // Nor is it an error event: a watch keeps running through it.
            if nativeError.domain == kCLErrorDomain && nativeError.code == CLError.Code.locationUnknown.rawValue {
                if let waiting = singleLocationCallbackId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                        guard let self, self.singleLocationCallbackId == waiting else { return }
                        self.locationManager?.requestLocation()
                    }
                }
                return
            }
            let callbackId = singleLocationCallbackId
            finishSingleLocationRequest()
            let code = nativeError.domain == kCLErrorDomain && nativeError.code == CLError.Code.denied.rawValue
                ? "PERMISSION_DENIED"
                : "POSITION_UNAVAILABLE"
            rejectCallback(callbackId, error: error.localizedDescription, code: code)
            sendToWeb("craftLocationError", data: ["message": error.localizedDescription])
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard let callbackId = locationPermissionCallbackId else { return }
            let status = manager.authorizationStatus
            if status == .notDetermined { return }
            if locationPermissionRequiresAlways && status == .authorizedWhenInUse { return }
            let granted = status == .authorizedAlways || (!locationPermissionRequiresAlways && status == .authorizedWhenInUse)
            resolveCallback(callbackId, result: permissionStatus(granted, denied: status == .denied, restricted: status == .restricted))
            locationPermissionCallbackId = nil
            locationPermissionRequiresAlways = false
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
            guard let store = contactStore else {
                rejectCallback(callbackId, error: "Contacts access is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            store.requestAccess(for: .contacts) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    return
                }

                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactIdentifierKey] as [CNKeyDescriptor]
                let request = CNContactFetchRequest(keysToFetch: keys)

                var contacts: [[String: Any]] = []
                do {
                    try store.enumerateContacts(with: request) { contact, _ in
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
            guard let store = contactStore else {
                rejectCallback(callbackId, error: "Contacts access is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            store.requestAccess(for: .contacts) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
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
                    try store.execute(saveRequest)
                    self?.resolveCallback(callbackId, result: contact.identifier)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        // MARK: - Calendar
        private func getCalendarEvents(startDate: Double?, endDate: Double?, callbackId: String?) {
            guard let store = eventStore else {
                rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            store.requestAccess(to: .event) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    return
                }

                let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())
                    ?? Date()

                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let events = store.events(matching: predicate)

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
            guard let store = eventStore else {
                rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            store.requestAccess(to: .event) { [weak self] granted, error in
                guard granted else {
                    self?.rejectCallback(callbackId, error: error?.localizedDescription ?? "Permission denied")
                    return
                }

                let event = EKEvent(eventStore: store)
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
                event.calendar = store.defaultCalendarForNewEvents

                do {
                    try store.save(event, span: .thisEvent)
                    guard let identifier = event.eventIdentifier else {
                        self?.rejectCallback(callbackId, error: "Saved event has no identifier")
                        return
                    }
                    self?.resolveCallback(callbackId, result: identifier)
                } catch {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                }
            }
        }

        private func deleteCalendarEvent(_ eventId: String, callbackId: String?) {
            guard let store = eventStore else {
                rejectCallback(callbackId, error: "Calendar access is disabled", code: "CAPABILITY_DISABLED")
                return
            }
            guard let event = store.event(withIdentifier: eventId) else {
                rejectCallback(callbackId, error: "Event not found")
                return
            }

            do {
                try store.remove(event, span: .thisEvent)
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
                // The page's `data`, which is what a tap (#255) and an arrival
                // (#256) hand back. It was dropped, so a tap on a scheduled
                // notification reached the page as {} (#258).
                if let info = data["data"] as? [String: Any] { content.userInfo = info }
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
            // Nobody is in front of a StoreKit fetch, and it reaches the
            // network: a request that never returns leaves the page waiting.
            let token = armDeadline(
                Coordinator.storeKitDeadline,
                callbackId: callbackId,
                error: "StoreKit did not return products within \(Int(Coordinator.storeKitDeadline))s"
            )
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
                    await MainActor.run { [weak self] in
                        guard let self, self.claimDeadline(token) else { return }
                        self.resolveCallback(callbackId, result: productData)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.claimDeadline(token) else { return }
                        self.rejectCallback(callbackId, error: error.localizedDescription)
                    }
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

        // MARK: - Speech Synthesis
        //
        // Native rather than the page's own `speechSynthesis`, which in a
        // WKWebView plays through the default soloAmbient session: it stops
        // the person's music and the silent switch mutes it. A workout cue has
        // to do neither, so the session is set up here for as long as there is
        // something to say, and handed back when there is not.

        private func speak(_ text: String, body: [String: Any], callbackId: String?) {
            DispatchQueue.main.async {
                if body["interrupt"] as? Bool ?? true {
                    self.cancelPendingSpeech()
                }

                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = Self.utteranceRate(body["rate"] as? Double ?? 1)
                // An unknown language finds no voice, and a nil voice is the
                // device's own, which is the default anyway.
                if let language = body["language"] as? String, !language.isEmpty,
                   let voice = AVSpeechSynthesisVoice(language: language) {
                    utterance.voice = voice
                }

                self.pendingUtterances.append((utterance, callbackId))
                self.claimAudioSessionForSpeech {
                    // Stopped while the session was being set up: say nothing.
                    guard self.pendingUtterances.contains(where: { $0.utterance === utterance }) else { return }
                    self.speechSynthesizer.speak(utterance)
                }
            }
        }

        private func stopSpeaking(callbackId: String?) {
            DispatchQueue.main.async {
                // When something was playing, its didCancel releases the
                // session once the audio has actually stopped; deactivating
                // before that fails as busy and leaves the music ducked.
                if !self.cancelPendingSpeech() { self.releaseAudioSessionIfSilent() }
                self.resolveCallback(callbackId, result: true)
            }
        }

        /// Stop what is being said and settle every call waiting on it, false.
        /// Returns whether the synthesizer was making a sound.
        ///
        /// Settled here rather than in `didCancel`, because the delegate hears
        /// about the utterance that was playing and nothing about the ones
        /// queued behind it, whose calls would otherwise never settle.
        @discardableResult
        private func cancelPendingSpeech() -> Bool {
            let waiting = pendingUtterances
            pendingUtterances.removeAll()
            let synthesizer = speechSynthesizer
            let wasSounding = synthesizer.isSpeaking || synthesizer.isPaused
            if wasSounding { synthesizer.stopSpeaking(at: .immediate) }
            for entry in waiting {
                resolveCallback(entry.callbackId, result: false)
            }
            return wasSounding
        }

        /// The page's rate, where 1 is normal, on AVSpeechUtterance's scale.
        ///
        /// Apple's scale is not linear in speed: the default sits at 0.5 and
        /// the maximum is far faster than twice that. So a slower rate scales
        /// the default down in proportion, and a faster one climbs toward the
        /// maximum at half the slope, which keeps 2 brisk but intelligible.
        private static func utteranceRate(_ rate: Double) -> Float {
            let requested = Float(min(max(rate.isFinite ? rate : 1, 0.5), 2))
            let normal = AVSpeechUtteranceDefaultSpeechRate
            let mapped = requested <= 1
                ? normal * requested
                : normal + (AVSpeechUtteranceMaximumSpeechRate - normal) * (requested - 1) / 2
            return min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        }

        /// Duck the music rather than stop it, and play through the silent
        /// switch.
        ///
        /// `.playback` is what the switch does not mute, `.duckOthers` lowers
        /// the music under the cue, and the spoken-audio option pauses a
        /// podcast rather than talking over it. Left alone while recognition
        /// or a recording holds the session: switching it to playback would
        /// cut their microphone off mid-take.
        ///
        /// Set up on the speech queue, then `start` runs on the main thread.
        private func claimAudioSessionForSpeech(then start: @escaping () -> Void) {
            let microphoneBusy = audioEngine.isRunning || (audioRecorder?.isRecording ?? false)
            speechAudioQueue.async {
                if self.speechAudioSessionToRestore == nil && !microphoneBusy {
                    let session = AVAudioSession.sharedInstance()
                    let previous = (session.category, session.mode, session.categoryOptions)
                    do {
                        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
                        try session.setActive(true)
                        self.speechAudioSessionToRestore = previous
                    } catch {
                        // Still speak, through whatever session the app has: a
                        // cue that does not duck beats one that never plays.
                        print("[Craft] Speech audio session failed: \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async(execute: start)
            }
        }

        /// Hand the audio back once nothing is left to say, so the music
        /// returns to full volume instead of staying ducked, and put back the
        /// category the app had, so the page's own media plays as before.
        ///
        /// Checked on the main thread, where the queue of utterances lives, and
        /// done on the speech queue after any setup already asked for, so a
        /// cue that arrives meanwhile reclaims the session after this.
        private func releaseAudioSessionIfSilent(retry: Bool = true) {
            guard pendingUtterances.isEmpty else { return }
            speechAudioQueue.async {
                guard let previous = self.speechAudioSessionToRestore else { return }
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    // Busy: the synthesizer's audio has not quite drained, or
                    // the page has its own media playing. Once more shortly
                    // covers the first; for the second, staying active is
                    // right, and the ducking still ends when the music app
                    // hears nothing more.
                    if retry {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.releaseAudioSessionIfSilent(retry: false)
                        }
                        return
                    }
                    print("[Craft] Speech audio session release failed: \(error.localizedDescription)")
                }
                self.speechAudioSessionToRestore = nil
                try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
            }
        }

        fileprivate func speechDidEnd(_ utterance: AVSpeechUtterance, spoken: Bool) {
            if let index = pendingUtterances.firstIndex(where: { $0.utterance === utterance }) {
                let entry = pendingUtterances.remove(at: index)
                resolveCallback(entry.callbackId, result: spoken)
            }
            releaseAudioSessionIfSilent()
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
        /// SQLite copies what it is given only when told to (SQLITE_TRANSIENT);
        /// with a nil destructor it keeps a pointer to a Swift string that is
        /// freed as soon as the bind call returns, and stores whatever is there
        /// later.
        private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        /// Binds JSON-bridged values: strings, integers as 64-bit (JS numbers
        /// that are whole, such as millisecond timestamps), other numbers as
        /// doubles, booleans as 0/1, and null.
        private func bindParameters(_ statement: OpaquePointer?, _ params: [Any]) {
            for (index, param) in params.enumerated() {
                let idx = Int32(index + 1)
                if let str = param as? String {
                    sqlite3_bind_text(statement, idx, str, -1, sqliteTransient)
                } else if let number = param as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() {
                        sqlite3_bind_int64(statement, idx, number.boolValue ? 1 : 0)
                    } else if CFNumberIsFloatType(number), number.doubleValue.rounded() != number.doubleValue {
                        sqlite3_bind_double(statement, idx, number.doubleValue)
                    } else {
                        sqlite3_bind_int64(statement, idx, number.int64Value)
                    }
                } else {
                    sqlite3_bind_null(statement, idx)
                }
            }
        }

        private func dbExecute(sql: String, params: [Any]?, callbackId: String?) {
            guard let db = db else {
                rejectCallback(callbackId, error: "Database not initialized")
                return
            }

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                // Bind parameters
                if let params = params {
                    bindParameters(statement, params)
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
                    bindParameters(statement, params)
                }

                let columnCount = sqlite3_column_count(statement)

                while sqlite3_step(statement) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    for i in 0..<columnCount {
                        let columnName = String(cString: sqlite3_column_name(statement, i))
                        let type = sqlite3_column_type(statement, i)

                        switch type {
                        case SQLITE_INTEGER:
                            // 64-bit: millisecond timestamps overflow Int32.
                            row[columnName] = sqlite3_column_int64(statement, i)
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
        private func requestHealthAuthorization(types: [String], readOnly: Bool = false, callbackId: String?) {
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
                    // A workout's own heart rate and energy are read through
                    // these; without them every workout comes back bare.
                    if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                        readTypes.insert(heartType)
                    }
                    if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                        readTypes.insert(energyType)
                    }
                case "restingHeartRate":
                    if let restingType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
                        readTypes.insert(restingType)
                    }
                case "heartRateVariability":
                    if let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
                        readTypes.insert(hrvType)
                    }
                case "bodyMass":
                    if let massType = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
                        readTypes.insert(massType)
                    }
                case "sleep":
                    if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                        readTypes.insert(sleepType)
                    }
                default:
                    break
                }
            }

            // A page that only reads asks only to read: the sheet then says
            // "access", not "access and update".
            if readOnly { shareTypes.removeAll() }
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

            guard let spec = Self.healthQuantity(type), let qType = spec.type else {
                rejectCallback(callbackId, error: "Unknown health data type")
                return
            }
            let qUnit = spec.unit

            let start = startDate != nil ? Date(timeIntervalSince1970: startDate! / 1000) : Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let end = endDate != nil ? Date(timeIntervalSince1970: endDate! / 1000) : Date()

            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

            // A discrete type (heart rate, weight) has no sum: HealthKit fails
            // the whole query when asked for one, which is what heart rate
            // used to do. Each type is asked for the statistic it has.
            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: spec.options) { [weak self] _, result, error in
                if let error = error {
                    // No samples in the range is an answer, not a failure.
                    if (error as? HKError)?.code == .errorNoData {
                        self?.resolveCallback(callbackId, result: ["value": 0, "unit": qUnit.unitString])
                        return
                    }
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                let value = result.flatMap { Self.statisticValue($0, options: spec.options, unit: qUnit) } ?? 0
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

        /// The quantity behind each health data type, its unit, and the one
        /// statistic that type supports.
        private static func healthQuantity(_ type: String) -> (type: HKQuantityType?, unit: HKUnit, options: HKStatisticsOptions)? {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            switch type {
            case "steps": return (HKQuantityType.quantityType(forIdentifier: .stepCount), .count(), .cumulativeSum)
            case "activeEnergy": return (HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), .kilocalorie(), .cumulativeSum)
            case "distance": return (HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning), .meter(), .cumulativeSum)
            case "heartRate": return (HKQuantityType.quantityType(forIdentifier: .heartRate), bpm, .discreteAverage)
            case "restingHeartRate": return (HKQuantityType.quantityType(forIdentifier: .restingHeartRate), bpm, .discreteAverage)
            case "heartRateVariability": return (HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN), .secondUnit(with: .milli), .discreteAverage)
            case "bodyMass": return (HKQuantityType.quantityType(forIdentifier: .bodyMass), .gramUnit(with: .kilo), .mostRecent)
            default: return nil
            }
        }

        private static func statisticValue(_ statistics: HKStatistics, options: HKStatisticsOptions, unit: HKUnit) -> Double? {
            if options.contains(.cumulativeSum) { return statistics.sumQuantity()?.doubleValue(for: unit) }
            if options.contains(.mostRecent) { return statistics.mostRecentQuantity()?.doubleValue(for: unit) }
            return statistics.averageQuantity()?.doubleValue(for: unit)
        }

        private static let healthDayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        /// A stable name for a workout's activity, independent of the SDK's
        /// raw values, so a page can map it to its own sports.
        private static func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
            switch type {
            case .running: return "running"
            case .cycling: return "cycling"
            case .walking: return "walking"
            case .hiking: return "hiking"
            case .swimming: return "swimming"
            case .rowing: return "rowing"
            case .elliptical: return "elliptical"
            case .stairClimbing, .stairs: return "stairClimbing"
            case .yoga: return "yoga"
            case .pilates: return "pilates"
            case .functionalStrengthTraining, .traditionalStrengthTraining, .coreTraining: return "strength"
            case .highIntensityIntervalTraining: return "hiit"
            case .crossTraining, .mixedCardio: return "crossTraining"
            case .crossCountrySkiing: return "crossCountrySkiing"
            case .downhillSkiing, .snowboarding: return "skiing"
            case .paddleSports: return "paddling"
            case .climbing: return "climbing"
            case .dance, .socialDance, .cardioDance: return "dance"
            case .cooldown, .flexibility, .mindAndBody: return "mobility"
            default: return "other"
            }
        }

        /// Workouts in Apple Health — the watch's, and every app's that
        /// writes there — newest first, with the numbers a training log needs.
        private func getHealthWorkouts(startDate: Double?, endDate: Double?, limit: Int?, callbackId: String?) {
            guard let healthStore = healthStore else {
                rejectCallback(callbackId, error: "HealthKit not available")
                return
            }

            let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let cap = max(1, min(limit ?? 200, 1000))

            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: cap, sortDescriptors: [newestFirst]) { [weak self] _, samples, error in
                if let error = error, (error as? HKError)?.code != .errorNoData {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }

                let bpm = HKUnit.count().unitDivided(by: .minute())
                let workouts: [[String: Any]] = (samples as? [HKWorkout] ?? []).map { workout in
                    var item: [String: Any] = [
                        "id": workout.uuid.uuidString,
                        "type": Self.workoutTypeName(workout.workoutActivityType),
                        "startDate": workout.startDate.timeIntervalSince1970 * 1000,
                        "endDate": workout.endDate.timeIntervalSince1970 * 1000,
                        "durationSeconds": workout.duration,
                        "sourceName": workout.sourceRevision.source.name,
                        "indoor": (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false,
                    ]
                    if let meters = workout.totalDistance?.doubleValue(for: .meter()), meters > 0 {
                        item["distanceMeters"] = meters
                    }
                    if let ascent = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                        item["elevationGainMeters"] = ascent.doubleValue(for: .meter())
                    }
                    if #available(iOS 16.0, *) {
                        if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate),
                           let heart = workout.statistics(for: heartType) {
                            if let average = heart.averageQuantity()?.doubleValue(for: bpm) { item["averageHeartRate"] = average }
                            if let maximum = heart.maximumQuantity()?.doubleValue(for: bpm) { item["maxHeartRate"] = maximum }
                        }
                        if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                           let calories = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                            item["activeEnergyCalories"] = calories
                        }
                    } else if let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                        item["activeEnergyCalories"] = calories
                    }
                    return item
                }
                self?.resolveCallback(callbackId, result: workouts)
            }
            healthStore.execute(query)
        }

        /// One value per local day: a sum for steps, energy and distance, an
        /// average for heart rate, resting heart rate and HRV, the latest
        /// weight, and hours asleep for sleep (counted on the day you woke).
        private func getHealthDailyStatistics(type: String, startDate: Double?, endDate: Double?, callbackId: String?) {
            guard let healthStore = healthStore else {
                rejectCallback(callbackId, error: "HealthKit not available")
                return
            }

            let calendar = Calendar.current
            let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let start = calendar.startOfDay(for: startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? calendar.date(byAdding: .day, value: -30, to: end)!)

            if type == "sleep" {
                guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
                    rejectCallback(callbackId, error: "Sleep data is unavailable")
                    return
                }
                // From the evening before the first day, so its night counts.
                let predicate = HKQuery.predicateForSamples(withStart: calendar.date(byAdding: .hour, value: -12, to: start), end: end, options: [])
                let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
                    if let error = error, (error as? HKError)?.code != .errorNoData {
                        self?.rejectCallback(callbackId, error: error.localizedDescription)
                        return
                    }
                    // Time in bed and time awake are not sleep; every asleep
                    // stage (and the older single "asleep" value) is.
                    let awake: Set<Int> = [HKCategoryValueSleepAnalysis.inBed.rawValue, HKCategoryValueSleepAnalysis.awake.rawValue]
                    var secondsByDay: [String: Double] = [:]
                    for sample in samples as? [HKCategorySample] ?? [] where !awake.contains(sample.value) {
                        let day = Self.healthDayFormatter.string(from: sample.endDate)
                        secondsByDay[day, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                    }
                    let days = secondsByDay.keys.sorted().map { day -> [String: Any] in
                        ["date": day, "value": (secondsByDay[day]! / 3600 * 100).rounded() / 100, "unit": "hr"]
                    }
                    self?.resolveCallback(callbackId, result: days)
                }
                healthStore.execute(query)
                return
            }

            guard let spec = Self.healthQuantity(type), let qType = spec.type else {
                rejectCallback(callbackId, error: "Unknown health data type")
                return
            }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKStatisticsCollectionQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: spec.options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { [weak self] _, collection, error in
                if let error = error, (error as? HKError)?.code != .errorNoData {
                    self?.rejectCallback(callbackId, error: error.localizedDescription)
                    return
                }
                var days: [[String: Any]] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let value = Self.statisticValue(statistics, options: spec.options, unit: spec.unit) else { return }
                    days.append([
                        "date": Self.healthDayFormatter.string(from: statistics.startDate),
                        "value": value,
                        "unit": spec.unit.unitString,
                    ])
                }
                self?.resolveCallback(callbackId, result: days)
            }
            healthStore.execute(query)
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
            guard #available(iOS 16.2, *) else {
                rejectCallback(callbackId, error: "No Live Activity is running")
                return
            }
            let activities = Activity<CraftActivityAttributes>.activities
            let activity: Activity<CraftActivityAttributes>
            if let activityId = body["id"] as? String {
                guard let matchingActivity = activities.first(where: { $0.id == activityId }) else {
                    rejectCallback(callbackId, error: "No Live Activity with id \(activityId) is running")
                    return
                }
                activity = matchingActivity
            } else {
                guard let currentActivity = activities.first else {
                    rejectCallback(callbackId, error: "No Live Activity is running")
                    return
                }
                activity = currentActivity
            }
            let current = activity.content.state
            let state = CraftActivityAttributes.ContentState(
                status: body["status"] as? String ?? current.status,
                distanceMeters: body["distanceMeters"] as? Double ?? current.distanceMeters,
                durationSeconds: body["durationSeconds"] as? Double ?? current.durationSeconds,
                progress: min(max(body["progress"] as? Double ?? current.progress, 0), 1)
            )
            let token = armDeadline(
                Coordinator.liveActivityDeadline,
                callbackId: callbackId,
                error: "Activity.update did not return within \(Int(Coordinator.liveActivityDeadline))s"
            )
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
                await MainActor.run { [weak self] in
                    guard let self, self.claimDeadline(token) else { return }
                    self.resolveCallback(callbackId, result: ["updated": true])
                }
            }
        }

        private func endLiveActivity(body: [String: Any], callbackId: String?) {
            guard #available(iOS 16.2, *) else {
                resolveCallback(callbackId, result: ["ended": false])
                return
            }
            let activities = Activity<CraftActivityAttributes>.activities
            let activity: Activity<CraftActivityAttributes>
            if let activityId = body["id"] as? String {
                guard let matchingActivity = activities.first(where: { $0.id == activityId }) else {
                    rejectCallback(callbackId, error: "No Live Activity with id \(activityId) is running")
                    return
                }
                activity = matchingActivity
            } else {
                guard let currentActivity = activities.first else {
                    resolveCallback(callbackId, result: ["ended": false])
                    return
                }
                activity = currentActivity
            }
            let hasFinalState = body["status"] != nil
                || body["distanceMeters"] != nil
                || body["durationSeconds"] != nil
                || body["progress"] != nil
            let finalContent: ActivityContent<CraftActivityAttributes.ContentState>?
            if hasFinalState {
                let current = activity.content.state
                let state = CraftActivityAttributes.ContentState(
                    status: body["status"] as? String ?? current.status,
                    distanceMeters: body["distanceMeters"] as? Double ?? current.distanceMeters,
                    durationSeconds: body["durationSeconds"] as? Double ?? current.durationSeconds,
                    progress: min(max(body["progress"] as? Double ?? current.progress, 0), 1)
                )
                finalContent = ActivityContent(state: state, staleDate: nil)
            } else {
                finalContent = nil
            }
            let token = armDeadline(
                Coordinator.liveActivityDeadline,
                callbackId: callbackId,
                error: "Activity.end did not return within \(Int(Coordinator.liveActivityDeadline))s"
            )
            Task {
                await activity.end(finalContent, dismissalPolicy: .default)
                await MainActor.run { [weak self] in
                    guard let self, self.claimDeadline(token) else { return }
                    self.resolveCallback(callbackId, result: ["ended": true])
                }
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

        // Removals waiting on their completion, each under a token of its own:
        // callbackId can be nil, and restarts when the page reloads.
        /// One entry per call whose only answer is a framework callback.
        ///
        /// Each of these waits on something no person is in front of — a
        /// notification-settings read, an APNs registration, a StoreKit fetch,
        /// a Live Activity update — and nothing else settles the page's
        /// promise if the callback never comes (#224). #211 found the same
        /// shape in a Siri deletion, twice, on CI.
        ///
        /// Whoever claims the token first answers: the callback or the
        /// deadline. Both run on the main queue, so the race is decided there
        /// rather than by a lock, and the loser finds nothing and does
        /// nothing. The deadline never claims the work happened — it may well
        /// have — only that nothing reported back in time.
        private var pendingDeadlines: [UUID: DispatchWorkItem] = [:]

        /// How long each of them waits. Comfortably under the 30s the page's
        /// own `_invoke` allows, so the caller hears the native answer rather
        /// than its own timeout, and long enough that a slow device is not
        /// cut off mid-answer.
        private static let notificationSettingsDeadline: TimeInterval = 10
        private static let pushRegistrationDeadline: TimeInterval = 20
        private static let storeKitDeadline: TimeInterval = 20
        private static let liveActivityDeadline: TimeInterval = 10

        /// Arm a deadline for a call, and return the token that claims it.
        private func armDeadline(_ seconds: TimeInterval, callbackId: String?, error: String) -> UUID {
            let token = UUID()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingDeadlines.removeValue(forKey: token) != nil else { return }
                self.rejectCallback(callbackId, error: error, code: "TIMEOUT")
            }
            pendingDeadlines[token] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            return token
        }

        /// Claim the right to answer. False means the deadline already did.
        ///
        /// Call it on the main queue: the callbacks below hop there first,
        /// because the queue a framework completion arrives on is its own
        /// business and a `zig:` hand-off reply reaches `evaluateJavaScript`
        /// with no hop of its own.
        private func claimDeadline(_ token: UUID) -> Bool {
            guard let work = pendingDeadlines.removeValue(forKey: token) else { return false }
            work.cancel()
            return true
        }

        private var pendingSiriRemovals: [UUID: DispatchWorkItem] = [:]
        // The only thing that settles craft.siri.remove, which arms no timeout
        // of its own; the same as Zig's.
        private static let siriRemovalDeadline: TimeInterval = 15

        private func removeSiriShortcut(action: String, callbackId: String?) {
            // The completion comes from a system daemon, and sometimes it never
            // comes (#211). The deadline settles the call instead, and never
            // with removed: true, because the deletion may still have happened.
            // Both run on the main queue and remove the same entry, so only one
            // of them answers.
            let token = UUID()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.pendingSiriRemovals.removeValue(forKey: token) != nil else { return }
                self.rejectCallback(
                    callbackId,
                    error: "NSUserActivity.deleteSavedUserActivities did not call its completion handler within \(Int(Coordinator.siriRemovalDeadline))s",
                    code: "TIMEOUT"
                )
            }
            pendingSiriRemovals[token] = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + Coordinator.siriRemovalDeadline, execute: deadline)

            NSUserActivity.deleteSavedUserActivities(withPersistentIdentifiers: [action]) {
                // The queue this runs on is not documented, and a zig: hand-off
                // reply goes to evaluateJavaScript without a hop of its own.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let pending = self.pendingSiriRemovals.removeValue(forKey: token) else {
                        print("removeSiriShortcut: the completion for \(action) arrived after its deadline; ignored")
                        return
                    }
                    pending.cancel()
                    self.resolveCallback(callbackId, result: ["removed": true, "action": action])
                }
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
// MARK: - AVSpeechSynthesizerDelegate
//
// The end of an utterance is what `craft.speech.speak()` waits for. Hopped to
// main because every piece of speech state is touched there and nowhere else.
// MARK: - The page's own windows and dialogs
//
// WebKit hands these to the UI delegate and, with none set, drops them: an
// alert() that never showed, a confirm() that answered false without asking,
// a target=_blank link that did nothing when tapped.
extension CraftWebView.Coordinator: WKUIDelegate {
    /// A dialog's title: none for the app's own page, which speaks as the app,
    /// and the origin's host for anything embedded in it, so a frame cannot
    /// pass its alert off as the app's.
    private func dialogTitle(for frame: WKFrameInfo) -> String? {
        trusts(frame.securityOrigin) ? nil : frame.securityOrigin.host
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: dialogTitle(for: frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CraftPresenter.systemString("OK"), style: .default) { _ in completionHandler() })
        if !CraftPresenter.present(alert, from: webView) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: dialogTitle(for: frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CraftPresenter.systemString("Cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: CraftPresenter.systemString("OK"), style: .default) { _ in completionHandler(true) })
        if !CraftPresenter.present(alert, from: webView) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: dialogTitle(for: frame), message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: CraftPresenter.systemString("Cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: CraftPresenter.systemString("OK"), style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        if !CraftPresenter.present(alert, from: webView) { completionHandler(nil) }
    }

    /// target=_blank and window.open. The app's own pages open in this web
    /// view, the way a native app pushes a screen rather than opening a
    /// second app. Anywhere else opens in Safari's in-app view, over the app
    /// and dismissed back to it, and a non-web link goes to whatever app
    /// handles it. A second web view is never made: there would be nothing to
    /// show it in.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if isTrustedURL(url) {
            webView.load(navigationAction.request)
        } else if url.scheme == "https" || url.scheme == "http" {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            if !CraftPresenter.present(safari, from: webView) { UIApplication.shared.open(url) }
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }

    /// getUserMedia from the app's own page is granted without WebKit's own
    /// per-page prompt: the app already holds (or will ask for) the camera
    /// and microphone permission iOS itself shows, and asking twice for one
    /// thing reads as a web page. Anything embedded still gets the prompt.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(trusts(origin) && trusts(frame.securityOrigin) ? .grant : .prompt)
    }
}

extension CraftWebView.Coordinator: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speechDidEnd(utterance, spoken: true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speechDidEnd(utterance, spoken: false) }
    }
}

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


// MARK: - Zig hand-off shim

/// The seam the page's messages reach the Zig runtime through.
///
/// The opposite direction from `CraftSwiftShim` below, and the two together
/// are the whole hand-off: this class offers each message to Zig, Zig serves
/// what it has migrated and declines the rest, and for anything Zig *did*
/// take that needs Swift work, `CraftSwiftShim` is how it comes back.
///
/// Discovery is `dlsym`, exactly as the shim's is, and for the same reason:
/// neither side links the other. An app built without the Zig static library
/// finds nothing here, `offer` answers false for every action, and the
/// coordinator's switch serves the entire surface as it always has. There is
/// no build flag and no second code path — the absence of a symbol is the
/// off switch.
@objc(CraftZigRuntime)
final class CraftZigRuntime: NSObject {
    private typealias SetWebViewFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ClearWebViewFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias HandleActionFn = @convention(c) (
        UnsafePointer<CChar>, UInt, UnsafePointer<CChar>, UInt, Int64
    ) -> Bool
    private typealias AdoptLocationRecordingFn = @convention(c) () -> Bool

    private static let image: UnsafeMutableRawPointer? = dlopen(nil, RTLD_NOW)

    private static let setWebViewFn: SetWebViewFn? = {
        guard let sym = dlsym(image, "craft_ios_set_webview") else { return nil }
        return unsafeBitCast(sym, to: SetWebViewFn.self)
    }()

    private static let clearWebViewFn: ClearWebViewFn? = {
        guard let sym = dlsym(image, "craft_ios_clear_webview") else { return nil }
        return unsafeBitCast(sym, to: ClearWebViewFn.self)
    }()

    private static let handleActionFn: HandleActionFn? = {
        guard let sym = dlsym(image, "craft_ios_handle_action") else { return nil }
        return unsafeBitCast(sym, to: HandleActionFn.self)
    }()

    private static let adoptLocationRecordingFn: AdoptLocationRecordingFn? = {
        guard let sym = dlsym(image, "craft_ios_adopt_location_recording") else { return nil }
        return unsafeBitCast(sym, to: AdoptLocationRecordingFn.self)
    }()

    /// Whether this build has a Zig runtime at all. Read by nothing here; kept
    /// because "is Zig linked" is the first question to ask when an action
    /// behaves like the Swift one after a migration was supposed to move it.
    @objc static var isLinked: Bool { handleActionFn != nil }

    /// Give Zig the webview its replies are evaluated against.
    ///
    /// Unretained on purpose, on both sides: this is the app's own root view
    /// and it outlives the runtime. A retain here would be a cycle with
    /// nothing to break it.
    static func attach(_ webView: WKWebView) {
        setWebViewFn?(Unmanaged.passUnretained(webView).toOpaque())
    }

    /// Hand a recording that outlived the last launch to whichever runtime owns
    /// the recorder.
    ///
    /// Returns true when Zig took it, and the caller must then *not* run
    /// `restoreLocationRecordingState()`. This is the one place the usual
    /// "offer it to Zig, fall back on false" pattern cannot be used through
    /// `handleAction`: there is no page message at launch, and the restore
    /// happens in `Coordinator.init` — before `attach`, because SwiftUI builds
    /// the coordinator before the view. Whoever restores first owns the
    /// `CLLocationManager` for the rest of the launch, so the decision has to
    /// be made here rather than at the first `stopLocationRecording`.
    ///
    /// False in a build with no Zig runtime, which is exactly when Swift's own
    /// restore is still the right thing to run.
    static func adoptLocationRecording() -> Bool {
        adoptLocationRecordingFn?() ?? false
    }

    /// Forget this webview, if Zig is still holding it.
    ///
    /// `attach` hands over an unretained pointer, so the moment SwiftUI
    /// deallocates the view Zig is holding freed memory and every later reply
    /// is an `objc_msgSend` into it. Nothing called this before, and nothing
    /// had to while the app had exactly one webview for its whole life — but
    /// a `UIViewRepresentable` is rebuilt whenever its identity changes, and
    /// the second rebuild is where that assumption stops holding.
    ///
    /// The webview is passed rather than implied: Zig clears only if this is
    /// still the pointer it has, so a rebuild that makes the replacement
    /// before dismantling the original cannot blank the live one.
    static func detach(_ webView: WKWebView) {
        clearWebViewFn?(Unmanaged.passUnretained(webView).toOpaque())
    }

    /// Offer one page message to the Zig dispatcher.
    ///
    /// Returns true when Zig has taken responsibility — the caller must not
    /// answer as well. False when no Zig module recognised the action, or when
    /// there is no runtime to ask.
    static func offer(action: String, body: [String: Any], callbackId: String?) -> Bool {
        guard let handleActionFn else { return false }

        // `_invoke` flattens the payload into the message —
        // `Object.assign({}, payload, {action, callbackId})` — so the payload
        // Zig's handlers parse is the message minus the two envelope keys.
        // This is the exact inverse of what `CraftSwiftShim.handleAction` does
        // when a call travels the other way, and the two must stay inverses:
        // leaving `action` in would put a key in the payload no handler
        // expects, and dropping a real field would hand a handler defaults the
        // page never asked for.
        var payload = body
        payload.removeValue(forKey: "action")
        payload.removeValue(forKey: "callbackId")

        // A payload that will not serialise is not offered. Falling through to
        // the Swift switch is the safe direction: it reads `body` directly and
        // never needs the round trip through JSON that just failed.
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return false }

        return action.withCString { a in
            json.withCString { p in
                handleActionFn(a, UInt(strlen(a)), p, UInt(strlen(p)), requestId(from: callbackId))
            }
        }
    }

    /// "cb_7" -> 7, and -1 for a message with no callback waiting on it.
    ///
    /// -1 rather than 0, matching what `craft_ios_deliver_result` already
    /// treats as "no id": zero is a perfectly good callback number, and a
    /// sentinel that collides with a real id would deliver one caller's answer
    /// to another.
    private static func requestId(from callbackId: String?) -> Int64 {
        guard let callbackId, callbackId.hasPrefix("cb_"),
              let n = Int64(callbackId.dropFirst(3))
        else { return -1 }
        return n
    }
}

/// The seam the Zig dispatcher hands unmigrated actions through.
///
/// Discovery is symmetric and both directions are runtime-only. Zig finds this
/// class with `objc_getClass("CraftSwiftShim")`; this class finds Zig's
/// delivery exports with `dlsym`. Neither side links the other, so a
/// pure-Swift app (no Zig runtime) and a fully-migrated Zig app (no shim work
/// left) both build and run without dead dependencies.
///
/// The shim decides *what* the answer is, never *how* it reaches the page.
/// Replies go back through Zig's `craft_ios_deliver_result` /
/// `craft_ios_deliver_error`, which own the wire format, the request id, and
/// the escaping. Two components replying to one page by different routes is
/// how this codebase accumulated five envelopes.
@objc(CraftSwiftShim)
final class CraftSwiftShim: NSObject {
    /// The coordinator serving hand-offs. Set by `makeCoordinator`.
    static weak var coordinator: CraftWebView.Coordinator?

    private typealias DeliverResultFn = @convention(c) (
        UnsafePointer<CChar>, UInt, UnsafePointer<CChar>, UInt, Int64
    ) -> Void
    private typealias DeliverErrorFn = @convention(c) (
        UnsafePointer<CChar>, UInt, UnsafePointer<CChar>, UInt,
        UnsafePointer<CChar>, UInt, Int64
    ) -> Void

    private static let deliverResult: DeliverResultFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "craft_ios_deliver_result") else { return nil }
        return unsafeBitCast(sym, to: DeliverResultFn.self)
    }()

    private static let deliverError: DeliverErrorFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "craft_ios_deliver_error") else { return nil }
        return unsafeBitCast(sym, to: DeliverErrorFn.self)
    }()

    /// Entry point for the Zig dispatcher. Selector: handleAction:payload:requestId:
    ///
    /// Returns false when this shim cannot serve the call — no live
    /// coordinator, or no Zig runtime to reply through — so Zig answers the
    /// page with UnknownAction instead of the call vanishing.
    @objc static func handleAction(_ action: String, payload: String, requestId: Int64) -> Bool {
        guard let coordinator, deliverResult != nil else { return false }

        let body = ((try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]) ?? [:]

        // The synthetic callbackId routes this call's reply back through Zig.
        // It carries the action too, because the reply helpers do not otherwise
        // know it, and Zig's reply names the action for the page's
        // action-matching fallback.
        coordinator.dispatch(action: action, body: body, callbackId: "zig:\(requestId):\(action)")
        return true
    }

    /// Route a resolve through Zig when the callbackId marks a hand-off.
    /// Returns true when the reply has been (or could only be) handled here.
    static func deliverResultIfHandOff(_ callbackId: String, json: String) -> Bool {
        guard let (requestId, action) = parseHandOffId(callbackId) else { return false }
        guard let deliverResult else { return true } // hand-off id but no runtime: drop, never eval JS
        action.withCString { a in
            json.withCString { j in
                deliverResult(a, UInt(strlen(a)), j, UInt(strlen(j)), requestId)
            }
        }
        return true
    }

    /// Route a rejection through Zig's error path, so the page's promise
    /// rejects rather than resolving with an error-shaped object.
    static func deliverErrorIfHandOff(_ callbackId: String, message: String, code: String) -> Bool {
        guard let (requestId, action) = parseHandOffId(callbackId) else { return false }
        guard let deliverError else { return true }
        action.withCString { a in
            message.withCString { m in
                code.withCString { c in
                    deliverError(a, UInt(strlen(a)), m, UInt(strlen(m)), c, UInt(strlen(c)), requestId)
                }
            }
        }
        return true
    }

    /// "zig:<requestId>:<action>" -> (requestId, action). Nil for ordinary
    /// page-issued callback ids, which keep their JavaScript reply path.
    private static func parseHandOffId(_ callbackId: String) -> (Int64, String)? {
        guard callbackId.hasPrefix("zig:") else { return nil }
        let rest = callbackId.dropFirst(4)
        guard let sep = rest.firstIndex(of: ":"), let id = Int64(rest[..<sep]) else { return nil }
        return (id, String(rest[rest.index(after: sep)...]))
    }
}
