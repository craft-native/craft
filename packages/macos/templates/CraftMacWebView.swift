#if CRAFT_WEBKIT
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import WebKit

// Web content for the AppKit host: one WKWebView per tab, for apps built with
// `buildMacOSNative({ webkit: true })` (a browser, a help viewer). The app's
// own screens still render as native controls through zig-js; only the pages
// a `<WebView>` shows are web content. Without the flag none of this is
// compiled and the host links no WebKit at all.
//
// Tabs belong to `CraftMacWebTabs`, not to the view showing them, so a tab
// keeps its page while the screen re-renders, moves between split panes, or
// is not on screen at all. A `<WebView tab="...">` decides where it appears.

/// One WKWebViewConfiguration per profile. Every tab of a profile shares its
/// website data store (cookies, storage, cache); profiles never share one.
final class CraftMacWebProfiles {
    static let shared = CraftMacWebProfiles()
    private var configurations: [String: WKWebViewConfiguration] = [:]

    /// Safari's own suffix, so sites serve the desktop Safari experience rather than an unknown WebKit embedder's.
    static let userAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(safari) Safari/605.1.15"
    }()

    /// `ephemeral` keeps nothing on disk (a private window); named profiles persist under their own identifier.
    func configuration(profile: String, ephemeral: Bool) -> WKWebViewConfiguration {
        let key = (ephemeral ? "ephemeral:" : "") + profile
        if let existing = configurations[key] { return existing.copy() as! WKWebViewConfiguration }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store(profile: profile, ephemeral: ephemeral)
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        configurations[key] = configuration
        return configuration.copy() as! WKWebViewConfiguration
    }

    func store(profile: String, ephemeral: Bool) -> WKWebsiteDataStore {
        if ephemeral { return .nonPersistent() }
        if profile == "default" { return .default() }
        if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: Self.identifier(profile)) }
        return .default()
    }

    /// A stable UUID per profile name, so a profile finds its data again on every launch.
    static func identifier(_ profile: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("craft.web.profile:" + profile).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// A tab: its WKWebView, the screen it reports to, and the state it reports.
final class CraftMacTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let profile: String
    let ephemeral: Bool
    let view: WKWebView
    /// The window whose script hears this tab's events. Showing the tab in another window moves it there.
    weak var owner: CraftMacRuntime?
    private var observations: [NSKeyValueObservation] = []
    private var statePending = false
    private var lastFavicon = ""

    init(id: String, profile: String, ephemeral: Bool, configuration: WKWebViewConfiguration, owner: CraftMacRuntime?, ownContent: Bool = true) {
        self.id = id; self.profile = profile; self.ephemeral = ephemeral; self.owner = owner
        // Its own content controller, so a site allowed past the blockers is allowed in this tab only.
        // A `window.open` child must take WebKit's configuration as given, and shares its opener's.
        if ownContent { configuration.userContentController = WKUserContentController() }
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityIdentifier("web:\(id)")
        // KVO fires once per property per change; a page load changes several at once.
        // They are reported together, at most once per run-loop turn.
        let report: (Any, Any) -> Void = { [weak self] _, _ in self?.scheduleState() }
        observations = [
            view.observe(\.title, changeHandler: report), view.observe(\.url, changeHandler: report),
            view.observe(\.estimatedProgress, changeHandler: report), view.observe(\.isLoading, changeHandler: report),
            view.observe(\.canGoBack, changeHandler: report), view.observe(\.canGoForward, changeHandler: report),
            view.observe(\.hasOnlySecureContent, changeHandler: report), view.observe(\.themeColor, changeHandler: report),
            view.observe(\.cameraCaptureState, changeHandler: report), view.observe(\.microphoneCaptureState, changeHandler: report),
        ]
        if ownContent {
            CraftMacContentRules.shared.apply(to: self, host: nil)
            CraftMacUserScripts.shared.apply(to: view.configuration.userContentController)
        }
    }

    /// The site on screen is allowed past the content blockers (or no longer is).
    private(set) var blockingHost: String?

    var state: [String: Any] {
        var state: [String: Any] = [
            "tab": id, "profile": profile, "private": ephemeral,
            "title": view.title ?? "", "url": view.url?.absoluteString ?? "",
            "progress": view.estimatedProgress, "loading": view.isLoading,
            "canGoBack": view.canGoBack, "canGoForward": view.canGoForward,
            "secure": view.hasOnlySecureContent, "zoom": view.pageZoom,
            "camera": view.cameraCaptureState == .active, "microphone": view.microphoneCaptureState == .active,
        ]
        if let color = view.themeColor?.usingColorSpace(.sRGB) {
            state["themeColor"] = String(format: "#%02x%02x%02x", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
        }
        return state
    }

    func emit(_ type: String, _ detail: [String: Any] = [:]) {
        var payload = detail; payload["tab"] = id; payload["type"] = type
        owner?.send("CRAFT_EVENT", ["event": "craftWebView", "detail": payload])
    }

    private func scheduleState() {
        guard !statePending else { return }
        statePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statePending = false
            self.emit("state", self.state)
        }
    }

    func close() {
        observations.forEach { $0.invalidate() }; observations.removeAll()
        view.stopLoading()
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.removeFromSuperview()
    }

    // MARK: navigation

    private static let pageSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "javascript" { decisionHandler(.allow); return }
        // mailto:, facetime:, zoommtg: and the like belong to other apps.
        if !Self.pageSchemes.contains(scheme) {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        // The blockers follow the site in the main frame: a site the person allowed loads without them.
        if action.targetFrame?.isMainFrame ?? true, let host = url.host?.lowercased(), host != blockingHost {
            blockingHost = host
            CraftMacContentRules.shared.apply(to: self, host: host)
        }
        // ⌘-click (and middle click) opens the link in a new tab, as every browser does; the screen decides where.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            emit("open", ["url": url.absoluteString, "background": !action.modifierFlags.contains(.shift), "reason": "modifier"])
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(response.isForMainFrame && (attachment || !response.canShowMIMEType) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { CraftMacDownloads.shared.adopt(download, tab: self) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { CraftMacDownloads.shared.adopt(download, tab: self) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { emit("navigationStart", ["url": webView.url?.absoluteString ?? ""]) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit("navigationFinish", ["url": webView.url?.absoluteString ?? ""])
        readFavicon()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        let nsError = error as NSError
        // A navigation replaced by another one, or turned into a download, is not a failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        emit("navigationError", ["url": (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? view.url?.absoluteString ?? "", "code": nsError.code, "domain": nsError.domain, "message": nsError.localizedDescription])
    }

    /// The page's renderer died (out of memory, a crash). Reload it rather than leave a blank tab.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        emit("crashed", ["url": webView.url?.absoluteString ?? ""])
        webView.reload()
    }

    /// The icon the page declares, else `/favicon.ico`. Read in an isolated world the page's scripts cannot see.
    private func readFavicon() {
        let script = """
        (() => { const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
          .map(l => ({ href: l.href, size: parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16) }))
          .filter(l => l.href).sort((a, b) => Math.abs(a.size - 32) - Math.abs(b.size - 32));
          return links.length ? links[0].href : (location.protocol.startsWith('http') ? location.origin + '/favicon.ico' : '') })()
        """
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let value) = result, let href = value as? String, !href.isEmpty, href != self.lastFavicon else { return }
            self.lastFavicon = href
            self.emit("favicon", ["url": href])
        }
    }

    // MARK: windows, dialogs, files

    /// `window.open` and `target=_blank`. WebKit needs the new view right now, so the tab is
    /// created here and announced; the screen adopts it by id like any other tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = CraftMacWebTabs.shared.make(profile: profile, ephemeral: ephemeral, configuration: configuration, owner: owner, ownContent: false)
        let popup = windowFeatures.width != nil || windowFeatures.height != nil
        var detail: [String: Any] = ["child": child.id, "url": action.request.url?.absoluteString ?? "", "popup": popup, "reason": "script"]
        if popup { detail["width"] = windowFeatures.width?.doubleValue ?? 0; detail["height"] = windowFeatures.height?.doubleValue ?? 0 }
        emit("open", detail)
        return child.view
    }

    func webViewDidClose(_ webView: WKWebView) { emit("close") }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(message, frame: frame, buttons: ["OK"]) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(message, frame: frame, buttons: ["OK", "Cancel"]) { response, _ in completionHandler(response == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        present(prompt, frame: frame, buttons: ["OK", "Cancel"], input: defaultText ?? "") { response, text in completionHandler(response == .alertFirstButtonReturn ? text : nil) }
    }
    private func present(_ message: String, frame: WKFrameInfo, buttons: [String], input: String? = nil, done: @escaping (NSApplication.ModalResponse, String) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let field = input.map { value -> NSTextField in let field = NSTextField(string: value); field.frame = CGRect(x: 0, y: 0, width: 280, height: 24); return field }
        alert.accessoryView = field
        guard let window = view.window else { done(alert.runModal(), field?.stringValue ?? ""); return }
        alert.beginSheetModal(for: window) { response in done(response, field?.stringValue ?? "") }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = view.window else { completionHandler(panel.runModal() == .OK ? panel.urls : nil); return }
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    // MARK: permissions

    /// A site asks for the camera or microphone. The screen decides (`permission`, answered with
    /// `answerPermission`), so it can remember a site's answer; macOS still asks for the app once.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kind: String
        switch type {
        case .camera: kind = "camera"
        case .microphone: kind = "microphone"
        default: kind = "camera+microphone"
        }
        let request = CraftMacWebTabs.shared.ask(tab: self, decide: decisionHandler)
        emit("permission", ["request": request, "kind": kind, "origin": origin.host, "protocol": origin.protocol, "port": origin.port, "mainFrame": frame.isMainFrame])
    }
}

/// Content blockers (an ad blocker's lists): compiled once by WebKit, kept on disk by identifier and
/// version, and applied to every tab except on the sites the person allowed.
final class CraftMacContentRules {
    static let shared = CraftMacContentRules()
    private(set) var lists: [String: WKContentRuleList] = [:]
    /// Sites where no list applies; a host here covers its subdomains.
    var allowed: Set<String> = []

    func isAllowed(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        while true {
            if allowed.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
        }
    }

    func apply(to tab: CraftMacTab, host: String?) {
        let controller = tab.view.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard !isAllowed(host ?? tab.view.url?.host) else { return }
        for list in lists.values { controller.add(list) }
    }

    func reapply() { for tab in CraftMacWebTabs.shared.tabs.values { apply(to: tab, host: tab.blockingHost) } }

    /// A list by identifier and version: the compiled copy on disk when there is one, else compiled
    /// from `json` (WebKit's content-blocker format). Without `json` and nothing on disk, `missing`.
    func set(_ identifier: String, version: String, json: String?, answer: @escaping (Any) -> Void, fail: @escaping (String, String) -> Void) {
        guard let store = WKContentRuleListStore.default() else { fail("UNAVAILABLE", "WebKit has no content rule list store"); return }
        let key = "\(identifier)@\(version)"
        store.lookUpContentRuleList(forIdentifier: key) { [weak self] found, _ in
            guard let self else { return }
            if let found {
                self.lists[identifier] = found; self.reapply(); answer(["identifier": identifier, "cached": true]); return
            }
            guard let json, !json.isEmpty else { answer(["identifier": identifier, "missing": true]); return }
            store.compileContentRuleList(forIdentifier: key, encodedContentRuleList: json) { list, error in
                guard let list else { fail("COMPILE_FAILED", error?.localizedDescription ?? "WebKit did not compile \(identifier)"); return }
                self.lists[identifier] = list; self.reapply()
                // Older versions of the same list are only disk space now.
                store.getAvailableContentRuleListIdentifiers { keys in
                    for old in keys ?? [] where old.hasPrefix("\(identifier)@") && old != key { store.removeContentRuleList(forIdentifier: old) { _ in } }
                }
                answer(["identifier": identifier, "cached": false])
            }
        }
    }

    func remove(_ identifier: String) { lists.removeValue(forKey: identifier); reapply() }
}

/// Scripts and styles a person added to sites (Boosts), injected in an isolated world the page's
/// own scripts cannot see. Each names the hosts it runs on; a host covers its subdomains.
final class CraftMacUserScripts {
    static let shared = CraftMacUserScripts()
    private var scripts: [WKUserScript] = []

    func set(_ entries: [[String: Any]]) {
        scripts = entries.flatMap { entry -> [WKUserScript] in
            let hosts = (entry["hosts"] as? [String] ?? []).map { $0.lowercased() }
            guard !hosts.isEmpty, let hostsJSON = try? JSONSerialization.data(withJSONObject: hosts), let hostList = String(data: hostsJSON, encoding: .utf8) else { return [] }
            let guardLine = "if (!\(hostList).some(h => location.hostname === h || location.hostname.endsWith('.' + h))) return;"
            let allFrames = entry["allFrames"] as? Bool == true
            var made: [WKUserScript] = []
            if let css = entry["css"] as? String, !css.isEmpty, let cssJSON = try? JSONSerialization.data(withJSONObject: [css]), let cssLiteral = String(data: cssJSON, encoding: .utf8) {
                let id = (entry["id"] as? String ?? "boost").replacingOccurrences(of: "\"", with: "")
                let source = "(() => { \(guardLine) const s = document.createElement('style'); s.dataset.craftBoost = \"\(id)\"; s.textContent = \(cssLiteral)[0]; (document.head || document.documentElement).appendChild(s) })()"
                made.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: !allFrames, in: .defaultClient))
            }
            if let js = entry["js"] as? String, !js.isEmpty {
                made.append(WKUserScript(source: "(() => { \(guardLine)\n\(js)\n})()", injectionTime: .atDocumentEnd, forMainFrameOnly: !allFrames, in: .defaultClient))
            }
            return made
        }
        // Pages pick the new set up on their next load.
        for tab in CraftMacWebTabs.shared.tabs.values { apply(to: tab.view.configuration.userContentController) }
    }

    func apply(to controller: WKUserContentController) {
        controller.removeAllUserScripts()
        scripts.forEach(controller.addUserScript)
    }
}

/// Downloads started by any tab, saved to ~/Downloads under a name that never overwrites.
final class CraftMacDownloads: NSObject, WKDownloadDelegate {
    static let shared = CraftMacDownloads()
    private struct Entry { let id: String; weak var tab: CraftMacTab?; var path: String; var observation: NSKeyValueObservation? }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var downloads: [WKDownload] = []
    private var lastReport: [String: CFAbsoluteTime] = [:]

    func adopt(_ download: WKDownload, tab: CraftMacTab) {
        download.delegate = self
        downloads.append(download)
        let id = UUID().uuidString
        var entry = Entry(id: id, tab: tab, path: "")
        entry.observation = download.progress.observe(\.fractionCompleted) { [weak self, weak download] _, _ in
            guard let self, let download else { return }
            DispatchQueue.main.async { self.report(download, state: "progress") }
        }
        entries[ObjectIdentifier(download)] = entry
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent.isEmpty ? "download" : (suggestedFilename as NSString).lastPathComponent
        var destination = folder.appendingPathComponent(name), copy = 1
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            copy += 1
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)")
        }
        entries[ObjectIdentifier(download)]?.path = destination.path
        report(download, state: "started")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) { report(download, state: "finished"); finish(download) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        report(download, state: "failed", extra: ["message": error.localizedDescription])
        finish(download)
    }

    /// Progress is reported at most every 250ms; a start, finish or failure always is.
    private func report(_ download: WKDownload, state: String, extra: [String: Any] = [:]) {
        guard let entry = entries[ObjectIdentifier(download)] else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if state == "progress", now - (lastReport[entry.id] ?? 0) < 0.25 { return }
        lastReport[entry.id] = now
        var detail: [String: Any] = ["id": entry.id, "state": state, "path": entry.path, "name": (entry.path as NSString).lastPathComponent,
            "url": download.originalRequest?.url?.absoluteString ?? "",
            "received": download.progress.completedUnitCount, "total": download.progress.totalUnitCount, "fraction": download.progress.fractionCompleted]
        extra.forEach { detail[$0.key] = $0.value }
        entry.tab?.emit("download", detail)
    }

    /// Stop a download that is still running; what arrived is kept as resume data no one uses yet.
    func cancel(_ id: String) -> Bool {
        guard let download = downloads.first(where: { entries[ObjectIdentifier($0)]?.id == id }) else { return false }
        download.cancel { _ in }
        report(download, state: "failed", extra: ["message": "Cancelled", "cancelled": true])
        finish(download)
        return true
    }

    /// A file in ~/Downloads (after resolving links), or nil: the screen may only point at downloads.
    static func downloadedFile(_ path: String) -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().standardizedFileURL.path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(folder + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    private func finish(_ download: WKDownload) {
        downloads.removeAll { $0 === download }
        if let entry = entries.removeValue(forKey: ObjectIdentifier(download)) { entry.observation?.invalidate(); lastReport.removeValue(forKey: entry.id) }
    }
}

/// Every tab, by id, and the screens' `Web` capability module.
final class CraftMacWebTabs {
    static let shared = CraftMacWebTabs()
    private(set) var tabs: [String: CraftMacTab] = [:]
    private let hosts = NSHashTable<CraftMacWebHost>.weakObjects()

    @discardableResult
    func make(id: String? = nil, profile: String = "default", ephemeral: Bool = false, configuration: WKWebViewConfiguration? = nil, owner: CraftMacRuntime?, ownContent: Bool = true) -> CraftMacTab {
        let id = id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        if let existing = tabs[id] { return existing }
        let tab = CraftMacTab(id: id, profile: profile, ephemeral: ephemeral,
            configuration: configuration ?? CraftMacWebProfiles.shared.configuration(profile: profile, ephemeral: ephemeral), owner: owner, ownContent: ownContent)
        tabs[id] = tab
        // A `<WebView>` may have named this tab before it existed (the render and the create cross).
        for host in hosts.allObjects where host.wanted == id { host.show(id) }
        return tab
    }

    func register(_ host: CraftMacWebHost) { hosts.add(host) }

    /// Permission requests waiting for the screen, by request id. Unanswered ones are denied after two minutes.
    private var pending: [String: (tab: String, decide: (WKPermissionDecision) -> Void)] = [:]
    func ask(tab: CraftMacTab, decide: @escaping (WKPermissionDecision) -> Void) -> String {
        let request = UUID().uuidString
        pending[request] = (tab.id, decide)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.answer(request, .deny) }
        return request
    }
    @discardableResult
    func answer(_ request: String, _ decision: WKPermissionDecision) -> Bool {
        guard let waiting = pending.removeValue(forKey: request) else { return false }
        waiting.decide(decision); return true
    }

    func close(_ id: String) {
        for (request, waiting) in pending where waiting.tab == id { answer(request, .deny) }
        tabs.removeValue(forKey: id)?.close()
    }

    /// Cookies, storage and caches of a profile: one site's (`host`, matched by its registrable
    /// domain as WebKit names records) or everything.
    func clearData(_ options: [String: Any], answer: @escaping (Any) -> Void) {
        let store = CraftMacWebProfiles.shared.store(profile: options["profile"] as? String ?? "default", ephemeral: options["private"] as? Bool == true)
        let kinds: [String: [String]] = [
            "cookies": [WKWebsiteDataTypeCookies],
            "storage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeServiceWorkerRegistrations],
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache],
        ]
        let asked = options["types"] as? [String] ?? Array(kinds.keys)
        let types = Set(asked.flatMap { kinds[$0] ?? [] })
        guard let host = (options["host"] as? String)?.lowercased(), !host.isEmpty else {
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { answer(["cleared": true]) }; return
        }
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: matching) { answer(["cleared": true, "records": matching.count]) }
        }
    }

    /// A closed window takes its tabs with it.
    func closeAll(owner: CraftMacRuntime) {
        for (id, tab) in tabs where tab.owner == nil || tab.owner === owner { tabs.removeValue(forKey: id); tab.close() }
    }

    func perform(_ method: String, _ args: [Any], owner: CraftMacRuntime, answer: @escaping (Any) -> Void, fail: @escaping (String, String) -> Void) {
        let options = args.first as? [String: Any] ?? [:]
        if method == "create" {
            let tab = make(id: options["id"] as? String, profile: options["profile"] as? String ?? "default", ephemeral: options["private"] as? Bool == true, owner: owner)
            tab.view.isInspectable = options["inspectable"] as? Bool ?? true
            if let address = options["url"] as? String, !address.isEmpty {
                guard let url = URL(string: address), url.scheme != nil else { fail("INVALID_ARGUMENT", "Not an absolute URL: \(address)"); return }
                tab.view.load(URLRequest(url: url))
            }
            answer(tab.state); return
        }
        if method == "list" { answer(tabs.values.map(\.state)); return }
        switch method {
        case "setContentRules":
            guard let identifier = args.first as? String, !identifier.isEmpty else { fail("INVALID_ARGUMENT", "setContentRules needs an identifier"); return }
            let list = args.dropFirst().first as? [String: Any] ?? [:]
            CraftMacContentRules.shared.set(identifier, version: list["version"] as? String ?? "1", json: list["json"] as? String, answer: answer, fail: fail); return
        case "removeContentRules": CraftMacContentRules.shared.remove(args.first as? String ?? ""); answer(true); return
        case "allowContent":
            CraftMacContentRules.shared.allowed = Set((args.first as? [String] ?? []).map { $0.lowercased() })
            CraftMacContentRules.shared.reapply(); answer(true); return
        case "setUserScripts": CraftMacUserScripts.shared.set(args.first as? [[String: Any]] ?? []); answer(true); return
        case "answerPermission":
            let decision: WKPermissionDecision = { switch args.dropFirst().first as? String { case "grant": return .grant; case "prompt": return .prompt; default: return .deny } }()
            answer(self.answer(args.first as? String ?? "", decision)); return
        case "clearData": clearData(options, answer: answer); return
        case "cancelDownload": answer(CraftMacDownloads.shared.cancel(args.first as? String ?? "")); return
        case "revealDownload", "openDownload":
            guard let file = CraftMacDownloads.downloadedFile(args.first as? String ?? "") else { fail("NOT_FOUND", "Not a file in Downloads"); return }
            // An app or a script is revealed, never run: opening it is the person's call in Finder.
            let runnable = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType.map { $0.conforms(to: .application) || $0.conforms(to: .executable) || $0.conforms(to: .script) } ?? true
            if method == "openDownload" && !runnable { answer(NSWorkspace.shared.open(file)) }
            else { NSWorkspace.shared.activateFileViewerSelecting([file]); answer(true) }
            return
        default: break
        }
        guard let id = args.first as? String, let tab = tabs[id] else { fail("NOT_FOUND", "No tab \(String(describing: args.first ?? ""))"); return }
        let view = tab.view
        switch method {
        case "navigate":
            guard let address = args.dropFirst().first as? String, let url = URL(string: address), url.scheme != nil else { fail("INVALID_ARGUMENT", "navigate needs an absolute URL"); return }
            view.load(URLRequest(url: url)); answer(true)
        case "back": answer(view.goBack() != nil)
        case "forward": answer(view.goForward() != nil)
        case "reload":
            let ignoreCache = (args.dropFirst().first as? [String: Any])?["ignoreCache"] as? Bool == true
            if ignoreCache { view.reloadFromOrigin() } else { view.reload() }
            answer(true)
        case "stop": view.stopLoading(); answer(true)
        case "close": close(id); answer(true)
        case "state": answer(tab.state)
        case "focus": view.window?.makeFirstResponder(view); answer(view.window != nil)
        case "setZoom": view.pageZoom = number(args.dropFirst().first).map { max(0.25, min(5, $0)) } ?? 1; answer(view.pageZoom)
        case "setInspectable": view.isInspectable = args.dropFirst().first as? Bool ?? true; answer(true)
        case "evaluate":
            let script = args.dropFirst().first as? String ?? ""
            // The page's own world by default (to read what its scripts set up); `isolated` hides the call from them.
            let world: WKContentWorld = (args.dropFirst(2).first as? [String: Any])?["isolated"] as? Bool == true ? .defaultClient : .page
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): answer(JSONSerialization.isValidJSONObject(["v": value]) ? value : String(describing: value))
                case .failure(let error): fail("SCRIPT_ERROR", error.localizedDescription)
                }
            }
        case "find":
            let text = args.dropFirst().first as? String ?? ""
            let options = args.dropFirst(2).first as? [String: Any] ?? [:]
            let configuration = WKFindConfiguration()
            configuration.backwards = options["backwards"] as? Bool == true
            configuration.caseSensitive = options["caseSensitive"] as? Bool == true
            configuration.wraps = options["wraps"] as? Bool ?? true
            view.find(text, configuration: configuration) { result in answer(["found": result.matchFound]) }
        case "print":
            let operation = view.printOperation(with: .shared)
            operation.view?.frame = view.bounds
            if let window = view.window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
            answer(true)
        case "snapshot":
            let configuration = WKSnapshotConfiguration()
            if let width = number((args.dropFirst().first as? [String: Any])?["width"]) { configuration.snapshotWidth = NSNumber(value: Double(width)) }
            view.takeSnapshot(with: configuration) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { fail("SNAPSHOT_FAILED", error?.localizedDescription ?? "No image"); return }
                answer("data:image/jpeg;base64," + jpeg.base64EncodedString())
            }
        default: fail("UNSUPPORTED_METHOD", "Web.\(method) is not supported")
        }
    }
}

/// What a `<WebView tab="...">` renders as: the tab's WKWebView, filling the box.
/// Every tab it has shown stays attached and hidden, so switching back is a visibility change
/// (WebKit throttles hidden pages) rather than a reparent.
final class CraftMacWebHost: NSView {
    weak var box: CraftMacBox?
    private(set) var wanted: String?
    override var isFlipped: Bool { true }

    init(box: CraftMacBox) {
        self.box = box
        super.init(frame: .zero)
        CraftMacWebTabs.shared.register(self)
    }
    required init?(coder: NSCoder) { fatalError("Created from STX") }

    func show(_ id: String?) {
        wanted = id
        let tab = id.flatMap { CraftMacWebTabs.shared.tabs[$0] }
        for case let view as WKWebView in subviews where view !== tab?.view { view.isHidden = true }
        // Tabs closed elsewhere leave nothing behind.
        for case let view as WKWebView in subviews where !CraftMacWebTabs.shared.tabs.values.contains(where: { $0.view === view }) { view.removeFromSuperview() }
        guard let tab else { return }
        if let runtime = box?.renderer?.runtime { tab.owner = runtime }
        if tab.view.superview !== self { tab.view.frame = bounds; addSubview(tab.view) }
        tab.view.isHidden = false
    }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}
#endif
