import Foundation
import LocalAuthentication
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
    private static var fetchTasks = [String: URLSessionDataTask]()
    private static let fetchSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = craftNativeFetchTimeoutSeconds
        configuration.timeoutIntervalForResource = craftNativeFetchTimeoutSeconds
        return URLSession(configuration: configuration)
    }()
    private static var initialDeepLinkClaimed = false
    private static var database: OpaquePointer?
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func capabilities(config: CraftConfig) -> [String] {
        var values = ["device", "clipboard", "haptics", "storage", "lifecycle", "fetch"]
        if config.enableBiometric { values.append("biometric") }
        if config.enableSecureStorage { values.append("secureStorage") }
        if config.enableLocalDatabase { values.append("database") }
        if config.enableDeepLinks { values.append("deepLinks") }
        if config.enableLocalNotifications { values.append("notifications") }
        return values
    }

    /// Nil means this small shared router does not own the action.
    static func perform(action: String, body: [String: Any], config: CraftConfig) -> Result<Any, CraftNativeActionError>? {
        switch action {
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
        case ("Device", "getInfo"):
            sync = perform(action: "getDeviceInfo", body: [:], config: config)
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
            sync = storage(method: method, args: args)
        case ("SecureStorage", _):
            guard config.enableSecureStorage else {
                complete(requestToken, failure("CAPABILITY_DISABLED", "Secure storage is disabled"), completion)
                return
            }
            sync = secureStorage(method: method, args: args)
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
        case ("Network", "fetch"):
            fetch(requestToken: requestToken, args: args, completion: completion)
            return
        case ("Lifecycle", "getState"):
            sync = .success(currentAppState())
        case ("DeepLinks", "getInitialURL"):
            if config.enableDeepLinks {
                sync = .success(claimInitialDeepLink().map(deepLinkData) ?? NSNull())
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

    static func cancel(requestToken: String) {
        cancellationLock.lock()
        cancelledRequests.insert(requestToken)
        let context = biometricContexts.removeValue(forKey: requestToken)
        let task = fetchTasks.removeValue(forKey: requestToken)
        cancellationLock.unlock()
        context?.invalidate()
        task?.cancel()
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
        if let body = options["body"] as? String {
            guard method != "GET", method != "HEAD" else {
                complete(requestToken, failure("INVALID_ARGUMENT", "A GET or HEAD request cannot have a body"), completion)
                return
            }
            request.httpBody = Data(body.utf8)
        } else if let body = options["body"], !(body is NSNull) {
            complete(requestToken, failure("INVALID_ARGUMENT", "fetch body must be a string"), completion)
            return
        }

        let task = fetchSession.dataTask(with: request) { data, response, error in
            cancellationLock.lock()
            fetchTasks.removeValue(forKey: requestToken)
            cancellationLock.unlock()
            if let error = error {
                let code = (error as? URLError)?.code == .timedOut ? "TIMEOUT" : "NETWORK_ERROR"
                complete(requestToken, failure(code, error.localizedDescription), completion)
                return
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
        cancellationLock.lock()
        let alreadyCancelled = cancelledRequests.contains(requestToken)
        if !alreadyCancelled { fetchTasks[requestToken] = task }
        cancellationLock.unlock()
        if !alreadyCancelled { task.resume() }
    }

    private static func claimInitialDeepLink() -> URL? {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        guard !initialDeepLinkClaimed else { return nil }
        initialDeepLinkClaimed = true
        return DeepLinkManager.shared.getInitialURL()
    }

    private static func complete(
        _ requestToken: String,
        _ result: Result<Any, CraftNativeActionError>,
        _ completion: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) {
        DispatchQueue.main.async {
            cancellationLock.lock()
            let cancelled = cancelledRequests.remove(requestToken) != nil
            cancellationLock.unlock()
            if !cancelled { completion(result) }
        }
    }

    private static func storage(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        if method == "clear" {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(storagePrefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return .success(true)
        }
        if method == "keys" {
            let keys = UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(storagePrefix) }
                .map { String($0.dropFirst(storagePrefix.count)) }
                .sorted()
            return .success(keys)
        }
        guard let key = validKey(args.first) else { return failure("INVALID_ARGUMENT", "Storage needs a non-empty key") }
        let defaultsKey = storagePrefix + key
        switch method {
        case "get":
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return .success(NSNull()) }
            do {
                return .success(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            } catch {
                return failure("STORAGE_CORRUPT", "Stored value is not valid JSON")
            }
        case "set":
            guard args.count == 2 else { return failure("INVALID_ARGUMENT", "Storage.set needs a key and value") }
            do {
                let data = try JSONSerialization.data(withJSONObject: args[1], options: [.fragmentsAllowed])
                UserDefaults.standard.set(data, forKey: defaultsKey)
                return .success(true)
            } catch {
                return failure("INVALID_ARGUMENT", "Storage values must be JSON serializable")
            }
        case "remove":
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return .success(true)
        default:
            return failure("UNKNOWN_ACTION", "Unsupported Storage method")
        }
    }

    private static func secureStorage(method: String, args: [Any]) -> Result<Any, CraftNativeActionError> {
        let service = "dev.craft.native.secure"
        if method == "clear" {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            let status = SecItemDelete(query as CFDictionary)
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
            guard removed == errSecSuccess || removed == errSecItemNotFound else {
                return failure("SECURE_STORAGE_ERROR", "Secure storage could not be replaced (\(removed))")
            }
            let status = SecItemAdd(query as CFDictionary, nil)
            return status == errSecSuccess ? .success(true) : failure("SECURE_STORAGE_ERROR", "Secure storage could not be written (\(status))")
        case "get":
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return .success(NSNull()) }
            guard status == errSecSuccess, let data = result as? Data else {
                return failure("SECURE_STORAGE_ERROR", "Secure storage could not be read")
            }
            return .success(String(decoding: data, as: UTF8.self))
        case "remove":
            let status = SecItemDelete(base as CFDictionary)
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
                if let badge = value["badge"] as? NSNumber { content.badge = badge }
                let id = (value["id"] as? String).flatMap { validKey($0) } ?? UUID().uuidString
                let delay = (value["delay"] as? NSNumber)?.doubleValue
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
