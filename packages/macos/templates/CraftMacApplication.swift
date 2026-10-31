import AppKit
import AVKit
import CoreImage
import UserNotifications
import UniformTypeIdentifiers

/// A window that tells its screen when Escape reaches it unhandled: the screen hears it as the desktop
/// command `escape` (close the open item, dismiss a sheet).
final class CraftMacWindow: NSWindow {
    weak var runtime: CraftMacRuntime?
    override func cancelOperation(_ sender: Any?) { runtime?.send("CRAFT_EVENT", ["event": "craftDesktopCommand", "detail": ["id": "escape"]]) }
}

final class CraftMacScene: NSObject, NSWindowDelegate {
    let name: String
    let window: NSWindow
    let runtime: CraftMacRuntime
    let renderer: CraftMacRenderer
    /// Where the close button's top-left corner sits, from the window's top-left (`--traffic-lights 18,18`):
    /// a browser lines the buttons up with its own toolbar row. Nil keeps AppKit's place.
    let trafficLights: CGPoint?
    /// The screen has work to finish before the app quits (`craft.desktop.onQuit`).
    var holdsQuit = false
    init(name: String, route: String, options: [String: Any], application: CraftMacApplication) {
        self.name = name
        runtime = CraftMacRuntime(route: route, params: options["params"] as? [String: Any] ?? [:], network: application.network)
        renderer = CraftMacRenderer(runtime: runtime)
        let width = number(options["width"]) ?? 1120, height = number(options["height"]) ?? 740
        let transparent = (options["titlebarStyle"] as? String ?? application.titlebarStyle) == "transparent"
        let lights = options["trafficLights"] as? [Any] ?? (name == "main" ? application.trafficLights : nil)
        trafficLights = lights.flatMap { values in values.count == 2 ? number(values[0]).flatMap { x in number(values[1]).map { CGPoint(x: x, y: $0) } } : nil }
        let panel = CraftMacWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: transparent ? [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView] : [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.runtime = runtime
        window = panel
        super.init()
        runtime.scene = self; renderer.window = window
        window.title = options["title"] as? String ?? application.appName
        if (options["titlebarStyle"] as? String ?? application.titlebarStyle) == "transparent" {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.minSize = CGSize(width: number(options["minWidth"]) ?? 640, height: number(options["minHeight"]) ?? 400)
        // A small window that stays above others (a link opened from another app, a quick look).
        if options["floating"] as? Bool == true { window.level = .floating; window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.isReleasedWhenClosed = false
        renderer.root.autoresizingMask = [.width, .height]
        window.contentView = renderer.root
        window.delegate = self; window.center()
        if name == "main" && application.testDirectory == nil { window.setFrameAutosaveName("\(application.appName)NativeMain") }
        window.makeKeyAndOrderFront(nil)
        placeTrafficLights()
        runtime.load(application.bundle)
    }

    /// AppKit lays the title bar out again on resize, full screen and appearance changes, so this runs after each.
    func placeTrafficLights() {
        guard let inset = trafficLights, let close = window.standardWindowButton(.closeButton), let titlebar = close.superview?.superview else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let size = close.frame.size
        let height = size.height + inset.y * 2
        titlebar.frame = CGRect(x: titlebar.frame.minX, y: window.frame.height - height, width: titlebar.frame.width, height: height)
        // The standard spacing: each button 6pt after the last.
        for (index, type) in buttons.enumerated() {
            window.standardWindowButton(type)?.setFrameOrigin(CGPoint(x: inset.x + CGFloat(index) * (size.width + 6), y: (height - size.height) / 2))
        }
    }
    func windowDidResize(_ notification: Notification) { placeTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { placeTrafficLights() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if name == "main" { sender.orderOut(nil); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        runtime.dispose()
        CraftMacApplication.shared.scenes.removeValue(forKey: name)
        CraftMacApplication.shared.quitReady(scene: name)
    }
    func windowDidBecomeKey(_ notification: Notification) { runtime.send("SCREEN_FOCUS", ["focused": true]) }
    func windowDidResignKey(_ notification: Notification) { runtime.send("SCREEN_FOCUS", ["focused": false]) }
}

final class CraftMacMenuTarget: NSObject {
    var chosen: String?
    @objc func choose(_ item: NSMenuItem) { chosen = item.representedObject as? String }
}

final class CraftMacApplication: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = CraftMacApplication()
    var appName = "Craft"
    var bundle = ""
    var initialRoute = "Main"
    var titlebarStyle = "standard"
    var trafficLights: [Any]?
    /// Apps that ship their own agent (Attic) hand out a session cookie at
    /// `/native/session`. An app that talks to a hosted API has no such
    /// endpoint and starts with `--no-session`.
    var requiresSession = true
    var mainWindowOptions: [String: Any] = [:]
    /// The Dock icon's menu (`craft-app.json` `dockMenu`): each item sends its action as a desktop command.
    var dockMenu: [[String: Any]] = []
    /// Links and files other apps opened with this one, waiting for a screen to take them (`takeOpenedURLs`).
    var openedURLs: [String] = []
    var network: CraftMacNetwork!
    var scenes: [String: CraftMacScene] = [:]
    var panels: [NSWindow] = []
    var chosenFiles = Set<String>()
    var testDirectory: URL?
    var testTimer: Timer?
    var processedActions = Set<String>()
    var appearanceObservation: NSKeyValueObservation?
    /// A quit waiting for screens to finish (`craft.desktop.onQuit`), for at most `quitGrace` seconds.
    private var pendingQuit: (token: String, waiting: Set<String>, timeout: Timer)?
    static let quitGrace: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceChanged() }
        }
        NSApp.activate(ignoringOtherApps: true)
        if !requiresSession {
            open(name: "main", route: initialRoute, options: mainWindowOptions.merging(["title": appName]) { _, new in new })
            startTestDriver()
            return
        }
        // The agent issues an HttpOnly cookie. It stays in URLSession, shared
        // by native windows, and is never handed to the JavaScript context.
        let request = URLRequest(url: network.base.appendingPathComponent("native/session"))
        network.session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let alert = NSAlert(); alert.messageText = "Could not connect to the app"; alert.informativeText = error?.localizedDescription ?? "The local agent did not issue a native session."; alert.runModal(); NSApp.terminate(nil); return
                }
                self.open(name: "main", route: self.initialRoute, options: self.mainWindowOptions.merging(["title": self.appName]) { _, new in new })
                self.startTestDriver()
            }
        }.resume()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { scenes["main"]?.window.makeKeyAndOrderFront(nil); return true }
    /// Links from other apps (this app as the default browser) and files dropped on the Dock icon.
    /// A screen hears `craftDesktopOpenURL`; ones that arrive before any screen listens wait for `takeOpenedURLs`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let list = urls.map(\.absoluteString)
        openedURLs.append(contentsOf: list)
        for scene in scenes.values { scene.runtime.send("CRAFT_EVENT", ["event": "craftDesktopOpenURL", "detail": ["urls": list]]) }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !dockMenu.isEmpty else { return nil }
        let menu = NSMenu()
        for raw in dockMenu {
            let item = NSMenuItem(title: raw["title"] as? String ?? "", action: #selector(command(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = raw["action"] as? String
            menu.addItem(item)
        }
        return menu
    }
    /// Is this app the one that opens web links?
    var isDefaultBrowser: Bool {
        guard let probe = URL(string: "https://example.com"), let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
    func applicationWillTerminate(_ notification: Notification) { scenes.values.forEach { $0.runtime.dispose() }; testTimer?.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Screens holding the quit hear `craftDesktopQuit` and answer `quitReady` once their work is saved.
    /// The main queue keeps running while AppKit waits, so their timers and requests still complete,
    /// unless `terminate` was called from inside a main-queue block: GCD runs no other main-queue
    /// block until that one returns. So the host never calls it from one, and the timeout is a run
    /// loop timer, which fires either way. A second quit while waiting quits at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let holding = scenes.values.filter(\.holdsQuit)
        guard !holding.isEmpty, pendingQuit == nil else { return .terminateNow }
        let token = UUID().uuidString
        let timeout = Timer(timeInterval: Self.quitGrace, repeats: false) { [weak self] _ in self?.finishQuit(token) }
        RunLoop.main.add(timeout, forMode: .common)
        pendingQuit = (token, Set(holding.map(\.name)), timeout)
        for scene in holding { scene.runtime.send("CRAFT_EVENT", ["event": "craftDesktopQuit", "detail": ["token": token]]) }
        return .terminateLater
    }
    /// A screen finished its quit work, or went away. `token` nil matches the quit in progress.
    func quitReady(scene: String, token: String? = nil) {
        guard var pending = pendingQuit, token == nil || token == pending.token else { return }
        pending.waiting.remove(scene)
        pendingQuit = pending
        if pending.waiting.isEmpty { finishQuit(pending.token) }
    }
    private func finishQuit(_ token: String) {
        guard let pending = pendingQuit, pending.token == token else { return }
        pending.timeout.invalidate()
        pendingQuit = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func open(name: String, route: String, options: [String: Any]) {
        if let scene = scenes[name] { scene.window.makeKeyAndOrderFront(nil); return }
        scenes[name] = CraftMacScene(name: name, route: route, options: options, application: self)
    }
    @objc func command(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        broadcast(id)
    }
    func broadcast(_ id: String) { for scene in scenes.values { scene.runtime.send("CRAFT_EVENT", ["event": "craftDesktopCommand", "detail": ["id": id]]) } }
    func appearanceChanged() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scheme = CraftMacColor.isDark ? "dark" : "light"
        for scene in scenes.values {
            scene.runtime.context.evaluateScript("__stxNativeBridge.colorScheme = '\(scheme)';")
            // The protocol's own message: the screen restyles its `dark:` classes and tells `craft.appearance.onChange`.
            scene.runtime.send("APPEARANCE", ["colorScheme": scheme])
            scene.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                for box in scene.renderer.boxes.values {
                    box.layer?.backgroundColor = CraftMacColor.parse(box.style["backgroundColor"], fallback: .clear).cgColor
                    box.layer?.borderColor = CraftMacColor.parse(box.style["borderColor"], fallback: .separatorColor).cgColor
                }
            }
        }
        broadcast("appearance")
    }

    private func installMenus() {
        let bar = NSMenu()
        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(command(_:)), keyEquivalent: ","); settings.target = self; settings.representedObject = "settings"
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(app, to: bar)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu(edit, to: bar)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        addMenu(window, to: bar)
        NSApp.mainMenu = bar; NSApp.windowsMenu = window
    }
    private func addMenu(_ menu: NSMenu, to bar: NSMenu) { let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: ""); item.submenu = menu; bar.addItem(item) }
    /// Keys a shortcut names rather than types (`ctrl+tab`, `cmd+alt+right`), as AppKit's key equivalents spell them.
    static let namedKeys: [String: String] = {
        var keys = ["up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
            "tab": "\t", "return": "\r", "enter": "\r", "escape": "\u{1B}", "esc": "\u{1B}", "space": " ",
            "backspace": "\u{08}", "delete": "\u{08}", "forwarddelete": "\u{F728}",
            "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}", "plus": "+", "minus": "-"]
        for number in 1...12 { keys["f\(number)"] = String(UnicodeScalar(0xF703 + number)!) }
        return keys
    }()
    private func menuItem(_ raw: [String: Any], target: AnyObject, action: Selector) -> NSMenuItem {
        if raw["separator"] as? Bool == true { return .separator() }
        let parts = (raw["shortcut"] as? String ?? "").lowercased().split(separator: "+").map(String.init)
        let key = Self.namedKeys[parts.last ?? ""] ?? parts.last ?? ""
        let item = NSMenuItem(title: raw["label"] as? String ?? raw["title"] as? String ?? "", action: action, keyEquivalent: key)
        item.target = target; item.representedObject = raw["id"]
        item.keyEquivalentModifierMask = []
        if parts.contains("cmd") { item.keyEquivalentModifierMask.insert(.command) }
        if parts.contains("ctrl") { item.keyEquivalentModifierMask.insert(.control) }
        if parts.contains("shift") { item.keyEquivalentModifierMask.insert(.shift) }
        if parts.contains("alt") { item.keyEquivalentModifierMask.insert(.option) }
        item.isEnabled = raw["disabled"] as? Bool != true
        item.state = raw["checked"] as? Bool == true ? .on : .off
        if let symbol = raw["icon"] as? String { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    func perform(_ method: String, args: [Any], scene: CraftMacScene?, reply: @escaping (Any) -> Void) {
        let options = args.first as? [String: Any] ?? [:]
        switch method {
        case "openWindow":
            let name = options["name"] as? String ?? options["route"] as? String ?? "window"
            let route = options["route"] as? String ?? initialRoute
            open(name: name, route: route, options: options); reply(["name": name])
        case "closeWindow": scene?.window.performClose(nil); reply(NSNull())
        case "focus":
            if let identifier = args.first as? String, let box = scene?.renderer.boxes.values.first(where: { ($0.props["testID"] as? String ?? $0.props["testId"] as? String ?? $0.id) == identifier }) {
                scene?.window.makeFirstResponder((box.control as? NSScrollView)?.documentView ?? box.control)
            }
            reply(NSNull())
        case "setMenus":
            for raw in args.first as? [[String: Any]] ?? [] {
                guard let title = raw["label"] as? String, ![appName, "Edit", "Window"].contains(title), let bar = NSApp.mainMenu else { continue }
                if let old = bar.items.first(where: { $0.title == title }) { bar.removeItem(old) }
                let menu = NSMenu(title: title); menu.autoenablesItems = false
                for item in raw["items"] as? [[String: Any]] ?? [] { menu.addItem(menuItem(item, target: self, action: #selector(command(_:)))) }
                let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: ""); item.submenu = menu
                // A File menu is the first after the app menu; the others sit
                // between Edit and Window, where a Mac app's own menus belong.
                let index = title == "File" ? 1 : (bar.items.firstIndex(where: { $0.title == "Window" }) ?? bar.items.count)
                bar.insertItem(item, at: min(index, bar.items.count))
            }; reply(true)
        case "contextMenu":
            let target = CraftMacMenuTarget(), menu = NSMenu(); menu.autoenablesItems = false
            for item in args.first as? [[String: Any]] ?? [] { menu.addItem(menuItem(item, target: target, action: #selector(CraftMacMenuTarget.choose(_:)))) }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil); reply(target.chosen ?? NSNull())
        case "pickFiles":
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { reply([]); return }
            let files: [[String: String]] = panel.urls.map { url in
                chosenFiles.insert(url.path)
                return ["path": url.path, "name": url.lastPathComponent, "type": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"]
            }; reply(files)
        case "uploadFiles":
            upload(args.first as? [[String: String]] ?? [], endpoint: args.count > 1 ? args[1] as? String ?? "" : "", reply: reply)
        case "preview": preview(options, scene: scene); reply(true)
        case "exportFile": export(options, reply: reply)
        case "qrCode":
            let text = args.first as? String ?? ""
            let filter = CIFilter(name: "CIQRCodeGenerator")!; filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { reply(NSNull()); return }
            reply("data:image/png;base64," + data.base64EncodedString())
        case "takeOpenedURLs": reply(openedURLs); openedURLs.removeAll()
        case "isDefaultBrowser": reply(isDefaultBrowser)
        case "setDefaultBrowser":
            // macOS asks the person to confirm; the answer is whether this app opens links afterwards.
            let app = Bundle.main.bundleURL
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                    DispatchQueue.main.async { reply(self.isDefaultBrowser) }
                }
            }
        case "setBadge": let count = (args.first as? NSNumber)?.intValue ?? 0; NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil; reply(true)
        case "holdQuit": scene?.holdsQuit = args.first as? Bool != false; reply(true)
        case "quitReady": if let scene { quitReady(scene: scene.name, token: args.first as? String) }; reply(true)
        default: reply(["error": "Unsupported desktop operation: \(method)"])
        }
    }
    private func upload(_ files: [[String: String]], endpoint: String, reply: @escaping (Any) -> Void) {
        var results: [Any] = []
        func next(_ index: Int) {
            guard index < files.count else { reply(results); return }
            let file = files[index]
            guard let path = file["path"], chosenFiles.contains(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 256 * 1024 * 1024,
                  var request = network.request(["url": endpoint, "method": "POST", "headers": ["x-filename": file["name"] ?? "Attachment", "content-type": file["type"] ?? "application/octet-stream"]]) else { reply(["error": "Could not read a picked attachment"]); return }
            request.httpBody = data
            network.session.dataTask(with: request) { data, response, error in DispatchQueue.main.async {
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, let value = try? JSONSerialization.jsonObject(with: data) else { reply(["error": error?.localizedDescription ?? "Attachment upload failed"]); return }
                results.append(value); next(index + 1)
            } }.resume()
        }; next(0)
    }
    private func preview(_ options: [String: Any], scene: CraftMacScene?) {
        guard let request = network.request(["url": options["url"] ?? ""]) else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = options["title"] as? String ?? "Preview"; panel.isReleasedWhenClosed = false; panels.append(panel)
        if options["type"] as? String == "video" || options["type"] as? String == "audio" {
            let player = AVPlayerView(); player.controlsStyle = .floating; panel.contentView = player
            let headers = network.session.configuration.httpCookieStorage?.cookies(for: request.url!).map { HTTPCookie.requestHeaderFields(with: $0) } ?? [:]
            player.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])))
            player.player?.play()
        } else {
            let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown; panel.contentView = image
            network.session.dataTask(with: request) { data, _, _ in DispatchQueue.main.async { image.image = data.flatMap(NSImage.init(data:)) } }.resume()
        }
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    private func export(_ options: [String: Any], reply: @escaping (Any) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = options["name"] as? String ?? "Attachment"
        guard panel.runModal() == .OK, let destination = panel.url, let request = network.request(["url": options["url"] ?? ""]) else { reply(false); return }
        network.session.downloadTask(with: request) { location, response, error in
            var saved = false
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let location { do { if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }; try FileManager.default.moveItem(at: location, to: destination); saved = true } catch {} }
            DispatchQueue.main.async { reply(saved) }
        }.resume()
    }
    func notification(_ method: String, options: [String: Any], reply: @escaping (Any) -> Void) {
        guard method == "schedule" else { reply(false); return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent(); content.title = options["title"] as? String ?? appName; content.body = options["body"] as? String ?? ""
        let identifier = options["id"] as? String ?? UUID().uuidString
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in DispatchQueue.main.async { reply(error == nil) } }
    }

    /// Explicit local test mode. Exercises AppKit controls on the main event
    /// loop and snapshots actual view classes, never a DOM or an HTTP driver.
    private func startTestDriver() {
        guard let directory = testDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("action-") && file.pathExtension == "json" && !self.processedActions.contains(file.lastPathComponent) {
                guard let data = try? Data(contentsOf: file), let action = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                self.processedActions.insert(file.lastPathComponent)
                let result = self.testAction(action)
                if let bytes = try? JSONSerialization.data(withJSONObject: result) { try? bytes.write(to: directory.appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: "action-", with: "result-")), options: .atomic) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: self.snapshot()) { try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic) }
        }
    }
    private func testAction(_ action: [String: Any]) -> [String: Any] {
        let kind = action["action"] as? String ?? ""
        if kind == "command", let id = action["id"] as? String { broadcast(id); return ["ok": true] }
        // After this result is written, from the run loop rather than a main-queue block (see applicationShouldTerminate).
        if kind == "quit" { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0); return ["ok": true] }
        if kind == "openURL", let url = (action["url"] as? String).flatMap(URL.init(string:)) { application(NSApp, open: [url]); return ["ok": true] }
        if kind == "appearance" {
            NSApp.appearance = NSAppearance(named: action["value"] as? String == "dark" ? .darkAqua : .aqua)
            appearanceChanged(); return ["ok": true]
        }
        let scene = scenes[action["window"] as? String ?? "main"]
        guard let scene else { return ["ok": false, "error": "Window not found"] }
        if kind == "close" { scene.window.performClose(nil); return ["ok": true] }
        if kind == "resize", let width = number(action["width"]), let height = number(action["height"]), width.isFinite, height.isFinite {
            scene.window.setContentSize(CGSize(width: max(scene.window.minSize.width, width), height: max(scene.window.minSize.height, height)))
            scene.renderer.root.layoutSubtreeIfNeeded()
            return ["ok": true]
        }
        // A control by its testID, driven the way a person would: pressed, typed into, submitted, a key, the pointer over it.
        if ["press", "type", "submit", "key", "hover"].contains(kind) {
            guard let target = action["target"] as? String,
                  let box = scene.renderer.boxes.values.first(where: { ($0.props["testID"] as? String ?? $0.props["testId"] as? String ?? $0.id) == target }) else { return ["ok": false, "error": "No control \(action["target"] ?? "")"] }
            let text = action["text"] as? String ?? ""
            switch kind {
            case "press": if let button = box.control as? NSButton { button.performClick(nil) } else { box.fire("onPress") }
            case "type":
                if let field = box.control as? NSTextField { field.stringValue = text }
                else if let view = (box.control as? NSScrollView)?.documentView as? NSTextView { view.string = text }
                box.input(text)
            case "submit": box.fire("onSubmitEditing", ["text": text, "value": text, "nativeEvent": ["text": text]])
            case "key": box.fire("onKeyPress", ["key": action["key"] as? String ?? "", "shiftKey": action["shift"] as? Bool == true, "text": text])
            default:
                let hovered = action["value"] as? Bool ?? true
                box.hovering = hovered; box.applyAppearance(animated: false)
                box.fire("onHoverChange", ["hovered": hovered])
            }
            return ["ok": true]
        }
        if kind == "screenshot" {
            guard let directory = testDirectory, let view = scene.window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return ["ok": false, "error": "Window cannot be rendered"] }
            scene.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                func invalidate(_ current: NSView) { current.needsDisplay = true; for child in current.subviews { invalidate(child) } }
                invalidate(view); view.displayIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return ["ok": false, "error": "PNG encoding failed"] }
            let destination = directory.appendingPathComponent("screenshot-\(scene.name)-\(CraftMacColor.isDark ? "dark" : "light").png")
            do { try png.write(to: destination, options: .atomic); return ["ok": true, "path": destination.path] }
            catch { return ["ok": false, "error": error.localizedDescription] }
        }
        guard let identifier = action["target"] as? String,
              let box = scene.renderer.boxes.values.first(where: { ($0.props["testID"] as? String ?? $0.props["testId"] as? String ?? $0.id) == identifier }) else { return ["ok": false, "error": "Control not found"] }
        box.scrollToVisible(box.bounds)
        guard box.window?.isVisible == true, !box.isHidden, box.frame.width > 0, box.frame.height > 0 else { return ["ok": false, "error": "Control is not visible"] }
        if let control = box.control as? NSControl, !control.isEnabled { return ["ok": false, "error": "Control is disabled"] }
        switch kind {
        case "key":
            // Return, Tab, Escape and the arrows, as the field editor receives them: they reach the same delegate commands a keystroke does.
            let commands = ["return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)), "escape": #selector(NSResponder.cancelOperation(_:)),
                            "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)), "backspace": #selector(NSResponder.deleteBackward(_:))]
            guard let name = action["value"] as? String, let command = commands[name] else { return ["ok": false, "error": "Unknown key"] }
            let target: NSView? = (box.control as? NSScrollView)?.documentView ?? box.control
            guard let target, scene.window.makeFirstResponder(target) else { return ["ok": false, "error": "Control cannot take focus"] }
            let editor = (target as? NSTextField)?.currentEditor() as? NSTextView ?? target as? NSTextView
            guard let editor else { return ["ok": false, "error": "Not a text input"] }
            editor.doCommand(by: command)
        case "click": if let button = box.control as? NSButton { button.performClick(nil) } else { box.pressed() }
        case "fill":
            let value = action["value"] as? String ?? ""
            if let field = box.control as? NSTextField { field.stringValue = value; box.input(value) }
            else if let text = (box.control as? NSScrollView)?.documentView as? NSTextView { text.string = value; box.input(value) }
            else { return ["ok": false, "error": "Not a text input"] }
        case "pick":
            if let picker = box.control as? NSPopUpButton, let item = picker.itemArray.first(where: { ($0.representedObject as? String) == action["value"] as? String }) { picker.select(item); box.changed() }
            else if let sidebar = box.control as? CraftMacSidebar, let id = action["value"] as? String {
                guard let row = (0..<sidebar.outline.numberOfRows).first(where: { (sidebar.outline.item(atRow: $0) as? CraftMacSidebar.Item)?.id == id }) else { return ["ok": false, "error": "Sidebar item not found"] }
                sidebar.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else { return ["ok": false, "error": "Not a picker"] }
        default: return ["ok": false, "error": "Unsupported test action"]
        }
        return ["ok": true]
    }
    private func snapshot() -> [String: Any] {
        let windows: [[String: Any]] = scenes.values.map { scene in
            let nodes: [[String: Any]] = scene.renderer.boxes.values.map { box in
                var node: [String: Any] = ["id": box.props["testID"] as? String ?? box.props["testId"] as? String ?? box.id, "type": box.kind,
                    "nativeClass": box.control.map { String(describing: type(of: $0)) } ?? "NSView", "visible": !box.isHiddenOrHasHiddenAncestor && box.window?.isVisible == true && !box.visibleRect.isEmpty,
                    "frame": [box.frame.minX, box.frame.minY, box.frame.width, box.frame.height]]
                if let field = box.control as? NSTextField { node["value"] = field.stringValue }
                if let field = box.control as? NSTextField { node["fontSize"] = field.font?.pointSize; node["lines"] = field.maximumNumberOfLines }
                let frame = box.convert(box.bounds, to: scene.renderer.root)
                node["windowFrame"] = [frame.minX, frame.minY, frame.width, frame.height]
                node["style"] = box.style
                node["hiddenAncestor"] = box.isHiddenOrHasHiddenAncestor
                node["visibleRect"] = [box.visibleRect.minX, box.visibleRect.minY, box.visibleRect.width, box.visibleRect.height]
                if let text = (box.control as? NSScrollView)?.documentView as? NSTextView { node["value"] = text.string; node["editorClass"] = NSStringFromClass(type(of: text)) }
                if let button = box.control as? NSButton { node["label"] = button.title; node["enabled"] = button.isEnabled }
                if let picker = box.control as? NSPopUpButton { node["value"] = picker.selectedItem?.representedObject ?? "" }
                if let sidebar = box.control as? CraftMacSidebar { node["value"] = (sidebar.outline.item(atRow: sidebar.outline.selectedRow) as? CraftMacSidebar.Item)?.id ?? "" }
                return node
            }
            func classes(_ view: NSView) -> [String] { [String(describing: type(of: view))] + view.subviews.flatMap(classes) }
            return ["name": scene.name, "title": scene.window.title, "route": scene.runtime.route, "contextClass": String(describing: type(of: scene.runtime.context)), "nodes": nodes, "viewClasses": classes(scene.renderer.root), "errors": scene.runtime.errors]
        }
        let webViews = windows.reduce(0) { count, window in count + ((window["viewClasses"] as? [String] ?? []).filter { $0.contains("WKWebView") || $0 == "WebView" }.count) }
        return ["renderer": "appkit", "scriptEngine": "zig-js", "appearance": CraftMacColor.isDark ? "dark" : "light", "windows": windows, "webViews": webViews]
    }
}

@main struct CraftMacMain {
    static func main() throws {
        // A bundled app is launched by Finder with no arguments: its settings are
        // `Contents/Resources/craft-app.json`, written by the build. A flag on the
        // command line still wins, so a development run can point elsewhere.
        let packaged = Bundle.main.url(forResource: "craft-app", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func argument(_ flag: String, key: String? = nil, fallback: String = "") -> String {
            if let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) { return CommandLine.arguments[index + 1] }
            if let key, let value = packaged[key] { return String(describing: value) }
            return fallback
        }
        let application = CraftMacApplication.shared
        if CommandLine.arguments.contains("--version") { print("craft native macOS renderer 0.0.172 (zig-js)"); return }
        guard let api = URL(string: argument("--api-url", key: "apiUrl")), ["http", "https"].contains(api.scheme ?? ""), api.host != nil else { throw NSError(domain: "Craft", code: 1, userInfo: [NSLocalizedDescriptionKey: "--api-url must name the application's HTTP agent"] ) }
        let bundledScreens = Bundle.main.path(forResource: "native-screen", ofType: "js") ?? ""
        let bundlePath = argument("--native-bundle", fallback: bundledScreens)
        guard !bundlePath.isEmpty else { throw NSError(domain: "Craft", code: 2, userInfo: [NSLocalizedDescriptionKey: "--native-bundle must name a compiled STX bundle"] ) }
        application.bundle = try String(contentsOfFile: bundlePath, encoding: .utf8)
        application.appName = argument("--title", key: "title", fallback: "Craft")
        application.initialRoute = argument("--route", key: "route", fallback: "Main")
        application.titlebarStyle = argument("--titlebar-style", key: "titlebarStyle", fallback: "standard")
        // `18,18` on the command line; `[18, 18]` in craft-app.json.
        application.dockMenu = packaged["dockMenu"] as? [[String: Any]] ?? []
        let lights = argument("--traffic-lights", key: "trafficLights").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " []"))) }
        if lights.count == 2 { application.trafficLights = lights }
        application.requiresSession = !CommandLine.arguments.contains("--no-session") && packaged["session"] as? Bool != false
        for (flag, key) in [("--width", "width"), ("--height", "height"), ("--min-width", "minWidth"), ("--min-height", "minHeight")] {
            if let value = Double(argument(flag, key: key)), value.isFinite, value > 0 { application.mainWindowOptions[key] = value }
        }
        application.network = CraftMacNetwork(base: api)
        let testDirectory = argument("--test-dir")
        if !testDirectory.isEmpty { application.testDirectory = URL(fileURLWithPath: testDirectory, isDirectory: true) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = application; app.run()
    }
}
