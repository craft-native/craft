import Foundation
import SwiftUI
import UIKit
import WebKit
import Combine

// MARK: - Hybrid: web plus native screens
//
// `renderer: "web"` with `nativeScreens` set: the app is its web page, except
// for the paths the config names, which are stx native screens drawn with
// UIKit from `dist/native-screen.js`. Each tab keeps one UINavigationController
// whose stack mixes native screens and web entries, and the one WKWebView
// moves into whichever web entry is on screen. It is created at launch and
// loads the app's page behind the first screen, so it is warm by the time
// anything opens it.
//
// The page takes part through a document-start script (`pageScript`): it
// hands navigations to native paths to the shell instead of drawing them,
// reports where it went, and leaves the edge swipe to UIKit while it is at the
// entry a native screen opened. Nothing in the page has to change for that;
// craft's typescript mobile API adds `snapshots` and `hybrid` on top.
//
// `renderer: "native"` with `nativeScreens` is the same shell with no web
// view at all (`hasWeb` false): the same tabs, stacks and path routing, every
// tab and the start path a native screen, and a path no screen draws opened
// in the in-app browser on the app's site (`devServerURL`). No WKWebView is
// ever made; the services the web view's coordinator holds (GPS, the route
// recorder, Apple Music) come from a coordinator with no web view instead.
//
// Either way an app may run an app script (`nativeApp`): a bundle route with
// no screen, loaded once after the first frame and kept for the app's life.
// It hears the app's events (CraftEventManager) instead of the page, and
// opens paths through the shell.

/// The `nativeScreens` table: which paths are native, and with what params.
///
/// Foundation only, so `hybrid.test.ts` compiles and runs it on its own. The
/// page script and the typescript API (`matchNativePath`) implement the same
/// rules, and the tests hold all three to one set of cases.
struct CraftHybridRoutes {
    struct Match: Equatable {
        let path: String
        let screen: String
        let params: [String: String]
    }

    private struct Route {
        let pattern: String
        let segments: [String]
        let screen: String
    }

    private let routes: [Route]

    init(_ table: [String: String]) {
        routes = table.compactMap { pattern, screen -> Route? in
            guard let normalized = CraftHybridRoutes.normalize(pattern), !screen.isEmpty else { return nil }
            return Route(pattern: normalized, segments: CraftHybridRoutes.segments(normalized), screen: screen)
        }.sorted(by: CraftHybridRoutes.precedes)
    }

    var isEmpty: Bool { routes.isEmpty }

    /// Static segments before parameters, parameters before a wildcard, so
    /// `/m/workout/new` wins over `/m/workout/:id`, which wins over `/m/*`.
    private static func precedes(_ left: Route, _ right: Route) -> Bool {
        let wild = { (route: Route) in route.segments.last == "*" ? 1 : 0 }
        let fixed = { (route: Route) in route.segments.filter { $0 != "*" && !$0.hasPrefix(":") }.count }
        if wild(left) != wild(right) { return wild(left) < wild(right) }
        if fixed(left) != fixed(right) { return fixed(left) > fixed(right) }
        if left.segments.count != right.segments.count { return left.segments.count > right.segments.count }
        return left.pattern < right.pattern
    }

    /// `/a//b/?q#h` → `/a/b`. Nil for anything that is not an absolute path.
    static func normalize(_ raw: String) -> String? {
        var path = raw
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        guard path.hasPrefix("/") else { return nil }
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func segments(_ path: String) -> [String] {
        path == "/" ? [] : path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    /// The screen for `raw` (a path, with or without a query), or nil when the
    /// path belongs to the web. Query items become params, under the path's own.
    func match(_ raw: String) -> Match? {
        guard let path = Self.normalize(raw) else { return nil }
        let parts = Self.segments(path)
        for route in routes {
            guard var params = Self.bind(route.segments, to: parts) else { continue }
            if let query = raw.firstIndex(of: "?") {
                let rest = raw[raw.index(after: query)...].split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                for item in rest.split(separator: "&") {
                    let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                    let key = (pair.first ?? "").removingPercentEncoding ?? ""
                    guard !key.isEmpty, params[key] == nil else { continue }
                    let value = pair.count > 1 ? pair[1].replacingOccurrences(of: "+", with: " ") : ""
                    params[key] = value.removingPercentEncoding ?? value
                }
            }
            return Match(path: path, screen: route.screen, params: params)
        }
        return nil
    }

    private static func bind(_ pattern: [String], to parts: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        for (index, segment) in pattern.enumerated() {
            if segment == "*" {
                params["*"] = parts[min(index, parts.count)...].joined(separator: "/")
                return params
            }
            guard index < parts.count else { return nil }
            if segment.hasPrefix(":") {
                guard !parts[index].isEmpty else { return nil }
                params[String(segment.dropFirst())] = parts[index].removingPercentEncoding ?? parts[index]
            } else if segment != parts[index] {
                return nil
            }
        }
        return pattern.count == parts.count ? params : nil
    }

    /// The app path a link stands for: a web link's path, or for a custom
    /// scheme the host as the first segment (`hq://m/calendar` → `/m/calendar`).
    /// The query is kept.
    static func appPath(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        let scheme = (components.scheme ?? "").lowercased()
        var path = components.percentEncodedPath
        if scheme != "http" && scheme != "https", let host = components.host, !host.isEmpty {
            path = "/" + host + (path.isEmpty || path.hasPrefix("/") ? path : "/" + path)
        }
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty { path += "?" + query }
        return path
    }

    /// Whether a web address is on the app's site: the host of `site`
    /// (`devServerURL`), over http or https.
    static func isSite(_ url: URL, site: URL?) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              let siteScheme = site?.scheme?.lowercased(), scheme == siteScheme,
              let siteHost = site?.host?.lowercased(), host == siteHost,
              url.port == site?.port else { return false }
        return true
    }

    /// Where a path no native screen draws opens in an app with no web view:
    /// a web address as it is, an app path on the origin of `site`. Nil for
    /// anything else, and for a path when there is no site.
    static func siteURL(for raw: String, site: URL?) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            return scheme == "http" || scheme == "https" ? url : nil
        }
        // `//host/x` is another host, not a path.
        guard raw.hasPrefix("/"), !raw.hasPrefix("//"), let site,
              var origin = URLComponents(url: site, resolvingAgainstBaseURL: false),
              let scheme = origin.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        origin.percentEncodedPath = ""
        origin.percentEncodedQuery = nil
        origin.percentEncodedFragment = nil
        guard let base = origin.url else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    /// The tab a path belongs to: the tab whose id is the path, or else the
    /// longest tab id that is a whole-segment prefix of it.
    static func tab(owning raw: String, among tabs: [String]) -> String? {
        guard let path = normalize(raw) else { return nil }
        var best: String?
        for tab in tabs {
            guard let id = normalize(tab) else { continue }
            let owns = path == id || id == "/" || path.hasPrefix(id + "/")
            if owns && (best.flatMap(normalize)?.count ?? -1) < id.count { best = tab }
        }
        return best
    }
}

/// What the page's `craftHybrid` channel says. Foundation only, for the tests.
enum CraftHybridMessage: Equatable {
    /// The router was asked for a native path; the page drew nothing.
    case navigateNative(path: String, replace: Bool)
    /// The page is somewhere new. `byHost` when the shell asked it to go there.
    case navigated(path: String, direction: String, depth: Int, byHost: Bool)
    /// Back, from the entry a native screen opened: the shell's to do.
    case back
    /// `craft.hybrid.open(path)` from the page.
    case open(path: String)
    case snapshotSet(name: String, json: String)
    case snapshotRemove(name: String)
    case snapshotClear
    /// A web-storage key the config shares with native screens changed.
    case shareStorage(key: String, value: String?)

    static func parse(_ body: [String: Any]) -> CraftHybridMessage? {
        func text(_ key: String) -> String? { (body[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch body["type"] as? String {
        case "navigateNative":
            guard let path = text("path"), path.hasPrefix("/") else { return nil }
            return .navigateNative(path: path, replace: body["replace"] as? Bool ?? false)
        case "navigated":
            guard let path = text("path"), path.hasPrefix("/") else { return nil }
            let depth = (body["depth"] as? NSNumber)?.intValue ?? 0
            return .navigated(path: path, direction: text("direction") ?? "push", depth: max(0, depth), byHost: body["byHost"] as? Bool ?? false)
        case "back":
            return .back
        case "open":
            guard let path = text("path"), path.hasPrefix("/") else { return nil }
            return .open(path: path)
        case "snapshotSet":
            guard let name = text("name"), let json = body["json"] as? String else { return nil }
            return .snapshotSet(name: name, json: json)
        case "snapshotRemove":
            guard let name = text("name") else { return nil }
            return .snapshotRemove(name: name)
        case "snapshotClear":
            return .snapshotClear
        case "shareStorage":
            guard let key = text("key") else { return nil }
            return .shareStorage(key: key, value: body["value"] as? String)
        default:
            return nil
        }
    }
}

/// A key the page shares with native screens, in the Keychain twice: as the
/// web's `secureStorage` writes it (generic password, account = key, no
/// service), which `craft.secureStorage.getSync` reads, and under the native
/// screens' own service, which their async `craft.secureStorage.get` reads.
enum CraftHybridKeychain {
    static let nativeService = "dev.craft.native.secure"

    static func set(_ key: String, value: String?) {
        defer { CraftKeychain.forget(account: key) }
        // Every item for the account, whatever its service.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
        CraftKeychain.forget(account: key)
        guard let value else { return }
        for service in [nil, nativeService] {
            var add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            if let service { add[kSecAttrService as String] = service }
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { NSLog("[craft hybrid] could not share %@ with native screens (%d)", key, status) }
        }
    }
}

/// What a native screen tells the hybrid shell. `CraftNativeScreenController`
/// calls these when the shell set itself as its `hybridEvents`.
protocol CraftHybridScreenEvents: AnyObject {
    /// The screen's first frame is laid out.
    func nativeScreenDidRender(_ screen: CraftNativeScreenController)
    /// The screen could not draw its first frame: no bundle, or its script threw.
    func nativeScreen(_ screen: CraftNativeScreenController, didFail message: String)
    /// `craft.navigation.open(path, props)`.
    func nativeScreen(_ screen: CraftNativeScreenController, open path: String, props: [String: Any])
    /// `craft.navigation.replace(path)`: finish the current flow atomically.
    func nativeScreen(_ screen: CraftNativeScreenController, replace path: String)
}

// MARK: - The shell

final class CraftHybrid: NSObject {
    static let shared = CraftHybrid()

    private(set) var config = CraftConfig()
    private(set) var routes = CraftHybridRoutes([:])
    /// Whether this app routes paths to native screens through the shell:
    /// web plus native screens (hybrid), or all native with paths and tabs.
    private(set) var isEnabled = false
    /// Whether the app has a web page at all (renderer "web"). False for an
    /// all-native app, whose shell never makes a web view.
    private(set) var hasWeb = true
    /// The app's site (`devServerURL`, http or https): where an all-native
    /// app opens a path no screen draws, in the in-app browser.
    private(set) var siteURL: URL?
    /// The path the app opens on: its page's path.
    private(set) var startPath = "/"
    /// Whether that path is a native screen, drawn before the page loads.
    private(set) var startsNative = false
    weak var controller: CraftHybridController?
    weak var webView: WKWebView?

    /// The app script's bundle route (`nativeApp`), when it runs.
    private(set) var appScriptRoute: String?
    /// The app script itself, held for the app's life and never shown.
    private var appScript: CraftNativeScreenController?
    /// An all-native app's services: the web view's coordinator, with no web
    /// view, so GPS, the route recorder (and its relaunch restore) and Apple
    /// Music serve native screens (CraftWebServices). Held here, because
    /// `CraftSwiftShim.coordinator` is weak.
    private var services: CraftWebView.Coordinator?
    private var isConfigured = false
    /// A single-stack native app's first frame, which starts the app script.
    private var firstFrameSeen = false
    /// What waits for the shell: links and opens that arrived before it
    /// existed (a launch from a notification or a link).
    private var untilShell: [(CraftHybridController) -> Void] = []

    /// Where the page is, as it last said.
    fileprivate(set) var pagePath: String?
    fileprivate(set) var pageDepth = 0
    fileprivate(set) var pageReady = false

    /// Shared keys a native screen wrote, by the page's own key (NSNull for a
    /// removal), until the page has them: it reports each back as its own
    /// write, which is when it leaves this list.
    private var pendingShared: [String: Any] = [:]

    private override init() {}

    /// A native screen wrote a key the page shares (`shareStorage`, named
    /// here by its native name): both Keychain copies, and the page's own
    /// storage, now if it is loaded or when it next loads. Nothing for a key
    /// the config does not share.
    func nativeWroteShared(nativeKey: String, value: String?) {
        guard let webKey = config.shareStorage?.first(where: { $0.value == nativeKey })?.key else { return }
        CraftHybridKeychain.set(nativeKey, value: value)
        guard hasWeb else { return }
        DispatchQueue.main.async {
            self.pendingShared[webKey] = value ?? NSNull()
            self.flushShared()
        }
    }

    private func flushShared() {
        guard pageReady, let webView, !pendingShared.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: pendingShared),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.adopt && window.__craftHybrid.adopt(\(json))")
    }

    /// Whether the app carries native screens: the one-file bundle, or a
    /// file per route (`CraftNativeBundle`).
    static var hasBundle: Bool { CraftNativeBundle.isAvailable }

    /// From the bundled config, at launch: whether the shell routes paths,
    /// whether there is a web view, where it starts, the tab bar it starts
    /// with, the app script, and an all-native app's services. Once: the app
    /// delegate calls it at launch and AppState again; the first call decides.
    func configure(_ config: CraftConfig) {
        guard !isConfigured else { return }
        isConfigured = true
        self.config = config
        CraftNativeScriptThread.isBackground = config.nativeScriptThread == "background"
        if CraftNativeScriptThread.isBackground { CraftNativeBundle.prewarm() }
        hasWeb = config.renderer != "native"
        siteURL = config.devServerURL.flatMap(URL.init(string:)).flatMap { url in
            ["http", "https"].contains((url.scheme ?? "").lowercased()) ? url : nil
        }
        routes = CraftHybridRoutes(config.nativeScreens ?? [:])
        startPath = config.devServerURL.flatMap(URL.init(string:)).map(CraftHybridRoutes.appPath(of:)) ?? "/"
        if startPath.isEmpty { startPath = "/" }
        let wanted = !routes.isEmpty
        if wanted && !Self.hasBundle {
            NSLog(hasWeb
                ? "[craft hybrid] nativeScreens are set but dist/native-screen.js is missing; every path opens in the web view"
                : "[craft hybrid] nativeScreens are set but dist/native-screen.js is missing; the app has no screens to show")
        }
        isEnabled = wanted && Self.hasBundle
        if isEnabled, !hasWeb, routes.match(startPath) == nil {
            // No web view to show it in: the first tab a screen draws.
            let fallback = (config.tabs ?? []).map(\.id).first { routes.match($0) != nil }
            NSLog("[craft hybrid] no native screen draws the start path %@ and there is no web view; starting on %@", startPath, fallback ?? "nothing")
            if let fallback { startPath = fallback }
        }
        startsNative = isEnabled && routes.match(startPath) != nil
        // The splash waits for a page; an all-native app's first screen draws itself.
        CraftChrome.shared.configure(tabs: config.tabs ?? [], selected: tabIds(from: config.tabs ?? []).isEmpty ? nil : CraftHybridRoutes.tab(owning: startPath, among: tabIds(from: config.tabs ?? [])), splash: hasWeb && !startsNative, appearance: config.tabBar)

        let script = config.nativeApp.flatMap { $0.isEmpty ? nil : $0 }
        appScriptRoute = script != nil && Self.hasBundle && (isEnabled || !hasWeb) ? script : nil
        if let script, appScriptRoute == nil {
            NSLog("[craft hybrid] nativeApp %@ does not run: it needs dist/native-screen.js, and nativeScreens or renderer \"native\"", script)
        }
        CraftEventManager.shared.configure(appScript: appScriptRoute != nil, page: hasWeb)

        if !hasWeb && services == nil {
            let coordinator = CraftWebView.Coordinator(config: config)
            services = coordinator
            CraftSwiftShim.coordinator = coordinator
        }

        guard appScriptRoute != nil else { return }
        // It starts after the first frame (`nativeScreenDidRender`), or as
        // soon as background work waits for it (`backgroundWorkWaiting`).
        // This is for the rest: a first screen that is the page's, one that
        // never draws, a launch in the background with nothing to draw.
        // (`applicationState` cannot tell those apart here: a scene-based app
        // is `.background` during launch however it was opened.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startAppScript() }
    }

    /// A silent push or a background refresh is waiting for the app script,
    /// with iOS's clock running: it starts now rather than after a frame,
    /// which a launch in the background never draws.
    func backgroundWorkWaiting() {
        guard appScriptRoute != nil, appScript == nil else { return }
        DispatchQueue.main.async { self.startAppScript() }
    }

    /// The app script: loaded once, off screen, and kept. Started after the
    /// first frame is committed, so it never delays it, or at once when
    /// background work is waiting for it. Its `craft.navigation.open` comes here
    /// (`nativeScreen(_:open:)`), and so to the shell.
    func startAppScript() {
        guard appScript == nil, let route = appScriptRoute else { return }
        let script = CraftNativeScreenController(config: config, routeName: route, isAppScript: true)
        script.hybridEvents = self
        appScript = script
        script.loadViewIfNeeded()
        #if DEBUG
        NSLog("[craft hybrid] app script %@ is running", route)
        #endif
    }

    #if DEBUG
    /// The crash reporter's debug-only test (`-CraftCrashTest js`): an
    /// uncaught error thrown in the app script, as a real one would be.
    func debugThrowInAppScript(_ message: String) {
        if appScript == nil { startAppScript() }
        let literal = (try? JSONSerialization.data(withJSONObject: [message])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"test\"]"
        appScript?.evaluateScript("(function crashReporterTest() { throw new TypeError(\(literal)[0]); })()")
    }
    #endif

    /// The shell is up: what waited for it.
    func shellReady() {
        guard let controller else { return }
        let waiting = untilShell
        untilShell.removeAll()
        for work in waiting { work(controller) }
    }

    /// A path or a web address opened by the app script or a single-stack
    /// screen: the shell opens it (holding it until the shell exists); an app
    /// with no shell opens a web address in the in-app browser.
    func open(_ path: String, props: [String: Any] = [:]) {
        if let controller {
            controller.open(path, props: props)
        } else if isEnabled {
            untilShell.append { $0.open(path, props: props) }
        } else {
            openOutside(path)
        }
    }

    /// A path no native screen draws, in an app with no web view, or an
    /// address on another site: the in-app browser.
    func openOutside(_ raw: String) {
        guard let url = CraftHybridRoutes.siteURL(for: raw, site: siteURL) else {
            NSLog("[craft hybrid] %@ has no native screen, and the app has no site (devServerURL) to open it on", raw)
            return
        }
        CraftBrowser.shared.open(url, mode: "safari", callbackScheme: nil, from: nil) { _ in }
    }

    private func tabIds(from tabs: [CraftConfig.Tab]) -> [String] { tabs.map(\.id) }

    /// The tab ids the bar shows now: the page's once it has described them.
    var tabIds: [String] {
        let shown = CraftChrome.shared.tabs.map(\.id)
        return shown.isEmpty ? (config.tabs ?? []).map(\.id) : shown
    }

    /// Whether the web view is what the person sees: always in a web app
    /// outside hybrid, never in an app with no web view.
    var webIsVisible: Bool {
        guard hasWeb else { return false }
        guard isEnabled else { return true }
        return controller?.webIsVisible ?? !startsNative
    }

    // MARK: Page script

    /// The document-start script the hybrid page runs, with the route table
    /// and the shared storage keys filled in.
    func pageScript() -> String {
        let routeList = (config.nativeScreens ?? [:]).map { ["pattern": $0.key, "screen": $0.value] }
        let share = Array((config.shareStorage ?? [:]).keys).sorted()
        // The page's key for the sign-in token, when it shares one.
        let tokenKey = CraftSession.tokenKey(config)
        let session = (config.shareStorage ?? [:]).filter { $0.value == tokenKey }.map(\.key).sorted().first
        func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return Self.pageScriptTemplate
            .replacingOccurrences(of: "__CRAFT_HYBRID_ROUTES__", with: json(routeList))
            .replacingOccurrences(of: "__CRAFT_HYBRID_SHARE__", with: json(share))
            .replacingOccurrences(of: "__CRAFT_HYBRID_SESSION__", with: session.map { json([$0]) } ?? "[]")
    }

    // CRAFT_HYBRID_PAGE_SCRIPT_START
    static let pageScriptTemplate = #"""
    (function () {
      if (window.__craftHybrid) return;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craftHybrid;
      if (!handler) return;
      var ROUTES = __CRAFT_HYBRID_ROUTES__;
      var SHARE = __CRAFT_HYBRID_SHARE__;
      function post(message) { try { handler.postMessage(message); } catch (e) {} }
      var web = location.protocol === 'http:' || location.protocol === 'https:';

      function normalize(path) {
        if (typeof path !== 'string') return null;
        var cut = path.search(/[?#]/);
        if (cut >= 0) path = path.slice(0, cut);
        if (path.charAt(0) !== '/') return null;
        path = path.replace(/\/{2,}/g, '/');
        if (path.length > 1 && path.charAt(path.length - 1) === '/') path = path.slice(0, -1);
        return path;
      }
      function segments(path) { return path === '/' ? [] : path.slice(1).split('/'); }
      function decode(value) { try { return decodeURIComponent(value); } catch (e) { return value; } }
      var table = [];
      for (var i = 0; i < ROUTES.length; i++) {
        var pattern = normalize(ROUTES[i].pattern);
        if (pattern && ROUTES[i].screen) table.push({ pattern: pattern, segments: segments(pattern), screen: ROUTES[i].screen });
      }
      function wild(r) { return r.segments[r.segments.length - 1] === '*' ? 1 : 0; }
      function fixed(r) { return r.segments.filter(function (s) { return s !== '*' && s.charAt(0) !== ':'; }).length; }
      table.sort(function (a, b) {
        return (wild(a) - wild(b)) || (fixed(b) - fixed(a)) || (b.segments.length - a.segments.length) || (a.pattern < b.pattern ? -1 : a.pattern > b.pattern ? 1 : 0);
      });
      function bind(pattern, parts) {
        var params = {};
        for (var i = 0; i < pattern.length; i++) {
          var s = pattern[i];
          if (s === '*') { params['*'] = parts.slice(i).join('/'); return params; }
          if (i >= parts.length) return null;
          if (s.charAt(0) === ':') { if (!parts[i]) return null; params[s.slice(1)] = decode(parts[i]); }
          else if (s !== parts[i]) return null;
        }
        return pattern.length === parts.length ? params : null;
      }
      function match(raw) {
        var path = normalize(raw);
        if (path === null) return null;
        var parts = segments(path);
        for (var i = 0; i < table.length; i++) {
          var params = bind(table[i].segments, parts);
          if (!params) continue;
          var query = raw.indexOf('?');
          if (query >= 0) {
            raw.slice(query + 1).split('#')[0].split('&').forEach(function (item) {
              if (!item) return;
              var at = item.indexOf('=');
              var key = decode(at < 0 ? item : item.slice(0, at));
              if (!key || Object.prototype.hasOwnProperty.call(params, key)) return;
              params[key] = at < 0 ? '' : decode(item.slice(at + 1).replace(/\+/g, ' '));
            });
          }
          return { path: path, screen: table[i].screen, params: params };
        }
        return null;
      }
      // The same origin's path and query, or null for anywhere else.
      function local(url) {
        try {
          var u = new URL(String(url), location.href);
          if (u.origin !== location.origin) return null;
          return u.pathname + u.search;
        } catch (e) { return null; }
      }

      // Where the page is in its router's stack, and the entry a native
      // screen opened (null when the page's own tab root is underneath).
      function depth() {
        var router = window.stxRouter;
        if (router && typeof router.screens === 'function') {
          try {
            var list = router.screens();
            for (var i = 0; i < list.length; i++) if (list[i].active) return list[i].depth | 0;
          } catch (e) {}
        }
        return 0;
      }
      var base = null;
      function atBase() { return base !== null && depth() <= base; }
      var hostNav = null;
      var hostPop = false;
      // The shell's navigation in flight, answered once the page has drawn it.
      var arriving = null;
      function frame(callback) { (window.requestAnimationFrame || setTimeout)(callback); }

      var navigate = null;
      var historyBack = history.back.bind(history);
      var historyGo = history.go.bind(history);
      function adopt(router) {
        if (!router || typeof router !== 'object' || router.__craftHybrid) return router;
        var own = router.navigate;
        if (typeof own !== 'function') return router;
        navigate = function () { return own.apply(router, arguments); };
        // A forward navigation to a native path is the shell's to show; the
        // page draws nothing. Back (pushState false), tab switches and the
        // shell's own navigations go through untouched. A redirect (replace),
        // as after signing in, is the page leaving where it was: the shell
        // shows the native screen and the page follows it there behind it,
        // or it stayed on the sign-in page and the next screen pushed from it
        // came up blank.
        router.navigate = router.navigateTo = function (url, pushState, force) {
          var path = local(url);
          if (path !== null && pushState !== false && pushState !== 'tab' && hostNav === null && match(path)) {
            var replace = pushState === 'replace' || !!(pushState && typeof pushState === 'object' && pushState.replace);
            post({ type: 'navigateNative', path: path, replace: replace });
            if (replace) return own.apply(router, arguments);
            return Promise.resolve(false);
          }
          return own.apply(router, arguments);
        };
        var ownBack = router.back;
        router.back = function () {
          if (atBase()) { post({ type: 'back' }); return; }
          return typeof ownBack === 'function' ? ownBack.apply(router, arguments) : historyBack();
        };
        router.__craftHybrid = true;
        return router;
      }
      var current = adopt(window.stxRouter);
      try {
        Object.defineProperty(window, 'stxRouter', {
          configurable: true,
          enumerable: true,
          get: function () { return current; },
          set: function (value) { current = adopt(value); }
        });
      } catch (e) {}

      // Back at the entry a native screen opened goes to that screen.
      history.back = function () {
        if (atBase()) { post({ type: 'back' }); return; }
        return historyBack();
      };

      // A link to a native path, before the router sees the click.
      window.addEventListener('click', function (event) {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        var link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!link) return;
        // The bar's Back (data-native-back). Its href is only where to go
        // without history, often a native path like the calendar; at the
        // entry a native screen opened, Back is that screen.
        if (link.hasAttribute('data-native-back')) {
          if (!atBase()) return;
          event.preventDefault();
          event.stopPropagation();
          post({ type: 'back' });
          return;
        }
        if ((link.target && link.target !== '_self') || link.hasAttribute('download') || link.hasAttribute('data-native-tab')
          || link.getAttribute('data-stx-nav') === 'tab' || link.hasAttribute('data-craft-web')) return;
        var path = local(link.href);
        if (path === null || !match(path)) return;
        event.preventDefault();
        event.stopPropagation();
        post({ type: 'navigateNative', path: path, replace: false });
      }, true);

      // At that entry the edge swipe is UIKit's, back to the native screen;
      // the router's own swipe would show the page's previous screen instead.
      window.addEventListener('touchstart', function (event) {
        var touch = event.touches && event.touches[0];
        if (touch && touch.clientX <= 30 && atBase()) event.stopPropagation();
      }, { capture: true, passive: true });

      function report(direction) {
        if (!web) return;
        var message = { type: 'navigated', path: location.pathname + location.search, direction: direction, depth: depth() };
        if (direction === 'pop' && hostPop) { message.byHost = true; hostPop = false; }
        else if (hostNav !== null && local(hostNav) === message.path) { message.byHost = true; hostNav = null; }
        post(message);
        if (arriving && arriving.path === message.path) {
          var finish = arriving.finish;
          arriving = null;
          // Two frames on: the new screen is on screen, not just in the DOM.
          frame(function () { frame(finish); });
        }
      }
      window.addEventListener('stx:navigate', function (event) {
        var detail = (event && event.detail) || {};
        report(detail.direction || 'push');
      });
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { report('load'); });
      else report('load');

      // Web storage the config shares with native screens (`shareStorage`).
      var shared = {};
      // The page's key for the sign-in token (`sessionTokenKey`), if shared.
      var SESSION = (__CRAFT_HYBRID_SESSION__)[0] || null;
      var sessionListeners = [];
      function stored(key) {
        var value = null;
        try { value = window.sessionStorage.getItem(key); } catch (e) {}
        try { if (value === null) value = window.localStorage.getItem(key); } catch (e) {}
        return value;
      }
      function sessionToken(value) { return typeof value === 'string' && value !== '' ? value : null; }
      function share(key) {
        var value = stored(key);
        if (shared[key] === value) return;
        var known = Object.prototype.hasOwnProperty.call(shared, key);
        var before = shared[key];
        shared[key] = value;
        post({ type: 'shareStorage', key: key, value: value });
        // A sign-in, sign-out or another account, made here or on a native
        // screen: `craftsession { key, token, previous }` and craft.session.
        if (key === SESSION && known && sessionToken(before) !== sessionToken(value)) {
          var change = { key: key, token: sessionToken(value), previous: sessionToken(before) };
          sessionListeners.slice().forEach(function (callback) {
            try { callback(change.token, change.previous); } catch (e) { console.error(e); }
          });
          try { window.dispatchEvent(new CustomEvent('craftsession', { detail: change })); } catch (e) {}
        }
      }
      if (SESSION && window.craft && !window.craft.session) {
        window.craft.session = {
          key: SESSION,
          token: function () { return sessionToken(stored(SESSION)); },
          onChange: function (callback) {
            if (typeof callback !== 'function') throw new TypeError('craft.session.onChange needs a function');
            sessionListeners.push(callback);
            return function () {
              var index = sessionListeners.indexOf(callback);
              if (index >= 0) sessionListeners.splice(index, 1);
            };
          }
        };
      }
      if (SHARE.length && window.Storage) {
        var proto = window.Storage.prototype;
        var setItem = proto.setItem, removeItem = proto.removeItem, clear = proto.clear;
        proto.setItem = function (key) { var out = setItem.apply(this, arguments); if (SHARE.indexOf(String(key)) >= 0) share(String(key)); return out; };
        proto.removeItem = function (key) { var out = removeItem.apply(this, arguments); if (SHARE.indexOf(String(key)) >= 0) share(String(key)); return out; };
        proto.clear = function () { var out = clear.apply(this, arguments); SHARE.forEach(share); return out; };
        SHARE.forEach(share);
      }

      // A shared key a native screen wrote (a sign-in there): into this
      // page's storage, which reports it back as the page's own write, and
      // a `craftsharedstorage` event for whoever holds it in memory. Named
      // apart from the router's adopt: function declarations hoist, so a
      // second `adopt` replaced the first and the router went unwrapped.
      function adoptShared(values) {
        Object.keys(values || {}).forEach(function (key) {
          if (SHARE.indexOf(key) < 0) return;
          var value = values[key];
          try {
            window.sessionStorage.removeItem(key);
            if (value === null) window.localStorage.removeItem(key);
            else window.localStorage.setItem(key, String(value));
          } catch (e) {}
          share(key);
          try { window.dispatchEvent(new CustomEvent('craftsharedstorage', { detail: { key: key, value: value } })); } catch (e) {}
        });
      }

      window.__craftHybrid = {
        match: function (url) { var path = local(url); return path === null ? null : match(path); },
        adopt: adoptShared,
        // The shell's own navigation: never handed back to it, and without
        // the page's slide, since the shell animates the push itself.
        // Answers once the page has drawn `path` (its router settles before
        // the new screen is up), or at once when it went nowhere.
        navigate: function (path) {
          hostNav = path;
          return new Promise(function (resolve) {
            var done = false;
            var finish = function () {
              if (done) return;
              done = true;
              // A navigation that never reported must not leave the next one unhandled.
              setTimeout(function () { if (hostNav === path) hostNav = null; }, 0);
              resolve({ path: location.pathname + location.search, depth: depth() });
            };
            if (!(navigate && current && current.__craftHybrid)) {
              location.assign(path);
              resolve({ path: path, depth: 0 });
              return;
            }
            arriving = { path: local(path), finish: finish };
            Promise.resolve(navigate(path, { instant: true })).then(function (went) {
              if (went === false && arriving && arriving.finish === finish) { arriving = null; finish(); }
            }, function () { arriving = null; finish(); });
          });
        },
        // Put the page at `path` in place of where it is, without a step in
        // its history: the shell is back at a native screen and the page
        // behind it had no history left to go back through (it reloaded).
        reset: function (path) {
          if (!(navigate && current && current.__craftHybrid)) { location.replace(path); return Promise.resolve(false); }
          hostNav = path;
          return Promise.resolve(navigate(path, { instant: true, replace: true }));
        },
        setBase: function (value) { base = typeof value === 'number' ? value : null; },
        // Back to `target` in the page's stack, after the shell popped the
        // entries above it.
        backTo: function (target) {
          var steps = depth() - (target | 0);
          if (steps <= 0) return 0;
          hostPop = true;
          historyGo(-steps);
          return steps;
        },
        depth: depth
      };
    })();
    """#
    // CRAFT_HYBRID_PAGE_SCRIPT_END

    // MARK: Messages from the page

    func receive(_ body: [String: Any]) {
        guard let message = CraftHybridMessage.parse(body) else { return }
        #if DEBUG
        if case .shareStorage(let key, let value) = message {
            NSLog("[craft hybrid] page: shareStorage %@ (%@)", key, value == nil ? "cleared" : "set")
        } else if case .snapshotSet(let name, _) = message {
            NSLog("[craft hybrid] page: snapshot %@", name)
        } else {
            NSLog("[craft hybrid] page: %@", String(describing: message))
        }
        #endif
        switch message {
        // The same files, through the same writer, as a native screen's
        // `craft.snapshots` (CraftSnapshots, CraftNativeActions.swift).
        case .snapshotSet(let name, let json):
            CraftSnapshots.write(name, json: json) { ok in
                if !ok { NSLog("[craft hybrid] snapshot %@ was not written: not a snapshot name, or not JSON", name) }
            }
        case .snapshotRemove(let name):
            CraftSnapshots.write(name, json: nil)
        case .snapshotClear:
            CraftSnapshots.clear()
        case .shareStorage(let key, let value):
            guard let nativeKey = config.shareStorage?[key] else { return }
            // The page's own write, or its echo of one a native screen made.
            pendingShared.removeValue(forKey: key)
            // The page's sign-in or sign-out moves the account for every
            // screen; an echo writes what is already there and moves nothing.
            CraftSession.observe(key: nativeKey, config: config) { CraftHybridKeychain.set(nativeKey, value: value) }
        case .navigated(let path, let direction, let depth, let byHost):
            pagePath = path
            pageDepth = depth
            if direction == "load" { pageReady = true }
            controller?.pageNavigated(path: path, direction: direction, depth: depth, byHost: byHost)
            if direction == "load" { flushShared() }
        case .navigateNative(let path, let replace):
            controller?.showNative(path: path, replace: replace)
        case .open(let path):
            controller?.open(path)
        case .back:
            controller?.popTop()
        }
    }

    /// Posted when the page wrote or removed a snapshot (`userInfo["name"]`).
    static let snapshotChanged = CraftSnapshots.changed

    // MARK: Tabs and links

    /// A tap on the native bar. Answers whether the page should also hear
    /// it (`craftTabSelect`), which it does for every switch so the page's own
    /// tab follows the screen.
    func tabTapped(_ id: String, reselect: Bool) -> Bool {
        guard isEnabled, let controller else { return true }
        return controller.tabTapped(id, reselect: reselect)
    }

    /// A native tab not prepared yet mounts its screen now, hidden, before
    /// the bar's selection moves (CraftChrome.tap).
    func mountTabBeforeSelecting(_ id: String) {
        guard isEnabled else { return }
        controller?.mountTabBeforeSelecting(id)
    }

    /// The page chose a tab itself (its `selectTab`, or a tab link).
    func pageSelectedTab(_ id: String) {
        guard isEnabled else { return }
        controller?.pageSelectedTab(id)
    }

    /// A deep link to a native path opens the native screen; in an app with
    /// no web view, a link to its own site that no screen draws opens in the
    /// in-app browser. True when the shell took it.
    func handleDeepLink(_ url: URL) -> Bool {
        guard isEnabled else { return false }
        let path = CraftHybridRoutes.appPath(of: url)
        let native = routes.match(path) != nil
        let browse = !native && !hasWeb && CraftHybridRoutes.isSite(url, site: siteURL)
        guard native || browse else { return false }
        let show: (CraftHybridController) -> Void = { [weak self] controller in
            if native { controller.showNative(path: path, replace: false, fromLink: true) } else { self?.openOutside(url.absoluteString) }
        }
        guard let controller, controller.isViewLoaded else {
            // Before the shell: a hybrid app's page has it; an all-native app
            // opens it once the shell is up (a link that launched the app).
            // Construction assigns controller before viewDidLoad makes the
            // navigation stacks; a link in that interval must wait too.
            guard !hasWeb else { return false }
            untilShell.append(show)
            return true
        }
        show(controller)
        return true
    }

    /// The bar covers this much of the bottom of the screen.
    func tabBarCovers(_ height: CGFloat) {
        controller?.tabBarCovers(height)
    }

    // MARK: Driving the page

    /// Navigate the page to `path` and answer with its depth there, or nil
    /// when the page could only be loaded afresh or is still on its way.
    /// Answers within `within` seconds: a push waits that long at most for
    /// the page, then slides in and shows the page when it has arrived.
    func navigatePage(_ path: String, within: TimeInterval = 0.35, completion: @escaping (Int?) -> Void) {
        var answered = false
        let answer: (Int?) -> Void = { depth in
            guard !answered else { return }
            answered = true
            completion(depth)
        }
        guard hasWeb else { answer(nil); return }
        guard let webView, pageReady, let scheme = webView.url?.scheme, scheme == "http" || scheme == "https" else {
            CraftSwiftShim.coordinator?.loadAppPath(path)
            answer(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + within) { answer(nil) }
        webView.callAsyncJavaScript(
            "if (!window.__craftHybrid) return null; var r = await window.__craftHybrid.navigate(path); return r ? r.depth : null;",
            arguments: ["path": path],
            in: nil,
            in: .page
        ) { result in
            if case .success(let value) = result, let depth = value as? NSNumber { answer(depth.intValue) } else { answer(nil) }
        }
    }

    func setPageBase(_ depth: Int?) {
        guard hasWeb else { return }
        let value = depth.map(String.init) ?? "null"
        webView?.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.setBase(\(value))", completionHandler: nil)
    }

    func pageReset(to path: String) {
        guard hasWeb, let data = try? JSONSerialization.data(withJSONObject: [path]), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.reset && window.__craftHybrid.reset(\(json)[0])", completionHandler: nil)
    }

    func pageBack(to depth: Int) {
        guard hasWeb else { return }
        webView?.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.backTo(\(max(0, depth)))", completionHandler: nil)
    }
}

/// What the app script and a single-stack native app's screens tell the shell.
extension CraftHybrid: CraftHybridScreenEvents {
    /// A single-stack app's first frame: the app script starts once it is
    /// committed. (The routed shell's controller does the same for its own.)
    func nativeScreenDidRender(_ screen: CraftNativeScreenController) {
        guard !firstFrameSeen else { return }
        firstFrameSeen = true
        CATransaction.setCompletionBlock { [weak self] in self?.startAppScript() }
    }

    /// The screen keeps its own error; the app script still runs.
    func nativeScreen(_ screen: CraftNativeScreenController, didFail message: String) {
        NSLog("[craft hybrid] the native screen could not draw its first frame: %@", message)
        DispatchQueue.main.async { self.startAppScript() }
    }

    func nativeScreen(_ screen: CraftNativeScreenController, open path: String, props: [String: Any]) {
        open(path, props: props)
    }

    func nativeScreen(_ screen: CraftNativeScreenController, replace path: String) {
        controller?.showNative(path: path, replace: true)
    }
}

/// The page's `craftHybrid` channel, only from a trusted origin's main frame.
final class CraftHybridRelay: NSObject, WKScriptMessageHandler {
    private let trusts: (WKSecurityOrigin) -> Bool

    init(trusts: @escaping (WKSecurityOrigin) -> Bool) {
        self.trusts = trusts
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusts(message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any] else { return }
        DispatchQueue.main.async { CraftHybrid.shared.receive(body) }
    }
}

// MARK: - Screens

struct CraftHybridRoot: UIViewControllerRepresentable {
    let config: CraftConfig

    func makeUIViewController(context: Context) -> CraftHybridController {
        CraftHybridController(config: config)
    }

    func updateUIViewController(_ controller: CraftHybridController, context: Context) {}
}

/// A web entry in a tab's stack. The one web view moves into whichever entry
/// is on screen; the others are empty until they are shown again.
final class CraftHybridWebSlot: UIViewController {
    /// The path the entry opened at.
    var path: String
    /// The page's depth at this entry; nil for a tab's own web root, where the
    /// page's stack is all the page's.
    var depth: Int?
    let isTabRoot: Bool
    /// The page has not reached `path` yet: retain its last rendered content
    /// until the replacement is ready.
    var awaitingPage = false
    /// A slow page keeps the last rendered content until its replacement is
    /// ready. This belongs to the incoming slot, beyond the push animation.
    private(set) var waitingPageSnapshot: UIView?

    /// A canceled tab swipe may leave this slot hidden after the page has
    /// already reported its destination. Reconcile that route before the
    /// WebView is adopted again, so the slot cannot stay transparent forever.
    @discardableResult
    func markArrivedIfNeeded(_ currentPath: String?) -> Bool {
        guard awaitingPage, let currentPath,
              CraftHybridRoutes.normalize(currentPath) == CraftHybridRoutes.normalize(path) else { return false }
        awaitingPage = false
        return true
    }

    func keepPageVisible(_ snapshot: UIView) {
        waitingPageSnapshot?.removeFromSuperview()
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.accessibilityElementsHidden = true
        view.addSubview(snapshot)
        waitingPageSnapshot = snapshot
    }

    func pageBecameVisible() {
        waitingPageSnapshot?.removeFromSuperview()
        waitingPageSnapshot = nil
    }

    init(path: String, depth: Int?, isTabRoot: Bool) {
        self.path = path
        self.depth = depth
        self.isTabRoot = isTabRoot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CraftHybrid.shared.config.resolvedBackgroundColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let controller = parent?.parent as? CraftHybridController {
            controller.prepareWebTransition(to: self)
            controller.adoptWeb(into: self)
        }
    }
}

/// A native stack lets the top screen consume Back for its presented modal
/// before UIKit removes the screen from the navigation stack.
final class CraftNativeNavigationController: UINavigationController {
    override func popViewController(animated: Bool) -> UIViewController? {
        if let screen = topViewController as? CraftNativeScreenController,
           screen.handleBackForModal() {
            return nil
        }
        return super.popViewController(animated: animated)
    }
}

final class CraftHybridController: UITabBarController, UITabBarControllerDelegate, UINavigationControllerDelegate, UIGestureRecognizerDelegate, CraftHybridScreenEvents {
    private let config: CraftConfig
    private let hybrid = CraftHybrid.shared
    /// The web view's host; nil in an all-native app, which never makes one.
    private let webHost: UIHostingController<AnyView>?
    /// Where the web view waits, behind the screens, while none of them is web.
    private let parking = UIView()
    private var stacks: [String: UINavigationController] = [:]
    private var currentTab = ""
    private var tabPlaceholders: [String: UIViewController] = [:]
    private var systemTabItems: [String: UITabBarItem] = [:]
    private var chromeSubscription: AnyCancellable?
    private var chromeUpdatePending = false
    private var synchronizingTabs = false
    private var accessoryModel: CraftChrome.Tab?
    private let accessoryButton = UIButton(type: .system)
    private let accessoryBadge = UILabel()
    private let accessoryGlass = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private static let tabPictures = NSCache<NSURL, UIImage>()
    private var requestedTabPictures = Set<URL>()
    /// The path each native entry opened at.
    private var nativePaths: [ObjectIdentifier: String] = [:]
    /// Each stack as it was after its last transition, to see what a pop removed.
    private var shownStacks: [ObjectIdentifier: [UIViewController]] = [:]
    /// A tab whose page has not caught up yet; shown when it has, or soon.
    private var pendingTab: (id: String, deadline: DispatchWorkItem)?
    /// The live WebView moves to the destination before UIKit animates a web
    /// push. Keep the outgoing page visible until that transition completes.
    private var webTransitionSnapshots: [UIView] = []
    private var openingWeb = false
    private var firstFrameLogged = false
    private var tabBarHeight: CGFloat = 0
    private var tabSwipeRecognizers: [UIGestureRecognizer] = []
    private var activeTabSwipeTarget: String?
    private var tabSwipeSettling = false
    private var tabSwipeGeneration: UInt = 0
    /// The edge the incoming tab started from for the current gesture. Keep
    /// this separate from the live frame: deriving it after the drag begins
    /// makes the target jump when the translation crosses the midpoint.
    private var tabSwipeFrom: CGFloat = 0
    /// A native screen waiting for its first content before it is pushed.
    private var pendingPush: String?
    /// Where the current screen already was when this gesture took over: a
    /// swipe that caught the last one while it settled starts from there.
    private var tabSwipeBase: CGFloat = 0
    /// A screen still partly on screen when this gesture caught a settling
    /// swipe and went the other way: it keeps its distance from the current
    /// screen (`tabSwipeTrailingGap`) until it has left.
    private var tabSwipeTrailing: UINavigationController?
    private var tabSwipeTrailingGap: CGFloat = 0
    /// The end of the settle under way, run at once when a swipe catches it.
    private var settleNow: (() -> Void)?
    private var settleCompleting = false
    /// A caught settle's screens, where they were, for the gesture that caught it.
    private var caughtSettle: (other: String, otherX: CGFloat, currentX: CGFloat)?

    init(config: CraftConfig) {
        self.config = config
        // Edge to edge, but not under the keyboard: the web view ends at its
        // top. Under it, WebKit scrolled the page's layout viewport to show a
        // focused field and carried every sticky header off the screen.
        webHost = CraftHybrid.shared.hasWeb
            ? UIHostingController(rootView: AnyView(CraftWebView(config: config).ignoresSafeArea(.container)))
            : nil
        super.init(nibName: nil, bundle: nil)
        hybrid.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        hybrid.controller = self
        delegate = self
        if #available(iOS 18.0, *) { mode = .tabBar }
#if compiler(>=6.2)
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
#endif
        accessoryButton.accessibilityIdentifier = "craft-tab-accessory"
        accessoryButton.addTarget(self, action: #selector(openTabAccessory), for: .touchUpInside)
        chromeSubscription = CraftChrome.shared.objectWillChange.sink { [weak self] in
            guard let self, !self.chromeUpdatePending else { return }
            self.chromeUpdatePending = true
            // Published sends before its value changes; coalesce the complete
            // chrome transaction before updating UIKit's retained tab items.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.chromeUpdatePending = false
                guard self.hybrid.controller === self else { return }
                self.synchronizeSystemTabs()
            }
        }
        view.backgroundColor = config.resolvedBackgroundColor
        parking.frame = view.bounds
        parking.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(parking, at: 0)

        // A native start screen draws first; the web view, whose creation
        // costs a frame or more, starts loading straight after it. An
        // all-native app has none.
        if hybrid.hasWeb && !hybrid.startsNative { attachWeb() }
        let tabs = hybrid.tabIds
        let start = CraftHybridRoutes.tab(owning: hybrid.startPath, among: tabs) ?? tabs.first ?? ""
        show(tab: start, rootPath: hybrid.startPath)
        installTabSwipeGestures()
        if hybrid.hasWeb && hybrid.startsNative {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attachWeb() }
        }
        // Links and opens that arrived before the shell, once the start
        // screen is up.
        DispatchQueue.main.async { [weak self] in self?.hybrid.shellReady() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prepareAdjacentNativeTabs()
    }

    /// UIKit owns the bar, selection indicator, badges and content safe area.
    /// Placeholders preserve lazy screen creation without inventing a second
    /// navigation stack when a tab is first selected or prepared for a swipe.
    private func synchronizeSystemTabs() {
        guard isViewLoaded, !synchronizingTabs else { return }
        synchronizingTabs = true
        defer { synchronizingTabs = false }
        let chrome = CraftChrome.shared
        let ids = hybrid.tabIds.isEmpty ? [currentTab] : hybrid.tabIds
        let controllers = ids.map { id -> UIViewController in
            let controller: UIViewController
            if let stack = stacks[id] { controller = stack }
            else if let placeholder = tabPlaceholders[id] { controller = placeholder }
            else {
                controller = UIViewController()
                tabPlaceholders[id] = controller
            }
            // An explicit retained item prevents UINavigationController from
            // adopting a newly loaded root screen's default tab item later.
            let item = systemTabItems[id] ?? UITabBarItem(title: nil, image: nil, tag: 0)
            systemTabItems[id] = item
            if controller.tabBarItem !== item { controller.tabBarItem = item }
            return controller
        }
        let existing = viewControllers ?? []
        if existing.count != controllers.count || zip(existing, controllers).contains(where: { $0 !== $1 }) {
            setViewControllers(controllers, animated: false)
            customizableViewControllers = []
        }
        // UIKit rebuilds item presentation when a lazy placeholder is replaced.
        // Apply accessibility metadata after installing the retained stacks so
        // the last prepared tab keeps the same identifier as every other tab.
        for (id, controller) in zip(ids, controllers) {
            guard let tab = chrome.tabs.first(where: { $0.id == id }) else { continue }
            let item = controller.tabBarItem!
            item.title = tab.displayTitle
            item.image = systemTabImage(tab, selected: false)
            item.selectedImage = systemTabImage(tab, selected: true)
            item.badgeValue = tab.badge
            item.accessibilityIdentifier = "craft-tab-\(tab.id)"
            item.accessibilityLabel = tab.accessibilityLabel ?? tab.displayTitle
        }
        if let committed = stacks[currentTab], controllers.contains(where: { $0 === committed }), selectedViewController !== committed {
            UIView.performWithoutAnimation {
                selectedViewController = committed
                view.layoutIfNeeded()
            }
        }
        tabBar.tintColor = chrome.tint ?? view.tintColor
        let hidden = !chrome.tabBarVisible || chrome.tabs.isEmpty
        if #available(iOS 18.0, *) { setTabBarHidden(hidden, animated: false) }
        else { tabBar.isHidden = hidden }
        updateSystemAccessory(hidden: hidden)
    }

    private func systemTabImage(_ tab: CraftChrome.Tab, selected: Bool) -> UIImage? {
        if let address = tab.image, let url = URL(string: address), url.scheme == "https" {
            if let image = Self.tabPictures.object(forKey: url as NSURL) { return image }
            if requestedTabPictures.insert(url).inserted {
                URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
                    guard let data, let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode), let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async { [weak self] in
                        let fitted = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
                            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 26, height: 26)).addClip()
                            let scale = max(26 / max(1, image.size.width), 26 / max(1, image.size.height))
                            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                            image.draw(in: CGRect(x: (26 - size.width) / 2, y: (26 - size.height) / 2, width: size.width, height: size.height))
                        }.withRenderingMode(.alwaysOriginal)
                        Self.tabPictures.countLimit = 16
                        Self.tabPictures.setObject(fitted, forKey: url as NSURL)
                        guard let self, self.hybrid.controller === self else { return }
                        self.synchronizeSystemTabs()
                    }
                }.resume()
            }
        } else if let text = tab.iconText {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.systemRed,
            ]
            let label = text as NSString
            let size = label.size(withAttributes: attributes)
            return UIGraphicsImageRenderer(size: CGSize(width: min(48, max(1, size.width)), height: 26)).image { _ in
                label.draw(in: CGRect(x: 0, y: (26 - size.height) / 2, width: 48, height: size.height), withAttributes: attributes)
            }.withRenderingMode(.alwaysOriginal)
        }
        let appearance = tab.iconAppearance(selected: selected, motionAllowed: false)
        let filled = selected && tab.selectedSymbol == nil && !appearance.symbol.hasSuffix(".fill")
            ? UIImage(systemName: appearance.symbol + ".fill") : nil
        let image = filled ?? UIImage(systemName: appearance.symbol)
        if let color = appearance.tint.flatMap({ UIColor(hex: $0) }) {
            return image?.withTintColor(color, renderingMode: .alwaysOriginal)
        }
        return image
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        let ids = hybrid.tabIds
        guard let index = viewControllers?.firstIndex(where: { $0 === viewController }), ids.indices.contains(index),
              let tab = CraftChrome.shared.tabs.first(where: { $0.id == ids[index] }) else { return false }
        // Craft may wait for the shared web page. Its committed stack decides
        // selection, including reselect-to-root and interruption of a swipe.
        CraftChrome.shared.tap(tab)
        return false
    }

    private func updateSystemAccessory(hidden: Bool) {
        let chrome = CraftChrome.shared
        let model = hidden ? nil : chrome.tabAccessory
        if let model {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: model.symbol)
            configuration.title = model.iconOnly ? nil : model.displayTitle
            configuration.subtitle = model.iconOnly ? nil : model.badge
            configuration.imagePadding = model.iconOnly ? 0 : 8
            accessoryButton.configuration = configuration
            accessoryButton.accessibilityLabel = model.accessibilityLabel ?? model.displayTitle
            accessoryButton.accessibilityValue = model.badge
            accessoryButton.accessibilityTraits = chrome.accessorySelected ? [.button, .selected] : [.button]
        }
#if compiler(>=6.2)
        if #available(iOS 26.0, *), model?.iconOnly != true {
            if accessoryGlass.superview != nil {
                accessoryGlass.removeFromSuperview()
                accessoryBadge.removeFromSuperview()
                accessoryButton.removeFromSuperview()
            }
            if (model == nil) != (bottomAccessory == nil) {
                bottomAccessory = model.map { _ in UITabAccessory(contentView: accessoryButton) }
            }
            accessoryModel = model
            for nav in stacks.values { nav.additionalSafeAreaInsets.bottom = 0 }
            return
        }
#endif
        // Older systems have no bottom-accessory container. Keep the action
        // available above the system bar, without recreating the tab control.
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            bottomAccessory = nil
            accessoryGlass.effect = UIGlassEffect()
        }
#endif
        if model != nil, accessoryButton.superview !== view {
            accessoryButton.removeFromSuperview()
            view.addSubview(accessoryGlass)
            view.addSubview(accessoryButton)
            view.addSubview(accessoryBadge)
        }
        accessoryButton.isHidden = model == nil
        accessoryGlass.isHidden = model == nil
        accessoryGlass.isUserInteractionEnabled = false
        accessoryGlass.layer.cornerRadius = 24
        accessoryGlass.clipsToBounds = true
        accessoryButton.backgroundColor = .clear
        accessoryButton.layer.cornerRadius = 24
        accessoryBadge.text = model?.badge
        accessoryBadge.isHidden = model?.badge == nil || model?.iconOnly != true
        accessoryBadge.font = .systemFont(ofSize: 11, weight: .bold)
        accessoryBadge.textColor = .white
        accessoryBadge.backgroundColor = .systemRed
        accessoryBadge.textAlignment = .center
        accessoryBadge.layer.cornerRadius = 9
        accessoryBadge.clipsToBounds = true
        accessoryBadge.isAccessibilityElement = false
        accessoryModel = model
        for nav in stacks.values { nav.additionalSafeAreaInsets.bottom = safeAreaForTabBar() }
        view.setNeedsLayout()
    }

    @objc private func openTabAccessory() {
        if let accessoryModel { hybrid.open(accessoryModel.id) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard hybrid.controller === self else { return }
#if compiler(>=6.2)
        if #available(iOS 26.0, *), accessoryModel?.iconOnly != true {
            // UIKit already supplies the native safe area. This measurement is
            // only the web CSS contract, not another native bottom inset.
            let top = bottomAccessory.map { $0.contentView.convert($0.contentView.bounds, to: view).minY } ?? tabBar.frame.minY
            CraftChrome.shared.layoutChanged(tabBar.isHidden ? 0 : max(0, view.bounds.maxY - top))
            return
        }
#endif
        let iconOnly = accessoryModel?.iconOnly == true
        let height: CGFloat = iconOnly ? 48 : 44
        let width: CGFloat = iconOnly ? 48 : max(0, view.bounds.width - 32)
        let x = iconOnly ? view.bounds.maxX - view.safeAreaInsets.right - width - 20 : 16
        accessoryButton.frame = CGRect(x: x, y: tabBar.frame.minY - height - (iconOnly ? 8 : 0), width: width, height: height)
        accessoryGlass.frame = accessoryButton.frame
        let badgeWidth = max(18, accessoryBadge.intrinsicContentSize.width + 8)
        accessoryBadge.frame = CGRect(x: accessoryButton.frame.maxX - badgeWidth + 4, y: accessoryButton.frame.minY - 3, width: badgeWidth, height: 18)
        CraftChrome.shared.layoutChanged(tabBar.isHidden ? 0 : max(0, view.bounds.maxY - tabBar.frame.minY) + (accessoryModel == nil ? 0 : (iconOnly ? 56 : 44)))
    }

    private var webAttached = false

    private func installTabSwipeGestures() {
        guard tabSwipeRecognizers.isEmpty else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(tabSwipeRecognized(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        view.addGestureRecognizer(recognizer)
        tabSwipeRecognizers.append(recognizer)
    }

    private func shouldCompleteTabSwipe(progress: CGFloat, speed: CGFloat) -> Bool {
        speed > -700 && (progress >= max(32, view.bounds.width * 0.28) || speed > 700)
    }

    @objc private func tabSwipeRecognized(_ recognizer: UIPanGestureRecognizer) {
        // A finger that lands while the last swipe settles takes the screens
        // from where they are, as a paging scroll view does. This swipe used
        // to be ignored until the settle ended.
        if recognizer.state == .began, tabSwipeSettling { catchSettlingSwipe() }
        guard !tabSwipeSettling else { return }
        let tabs = hybrid.tabIds
        guard let index = tabs.firstIndex(of: currentTab), tabs.count > 1 else { return }
        let translation = recognizer.translation(in: view).x
        let velocity = recognizer.velocity(in: view).x
        switch recognizer.state {
        case .began, .changed:
            // Catching a settle can begin at zero translation. Keep its
            // committed selection until the new finger actually moves.
            if recognizer.state == .began, caughtSettle != nil, abs(translation) <= 1 { return }
            if activeTabSwipeTarget == nil {
                let direction = abs(translation) > 1 ? translation : velocity
                guard abs(direction) > 1 else { return }
                let next = direction < 0 ? index + 1 : index - 1
                guard tabs.indices.contains(next), beginInteractiveTabSwipe(to: tabs[next], direction: direction < 0 ? -1 : 1) else { return }
                activeTabSwipeTarget = tabs[next]
            }
            updateInteractiveTabSwipe(translation: translation)
        case .ended, .cancelled, .failed:
            guard let target = activeTabSwipeTarget else {
                // Caught and let go without a direction (or toward the edge):
                // the caught screens finish where they were going.
                if caughtSettle != nil { settleCaughtScreens(); return }
                guard recognizer.state == .ended else { return }
                // UIKit can coalesce a short gesture without a changed
                // callback. Keep the same completion rule as the animated
                // path instead of treating any 32-point drag as a full page.
                let direction = abs(translation) > 1 ? translation : velocity
                guard abs(direction) > 1 else { return }
                let sign: CGFloat = direction < 0 ? -1 : 1
                guard shouldCompleteTabSwipe(progress: translation * sign, speed: velocity * sign) else { return }
                let next = direction < 0 ? index + 1 : index - 1
                guard tabs.indices.contains(next) else { return }
                CraftChrome.shared.swipe(to: tabs[next])
                return
            }
            // Keep the target until the settling animation has read it and
            // finished. Clearing it here made finishInteractiveTabSwipe return
            // early, leaving cancelled screens offset and completed swipes
            // jumping straight to their destination.
            tabSwipeSettling = true
            let direction: CGFloat = tabSwipeFrom > 0 ? -1 : 1
            let progress = (translation + tabSwipeBase) * direction
            let speed = velocity * direction
            let complete = recognizer.state == .ended && shouldCompleteTabSwipe(progress: progress, speed: speed)
            finishInteractiveTabSwipe(completed: complete, velocity: velocity) { [weak self] in
                CraftFramePacing.shared.end("tab swipe")
                self?.activeTabSwipeTarget = nil
                self?.tabSwipeSettling = false
                self?.prepareAdjacentNativeTabs()
                guard complete else {
                    CraftChrome.shared.cancelTabSwipe()
                    return
                }
                CraftChrome.shared.commitTabSwipe(to: target)
                self?.view.layoutIfNeeded()
            }
        default:
            break
        }
    }

    /// Prepare a mounted target beside the current stack. Native roots render
    /// immediately; a web root borrows the shared WebView and stays
    /// transparent until its page route catches up. Two web roots still use
    /// the route-aware fallback because one WebView cannot render both pages.
    private func beginInteractiveTabSwipe(to id: String, direction: CGFloat) -> Bool {
        guard let current = visibleStack, view.bounds.width > 0 else { return false }
        let target: UINavigationController
        if let mounted = stacks[id] {
            target = mounted
        } else {
            // A native tab must also follow the first swipe to it. Do not
            // create a second web root here: the shared WebView cannot draw
            // both pages during the same gesture.
            guard hybrid.routes.match(id) != nil else { return false }
            target = CraftFramePacing.shared.measure("tab swipe mount \(id)") { makeStack(tab: id, rootPath: id, hidden: true) }
        }
        guard current.view !== target.view,
              !(current.topViewController is CraftHybridWebSlot && target.topViewController is CraftHybridWebSlot),
              view.bounds.width > 0 else { return false }
        if let slot = target.topViewController as? CraftHybridWebSlot {
            // There is one shared WebView, so a web-to-web gesture cannot
            // render two pages at once. A native-to-web gesture can: move the
            // WebView into the hidden target slot and let its route catch up
            // while the slot follows the finger. It stays transparent until
            // the page reports that it reached the target path.
            slot.awaitingPage = true
            adoptWeb(into: slot, allowHiddenStack: true)
            webHost?.view.alpha = 0
            hybrid.navigatePage(slot.path) { [weak self, weak slot] depth in
                guard let self, let slot else { return }
                slot.depth = depth
                guard self.activeTabSwipeTarget == id,
                      CraftHybridRoutes.normalize(self.hybrid.pagePath ?? "") == CraftHybridRoutes.normalize(slot.path) else { return }
                self.reveal(slot)
            }
        }
        if let container = current.view.superview, target.view.superview !== container {
            container.addSubview(target.view)
        }
        target.view.isHidden = false
        let width = view.bounds.width
        tabSwipeFrom = -direction * width
        // Caught from a settle: the current screen is still where the last
        // swipe left it, and the other screen it showed either is this
        // target (the finger went back to it) or trails behind.
        tabSwipeBase = 0
        tabSwipeTrailing = nil
        if let caught = caughtSettle {
            caughtSettle = nil
            tabSwipeBase = caught.currentX
            if caught.other != id, let other = stacks[caught.other] {
                tabSwipeTrailing = other
                tabSwipeTrailingGap = caught.otherX - caught.currentX
            }
        }
        target.view.frame = view.bounds.offsetBy(dx: tabSwipeFrom + tabSwipeBase, dy: 0)
        target.view.superview?.bringSubviewToFront(target.view)
        CraftChrome.shared.beginTabSwipe(to: id, from: currentTab)
        lastNavigation = CACurrentMediaTime()
        CraftFramePacing.shared.begin("tab swipe")
        return true
    }

    private func updateInteractiveTabSwipe(translation: CGFloat) {
        guard let targetId = activeTabSwipeTarget, let current = visibleStack,
              let target = stacks[targetId] else { return }
        let width = max(1, view.bounds.width)
        // Reversing past the start stays at zero progress, rather than
        // pulling both screens away and exposing the background; past where
        // a caught swipe left the screens, when it left them further out.
        let raw = translation + tabSwipeBase
        let offset = tabSwipeFrom > 0
            ? min(max(0, tabSwipeBase), max(-width, raw))
            : max(min(0, tabSwipeBase), min(width, raw))
        target.view.frame.origin.x = tabSwipeFrom + offset
        current.view.frame.origin.x = offset
        tabSwipeTrailing?.view.frame.origin.x = offset + tabSwipeTrailingGap
        CraftChrome.shared.updateTabSwipe(progress: max(0, tabSwipeFrom > 0 ? -offset : offset) / width)
    }

    private func finishInteractiveTabSwipe(completed: Bool, velocity: CGFloat, completion: @escaping () -> Void) {
        guard let targetId = activeTabSwipeTarget, let current = visibleStack,
              let target = stacks[targetId] else { completion(); return }
        let width = view.bounds.width
        let direction: CGFloat = tabSwipeFrom > 0 ? 1 : -1
        let end = completed ? 0 : direction * width
        let settlingDuration = completed ? 0.22 : 0.18
        let duration = CraftChrome.motion(.easeOut(duration: settlingDuration)) == nil ? 0 : settlingDuration
        let generation = tabSwipeGeneration
        CraftChrome.shared.settleTabSwipe(completed: completed, duration: duration)
        let remaining = end - target.view.frame.minX
        let initialVelocity = abs(remaining) > 1 ? max(0, min(12, velocity / remaining)) : 0
        let trailing = tabSwipeTrailing
        let gap = tabSwipeTrailingGap
        let move = {
            target.view.frame.origin.x = end
            current.view.frame.origin.x = completed ? -direction * width : 0
            trailing?.view.frame.origin.x = current.view.frame.origin.x + gap
        }
        let finish = {
            if let trailing {
                trailing.view.isHidden = true
                trailing.view.frame = self.view.bounds
            }
            self.tabSwipeTrailing = nil
            self.tabSwipeBase = 0
            if completed {
                current.view.isHidden = true
                current.view.frame = self.view.bounds
                target.view.frame = self.view.bounds
            } else {
                target.view.isHidden = true
                target.view.frame = self.view.bounds
                current.view.frame = self.view.bounds
                (current.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)
                if target.topViewController is CraftHybridWebSlot,
                   current.topViewController is CraftNativeScreenController {
                    self.parkWeb()
                }
            }
            completion()
        }
        settleNow = finish
        settleCompleting = completed
        let settled: (Bool) -> Void = { _ in
            guard self.tabSwipeGeneration == generation,
                  self.activeTabSwipeTarget == targetId else { return }
            self.settleNow = nil
            finish()
        }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: initialVelocity,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: move, completion: settled)
    }

    /// A finger landed while the last swipe settled. Its end happens now,
    /// commit or cancel, chrome and events included, and the two screens go
    /// back exactly where they were on screen (no frame is drawn between),
    /// for this gesture to carry on from.
    private func catchSettlingSwipe() {
        guard let finish = settleNow, let targetId = activeTabSwipeTarget,
              let current = visibleStack, let target = stacks[targetId] else { return }
        let outgoing = currentTab
        let currentX = current.view.layer.presentation()?.frame.minX ?? current.view.frame.minX
        let targetX = target.view.layer.presentation()?.frame.minX ?? target.view.frame.minX
        tabSwipeGeneration &+= 1
        for nav in [current, target] + (tabSwipeTrailing.map { [$0] } ?? []) { nav.view.layer.removeAllAnimations() }
        settleNow = nil
        let completing = settleCompleting
        CraftFramePacing.shared.end("tab swipe")
        finish()
        // The two pages are exactly one viewport apart. UIKit can reparent
        // the outgoing layer when selection commits; its presentation frame
        // then uses the new container's coordinates, not the old swipe's.
        let (stay, stayX, other, otherId, otherX) = completing
            ? (target, targetX, current, outgoing, targetX - tabSwipeFrom)
            : (current, currentX, target, targetId, currentX + tabSwipeFrom)
        guard abs(stayX) > 0.5 else { return }
        // Selection removes UIKit's outgoing view. A caught interactive swipe
        // needs it beside the new selected view again, in the same container.
        if let container = stay.view.superview, other.view.superview !== container {
            container.addSubview(other.view)
        }
        stay.view.frame = view.bounds.offsetBy(dx: stayX, dy: 0)
        other.view.isHidden = false
        other.view.frame = view.bounds.offsetBy(dx: otherX, dy: 0)
        caughtSettle = (otherId, otherX, stayX)
    }

    /// A caught settle that no new swipe took on: its screens finish where
    /// they were going.
    private func settleCaughtScreens(animated: Bool = true) {
        guard let caught = caughtSettle else { return }
        caughtSettle = nil
        guard let current = visibleStack else { return }
        let other = stacks[caught.other]
        let gap = caught.otherX - caught.currentX
        let generation = tabSwipeGeneration
        let done = {
            guard self.tabSwipeGeneration == generation else { return }
            current.view.frame = self.view.bounds
            other?.view.frame = self.view.bounds
            if other !== current { other?.view.isHidden = true }
        }
        guard animated, CraftChrome.motion(.easeOut(duration: 0.18)) != nil else { done(); return }
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            current.view.frame.origin.x = 0
            other?.view.frame.origin.x = gap
        }, completion: { _ in done() })
    }

    /// A newer navigation action wins immediately, including a tap back on
    /// the outgoing tab. Invalidate the old animation before removing it:
    /// UIKit may deliver its completion while the replacement is starting.
    private func interruptTabSwipe(restoringSelection: Bool) {
        if caughtSettle != nil { settleCaughtScreens(animated: false) }
        if let trailing = tabSwipeTrailing {
            trailing.view.layer.removeAllAnimations()
            trailing.view.frame = view.bounds
            trailing.view.isHidden = trailing !== visibleStack
            tabSwipeTrailing = nil
        }
        tabSwipeBase = 0
        settleNow = nil
        guard let targetId = activeTabSwipeTarget else { return }
        tabSwipeGeneration &+= 1
        activeTabSwipeTarget = nil
        tabSwipeSettling = false
        for nav in [visibleStack, stacks[targetId]].compactMap({ $0 }) {
            nav.view.layer.removeAllAnimations()
            nav.view.frame = view.bounds
            nav.view.isHidden = nav !== visibleStack
        }
        // Cancel the current touch stream, so its later moved/ended events
        // cannot claim another tab after the explicit navigation.
        for recognizer in tabSwipeRecognizers {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        CraftChrome.shared.cancelTabSwipe(restoringSelection: restoringSelection)
        (visibleStack?.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)
        if visibleStack?.topViewController is CraftNativeScreenController { parkWeb() }
    }

    private func horizontalScrollAt(_ point: CGPoint, in root: UIView) -> Bool {
        let local = root.convert(point, from: view)
        guard root.bounds.contains(local), let hit = root.hitTest(local, with: nil) else { return false }
        // WKWebView keeps its scrolling UIScrollView below the hosting view
        // that owns the native slot, so it is not necessarily on the hit
        // view's superview chain. Treat an overflowing page as its own
        // horizontal gesture surface before the shell claims the swipe.
        if let webView = CraftChrome.shared.webView,
           hit === webView || hit.isDescendant(of: webView) || webView.isDescendant(of: hit) {
            let scroll = webView.scrollView
            if scroll.isScrollEnabled,
               scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 {
                return true
            }
        }
        var candidate: UIView? = hit
        while let current = candidate {
            if let scroll = current as? UIScrollView,
               scroll.isScrollEnabled,
               scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    /// The web view joins the screen, behind the native screens, and loads.
    private func attachWeb() {
        guard let webHost, !webAttached else { return }
        webAttached = true
        webHost.view.backgroundColor = config.resolvedBackgroundColor
        if #available(iOS 16.4, *) { webHost.safeAreaRegions = [.keyboard] }
        if let slot = visibleStack?.topViewController as? CraftHybridWebSlot, slot.isViewLoaded {
            moveWeb(to: slot, in: slot.view)
        } else {
            moveWeb(to: self, in: parking)
        }
    }

    /// The web view's controller is the child of whichever controller shows
    /// it: UIKit refuses a child's view in another controller's hierarchy.
    private func moveWeb(to owner: UIViewController, in container: UIView) {
        guard let webHost else { return }
        if webHost.parent !== owner {
            if webHost.parent != nil {
                webHost.willMove(toParent: nil)
                webHost.view.removeFromSuperview()
                webHost.removeFromParent()
            }
            owner.addChild(webHost)
            place(webHost.view, in: container)
            webHost.didMove(toParent: owner)
        } else if webHost.view.superview !== container {
            place(webHost.view, in: container)
        }
    }

    private func place(_ child: UIView, in container: UIView) {
        child.removeFromSuperview()
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// UIKit calls the destination's viewWillAppear before it starts a push.
    /// Since the hybrid shell has one WebView shared by all web entries, moving
    /// it at that point would leave the outgoing slot blank for the whole
    /// transition. A snapshot gives that slot the page it was showing while
    /// the live WebView is adopted by the destination.
    func prepareWebTransition(to slot: CraftHybridWebSlot) {
        guard let nav = slot.navigationController,
              nav === visibleStack,
              let from = nav.transitionCoordinator?.viewController(forKey: .from),
              let source = from as? CraftHybridWebSlot,
              source !== slot,
              let webHost,
              webHost.view.superview === source.view,
              let snapshot = webHost.view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = source.view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        source.view.addSubview(snapshot)
        webTransitionSnapshots.append(snapshot)
        if slot.awaitingPage,
           let waiting = webHost.view.snapshotView(afterScreenUpdates: false) {
            slot.keepPageVisible(waiting)
        }
    }

    private var visibleStack: UINavigationController? { stacks[currentTab] }

    /// A swipe preview can be visible without owning navigation or focus.
    /// UIKit appearance callbacks must follow the committed native stack.
    func isFocusedScreen(_ screen: CraftNativeScreenController) -> Bool {
        visibleStack?.topViewController === screen
    }

    var webIsVisible: Bool {
        guard let webHost, let slot = visibleStack?.topViewController as? CraftHybridWebSlot else { return false }
        return webHost.view.superview === slot.view
    }

    // MARK: Stacks

    /// `hidden`: a stack prepared off screen. It is hidden before it joins
    /// the view hierarchy, so its screen never takes the shell's chrome (the
    /// bar, the tab accessory) from the one on screen.
    private func makeStack(tab: String, rootPath: String, hidden: Bool = false) -> UINavigationController {
        let root = entry(for: rootPath, isTabRoot: true, depth: nil)
        // Constructing the navigation controller can load the root's view and
        // mount its script immediately. Set its initial focus before that.
        if hidden { (root as? CraftNativeScreenController)?.screenVisibilityChanged(false) }
        let nav = CraftNativeNavigationController(rootViewController: root)
        nav.delegate = self
        nav.view.backgroundColor = config.resolvedBackgroundColor
        nav.additionalSafeAreaInsets.bottom = safeAreaForTabBar()
        nav.setNavigationBarHidden(true, animated: false)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nav.view.isHidden = hidden
        // Only once the stack's view has loaded: the recognizer is made then,
        // and before it is nil, so the delegate never took.
        for recognizer in popRecognizers(of: nav) { recognizer.delegate = self }
        stacks[tab] = nav
        shownStacks[ObjectIdentifier(nav)] = nav.viewControllers
        synchronizeSystemTabs()
        if hidden, nav.view.superview == nil, let container = visibleStack?.view.superview {
            container.addSubview(nav.view)
        }
        return nav
    }

    /// A native screen's route params for `path`: the pattern's and the
    /// query's, and the path itself.
    private func params(for path: String, _ match: CraftHybridRoutes.Match) -> [String: Any] {
        var params: [String: Any] = match.params
        params["path"] = path
        return params
    }

    /// The entry for a path: its native screen, or a web entry.
    private func entry(for path: String, isTabRoot: Bool, depth: Int?, props: [String: Any] = [:]) -> UIViewController {
        if hybrid.isEnabled, let match = hybrid.routes.match(path) {
            let params = self.params(for: path, match)
            let screen = CraftNativeScreenController(config: config, routeName: match.screen, routeParams: params, routeProps: props)
            screen.hybridEvents = self
            nativePaths[ObjectIdentifier(screen)] = match.path
            return screen
        }
        guard hybrid.hasWeb else {
            // The config checks rule this out (every tab and the start path
            // are native screens); an empty screen rather than a web entry
            // nothing would ever fill.
            NSLog("[craft hybrid] no native screen draws %@, and the app has no web view", path)
            let empty = UIViewController()
            empty.view.backgroundColor = config.resolvedBackgroundColor
            return empty
        }
        return CraftHybridWebSlot(path: path, depth: depth, isTabRoot: isTabRoot)
    }

    private func show(tab id: String, rootPath: String? = nil) {
        lastNavigation = CACurrentMediaTime()
        interruptTabSwipe(restoringSelection: false)
        cancelPendingTab()
        let pacing = CraftFramePacing.shared
        if pacing.enabled, id != currentTab, !currentTab.isEmpty {
            pacing.begin("tab \(id)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pacing.end("tab \(id)") }
        }
        let nav = stacks[id] ?? pacing.measure("tab \(id) mount") { makeStack(tab: id, rootPath: rootPath ?? (id.isEmpty ? hybrid.startPath : id)) }
        // A stack is hidden and shown rather than moved, so UIKit tells its
        // screens nothing: the shell says which went away and which is back.
        if id != currentTab {
            (visibleStack?.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(false)
            (nav.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)
        }
        currentTab = id
        synchronizeSystemTabs()
        if let top = nav.topViewController { CraftChrome.shared.visiblePath = nativePaths[ObjectIdentifier(top)] }
        for (key, other) in stacks { other.view.isHidden = key != id }
        nav.view.frame = view.bounds
        nav.view.superview?.bringSubviewToFront(nav.view)
        prepareAdjacentNativeTabs()
        if let slot = nav.topViewController as? CraftHybridWebSlot, slot.isViewLoaded {
            adoptWeb(into: slot)
        } else if !(nav.topViewController is CraftHybridWebSlot) {
            parkWeb()
        }
    }

    /// Prepare the other tabs' first screens after the first frame, nearest
    /// first, one per idle moment and never inside the finger's tracking
    /// run-loop mode. A swipe or a tap then lands on a laid-out native root
    /// rather than compiling, measuring and fetching while it animates. Only
    /// the neighbours used to be prepared, so arriving on a tab mounted the
    /// next one 150ms later, which was just when the next swipe began.
    ///
    /// Idle means idle: not while a push, a pop or a tab swipe animates, and
    /// not right after one (a link opened at launch must not wait behind
    /// tabs nobody asked for). The neighbours come first and soon; the tabs
    /// further away only once the screen has been still for a while.
    private func prepareAdjacentNativeTabs() {
        let owner = currentTab
        guard let index = hybrid.tabIds.firstIndex(of: owner) else { return }
        let tabs = hybrid.tabIds
        let waiting = tabs.indices.filter { $0 != index && stacks[tabs[$0]] == nil && hybrid.routes.match(tabs[$0]) != nil }
            .sorted { abs($0 - index) < abs($1 - index) || (abs($0 - index) == abs($1 - index) && $0 > $1) }
        // One preparation pending at a time, for the tab on screen now.
        preparation?.invalidate()
        preparation = nil
        guard let next = waiting.first else { return }
        let neighbour = abs(next - index) == 1
        let timer = Timer(timeInterval: neighbour ? 0.15 : 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.preparation = nil
            guard self.currentTab == owner, self.view.window != nil else { return }
            let quietFor = neighbour ? 0.3 : 1.0
            guard self.activeTabSwipeTarget == nil, !self.tabSwipeSettling,
                  !self.stacks.values.contains(where: { $0.transitionCoordinator != nil }),
                  CACurrentMediaTime() - self.lastNavigation >= quietFor else {
                self.prepareAdjacentNativeTabs()
                return
            }
            let id = tabs[next]
            guard self.stacks[id] == nil else { self.prepareAdjacentNativeTabs(); return }
            let nav = CraftFramePacing.shared.measure("prepare \(id)") { () -> UINavigationController in
                let nav = self.makeStack(tab: id, rootPath: id, hidden: true)
                nav.view.layoutIfNeeded()
                // Draw its text and pictures now. A hidden layer is not
                // drawn at commit, so the first swipe to this tab drew
                // every label of the screen in the gesture's first frame.
                Self.drawContents(of: nav.view.layer)
                return nav
            }
            (nav.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(false)
            (self.visibleStack?.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)
            // A script on its own thread draws a moment later: its first
            // content is drawn ahead too, once it is there.
            if CraftNativeScriptThread.isBackground, let screen = nav.topViewController as? CraftNativeScreenController {
                screen.whenFirstRendered(within: 1) { [weak nav] in
                    guard let nav, nav.view.isHidden else { return }
                    nav.view.layoutIfNeeded()
                    Self.drawContents(of: nav.view.layer)
                }
            }
            self.prepareAdjacentNativeTabs()
        }
        preparation = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private var preparation: Timer?

    /// A native tab tapped before the shell prepared it (HQ's Me, prepared
    /// last, tapped right after launch) mounts its screen hidden first. Mounted
    /// in the tap's own turn after the selection began, it held the main
    /// thread while SwiftUI's spring should have moved the pill, which then
    /// stalled and jumped in from the side.
    func mountTabBeforeSelecting(_ id: String) {
        guard stacks[id] == nil, id != currentTab, activeTabSwipeTarget == nil,
              hybrid.tabIds.contains(id), hybrid.routes.match(id) != nil, view.window != nil else { return }
        let nav = makeStack(tab: id, rootPath: id, hidden: true)
        nav.view.layoutIfNeeded()
        Self.drawContents(of: nav.view.layer)
        (visibleStack?.topViewController as? CraftNativeScreenController)?.screenVisibilityChanged(true)
    }

    /// When the shell last moved between screens: a tab, a push or a pop.
    private var lastNavigation: CFTimeInterval = 0

    private static func drawContents(of layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(drawContents(of:))
    }

    private func cancelPendingTab() {
        pendingTab?.deadline.cancel()
        pendingTab = nil
    }

    func adoptWeb(into slot: CraftHybridWebSlot, allowHiddenStack: Bool = false) {
        guard let webHost,
              allowHiddenStack || slot.navigationController === visibleStack || visibleStack == nil else { return }
        slot.markArrivedIfNeeded(hybrid.pagePath)
        attachWeb()
        moveWeb(to: slot, in: slot.view)
        webHost.view.alpha = slot.awaitingPage ? 0 : 1
        if !slot.awaitingPage { slot.pageBecameVisible() }
        hybrid.setPageBase(slot.isTabRoot ? nil : slot.depth)
    }

    private func parkWeb() {
        guard webAttached, let webHost else { return }
        webHost.view.alpha = 1
        moveWeb(to: self, in: parking)
    }

    // MARK: Opening paths

    /// `craft.navigation.open(path)` or `craft.hybrid.open(path)`: a tab, a
    /// native screen, or the web view pushed over the screen that asked. In
    /// an app with no web view, a path no screen draws opens in the in-app
    /// browser on the app's site. A web address on the app's site is its
    /// path; one anywhere else opens in the in-app browser.
    func open(_ raw: String, props: [String: Any] = [:]) {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard CraftHybridRoutes.isSite(url, site: hybrid.siteURL) else {
                hybrid.openOutside(raw)
                return
            }
            open(CraftHybridRoutes.appPath(of: url), props: props)
            return
        }
        guard let path = CraftHybridRoutes.normalize(raw) else { return }
        if let tab = hybrid.tabIds.first(where: { CraftHybridRoutes.normalize($0) == path }) {
            if hybrid.routes.match(raw) != nil, URLComponents(string: raw)?.query != nil || !props.isEmpty {
                // A checkout/auth return targets the retained tab with new
                // parameters. Selecting alone would discard that handoff.
                showNative(path: raw, replace: false, props: props)
            } else {
                selectTabAsIfTapped(tab)
            }
            return
        }
        if hybrid.routes.match(raw) != nil {
            showNative(path: raw, replace: false, props: props)
            return
        }
        if hybrid.hasWeb {
            pushWeb(raw)
        } else {
            hybrid.openOutside(raw)
        }
    }

    private func selectTabAsIfTapped(_ id: String) {
        if let tab = CraftChrome.shared.tabs.first(where: { $0.id == id }) {
            CraftChrome.shared.tap(tab)
        } else {
            _ = tabTapped(id, reselect: id == currentTab)
        }
    }

    /// The native screen for `raw`: the one already in the stack (popping to
    /// it), a tab's root, or a new one pushed.
    func showNative(path raw: String, replace: Bool, fromLink: Bool = false, props: [String: Any] = [:]) {
        guard let match = hybrid.routes.match(raw) else { return }
        interruptTabSwipe(restoringSelection: true)
        let tabs = hybrid.tabIds
        if let tab = tabs.first(where: { CraftHybridRoutes.normalize($0) == match.path }) {
            // Finish the flow in its original tab before selecting another.
            if replace, let current = visibleStack, current.viewControllers.count > 1 {
                current.setViewControllers(Array(current.viewControllers.dropLast()), animated: false)
            }
            if tab != currentTab {
                selectTabAsIfTapped(tab)
            }
            if let nav = stacks[tab], nav.viewControllers.count > 1 {
                nav.popToRootViewController(animated: !fromLink)
            }
            // `/m/store?coach=5`: the tab's own screen, with the query.
            (stacks[tab]?.viewControllers.first as? CraftNativeScreenController)?.receiveRouteParams(params(for: raw, match), props: props)
            return
        }
        if fromLink, let owner = CraftHybridRoutes.tab(owning: match.path, among: tabs), owner != currentTab {
            selectTabAsIfTapped(owner)
        }
        guard let nav = visibleStack ?? stacks.values.first else { return }
        if let existing = nav.viewControllers.last(where: { nativePaths[ObjectIdentifier($0)] == match.path }) {
            if existing !== nav.topViewController { nav.popToViewController(existing, animated: true) }
            // Opened again, perhaps with another query (`?person=8`): the
            // screen hears the params it was opened with this time.
            (existing as? CraftNativeScreenController)?.receiveRouteParams(params(for: raw, match), props: props)
            return
        }
        let screen = entry(for: raw, isTabRoot: false, depth: nil, props: props)
        let show = { [weak nav] in
            guard let nav else { return }
            if replace, !nav.viewControllers.isEmpty {
                nav.setViewControllers(Array(nav.viewControllers.dropLast()) + [screen], animated: true)
            } else {
                nav.pushViewController(screen, animated: true)
            }
        }
        guard let native = screen as? CraftNativeScreenController, CraftNativeScriptThread.isBackground else { show(); return }
        // Its script runs on its own thread: it slides in with its content,
        // and a second tap meanwhile does not push it twice.
        guard pendingPush != match.path else { return }
        pendingPush = match.path
        native.whenFirstRendered(within: 0.3) { [weak self, weak nav] in
            guard let self, self.pendingPush == match.path else { return }
            self.pendingPush = nil
            // Not into a tab the person has left meanwhile.
            guard let nav, nav === self.visibleStack else { return }
            show()
        }
    }

    /// The web view, pushed: the page goes to `path` first, without its own
    /// slide, then the entry slides in over the screen that opened it.
    private func pushWeb(_ path: String) {
        guard hybrid.hasWeb, !openingWeb, let nav = visibleStack else { return }
        interruptTabSwipe(restoringSelection: true)
        openingWeb = true
        hybrid.navigatePage(path) { [weak self, weak nav] depth in
            guard let self else { return }
            self.openingWeb = false
            guard let nav else { return }
            let slot = CraftHybridWebSlot(path: path, depth: depth, isTabRoot: false)
            // Slow to answer: slide in the entry, and the page once it is there.
            if depth == nil {
                slot.awaitingPage = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak slot] in
                    guard let slot, slot.awaitingPage else { return }
                    self?.reveal(slot)
                }
            }
            nav.pushViewController(slot, animated: true)
        }
    }

    private func reveal(_ slot: CraftHybridWebSlot) {
        slot.awaitingPage = false
        guard let webHost, webHost.view.superview === slot.view else { return }
        // Commit the ready page and remove its placeholder in the same frame.
        // Fading it up from zero exposed the slot's empty background again.
        webHost.view.alpha = 1
        slot.pageBecameVisible()
    }

    /// Back from the web entry on top, as the page's Back at that entry asks.
    func popTop() {
        guard let nav = visibleStack, nav.viewControllers.count > 1, nav.topViewController is CraftHybridWebSlot else { return }
        nav.popViewController(animated: true)
    }

    // MARK: The page moved

    func pageNavigated(path: String, direction: String, depth: Int, byHost: Bool) {
        let owner = CraftHybridRoutes.tab(owning: path, among: hybrid.tabIds)
        if let targetId = activeTabSwipeTarget,
           let target = stacks[targetId]?.topViewController as? CraftHybridWebSlot,
           owner == targetId || CraftHybridRoutes.normalize(path) == CraftHybridRoutes.normalize(target.path) {
            target.depth = depth
            target.awaitingPage = false
            reveal(target)
        }
        if let pending = pendingTab, owner == pending.id || direction == "tab" {
            show(tab: pending.id)
        }
        if let slot = visibleStack?.topViewController as? CraftHybridWebSlot {
            if !slot.isTabRoot, slot.depth == nil { slot.depth = depth }
            if slot.awaitingPage, CraftHybridRoutes.normalize(path) == CraftHybridRoutes.normalize(slot.path) { reveal(slot) }
            if webIsVisible { hybrid.setPageBase(slot.isTabRoot ? nil : slot.depth) }
        }
        guard !byHost, direction != "tab", !openingWeb, let nav = visibleStack else { return }
        let top = nav.topViewController
        if let match = hybrid.routes.match(path) {
            // The page went to a native path the shell did not catch first:
            // a full load, or Back past the entry a native screen opened.
            guard top is CraftHybridWebSlot else { return }
            if let existing = nav.viewControllers.last(where: { nativePaths[ObjectIdentifier($0)] == match.path }) {
                nav.popToViewController(existing, animated: direction != "pop")
                (existing as? CraftNativeScreenController)?.receiveRouteParams(params(for: path, match))
            } else if !((top as? CraftHybridWebSlot)?.isTabRoot ?? false) {
                nav.pushViewController(entry(for: path, isTabRoot: false, depth: nil), animated: true)
            }
            return
        }
        // The page went somewhere of its own accord (a sign-in redirect, a
        // notification, a link it handled) while a native screen shows.
        if top is CraftNativeScreenController {
            log("the page went to \(path) by itself; showing it")
            nav.pushViewController(CraftHybridWebSlot(path: path, depth: depth, isTabRoot: false), animated: direction != "load" || firstFrameLogged)
        }
    }

    // MARK: Tabs

    func tabTapped(_ id: String, reselect: Bool) -> Bool {
        let interruptedSwipe = activeTabSwipeTarget != nil
        interruptTabSwipe(restoringSelection: false)
        // The incoming tab is only a preview until the swipe commits, so a
        // tap on its already-lit indicator is a selection, not a reselect.
        if (reselect && !interruptedSwipe) || id == currentTab {
            guard let nav = stacks[id] else { return true }
            if nav.viewControllers.count > 1 {
                nav.popToRootViewController(animated: true)
                return false
            }
            // The root again: a web root is the page's to handle (to its top,
            // then its own first screen).
            return nav.topViewController is CraftHybridWebSlot
        }
        // No page to wait for: the tab's own stack, now.
        guard hybrid.hasWeb else {
            show(tab: id)
            return true
        }
        let target = stacks[id]
        let rootIsWeb = target.map { $0.topViewController is CraftHybridWebSlot } ?? (hybrid.routes.match(id) == nil)
        let pageThere = hybrid.pagePath.flatMap { CraftHybridRoutes.tab(owning: $0, among: hybrid.tabIds) } == id
        if rootIsWeb && !pageThere {
            // Keep this screen up until the page has switched, rather than
            // showing it half way.
            cancelPendingTab()
            if stacks[id] == nil { _ = makeStack(tab: id, rootPath: id, hidden: true); view.bringSubviewToFront(visibleStack?.view ?? view) }
            let deadline = DispatchWorkItem { [weak self] in self?.show(tab: id) }
            pendingTab = (id, deadline)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: deadline)
        } else {
            show(tab: id)
        }
        return true
    }

    /// The page's own idea of its tab counts only while the page is a
    /// tab's root: over a native screen, or on an entry the shell pushed
    /// there, the page cannot know which tab it is in (a workout page
    /// loaded on its own lights Calendar, though Today opened it). The bar
    /// then keeps the tab that is on screen, or the finger's active preview.
    func pageSelectedTab(_ id: String) {
        guard id != (activeTabSwipeTarget ?? currentTab), pendingTab?.id != id else { return }
        guard activeTabSwipeTarget == nil,
              let top = visibleStack?.topViewController as? CraftHybridWebSlot, top.isTabRoot else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hybrid.controller === self else { return }
                // Resolve ownership when the correction runs: a newer tap
                // or swipe may have arrived while a native root was mounting.
                let shown = self.activeTabSwipeTarget ?? self.currentTab
                guard CraftChrome.shared.selected != shown else { return }
                CraftChrome.shared.selected = shown
            }
            return
        }
        show(tab: id)
    }

    // MARK: Layout

    func tabBarCovers(_ height: CGFloat) {
        tabBarHeight = height
    }

    private func safeAreaForTabBar() -> CGFloat {
        // UIKit supplies the bar (and on iOS 26, its accessory) inset. Only
        // the older-system accessory above that bar needs an extra inset.
        let chrome = CraftChrome.shared
        if chrome.tabBarVisible && !chrome.tabs.isEmpty && chrome.tabAccessory?.iconOnly == true { return 56 }
#if compiler(>=6.2)
        if #available(iOS 26.0, *) { return 0 }
#endif
        return chrome.tabBarVisible && !chrome.tabs.isEmpty && chrome.tabAccessory != nil ? 44 : 0
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        tabBarCovers(tabBarHeight)
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        lastNavigation = CACurrentMediaTime()
        if animated { CraftFramePacing.shared.begin("navigation") }
        if navigationController === visibleStack {
            CraftChrome.shared.visiblePath = nativePaths[ObjectIdentifier(viewController)]
        }
        // The page draws its own header, and a tab's root screen its own
        // title unless it asked for the bar; a pushed native screen gets the
        // bar and its Back.
        // A root screen that asked for its own bar (setOptions) keeps it.
        // A screen that put its bar away (`hidden: true`, a tour drawing its
        // own Back and Skip) stays bare, pushed or not.
        let native = viewController as? CraftNativeScreenController
        let asksForBar = native?.wantsNavigationBar ?? false
        let bare = viewController is CraftHybridWebSlot || native?.navigationBarHidden == true
            || (navigationController.viewControllers.first === viewController && !asksForBar)
        navigationController.setNavigationBarHidden(bare, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        lastNavigation = CACurrentMediaTime()
        CraftFramePacing.shared.end("navigation")
        // A page shows no native accessory; one a screen gave up is taken off.
        if viewController is CraftHybridWebSlot { CraftChrome.shared.clearUnclaimedTabAccessory() }
        let key = ObjectIdentifier(navigationController)
        let before = shownStacks[key] ?? []
        let now = navigationController.viewControllers
        shownStacks[key] = now
        let removed = before.filter { old in !now.contains(where: { $0 === old }) }
        for gone in removed { nativePaths.removeValue(forKey: ObjectIdentifier(gone)) }
        // The page goes back to where it was before the first web entry the
        // pop removed.
        if let depth = removed.compactMap({ ($0 as? CraftHybridWebSlot)?.depth }).min() {
            hybrid.pageBack(to: depth - 1)
        }
        for snapshot in webTransitionSnapshots { snapshot.removeFromSuperview() }
        webTransitionSnapshots.removeAll()
        // Back at a tab's native root while the page, with no history left
        // to go back through (it reloaded on the screen just popped), still
        // shows that screen: it moves to the root's path. Left there, the
        // next screen opened from the root was pushed on top of it and named
        // it in its Back button ("Me" instead of "Today").
        if !removed.isEmpty, !(viewController is CraftHybridWebSlot), navigationController.viewControllers.first === viewController,
           let rootPath = nativePaths[ObjectIdentifier(viewController)], !rootPath.contains(":"), hybrid.pageDepth == 0,
           let pagePath = hybrid.pagePath, CraftHybridRoutes.normalize(pagePath) != CraftHybridRoutes.normalize(rootPath) {
            hybrid.pageReset(to: rootPath)
        }
        guard navigationController === visibleStack else { return }
        // Also restore selection after a cancelled interactive pop.
        CraftChrome.shared.visiblePath = nativePaths[ObjectIdentifier(viewController)]
        if let slot = viewController as? CraftHybridWebSlot { adoptWeb(into: slot) } else { parkWeb() }
    }

    // MARK: UIGestureRecognizerDelegate

    /// The edge swipe back, and on iOS 26 the swipe back from anywhere on the
    /// screen, which is the one that answers a swipe that starts a little in
    /// from the edge. Both refuse on their own while the bar is hidden, which
    /// it is over a web entry; the shell decides for them instead.
    private func popRecognizers(of nav: UINavigationController) -> [UIGestureRecognizer] {
        var recognizers = [nav.interactivePopGestureRecognizer].compactMap { $0 }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let content = nav.interactiveContentPopGestureRecognizer {
            recognizers.append(content)
        }
        #endif
        return recognizers
    }

    private func isPopRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let nav = visibleStack else { return false }
        return popRecognizers(of: nav).contains { $0 === recognizer }
    }

    /// Whether the touch at `point` (in this controller's view) is on a
    /// horizontal scroll view of `root` that is past its leading edge, so a
    /// swipe to the right scrolls it back rather than leaving the screen.
    private func horizontalScrollCanScrollBack(at point: CGPoint, in root: UIView) -> Bool {
        let local = root.convert(point, from: view)
        guard root.bounds.contains(local), let hit = root.hitTest(local, with: nil) else { return false }
        var candidate: UIView? = hit
        while let current = candidate, current !== root.superview {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    /// The edge swipe goes ahead of the web view's own gestures, which
    /// otherwise hold every touch over the page until the page has answered it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === visibleStack?.interactivePopGestureRecognizer { return true }
        guard tabSwipeRecognizers.contains(where: { $0 === gestureRecognizer }),
              let scroll = otherGestureRecognizer.view as? UIScrollView,
              otherGestureRecognizer === scroll.panGestureRecognizer,
              scroll.isScrollEnabled else { return false }
        // A vertical list must not suppress the shell's horizontal tab pan.
        // Horizontal content keeps ownership of its own drag instead.
        return !scroll.alwaysBounceHorizontal && scroll.contentSize.width <= scroll.bounds.width + 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if tabSwipeRecognizers.contains(where: { $0 === gestureRecognizer }) {
            // System tab-bar tracking owns touches on the bar and accessory;
            // Craft's content swipe must not steal their drag/hold gestures.
            let point = gestureRecognizer.location(in: view)
            if !tabBar.isHidden, tabBar.frame.contains(point) { return false }
            if !accessoryButton.isHidden, accessoryButton.window != nil,
               accessoryButton.convert(accessoryButton.bounds, to: view).contains(point) { return false }
            // A swipe may begin while the last one settles: it catches it.
            guard activeTabSwipeTarget == nil || tabSwipeSettling,
                  hybrid.tabIds.count > 1, let nav = visibleStack, let top = nav.topViewController else { return false }
            guard CraftChrome.shared.tabSwipeEnabled else { return false }
            // Only between the tabs' own first screens, as the bar shows them:
            // deeper in a tab a swipe to the right is Back, and a screen that
            // put the bar away (a workout under way, a tour) has the whole
            // screen to itself.
            guard nav.viewControllers.count == 1, nav.transitionCoordinator == nil,
                  !CraftChrome.shared.hiddenByScreen else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: view)
                guard abs(velocity.x) > abs(velocity.y) else { return false }
            }
            if let native = top as? CraftNativeScreenController,
               !native.tabSwipeEnabled || !native.contentSwipeBack { return false }
            return !horizontalScrollAt(gestureRecognizer.location(in: view), in: top.view)
        }
        guard let nav = visibleStack, isPopRecognizer(gestureRecognizer),
              nav.viewControllers.count > 1, nav.transitionCoordinator == nil else { return false }
        if let native = nav.topViewController as? CraftNativeScreenController {
            // `swipeBack: false`: the screen's own Back is the only way back.
            if !native.swipeBack { return false }
            if gestureRecognizer !== nav.interactivePopGestureRecognizer, !native.contentSwipeBack { return false }
            // A back-swipe that starts on a pager, a carousel or a chart that
            // can still scroll back is that view's: the pager goes back a
            // page. At its first page there is nothing to scroll back to, and
            // the swipe is the screen's Back again, from the edge or (iOS 26)
            // from anywhere.
            let moved = (gestureRecognizer as? UIPanGestureRecognizer)?.translation(in: nav.view) ?? .zero
            let location = gestureRecognizer.location(in: nav.view)
            let start = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
            if horizontalScrollCanScrollBack(at: nav.view.convert(start, to: view), in: native.view) { return false }
        }
        guard let slot = nav.topViewController as? CraftHybridWebSlot else { return true }
        // Over the page, only from its left edge: a swipe across the page is
        // the page's (a carousel, a slider).
        if gestureRecognizer !== nav.interactivePopGestureRecognizer {
            // Where the finger came down: where it is, less how far it moved.
            let moved = (gestureRecognizer as? UIPanGestureRecognizer)?.translation(in: nav.view).x ?? 0
            if gestureRecognizer.location(in: nav.view).x - moved > 32 { return false }
        }
        // And only while the page is at that entry: deeper, the swipe is the
        // page's own Back.
        if let depth = slot.depth { return hybrid.pageDepth <= depth }
        return true
    }

    // MARK: CraftHybridScreenEvents

    func nativeScreenDidRender(_ screen: CraftNativeScreenController) {
        guard !firstFrameLogged else { return }
        firstFrameLogged = true
        let path = nativePaths[ObjectIdentifier(screen)] ?? "?"
        // Logged when the frame is committed: a cold launch is timed from the
        // process's first log line to this one, as the web's "splash hidden".
        CATransaction.setCompletionBlock { [weak self] in
            NSLog("[craft hybrid] native first frame %@", path)
            self?.attachWeb()
            // The app script after the first frame, never before it.
            self?.hybrid.startAppScript()
        }
        CraftChrome.shared.hideSplash()
    }

    func nativeScreen(_ screen: CraftNativeScreenController, didFail message: String) {
        let path = nativePaths[ObjectIdentifier(screen)] ?? hybrid.startPath
        guard hybrid.hasWeb else {
            // No web view to open it in: the screen keeps its own error.
            NSLog("[craft hybrid] native screen for %@ failed (%@); the app has no web view to open it in", path, message)
            if !firstFrameLogged { DispatchQueue.main.async { [weak self] in self?.hybrid.startAppScript() } }
            return
        }
        NSLog("[craft hybrid] native screen for %@ failed (%@); opening it in the web view", path, message)
        DispatchQueue.main.async { [weak self, weak screen] in
            guard let self, let screen, let nav = screen.navigationController else { return }
            self.attachWeb()
            let isRoot = nav.viewControllers.first === screen
            let slot = CraftHybridWebSlot(path: path, depth: isRoot ? nil : self.hybrid.pageDepth, isTabRoot: isRoot)
            self.nativePaths.removeValue(forKey: ObjectIdentifier(screen))
            if !self.firstFrameLogged, !self.hybrid.pageReady {
                CraftChrome.shared.showSplash(atMost: self.config.splashMaxSeconds)
            }
            // The page loads the start path already; anywhere else it is sent.
            let pageAt = self.hybrid.pagePath ?? (self.hybrid.pageReady ? nil : self.hybrid.startPath)
            if pageAt.flatMap(CraftHybridRoutes.normalize) != CraftHybridRoutes.normalize(path) {
                self.hybrid.navigatePage(path) { _ in }
            }
            nav.setViewControllers(nav.viewControllers.map { $0 === screen ? slot : $0 }, animated: false)
            self.shownStacks[ObjectIdentifier(nav)] = nav.viewControllers
            if nav === self.visibleStack, nav.topViewController === slot { self.adoptWeb(into: slot) }
        }
    }

    func nativeScreen(_ screen: CraftNativeScreenController, open path: String, props: [String: Any]) {
        open(path, props: props)
    }

    func nativeScreen(_ screen: CraftNativeScreenController, replace path: String) {
        guard screen.navigationController?.topViewController === screen else { return }
        showNative(path: path, replace: true)
    }

    private func log(_ message: String) {
        #if DEBUG
        NSLog("[craft hybrid] %@", message)
        #endif
    }
}

// MARK: - Frame pacing

/// How smoothly the app's own motion runs, measured the way Instruments'
/// Animation Hitches template counts it: a frame that reaches the screen
/// later than the display expected it is a hitch, and the time it was late
/// is hitch time. Apple's bar is a hitch time ratio under 5 ms per second of
/// motion; above 10 the motion reads as broken.
///
/// Off unless the app is launched with `-CraftFramePacing YES` (or
/// `CRAFT_FRAME_PACING=1`), so a shipped app never runs a display link for
/// it. Each span (a scroll, a tab swipe, a push, a screen mount) logs one
/// `[craft frames]` line, which simulator and device runs read back with
/// `log show`. The Animation Hitches instrument does not run in the
/// simulator; this does.
final class CraftFramePacing: NSObject {
    static let shared = CraftFramePacing()

    let enabled: Bool = {
        let info = ProcessInfo.processInfo
        return UserDefaults.standard.bool(forKey: "CraftFramePacing") || info.environment["CRAFT_FRAME_PACING"] == "1"
    }()

    private struct Span {
        var started: CFTimeInterval
        var frames = 0
        var hitches = 0
        var hitchTime: CFTimeInterval = 0
        var worst: CFTimeInterval = 0
    }

    private var spans: [String: Span] = [:]
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastTarget: CFTimeInterval = 0

    /// Start counting frames for `name`; a span already open keeps counting.
    func begin(_ name: String) {
        guard enabled, spans[name] == nil else { return }
        spans[name] = Span(started: CACurrentMediaTime())
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        // ProMotion runs scrolling at up to 120Hz; measure against what the
        // display actually asked for, not a fixed 60.
        if #available(iOS 15.0, *) { link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    /// Close `name` and log its frames.
    func end(_ name: String) {
        guard enabled, let span = spans.removeValue(forKey: name) else { return }
        let duration = max(0.001, CACurrentMediaTime() - span.started)
        write(String(format: "%@ frames=%d duration=%.0fms hitches=%d hitchTime=%.1fms worst=%.1fms ratio=%.1fms/s",
                     name, span.frames, duration * 1000, span.hitches, span.hitchTime * 1000, span.worst * 1000,
                     span.hitchTime * 1000 / duration))
        if spans.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    /// One block, timed: a screen mount, a bundle evaluation. Labelled by the
    /// thread it ran on, since a screen's script now runs off the main thread
    /// and a bundle's time there costs no frames.
    @discardableResult
    func measure<T>(_ name: String, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let started = CACurrentMediaTime()
        let result = work()
        write(String(format: "%@ %@=%.1fms", name, Thread.isMainThread ? "main" : "script", (CACurrentMediaTime() - started) * 1000))
        return result
    }

    /// One piece of the screens' JavaScript (CraftNativeScriptThread): how
    /// long it waited behind other screens' work, and how long it ran. The
    /// screens share one serial script thread, so a screen in front can sit
    /// behind hidden tabs reloading; `waited` is where that shows.
    func scriptWork(_ name: String, waited: CFTimeInterval, ran: CFTimeInterval) {
        guard enabled else { return }
        write(String(format: "script %@ waited=%.1fms ran=%.1fms", name, waited * 1000, ran * 1000))
    }

    /// A capability a screen asked for (a request, the keychain), from the
    /// ask to the answer. Logged from 4ms, as script work is.
    func capability(_ name: String, took: CFTimeInterval) {
        guard enabled, took >= 0.004 else { return }
        write(String(format: "capability %@ took=%.1fms", name, took * 1000))
    }

    /// Each line to the log and to `Library/Caches/craft-frame-pacing.log`
    /// in the app's container, which a test run reads back whole (a
    /// simulator's unified log can drop an app's lines under load). Written
    /// off the main thread, so the measuring costs no frames itself.
    private let output = DispatchQueue(label: "craft.frame-pacing", qos: .utility)
    private lazy var file: FileHandle? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("craft-frame-pacing.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private func write(_ line: String) {
        NSLog("[craft frames] %@", line)
        let stamped = "\(Date().timeIntervalSince1970) \(line)\n"
        output.async { [weak self] in try? self?.file?.write(contentsOf: Data(stamped.utf8)) }
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer {
            lastTimestamp = link.timestamp
            lastTarget = link.targetTimestamp
        }
        guard lastTimestamp > 0 else { return }
        // The frame was due at the last target; anything later than that,
        // beyond a millisecond of scheduling noise, is hitch time.
        let late = link.timestamp - lastTarget
        for key in spans.keys {
            spans[key]!.frames += 1
            if late > 0.001 {
                spans[key]!.hitches += 1
                spans[key]!.hitchTime += late
                spans[key]!.worst = max(spans[key]!.worst, late)
            }
        }
    }
}
