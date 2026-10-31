import AppKit
import WebKit

// Tabs through the real renderer and real WKWebViews, built the way
// `buildMacOSNative({ webkit: true })` builds them. Pages are data: URLs,
// so nothing here touches the network.
final class FixtureNetwork {
    let session = URLSession.shared
    func request(_ options: [String: Any]) -> URLRequest? { nil }
}
final class CraftMacRuntime {
    var errors: [String] = []
    var sent: [[String: Any]] = []
    let network = FixtureNetwork()
    func event(_ handler: String?, payload: [String: Any]) {}
    func send(_ type: String, _ payload: [String: Any], correlation: String? = nil) {
        if type == "CRAFT_EVENT", payload["event"] as? String == "craftWebView", let detail = payload["detail"] as? [String: Any] { sent.append(detail) }
    }
}

@main struct WebChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func wait(_ seconds: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    static func node(_ id: String, _ type: String = "View", _ style: [String: Any] = [:], _ children: [[String: Any]] = [], props: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "type": type, "style": style, "props": props, "children": children]
    }
    static func page(_ title: String, _ body: String = "") -> String {
        "data:text/html;charset=utf-8," + "<title>\(title)</title><body>\(body)</body>".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
    static func call(_ method: String, _ args: [Any], _ runtime: CraftMacRuntime) -> Any? {
        var result: Any?, done = false, failure = ""
        CraftMacWebTabs.shared.perform(method, args, owner: runtime, answer: { result = $0; done = true }, fail: { code, message in failure = "\(code): \(message)"; done = true })
        require(wait { done }, "Web.\(method) never answered")
        require(failure.isEmpty, "Web.\(method) failed: \(failure)")
        return result
    }

    static func main() {
        _ = NSApplication.shared
        let runtime = CraftMacRuntime()
        let renderer = CraftMacRenderer(runtime: runtime)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = renderer.root
        renderer.window = window
        renderer.root.frame = CGRect(x: 0, y: 0, width: 640, height: 480)

        // The screen names a tab before it exists; the host shows it once it is created.
        renderer.render(node("root", "View", ["flexGrow": 1], [node("bar", "View", ["height": 40]), node("content", "WebView", ["flexGrow": 1], props: ["tab": "a"])]))
        let host = renderer.boxes["content"]!.control as! CraftMacWebHost
        require(abs(renderer.boxes["content"]!.frame.height - 440) < 1, "A WebView did not fill its flex space")
        require(host.subviews.isEmpty, "A host showed a tab that does not exist yet")
        let created = call("create", [["id": "a", "url": page("First")]], runtime) as! [String: Any]
        require(created["tab"] as? String == "a", "create did not answer the tab's state")
        let first = CraftMacWebTabs.shared.tabs["a"]!
        require(first.view.superview === host && !first.view.isHidden, "A tab created after its WebView rendered was not adopted")
        require(first.view.frame.size == host.bounds.size, "A tab does not fill its WebView")

        require(wait { runtime.sent.contains { $0["type"] as? String == "state" && $0["title"] as? String == "First" } }, "No state event carried the page title")
        require(runtime.sent.contains { $0["type"] as? String == "navigationFinish" }, "No navigationFinish event")
        let state = runtime.sent.last { $0["type"] as? String == "state" }!
        require(state["loading"] as? Bool == false || state["progress"] as? Double ?? 0 > 0, "State reported no progress")

        require(call("evaluate", ["a", "document.title + ':' + (1 + 2)"], runtime) as? String == "First:3", "evaluate did not run in the page")
        require(call("find", ["a", "First"], runtime) as? [String: Any] != nil, "find did not answer")

        // A second page in the same tab gives it history.
        runtime.sent.removeAll()
        _ = call("navigate", ["a", page("Second")], runtime)
        require(wait { runtime.sent.contains { $0["title"] as? String == "Second" && $0["canGoBack"] as? Bool == true } }, "Navigation did not report the new title and back history")

        // Switching tabs hides the first rather than detaching it.
        _ = call("create", [["id": "b", "url": page("Other")]], runtime)
        renderer.render(node("root", "View", ["flexGrow": 1], [node("bar", "View", ["height": 40]), node("content", "WebView", ["flexGrow": 1], props: ["tab": "b"])]))
        let second = CraftMacWebTabs.shared.tabs["b"]!
        require(second.view.superview === host && !second.view.isHidden, "The selected tab is not visible")
        require(first.view.superview === host && first.view.isHidden, "The previous tab was detached instead of hidden")

        // Profiles never share a data store; the same profile always gets the same one back.
        require(CraftMacWebProfiles.identifier("work") == CraftMacWebProfiles.identifier("work"), "A profile's data store identifier is not stable")
        require(CraftMacWebProfiles.identifier("work") != CraftMacWebProfiles.identifier("personal"), "Two profiles share a data store identifier")
        let isolated = call("create", [["id": "p", "private": true]], runtime) as! [String: Any]
        require(isolated["private"] as? Bool == true && !CraftMacWebTabs.shared.tabs["p"]!.view.configuration.websiteDataStore.isPersistent, "A private tab persisted its data")

        // A content blocker applies to new tabs, is found again compiled by its version, and stays off on allowed sites.
        let hide = #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad"}}]"#
        let fresh = call("setContentRules", ["checks", ["version": UUID().uuidString, "json": hide]], runtime) as! [String: Any]
        require(fresh["cached"] as? Bool == false, "A new content rule list was not compiled")
        let version = UUID().uuidString
        require((call("setContentRules", ["checks-2", ["version": version]], runtime) as! [String: Any])["missing"] as? Bool == true, "A list never compiled was not reported missing")
        _ = call("setContentRules", ["checks-2", ["version": version, "json": hide]], runtime)
        require((call("setContentRules", ["checks-2", ["version": version]], runtime) as! [String: Any])["cached"] as? Bool == true, "A compiled list was not found again by its version")
        // A Boost's style runs on the sites it names.
        // A page-world script runs where the page's own scripts can see what it set, on every site.
        _ = call("setUserScripts", [[["id": "boost", "hosts": ["checks.invalid"], "css": "body { color: rgb(1, 2, 3) }"],
                                     ["id": "page", "hosts": [], "world": "page", "at": "start", "js": "window.__craftPageScript = 'ran'"]]], runtime)
        // Blockers act on web documents, not data: ones; an https base URL needs no network.
        _ = call("create", [["id": "ads"]], runtime)
        CraftMacWebTabs.shared.tabs["ads"]!.view.loadHTMLString("<title>Ads</title><div class=ad>ad</div><div class=keep>keep</div>", baseURL: URL(string: "https://checks.invalid/"))
        renderer.render(node("root", "View", ["flexGrow": 1], [node("bar", "View", ["height": 40]), node("content", "WebView", ["flexGrow": 1], props: ["tab": "ads"])]))
        require(wait { (try? JSONSerialization.jsonObject(with: Data(((call("evaluate", ["ads", "(() => { const ad = document.querySelector('.ad'), keep = document.querySelector('.keep'); return ad && keep ? JSON.stringify([getComputedStyle(ad).display, getComputedStyle(keep).display, getComputedStyle(document.body).color]) : '[]' })()"], runtime) as? String) ?? "[]").utf8)) as? [String]) == ["none", "block", "rgb(1, 2, 3)"] }, "The blocker did not hide .ad, or the Boost's style did not apply")
        require(call("evaluate", ["ads", "window.__craftPageScript || 'missing'"], runtime) as? String == "ran", "A page-world script did not run in the page's world")
        CraftMacContentRules.shared.allowed = ["example.com"]
        require(CraftMacContentRules.shared.isAllowed("news.example.com") && !CraftMacContentRules.shared.isAllowed("example.org"), "An allowed site did not cover its subdomains")
        _ = call("removeContentRules", ["checks"], runtime); _ = call("removeContentRules", ["checks-2"], runtime)
        _ = call("setUserScripts", [[]], runtime)
        require(call("answerPermission", ["no-such-request", "grant"], runtime) as? Bool == false, "An unknown permission request was answered")
        require((call("clearData", [["profile": "checks", "private": true]], runtime) as? [String: Any])?["cleared"] as? Bool == true, "clearData did not answer")

        // Unknown tabs fail with NOT_FOUND instead of answering.
        var code = ""
        CraftMacWebTabs.shared.perform("back", ["missing"], owner: runtime, answer: { _ in }, fail: { failure, _ in code = failure })
        require(code == "NOT_FOUND", "An unknown tab did not fail with NOT_FOUND")

        _ = call("close", ["b"], runtime)
        require(CraftMacWebTabs.shared.tabs["b"] == nil && second.view.superview == nil, "close left the tab behind")
        CraftMacWebTabs.shared.closeAll(owner: runtime)
        require(CraftMacWebTabs.shared.tabs.isEmpty, "A closed window left tabs behind")
        print("PASS native web tabs")
    }
}
