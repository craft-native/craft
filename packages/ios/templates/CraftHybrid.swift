import Foundation
import SwiftUI
import UIKit
import WebKit

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
        // Every item for the account, whatever its service.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
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
    /// `craft.navigation.open(path)`.
    func nativeScreen(_ screen: CraftNativeScreenController, open path: String)
}

// MARK: - The shell

final class CraftHybrid: NSObject {
    static let shared = CraftHybrid()

    private(set) var config = CraftConfig()
    private(set) var routes = CraftHybridRoutes([:])
    /// Whether this app mixes native screens into its web page.
    private(set) var isEnabled = false
    /// The path the app opens on: its page's path.
    private(set) var startPath = "/"
    /// Whether that path is a native screen, drawn before the page loads.
    private(set) var startsNative = false
    weak var controller: CraftHybridController?
    weak var webView: WKWebView?

    /// Where the page is, as it last said.
    fileprivate(set) var pagePath: String?
    fileprivate(set) var pageDepth = 0
    fileprivate(set) var pageReady = false

    private override init() {}

    static var bundleURL: URL? {
        Bundle.main.url(forResource: "native-screen", withExtension: "js", subdirectory: "dist")
            ?? Bundle.main.url(forResource: "native-screen", withExtension: "js")
    }

    /// From the bundled config, before the first frame: whether the app is
    /// hybrid, where it starts, and the tab bar it starts with.
    func configure(_ config: CraftConfig) {
        self.config = config
        routes = CraftHybridRoutes(config.nativeScreens ?? [:])
        startPath = config.devServerURL.flatMap(URL.init(string:)).map(CraftHybridRoutes.appPath(of:)) ?? "/"
        if startPath.isEmpty { startPath = "/" }
        let wanted = config.renderer == "web" && !routes.isEmpty
        if wanted && Self.bundleURL == nil {
            NSLog("[craft hybrid] nativeScreens are set but dist/native-screen.js is missing; every path opens in the web view")
        }
        isEnabled = wanted && Self.bundleURL != nil
        startsNative = isEnabled && routes.match(startPath) != nil
        CraftChrome.shared.configure(tabs: config.tabs ?? [], selected: tabIds(from: config.tabs ?? []).isEmpty ? nil : CraftHybridRoutes.tab(owning: startPath, among: tabIds(from: config.tabs ?? [])), splash: !startsNative)
    }

    private func tabIds(from tabs: [CraftConfig.Tab]) -> [String] { tabs.map(\.id) }

    /// The tab ids the bar shows now: the page's once it has described them.
    var tabIds: [String] {
        let shown = CraftChrome.shared.tabs.map(\.id)
        return shown.isEmpty ? (config.tabs ?? []).map(\.id) : shown
    }

    /// Whether the web view is what the person sees: always, outside hybrid.
    var webIsVisible: Bool {
        guard isEnabled else { return true }
        return controller?.webIsVisible ?? !startsNative
    }

    // MARK: Page script

    /// The document-start script the hybrid page runs, with the route table
    /// and the shared storage keys filled in.
    func pageScript() -> String {
        let routeList = (config.nativeScreens ?? [:]).map { ["pattern": $0.key, "screen": $0.value] }
        let share = Array((config.shareStorage ?? [:]).keys).sorted()
        func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return Self.pageScriptTemplate
            .replacingOccurrences(of: "__CRAFT_HYBRID_ROUTES__", with: json(routeList))
            .replacingOccurrences(of: "__CRAFT_HYBRID_SHARE__", with: json(share))
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
      function share(key) {
        var value = null;
        try { value = window.sessionStorage.getItem(key); } catch (e) {}
        try { if (value === null) value = window.localStorage.getItem(key); } catch (e) {}
        if (shared[key] === value) return;
        shared[key] = value;
        post({ type: 'shareStorage', key: key, value: value });
      }
      if (SHARE.length && window.Storage) {
        var proto = window.Storage.prototype;
        var setItem = proto.setItem, removeItem = proto.removeItem, clear = proto.clear;
        proto.setItem = function (key) { var out = setItem.apply(this, arguments); if (SHARE.indexOf(String(key)) >= 0) share(String(key)); return out; };
        proto.removeItem = function (key) { var out = removeItem.apply(this, arguments); if (SHARE.indexOf(String(key)) >= 0) share(String(key)); return out; };
        proto.clear = function () { var out = clear.apply(this, arguments); SHARE.forEach(share); return out; };
        SHARE.forEach(share);
      }

      window.__craftHybrid = {
        match: function (url) { var path = local(url); return path === null ? null : match(path); },
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
                if ok { NotificationCenter.default.post(name: Self.snapshotChanged, object: nil, userInfo: ["name": name]) }
                else { NSLog("[craft hybrid] snapshot %@ was not written: not a snapshot name, or not JSON", name) }
            }
        case .snapshotRemove(let name):
            CraftSnapshots.write(name, json: nil) { _ in
                NotificationCenter.default.post(name: Self.snapshotChanged, object: nil, userInfo: ["name": name])
            }
        case .snapshotClear:
            let names = CraftSnapshots.directory
                .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(5)) } ?? []
            for name in names { CraftSnapshots.write(name, json: nil) }
        case .shareStorage(let key, let value):
            guard let nativeKey = config.shareStorage?[key] else { return }
            CraftHybridKeychain.set(nativeKey, value: value)
        case .navigated(let path, let direction, let depth, let byHost):
            pagePath = path
            pageDepth = depth
            if direction == "load" { pageReady = true }
            controller?.pageNavigated(path: path, direction: direction, depth: depth, byHost: byHost)
        case .navigateNative(let path, let replace):
            controller?.showNative(path: path, replace: replace)
        case .open(let path):
            controller?.open(path)
        case .back:
            controller?.popTop()
        }
    }

    /// Posted when the page wrote or removed a snapshot (`userInfo["name"]`).
    static let snapshotChanged = Notification.Name("craftSnapshotChanged")

    // MARK: Tabs and links

    /// A tap on the native bar. Answers whether the page should also hear
    /// it (`craftTabSelect`), which it does for every switch so the page's own
    /// tab follows the screen.
    func tabTapped(_ id: String, reselect: Bool) -> Bool {
        guard isEnabled, let controller else { return true }
        return controller.tabTapped(id, reselect: reselect)
    }

    /// The page chose a tab itself (its `selectTab`, or a tab link).
    func pageSelectedTab(_ id: String) {
        guard isEnabled else { return }
        controller?.pageSelectedTab(id)
    }

    /// A deep link to a native path opens the native screen; true when it did.
    func handleDeepLink(_ url: URL) -> Bool {
        guard isEnabled, let controller else { return false }
        let path = CraftHybridRoutes.appPath(of: url)
        guard routes.match(path) != nil else { return false }
        controller.showNative(path: path, replace: false, fromLink: true)
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
        let value = depth.map(String.init) ?? "null"
        webView?.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.setBase(\(value))", completionHandler: nil)
    }

    func pageBack(to depth: Int) {
        webView?.evaluateJavaScript("window.__craftHybrid && window.__craftHybrid.backTo(\(max(0, depth)))", completionHandler: nil)
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
    /// The page has not reached `path` yet: the entry shows its background,
    /// not the page it is leaving, until it has.
    var awaitingPage = false

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
        (parent?.parent as? CraftHybridController)?.adoptWeb(into: self)
    }
}

final class CraftHybridController: UIViewController, UINavigationControllerDelegate, UIGestureRecognizerDelegate, CraftHybridScreenEvents {
    private let config: CraftConfig
    private let hybrid = CraftHybrid.shared
    private let webHost: UIHostingController<AnyView>
    /// Where the web view waits, behind the screens, while none of them is web.
    private let parking = UIView()
    private var stacks: [String: UINavigationController] = [:]
    private var currentTab = ""
    /// The path each native entry opened at.
    private var nativePaths: [ObjectIdentifier: String] = [:]
    /// Each stack as it was after its last transition, to see what a pop removed.
    private var shownStacks: [ObjectIdentifier: [UIViewController]] = [:]
    /// A tab whose page has not caught up yet; shown when it has, or soon.
    private var pendingTab: (id: String, deadline: DispatchWorkItem)?
    private var openingWeb = false
    private var firstFrameLogged = false
    private var tabBarHeight: CGFloat = 0

    init(config: CraftConfig) {
        self.config = config
        webHost = UIHostingController(rootView: AnyView(CraftWebView(config: config).ignoresSafeArea()))
        super.init(nibName: nil, bundle: nil)
        hybrid.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = config.resolvedBackgroundColor
        parking.frame = view.bounds
        parking.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(parking)

        // A native start screen draws first; the web view, whose creation
        // costs a frame or more, starts loading straight after it.
        if !hybrid.startsNative { attachWeb() }
        let tabs = hybrid.tabIds
        let start = CraftHybridRoutes.tab(owning: hybrid.startPath, among: tabs) ?? tabs.first ?? ""
        show(tab: start, rootPath: hybrid.startPath)
        if hybrid.startsNative {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attachWeb() }
        }
    }

    private var webAttached = false

    /// The web view joins the screen, behind the native screens, and loads.
    private func attachWeb() {
        guard !webAttached else { return }
        webAttached = true
        webHost.view.backgroundColor = config.resolvedBackgroundColor
        if #available(iOS 16.4, *) { webHost.safeAreaRegions = [] }
        if let slot = visibleStack?.topViewController as? CraftHybridWebSlot, slot.isViewLoaded {
            moveWeb(to: slot, in: slot.view)
        } else {
            moveWeb(to: self, in: parking)
        }
    }

    /// The web view's controller is the child of whichever controller shows
    /// it: UIKit refuses a child's view in another controller's hierarchy.
    private func moveWeb(to owner: UIViewController, in container: UIView) {
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

    private var visibleStack: UINavigationController? { stacks[currentTab] }

    var webIsVisible: Bool {
        guard let slot = visibleStack?.topViewController as? CraftHybridWebSlot else { return false }
        return webHost.view.superview === slot.view
    }

    // MARK: Stacks

    private func makeStack(tab: String, rootPath: String) -> UINavigationController {
        let nav = UINavigationController(rootViewController: entry(for: rootPath, isTabRoot: true, depth: nil))
        nav.delegate = self
        nav.view.backgroundColor = config.resolvedBackgroundColor
        nav.additionalSafeAreaInsets.bottom = safeAreaForTabBar()
        nav.setNavigationBarHidden(true, animated: false)
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)
        // Only once the stack's view has loaded: the recognizer is made then,
        // and before it is nil, so the delegate never took.
        for recognizer in popRecognizers(of: nav) { recognizer.delegate = self }
        stacks[tab] = nav
        shownStacks[ObjectIdentifier(nav)] = nav.viewControllers
        return nav
    }

    /// The entry for a path: its native screen, or a web entry.
    private func entry(for path: String, isTabRoot: Bool, depth: Int?, params extra: [String: Any] = [:]) -> UIViewController {
        if let match = hybrid.routes.match(path) {
            var params: [String: Any] = match.params
            params["path"] = path
            extra.forEach { params[$0.key] = $0.value }
            let screen = CraftNativeScreenController(config: config, routeName: match.screen, routeParams: params)
            screen.hybridEvents = self
            nativePaths[ObjectIdentifier(screen)] = match.path
            return screen
        }
        return CraftHybridWebSlot(path: path, depth: depth, isTabRoot: isTabRoot)
    }

    private func show(tab id: String, rootPath: String? = nil) {
        cancelPendingTab()
        let nav = stacks[id] ?? makeStack(tab: id, rootPath: rootPath ?? (id.isEmpty ? hybrid.startPath : id))
        currentTab = id
        for (key, other) in stacks { other.view.isHidden = key != id }
        view.bringSubviewToFront(nav.view)
        if let slot = nav.topViewController as? CraftHybridWebSlot, slot.isViewLoaded {
            adoptWeb(into: slot)
        } else if !(nav.topViewController is CraftHybridWebSlot) {
            parkWeb()
        }
    }

    private func cancelPendingTab() {
        pendingTab?.deadline.cancel()
        pendingTab = nil
    }

    func adoptWeb(into slot: CraftHybridWebSlot) {
        guard slot.navigationController === visibleStack || visibleStack == nil else { return }
        attachWeb()
        moveWeb(to: slot, in: slot.view)
        webHost.view.alpha = slot.awaitingPage ? 0 : 1
        hybrid.setPageBase(slot.isTabRoot ? nil : slot.depth)
    }

    private func parkWeb() {
        guard webAttached else { return }
        webHost.view.alpha = 1
        moveWeb(to: self, in: parking)
    }

    // MARK: Opening paths

    /// `craft.navigation.open(path)` or `craft.hybrid.open(path)`: a tab, a
    /// native screen, or the web view pushed over the screen that asked.
    func open(_ raw: String) {
        guard let path = CraftHybridRoutes.normalize(raw) else { return }
        if let tab = hybrid.tabIds.first(where: { CraftHybridRoutes.normalize($0) == path }) {
            selectTabAsIfTapped(tab)
            return
        }
        if hybrid.routes.match(raw) != nil {
            showNative(path: raw, replace: false)
            return
        }
        pushWeb(raw)
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
    func showNative(path raw: String, replace: Bool, fromLink: Bool = false) {
        guard let match = hybrid.routes.match(raw) else { return }
        let tabs = hybrid.tabIds
        if let tab = tabs.first(where: { CraftHybridRoutes.normalize($0) == match.path }) {
            if tab != currentTab {
                selectTabAsIfTapped(tab)
            }
            if let nav = stacks[tab], nav.viewControllers.count > 1 {
                nav.popToRootViewController(animated: !fromLink)
            }
            return
        }
        if fromLink, let owner = CraftHybridRoutes.tab(owning: match.path, among: tabs), owner != currentTab {
            selectTabAsIfTapped(owner)
        }
        guard let nav = visibleStack ?? stacks.values.first else { return }
        if let existing = nav.viewControllers.last(where: { nativePaths[ObjectIdentifier($0)] == match.path }) {
            if existing !== nav.topViewController { nav.popToViewController(existing, animated: true) }
            return
        }
        let screen = entry(for: raw, isTabRoot: false, depth: nil)
        if replace, nav.viewControllers.count > 1 {
            nav.setViewControllers(Array(nav.viewControllers.dropLast()) + [screen], animated: true)
        } else {
            nav.pushViewController(screen, animated: true)
        }
    }

    /// The web view, pushed: the page goes to `path` first, without its own
    /// slide, then the entry slides in over the screen that opened it.
    private func pushWeb(_ path: String) {
        guard !openingWeb, let nav = visibleStack else { return }
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
        guard webHost.view.superview === slot.view else { return }
        UIView.animate(withDuration: 0.15) { self.webHost.view.alpha = 1 }
    }

    /// Back from the web entry on top, as the page's Back at that entry asks.
    func popTop() {
        guard let nav = visibleStack, nav.viewControllers.count > 1, nav.topViewController is CraftHybridWebSlot else { return }
        nav.popViewController(animated: true)
    }

    // MARK: The page moved

    func pageNavigated(path: String, direction: String, depth: Int, byHost: Bool) {
        let owner = CraftHybridRoutes.tab(owning: path, among: hybrid.tabIds)
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
        if reselect || id == currentTab {
            guard let nav = stacks[id] else { return true }
            if nav.viewControllers.count > 1 {
                nav.popToRootViewController(animated: true)
                return false
            }
            // The root again: a web root is the page's to handle (to its top,
            // then its own first screen).
            return nav.topViewController is CraftHybridWebSlot
        }
        let target = stacks[id]
        let rootIsWeb = target.map { $0.topViewController is CraftHybridWebSlot } ?? (hybrid.routes.match(id) == nil)
        let pageThere = hybrid.pagePath.flatMap { CraftHybridRoutes.tab(owning: $0, among: hybrid.tabIds) } == id
        if rootIsWeb && !pageThere {
            // Keep this screen up until the page has switched, rather than
            // showing it half way.
            cancelPendingTab()
            if stacks[id] == nil { _ = makeStack(tab: id, rootPath: id); stacks[id]?.view.isHidden = true; view.bringSubviewToFront(visibleStack?.view ?? view) }
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
    /// then keeps the tab that is on screen.
    func pageSelectedTab(_ id: String) {
        guard id != currentTab, pendingTab?.id != id else { return }
        guard let top = visibleStack?.topViewController as? CraftHybridWebSlot, top.isTabRoot else {
            let shown = currentTab
            DispatchQueue.main.async {
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
        let inset = safeAreaForTabBar()
        for nav in stacks.values where nav.additionalSafeAreaInsets.bottom != inset {
            nav.additionalSafeAreaInsets.bottom = inset
        }
    }

    private func safeAreaForTabBar() -> CGFloat {
        let bottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        return max(0, tabBarHeight - bottom)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        tabBarCovers(tabBarHeight)
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // The page draws its own header, and a tab's root screen its own
        // title unless it asked for the bar; a pushed native screen gets the
        // bar and its Back.
        // A root screen that asked for its own bar (setOptions) keeps it.
        let asksForBar = (viewController as? CraftNativeScreenController)?.wantsNavigationBar ?? false
        let bare = viewController is CraftHybridWebSlot || (navigationController.viewControllers.first === viewController && !asksForBar)
        navigationController.setNavigationBarHidden(bare, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
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
        guard navigationController === visibleStack else { return }
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

    /// The edge swipe goes ahead of the web view's own gestures, which
    /// otherwise hold every touch over the page until the page has answered it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === visibleStack?.interactivePopGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = visibleStack, isPopRecognizer(gestureRecognizer),
              nav.viewControllers.count > 1, nav.transitionCoordinator == nil else { return false }
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
        }
        CraftChrome.shared.hideSplash()
    }

    func nativeScreen(_ screen: CraftNativeScreenController, didFail message: String) {
        let path = nativePaths[ObjectIdentifier(screen)] ?? hybrid.startPath
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

    func nativeScreen(_ screen: CraftNativeScreenController, open path: String) {
        open(path)
    }

    private func log(_ message: String) {
        #if DEBUG
        NSLog("[craft hybrid] %@", message)
        #endif
    }
}
