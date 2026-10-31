import AppKit
import ZigJS
import Foundation
import Security
import LocalAuthentication

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
            // Never stop the main thread on a Keychain permission prompt (a rebuilt,
            // differently signed app is not trusted by an older item's access list):
            // the read fails, the user signs in again, and the new item is trusted.
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
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

/// One zig-js context per STX window. No DOM and no browser view.
final class CraftMacRuntime {
    let context = ZigJSContext()!
    let route: String
    let network: CraftMacNetwork
    weak var scene: CraftMacScene?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var disposed = false
    var errors: [String] = []
    let document = CraftNativeMutationDocument()

    init(route: String, params: [String: Any], network: CraftMacNetwork) {
        self.route = route
        self.network = network
        context.exceptionHandler = { [weak self] _, value in
            let message = value?.objectForKeyedSubscript("message")?.toString() ?? "Native script failed"
            let stack = value?.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.errors.append(message)
            fputs("[craft native] \(message)\n\(stack)\n", stderr)
        }
        let post: @convention(block) (String) -> Void = { [weak self] text in self?.receive(text) }
        let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
            guard let self, !self.disposed else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil, !self.disposed else { return }
                self.context.objectForKeyedSubscript("__craftNativeFireTimer")?.call(withArguments: [id])
                ZJSContextRunMicrotasks(self.context)
            }
            self.timers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, min(delay.isFinite ? delay : 0, 2_147_483_647)) / 1000, execute: work)
        }
        let cancel: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            if level == "error" { self?.errors.append(text) }
            fputs("[stx \(level)] \(text)\n", stderr)
        }
        // The synchronous halves of craft.storage and craft.secureStorage
        // (getSync/setSync), which the stx runtime keeps when the host has them.
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
            "capabilityTimeoutMs": 30_000, "capabilities": ["desktop", "fetch", "eventStream", "storage", "secureStorage", "clipboard", "dialog", "linking", "haptics", "notifications"],
            "sessionTokenKey": "auth.token",
            "initialAppState": "active", "colorScheme": CraftMacColor.isDark ? "dark" : "light",
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

    func load(_ bundle: String) { context.evaluateScript(bundle); ZJSContextRunMicrotasks(context) }

    func dispose() {
        guard !disposed else { return }
        context.objectForKeyedSubscript("__stxNativeUnmount")?.call(withArguments: [])
        disposed = true
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        network.cancelStreams(owner: self)
    }

    func send(_ type: String, _ payload: [String: Any], correlation: String? = nil) {
        guard !disposed else { return }
        var message: [String: Any] = ["id": UUID().uuidString, "type": type, "timestamp": Date().timeIntervalSince1970 * 1000, "source": "native", "payload": payload]
        if let correlation { message["correlationId"] = correlation }
        guard let bytes = try? JSONSerialization.data(withJSONObject: message), let text = String(data: bytes, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed else { return }
            self.context.objectForKeyedSubscript("__stxNativeCallback")?.call(withArguments: [text])
            ZJSContextRunMicrotasks(self.context)
        }
    }

    func event(_ id: String?, payload: [String: Any] = [:]) {
        guard let id, !id.isEmpty else { return }
        send("EVENT", ["handlerId": id, "nativeEvent": payload])
    }

    private func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch message["type"] as? String {
        case "RENDER":
            guard let tree = payload["document"] as? [String: Any] else { return }
            document.replace(with: tree)
            scene?.renderer.render(tree)
        case "MUTATE":
            do {
                let result = try document.apply(payload)
                if let tree = result.document { scene?.renderer.render(tree) }
                send("MUTATION_ACK", ["version": 1, "batchId": result.batchId, "revision": result.revision])
            } catch let error as CraftNativeMutationFailure {
                send("MUTATION_ERROR", ["version": 1, "batchId": payload["batchId"] ?? "", "code": error.code, "message": error.message])
            } catch { errors.append(error.localizedDescription) }
        case "API_REQUEST":
            guard let id = message["id"] as? String else { return }
            guard payload["version"] as? Int == 1 else { fail(id, "UNSUPPORTED_VERSION", "Native capability version must be 1"); return }
            perform(id, payload["module"] as? String ?? "", payload["method"] as? String ?? "", payload["args"] as? [Any] ?? [])
        case "API_CANCEL":
            if let id = payload["requestId"] as? String { tasks.removeValue(forKey: id)?.cancel() }
        default: break
        }
    }

    /// `craft.session.onChange`: the sign-in token moved, in any window.
    private func sessionChanged(_ key: String, token: String?, previous: String?) {
        guard key == "auth.token", token != previous else { return }
        for scene in CraftMacApplication.shared.scenes.values {
            scene.runtime.send("SESSION_CHANGED", ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()])
        }
    }

    func answer(_ id: String, _ value: Any = NSNull()) {
        tasks.removeValue(forKey: id)
        send("API_RESPONSE", ["version": 1, "requestId": id, "data": value], correlation: id)
    }
    func fail(_ id: String, _ code: String, _ message: String) {
        tasks.removeValue(forKey: id)
        send("API_ERROR", ["version": 1, "requestId": id, "code": code, "message": message], correlation: id)
    }

    private func perform(_ id: String, _ module: String, _ method: String, _ args: [Any]) {
        let options = args.first as? [String: Any] ?? [:]
        switch module {
        case "Network":
            if method == "cancelStream" { network.cancelStream(args.first as? String ?? "", owner: self); answer(id); return }
            guard let request = network.request(options) else { fail(id, "INVALID_ARGUMENT", "Network.fetch requires an HTTP URL"); return }
            if method == "stream" {
                network.stream(request, id: options["id"] as? String ?? id, owner: self, requestId: id)
                return
            }
            guard method == "fetch" else { fail(id, "UNSUPPORTED_METHOD", method); return }
            let task = network.session.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, !self.disposed else { return }
                    if let error { self.fail(id, "NETWORK_ERROR", error.localizedDescription); return }
                    guard let http = response as? HTTPURLResponse else { self.fail(id, "NETWORK_ERROR", "Invalid HTTP response"); return }
                    if (data?.count ?? 0) > 32 * 1024 * 1024 { self.fail(id, "RESPONSE_TOO_LARGE", "Response exceeds 32 MB"); return }
                    self.answer(id, CraftMacNetwork.response(http, original: request.url, body: String(decoding: data ?? Data(), as: UTF8.self)))
                }
            }
            tasks[id] = task; task.resume()
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
        case "Desktop": CraftMacApplication.shared.perform(method, args: args, scene: scene, reply: { [weak self] value in self?.answer(id, value) })
        case "Notifications": CraftMacApplication.shared.notification(method, options: options, reply: { [weak self] value in self?.answer(id, value) })
        default: fail(id, "CAPABILITY_DISABLED", "Unsupported native capability \(module).\(method)")
        }
    }
}

/// A session shared by native windows, with an isolated, HttpOnly cookie store.
final class CraftMacNetwork: NSObject, URLSessionDataDelegate {
    let base: URL
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private struct Stream { let id: String; weak var owner: CraftMacRuntime?; let requestId: String; var opened: Bool = false; var carry = Data() }
    private var streams: [Int: Stream] = [:]
    init(base: URL) { self.base = base }
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
        streams[task.taskIdentifier] = Stream(id: id, owner: owner, requestId: requestId)
        task.resume()
    }
    func cancelStream(_ id: String, owner: CraftMacRuntime) {
        let identifiers = streams.filter { $0.value.id == id && $0.value.owner === owner }.map(\.key)
        session.getAllTasks { tasks in DispatchQueue.main.async { for task in tasks where identifiers.contains(task.taskIdentifier) { self.streams.removeValue(forKey: task.taskIdentifier); task.cancel() } } }
    }
    func cancelStreams(owner: CraftMacRuntime) { for stream in streams.values where stream.owner === owner { cancelStream(stream.id, owner: owner) } }
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
