import AppKit
import ZigJS
import Foundation
import Security

/// `CRAFT_TRACE=1`: launch and render phases on stderr, as `[craft trace] <ms since the process
/// started> <phase>`, with a span's own duration after it. Off, every call is one boolean test.
enum CraftTrace {
    static let enabled = ProcessInfo.processInfo.environment["CRAFT_TRACE"].map { !$0.isEmpty && $0 != "0" } ?? false
    /// When the kernel started this process, so the first mark already counts dyld and Swift start-up.
    private static let processStart: Double = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        return Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    }()
    private static func since() -> Double { (Date().timeIntervalSince1970 - processStart) * 1000 }
    static func mark(_ phase: @autoclosure () -> String) {
        guard enabled else { return }
        fputs(String(format: "[craft trace] %8.1f %@\n", since(), phase()), stderr)
    }
    /// Times `work`; spans under `atLeast` milliseconds are left out, so per-message spans stay readable.
    static func span<T>(_ phase: @autoclosure () -> String, atLeast: Double = 0, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = since()
        defer {
            let end = since()
            if end - start >= atLeast { fputs(String(format: "[craft trace] %8.1f %@ (%.1f ms)\n", end, phase(), end - start), stderr) }
        }
        return try work()
    }
}

/// The macOS Keychain behind `craft.secureStorage`: one generic password per
/// key, under a service named for the app. The data-protection keychain is
/// used when the app is signed for it (a Mac App Store build, which carries
/// the application-identifier / keychain-access-groups entitlements); an
/// unsigned or ad-hoc development build has none and uses the login keychain,
/// so the same code runs both.
enum CraftMacKeychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "dev.craft.native") + ".secure" }
    /// Whether this process carries the keychain-access-groups entitlement, which
    /// is what the data-protection keychain requires. Decided once, from the
    /// signature, so reads and writes always use the same keychain: a failure
    /// based fallback let a write land in the login keychain and the next
    /// launch read an empty data-protection one.
    private static var dataProtection: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
            || SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()
    private static func base(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
    private static func run(_ account: String?, _ body: ([String: Any]) -> OSStatus) -> OSStatus { body(base(account)) }
    static func get(_ account: String) -> String? {
        var result: AnyObject?
        let status = run(account) { query in
            var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            // Never stop the main thread on a Keychain permission prompt: an older item's
            // access list does not trust a rebuilt app, and the prompt (with no window behind
            // it) would hang the launch. With interaction off the read fails instead, the
            // user signs in again, and the new item is trusted. Neither LAContext nor
            // kSecUseAuthenticationUI stops a login-keychain access-list prompt; this does.
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    @discardableResult static func set(_ account: String, _ value: String) -> Bool {
        _ = run(account) { SecItemDelete($0 as CFDictionary) }
        let status = run(account) { query in
            var query = query; query[kSecValueData as String] = Data(value.utf8); query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
    @discardableResult static func remove(_ account: String?) -> Bool {
        let status = run(account) { SecItemDelete($0 as CFDictionary) }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The thread a window's JavaScript runs on, with a run loop for its timers and messages. A zig-js
/// context belongs to the thread that made it, so the context is made here and every call into it
/// runs here. AppKit keeps the main thread: a screen evaluates its bundle while the app is still
/// connecting to the window server, and a long render in JavaScript no longer stalls scrolling.
final class CraftMacScriptThread: Thread {
    private var loop: CFRunLoop!
    private let started = DispatchSemaphore(value: 0)
    override init() {
        super.init()
        name = "craft.script"; qualityOfService = .userInteractive
        // The main thread's size: a parser or a deep render recurses as far on this one.
        stackSize = 16 << 20
    }
    override func main() {
        loop = CFRunLoopGetCurrent()
        // A run loop with nothing to wait on returns at once; this source keeps it running until `stop`.
        var context = CFRunLoopSourceContext()
        CFRunLoopAddSource(loop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
        started.signal()
        CFRunLoopRun()
    }
    /// Starts the thread and returns once its run loop can take work.
    func begin() { start(); started.wait() }
    /// Runs `work` on this thread, after the work already asked for.
    func run(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { autoreleasepool(invoking: work) }
        CFRunLoopWakeUp(loop)
    }
    /// Runs `work` on this thread `seconds` from now, unless the returned timer is invalidated first.
    func after(_ seconds: Double, _ work: @escaping () -> Void) -> CFRunLoopTimer {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + seconds, 0, 0, 0) { _ in autoreleasepool(invoking: work) }!
        CFRunLoopAddTimer(loop, timer, .defaultMode)
        return timer
    }
}

/// One zig-js context per STX window, on its own thread. No DOM and no browser view.
final class CraftMacRuntime {
    /// What this host offers a screen. `web` (tabs in a `<WebView>`) only in a build made with `webkit: true`.
    static var capabilities: [String] {
        var list = ["desktop", "fetch", "eventStream", "storage", "secureStorage", "clipboard", "dialog", "linking", "haptics", "notifications"]
        #if CRAFT_WEBKIT
        list.append("web")
        #endif
        return list
    }
    let route: String
    let network: CraftMacNetwork
    private let thread = CraftMacScriptThread()
    // Script thread only: the context and what the screen asked of it.
    private var context: ZigJSContext?
    private var timers: [Int: CFRunLoopTimer] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var stopped = false
    // Main thread only.
    private(set) weak var scene: CraftMacScene?
    /// What the screen drew or asked of AppKit before its window existed, done when it attaches.
    private var held: [() -> Void] = []
    private var disposed = false
    var errors: [String] = []
    let document = CraftNativeMutationDocument()

    /// Starts the screen's thread and makes its context there. `colorScheme` is the appearance the screen
    /// starts with, read by the caller: AppKit's appearance can only be asked on the main thread.
    init(route: String, params: [String: Any], network: CraftMacNetwork, colorScheme: String) {
        self.route = route
        self.network = network
        thread.begin()
        thread.run { self.setUp(params: params, colorScheme: colorScheme) }
    }

    private func setUp(params: [String: Any], colorScheme: String) {
        // zig-js's precise collector, not the default arena: an arena frees nothing until the
        // context goes, so a window open all day kept every object its screen ever made.
        let created = ZJSGlobalContextCreateGarbageCollected(true)!
        defer { JSGlobalContextRelease(created) }
        let context = ZigJSContext(jsGlobalContextRef: created)!
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            let message = value?.objectForKeyedSubscript("message")?.toString() ?? "Native script failed"
            let stack = value?.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.report(message)
            fputs("[craft native] \(message)\n\(stack)\n", stderr)
        }
        let post: @convention(block) (String) -> Void = { [weak self] text in self?.receive(text) }
        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
            guard let self, !self.stopped else { return }
            self.timers[id] = self.thread.after(max(0, min(delay.isFinite ? delay : 0, 2_147_483_647)) / 1000) { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil, !self.stopped else { return }
                CraftTrace.span("js timer", atLeast: 1) {
                    self.context?.objectForKeyedSubscript("__craftNativeFireTimer")?.call(withArguments: [id])
                    self.context.map { ZJSContextRunMicrotasks($0) }
                }
            }
        }
        let cancel: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id).map(CFRunLoopTimerInvalidate) }
        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            if level == "error" { self?.report(text) }
            fputs("[stx \(level)] \(text)\n", stderr)
        }
        // The synchronous halves of craft.storage and craft.secureStorage
        // (getSync/setSync), which the stx runtime keeps when the host has them.
        // UserDefaults and the Keychain answer on any thread.
        let storageGet: @convention(block) (String) -> String? = { key in
            guard let value = UserDefaults.standard.object(forKey: "craft.native." + key) else { return nil }
            if let text = value as? String { return text }
            return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }
        }
        let storageSet: @convention(block) (String, String) -> Void = { key, json in UserDefaults.standard.set(json, forKey: "craft.native." + key) }
        let secureGet: @convention(block) (String) -> String? = { key in CraftMacKeychain.get(key) }
        context.setObject(storageGet, forKeyedSubscript: "craftNativeStorageGet" as NSString)
        context.setObject(storageSet, forKeyedSubscript: "craftNativeStorageSet" as NSString)
        context.setObject(secureGet, forKeyedSubscript: "craftNativeSecureGet" as NSString)
        context.setObject(post, forKeyedSubscript: "craftNativePostMessage" as NSString)
        context.setObject(schedule, forKeyedSubscript: "craftNativeScheduleTimer" as NSString)
        context.setObject(cancel, forKeyedSubscript: "craftNativeCancelTimer" as NSString)
        context.setObject(log, forKeyedSubscript: "craftNativeLog" as NSString)
        context.setObject(route, forKeyedSubscript: "__stxNativeRoute" as NSString)
        context.setObject(params, forKeyedSubscript: "__stxNativeParams" as NSString)
        let info = Bundle.main.infoDictionary ?? [:]
        let bridge: [String: Any] = [
            "platform": "macos", "mutationProtocolVersion": 1, "capabilityProtocolVersion": 1,
            "capabilityTimeoutMs": 30_000, "capabilities": Self.capabilities,
            "sessionTokenKey": "auth.token",
            "initialAppState": "active", "colorScheme": colorScheme,
            "appURL": network.base.absoluteString, "appVersion": info["CFBundleShortVersionString"] as? String ?? "", "appBuild": info["CFBundleVersion"] as? String ?? ""
        ]
        let bridgeJSON = String(data: try! JSONSerialization.data(withJSONObject: bridge), encoding: .utf8)!
        context.evaluateScript("""
        globalThis.__stxNativeCallback = null;
        globalThis.__stxNativeBridge = \(bridgeJSON);
        __stxNativeBridge.postMessage = function(text) { craftNativePostMessage(text); };
        __stxNativeBridge.onMessage = function(callback) { globalThis.__stxNativeCallback = callback; };
        globalThis.craft = globalThis.craft || {};
        craft.storage = {
            getSync: function(key) { var raw = craftNativeStorageGet(String(key)); if (raw === null || raw === undefined) return null; try { return JSON.parse(raw); } catch (e) { return raw; } },
            setSync: function(key, value) { craftNativeStorageSet(String(key), JSON.stringify(value === undefined ? null : value)); }
        };
        craft.secureStorage = { getSync: function(key) { var value = craftNativeSecureGet(String(key)); return value === null || value === undefined ? null : value; } };
        globalThis.console = {};
        ['log','info','warn','error','debug'].forEach(function(level) {
            console[level] = function() { craftNativeLog(level, Array.from(arguments).map(String).join(' ')); };
        });
        (function() {
            var timers = new Map(), sequence = 0;
            globalThis.setTimeout = function(callback, delay) {
                var args = Array.prototype.slice.call(arguments, 2), id = ++sequence;
                timers.set(id, function() { if (typeof callback === 'function') callback.apply(undefined, args); });
                craftNativeScheduleTimer(id, Number(delay) || 0); return id;
            };
            globalThis.clearTimeout = function(id) { if (timers.delete(id)) craftNativeCancelTimer(id); };
            globalThis.__craftNativeFireTimer = function(id) {
                var callback = timers.get(id); if (!callback) return; timers.delete(id); callback();
            };
            var intervals = new Map();
            globalThis.setInterval = function(callback, delay) {
                var id = ++sequence, args = Array.prototype.slice.call(arguments, 2);
                function tick() { if (!intervals.has(id)) return; intervals.set(id, setTimeout(tick, Math.max(1, Number(delay) || 0))); callback.apply(undefined,args); }
                intervals.set(id, setTimeout(tick, Math.max(1, Number(delay) || 0))); return id;
            };
            globalThis.clearInterval = function(id) { clearTimeout(intervals.get(id)); intervals.delete(id); };
        })();
        """)
    }

    /// Evaluates the screen's bundle on its thread, knowing the window's content size first: `md:`/`lg:`
    /// classes and `matchMedia` are right on the first frame, before the window exists.
    func load(_ bundle: String, viewport: CGSize) {
        thread.run {
            guard let context = self.context else { return }
            context.evaluateScript("__stxNativeBridge.viewportWidth = \(Double(viewport.width)); __stxNativeBridge.viewportHeight = \(Double(viewport.height));")
            self.startProfileIfAsked()
            CraftTrace.span("bundle evaluated") { context.evaluateScript(bundle); ZJSContextRunMicrotasks(context) }
        }
    }

    /// Evaluates `script` in the screen's context, after the messages already sent to it.
    func evaluate(_ script: String) { thread.run { _ = self.context?.evaluateScript(script) } }

    /// A script error, kept for the test driver's snapshot, which reads it on the main thread.
    private func report(_ message: String) { DispatchQueue.main.async { self.errors.append(message) } }

    /// The screen's window exists: what the screen drew before it is drawn now, into its views.
    func attach(_ scene: CraftMacScene) {
        self.scene = scene
        let waiting = held; held.removeAll()
        waiting.forEach { $0() }
    }
    /// On the main thread: `work` now if the window exists, else when it attaches.
    private func whenAttached(_ work: @escaping () -> Void) {
        guard !disposed else { return }
        if scene != nil { work() } else { held.append(work) }
    }

    /// `CRAFT_JS_PROFILE=<file>`: sample this screen's JavaScript from the moment its bundle loads,
    /// for `CRAFT_JS_PROFILE_MS` milliseconds (5000, every `CRAFT_JS_PROFILE_INTERVAL_US`, 1000),
    /// and write it as Chrome's `.cpuprofile` (DevTools and speedscope open it). A window other
    /// than Main writes beside it, its route in the name.
    private func startProfileIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CRAFT_JS_PROFILE"], !path.isEmpty, let ref = context?.jsGlobalContextRef else { return }
        guard ZJSContextStartCPUProfile(ref, UInt32(env["CRAFT_JS_PROFILE_INTERVAL_US"] ?? "") ?? 0) else { return }
        let seconds = (Double(env["CRAFT_JS_PROFILE_MS"] ?? "") ?? 5000) / 1000
        _ = thread.after(seconds) { [weak self] in self?.writeProfile(to: path) }
    }

    private func writeProfile(to path: String) {
        guard !stopped, let ref = context?.jsGlobalContextRef, let json = ZJSContextStopCPUProfile(ref) else { return }
        defer { JSStringRelease(json) }
        let size = JSStringGetMaximumUTF8CStringSize(json)
        var bytes = [CChar](repeating: 0, count: size)
        JSStringGetUTF8CString(json, &bytes, size)
        let url = URL(fileURLWithPath: path)
        let target = route == "Main" ? url : url.deletingPathExtension().appendingPathExtension("\(route).cpuprofile")
        do {
            try String(cString: bytes).write(to: target, atomically: true, encoding: .utf8)
            fputs("[craft] JavaScript profile written to \(target.path)\n", stderr)
        }
        catch { fputs("[craft] could not write the JavaScript profile to \(target.path): \(error)\n", stderr) }
    }

    /// Unmounts the screen and stops its thread. Waits (a little) for the unmount, as a quit would.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        #if CRAFT_WEBKIT
        CraftMacWebTabs.shared.closeAll(owner: self)
        #endif
        network.cancelStreams(owner: self)
        let done = DispatchSemaphore(value: 0)
        thread.run {
            self.context?.objectForKeyedSubscript("__stxNativeUnmount")?.call(withArguments: [])
            self.stopped = true
            self.timers.values.forEach(CFRunLoopTimerInvalidate); self.timers.removeAll()
            self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll()
            // Released on the thread that made it.
            self.context = nil
            done.signal()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// A message for the screen, from any thread: delivered on its thread, in the order sent.
    func send(_ type: String, _ payload: [String: Any], correlation: String? = nil) {
        var message: [String: Any] = ["id": UUID().uuidString, "type": type, "timestamp": Date().timeIntervalSince1970 * 1000, "source": "native", "payload": payload]
        if let correlation { message["correlationId"] = correlation }
        guard let bytes = try? JSONSerialization.data(withJSONObject: message), let text = String(data: bytes, encoding: .utf8) else { return }
        thread.run { [weak self] in
            guard let self, !self.stopped, let context = self.context else { return }
            CraftTrace.span("js \(type)", atLeast: 1) {
                context.objectForKeyedSubscript("__stxNativeCallback")?.call(withArguments: [text])
                ZJSContextRunMicrotasks(context)
            }
        }
    }

    func event(_ id: String?, payload: [String: Any] = [:]) {
        guard let id, !id.isEmpty else { return }
        send("EVENT", ["handlerId": id, "nativeEvent": payload])
    }

    /// A message from the screen, on its thread. Network requests start here, so a screen's first fetch
    /// leaves while AppKit is still launching; whatever draws or needs AppKit goes to the main thread.
    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch message["type"] as? String {
        case "RENDER", "MUTATE": DispatchQueue.main.async { self.whenAttached { self.handle(message) } }
        case "API_REQUEST":
            guard let id = message["id"] as? String else { return }
            guard payload["version"] as? Int == 1 else { fail(id, "UNSUPPORTED_VERSION", "Native capability version must be 1"); return }
            let module = payload["module"] as? String ?? "", method = payload["method"] as? String ?? "", args = payload["args"] as? [Any] ?? []
            switch module {
            case "Network": fetch(id, method, args)
            case "Storage", "SecureStorage": store(id, module, method, args)
            default: DispatchQueue.main.async { self.whenAttached { self.perform(id, module, method, args) } }
            }
        case "API_CANCEL":
            if let id = payload["requestId"] as? String { tasks.removeValue(forKey: id)?.cancel() }
        default: break
        }
    }

    /// A tree or a batch, on the main thread.
    private func handle(_ message: [String: Any]) {
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch message["type"] as? String {
        case "RENDER":
            guard let tree = payload["document"] as? [String: Any] else { return }
            CraftTrace.span("  native RENDER") {
                document.replace(with: tree)
                scene?.renderer.render(tree)
            }
        case "MUTATE":
            do { try CraftTrace.span("  native MUTATE \((payload["mutations"] as? [Any])?.count ?? 0)", atLeast: 1) {
                let result = try document.apply(payload)
                // Drawn where it changed; the whole tree only when the batch reshaped it.
                if result.requiresFullRender || scene?.renderer.update(result.affectedNodeIds, parentOf: document.parentId(of:), node: document.node) != true,
                   let tree = result.document { scene?.renderer.render(tree) }
                send("MUTATION_ACK", ["version": 1, "batchId": result.batchId, "revision": result.revision])
            } } catch let error as CraftNativeMutationFailure {
                send("MUTATION_ERROR", ["version": 1, "batchId": payload["batchId"] ?? "", "code": error.code, "message": error.message])
            } catch { errors.append(error.localizedDescription) }
        default: break
        }
    }

    /// `craft.session.onChange`: the sign-in token moved, in any window.
    private func sessionChanged(_ key: String, token: String?, previous: String?) {
        guard key == "auth.token", token != previous else { return }
        DispatchQueue.main.async {
            for scene in CraftMacApplication.shared.scenes.values {
                scene.runtime.send("SESSION_CHANGED", ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()])
            }
        }
    }

    /// An answer to the screen's request `id`, from any thread.
    func answer(_ id: String, _ value: Any = NSNull()) {
        thread.run { self.tasks.removeValue(forKey: id) }
        send("API_RESPONSE", ["version": 1, "requestId": id, "data": value], correlation: id)
    }
    func fail(_ id: String, _ code: String, _ message: String) {
        thread.run { self.tasks.removeValue(forKey: id) }
        send("API_ERROR", ["version": 1, "requestId": id, "code": code, "message": message], correlation: id)
    }

    /// `Network` requests, on the script thread. Their answers come back on the network's own queue.
    private func fetch(_ id: String, _ method: String, _ args: [Any]) {
        let options = args.first as? [String: Any] ?? [:]
        if method == "cancelStream" { network.cancelStream(args.first as? String ?? "", owner: self); answer(id); return }
        guard let request = network.request(options) else { fail(id, "INVALID_ARGUMENT", "Network.fetch requires an HTTP URL"); return }
        if method == "stream" {
            network.stream(request, id: options["id"] as? String ?? id, owner: self, requestId: id)
            return
        }
        guard method == "fetch" else { fail(id, "UNSUPPORTED_METHOD", method); return }
        let task = network.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.fail(id, "NETWORK_ERROR", error.localizedDescription); return }
            guard let http = response as? HTTPURLResponse else { self.fail(id, "NETWORK_ERROR", "Invalid HTTP response"); return }
            if (data?.count ?? 0) > 32 * 1024 * 1024 { self.fail(id, "RESPONSE_TOO_LARGE", "Response exceeds 32 MB"); return }
            self.answer(id, CraftMacNetwork.response(http, original: request.url, body: String(decoding: data ?? Data(), as: UTF8.self)))
        }
        tasks[id] = task; network.resume(task)
    }

    /// `Storage` and `SecureStorage`, on the script thread: UserDefaults and the Keychain answer on any.
    private func store(_ id: String, _ module: String, _ method: String, _ args: [Any]) {
        switch module {
        case "SecureStorage":
            if method == "clear" { CraftMacKeychain.remove(nil); answer(id, true); return }
            guard let key = args.first as? String, !key.isEmpty else { fail(id, "INVALID_ARGUMENT", "Secure storage needs a non-empty key"); return }
            switch method {
            case "get": answer(id, CraftMacKeychain.get(key) ?? NSNull())
            case "set":
                guard args.count == 2, let value = args[1] as? String else { fail(id, "INVALID_ARGUMENT", "SecureStorage.set needs a key and string value"); return }
                let previous = CraftMacKeychain.get(key)
                guard CraftMacKeychain.set(key, value) else { fail(id, "SECURE_STORAGE_ERROR", "Secure storage could not be written"); return }
                sessionChanged(key, token: value, previous: previous); answer(id, true)
            case "remove":
                let previous = CraftMacKeychain.get(key)
                guard CraftMacKeychain.remove(key) else { fail(id, "SECURE_STORAGE_ERROR", "Secure storage could not be removed"); return }
                sessionChanged(key, token: nil, previous: previous); answer(id, true)
            default: fail(id, "UNKNOWN_ACTION", "Unsupported SecureStorage method")
            }
        case "Storage":
            let prefix = "craft.native."
            let key = prefix + (args.first as? String ?? "")
            switch method {
            case "get": answer(id, UserDefaults.standard.object(forKey: key) ?? NSNull())
            case "set": if args.count > 1 { UserDefaults.standard.set(args[1], forKey: key) }; answer(id)
            case "remove": UserDefaults.standard.removeObject(forKey: key); answer(id)
            case "keys": answer(id, UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            default: fail(id, "UNSUPPORTED_METHOD", method)
            }
        default: break
        }
    }

    /// Every other capability, on the main thread.
    private func perform(_ id: String, _ module: String, _ method: String, _ args: [Any]) {
        guard !disposed else { return }
        let options = args.first as? [String: Any] ?? [:]
        switch module {
        case "Clipboard":
            if method == "read" { answer(id, NSPasteboard.general.string(forType: .string) ?? "") }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(args.first as? String ?? "", forType: .string); answer(id) }
        case "Haptics": NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default); answer(id)
        case "Dialog":
            let alert = NSAlert(); alert.messageText = options["title"] as? String ?? ""; alert.informativeText = options["message"] as? String ?? options["body"] as? String ?? ""
            alert.addButton(withTitle: options["confirmText"] as? String ?? "OK")
            if method == "confirm" { alert.addButton(withTitle: options["cancelText"] as? String ?? "Cancel") }
            let accepted = alert.runModal() == .alertFirstButtonReturn
            answer(id, method == "confirm" ? accepted : NSNull())
        case "Linking":
            guard let text = args.first as? String, let url = URL(string: text), let scheme = url.scheme, ["https", "http", "imessage", "sms", "mailto", "x-apple.systempreferences"].contains(scheme) else { fail(id, "INVALID_ARGUMENT", "Unsupported URL scheme"); return }
            answer(id, method == "canOpenURL" ? NSWorkspace.shared.urlForApplication(toOpen: url) != nil : NSWorkspace.shared.open(url))
        #if CRAFT_WEBKIT
        case "Web": CraftMacWebTabs.shared.perform(method, args, owner: self, answer: { [weak self] value in self?.answer(id, value) }, fail: { [weak self] code, message in self?.fail(id, code, message) })
        #endif
        case "Desktop": CraftMacApplication.shared.perform(method, args: args, scene: scene, reply: { [weak self] value in self?.answer(id, value) })
        case "Notifications": CraftMacApplication.shared.notification(method, options: options, reply: { [weak self] value in self?.answer(id, value) })
        default: fail(id, "CAPABILITY_DISABLED", "Unsupported native capability \(module).\(method)")
        }
    }
}

/// A session shared by native windows, with an isolated, HttpOnly cookie store.
final class CraftMacNetwork: NSObject, URLSessionDataDelegate {
    let base: URL
    /// Where the session answers: a queue of its own rather than the main one, so a screen hears a
    /// response while AppKit is busy (or still launching). Stream bookkeeping happens on it too.
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "craft.network"; queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()
    private(set) var session: URLSession!
    private struct Stream { let id: String; weak var owner: CraftMacRuntime?; let requestId: String; var opened: Bool = false; var carry = Data() }
    private var streams: [Int: Stream] = [:]
    /// Requests made before the agent issued the session cookie, sent once it has (`authorize`).
    private let gate = NSLock()
    private var authorized = true
    private var held: [URLSessionTask] = []
    init(base: URL) {
        self.base = base
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    /// Apps that ship their own agent (Attic) hand out a session cookie at `/native/session`. It is asked
    /// for at once, while the window opens and the screen starts, and every request waits for it: the
    /// agent answers nothing else without it. The cookie is HttpOnly and stays in this session, shared
    /// by native windows; it never reaches JavaScript. `answered` gets nil, or why there is no session.
    func authorize(_ answered: @escaping (String?) -> Void) {
        gate.lock(); authorized = false; gate.unlock()
        session.dataTask(with: URLRequest(url: base.appendingPathComponent("native/session"))) { [self] _, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                // What waits stays unsent: the app shows why and quits.
                answered(error?.localizedDescription ?? "The local agent did not issue a native session."); return
            }
            gate.lock(); authorized = true; let waiting = held; held.removeAll(); gate.unlock()
            waiting.forEach { $0.resume() }
            answered(nil)
        }.resume()
    }
    /// Sends `task` now, or once the session is issued. Every request to the agent goes through here.
    func resume(_ task: URLSessionTask) {
        gate.lock()
        if authorized { gate.unlock(); task.resume(); return }
        held.append(task); gate.unlock()
    }
    func request(_ options: [String: Any]) -> URLRequest? {
        guard let address = options["url"] as? String, let url = URL(string: address, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        for (key, value) in options["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        return request
    }
    static func response(_ response: HTTPURLResponse, original: URL?, body: String = "") -> [String: Any] {
        ["url": response.url?.absoluteString ?? "", "status": response.statusCode,
         "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode), "body": body,
         "redirected": response.url != original,
         "headers": Dictionary(response.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }, uniquingKeysWith: { _, value in value })]
    }
    func stream(_ request: URLRequest, id: String, owner: CraftMacRuntime, requestId: String) {
        let task = session.dataTask(with: request)
        queue.addOperation { self.streams[task.taskIdentifier] = Stream(id: id, owner: owner, requestId: requestId); self.resume(task) }
    }
    func cancelStream(_ id: String, owner: CraftMacRuntime) {
        queue.addOperation {
            let identifiers = self.streams.filter { $0.value.id == id && $0.value.owner === owner }.map(\.key)
            self.session.getAllTasks { tasks in self.queue.addOperation { for task in tasks where identifiers.contains(task.taskIdentifier) { self.streams.removeValue(forKey: task.taskIdentifier); task.cancel() } } }
        }
    }
    func cancelStreams(owner: CraftMacRuntime) { queue.addOperation { for stream in self.streams.values where stream.owner === owner { self.cancelStream(stream.id, owner: owner) } } }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var stream = streams[dataTask.taskIdentifier] else { completionHandler(.allow); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); stream.owner?.fail(stream.requestId, "NETWORK_ERROR", "Invalid stream response"); return }
        stream.opened = true; streams[dataTask.taskIdentifier] = stream
        stream.owner?.answer(stream.requestId, Self.response(http, original: dataTask.originalRequest?.url))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var stream = streams[dataTask.taskIdentifier] else { return }
        let bytes = [UInt8](stream.carry + data)
        var cut = bytes.count, back = 1
        while back <= min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if length > back { cut -= back }
            break
        }
        stream.carry = Data(bytes[cut...]); streams[dataTask.taskIdentifier] = stream
        let text = String(decoding: bytes[..<cut], as: UTF8.self)
        if !text.isEmpty { stream.owner?.send("NETWORK_STREAM", ["id": stream.id, "chunk": text]) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let stream = streams.removeValue(forKey: task.taskIdentifier) else { return }
        if !stream.opened { stream.owner?.fail(stream.requestId, "NETWORK_ERROR", error?.localizedDescription ?? "Stream failed") }
        else if let error { stream.owner?.send("NETWORK_STREAM", ["id": stream.id, "error": error.localizedDescription]) }
        else { stream.owner?.send("NETWORK_STREAM", ["id": stream.id, "done": true]) }
    }
}
