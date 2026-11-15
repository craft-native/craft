import Foundation
import CryptoKit
import Security

/// Why an update was refused, as a sentence a settings screen can show.
struct CraftUpdateFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// JSON as JavaScript's `JSON.parse` reads it. The manifest's strings go back into the bytes its
/// signature covers, so they have to arrive exactly as written: Foundation's reader drops a byte
/// order mark that opens a string (release notes saved by an editor that writes one), and the
/// signature of that manifest would then never verify here while it does everywhere else.
enum CraftUpdateJSON {
    static func parse(_ data: Data) throws -> Any {
        var reader = Reader(bytes: [UInt8](data))
        // A mark before the document itself is the encoding's, not the text's.
        if reader.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { reader.index = 3 }
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        guard reader.index == reader.bytes.count else { throw reader.failure }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var failure: CraftUpdateFailure { CraftUpdateFailure("The update feed did not answer with valid JSON") }
        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpace() { while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 } }
        mutating func take(_ text: String) throws { for byte in text.utf8 { guard peek == byte else { throw failure }; index += 1 } }

        mutating func value(depth: Int) throws -> Any {
            guard depth < 64 else { throw failure }
            skipSpace()
            switch peek {
            case UInt8(ascii: "{"):
                index += 1
                var object: [String: Any] = [:]
                skipSpace()
                if peek == UInt8(ascii: "}") { index += 1; return object }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace(); try take(":")
                    // A name written twice keeps its last value, as in JavaScript.
                    object[key] = try value(depth: depth + 1)
                    skipSpace()
                    if peek == UInt8(ascii: ",") { index += 1; continue }
                    try take("}"); return object
                }
            case UInt8(ascii: "["):
                index += 1
                var array: [Any] = []
                skipSpace()
                if peek == UInt8(ascii: "]") { index += 1; return array }
                while true {
                    array.append(try value(depth: depth + 1))
                    skipSpace()
                    if peek == UInt8(ascii: ",") { index += 1; continue }
                    try take("]"); return array
                }
            case UInt8(ascii: "\""): return try string()
            case UInt8(ascii: "t"): try take("true"); return true
            case UInt8(ascii: "f"): try take("false"); return false
            case UInt8(ascii: "n"): try take("null"); return NSNull()
            default: return try number()
            }
        }

        mutating func number() throws -> Double {
            let start = index
            func digit(_ byte: UInt8?) -> Bool { byte.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
            if peek == UInt8(ascii: "-") { index += 1 }
            guard digit(peek) else { throw failure }
            if peek == 0x30 { index += 1 } else { while digit(peek) { index += 1 } }
            if peek == UInt8(ascii: ".") { index += 1; guard digit(peek) else { throw failure }; while digit(peek) { index += 1 } }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                index += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
                guard digit(peek) else { throw failure }
                while digit(peek) { index += 1 }
            }
            guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw failure }
            return number
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let unit = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16),
                  bytes[index..<index + 4].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) }) else { throw failure }
            index += 4
            return unit
        }

        mutating func string() throws -> String {
            guard peek == UInt8(ascii: "\"") else { throw failure }
            index += 1
            var text: [UInt8] = []
            while let byte = peek {
                index += 1
                if byte == UInt8(ascii: "\"") {
                    let decoded = String(decoding: text, as: UTF8.self)
                    // Bytes that are not UTF-8 would be repaired into something nobody signed.
                    guard Array(decoded.utf8) == text else { throw failure }
                    return decoded
                }
                guard byte >= 0x20 else { throw failure }
                guard byte == UInt8(ascii: "\\") else { text.append(byte); continue }
                guard let escape = peek else { throw failure }
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): text.append(escape)
                case UInt8(ascii: "b"): text.append(0x08)
                case UInt8(ascii: "f"): text.append(0x0C)
                case UInt8(ascii: "n"): text.append(0x0A)
                case UInt8(ascii: "r"): text.append(0x0D)
                case UInt8(ascii: "t"): text.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar) {
                        // The first half of a pair: the second has to follow. Half a pair is not text.
                        try take("\\u")
                        let low = try hex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw failure }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let character = Unicode.Scalar(scalar) else { throw failure }
                    text.append(contentsOf: Array(String(character).utf8))
                default: throw failure
                }
            }
            throw failure
        }
    }
}

/// The rules an update manifest is held to. They mirror the JavaScript updater the release
/// tooling signs for (`updater.ts` in Stacks' desktop package) byte for byte: the same
/// validation, the same canonical payload under the signature, the same version order.
enum CraftUpdateRules {
    /// Node's name for this build's architecture, which is what a manifest carries.
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x64"
    #endif
    static let platform = "darwin"

    /// The whole of `text` against `pattern`. `\z`, not `$`: ICU's `$` also matches before a final newline.
    static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z", options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `major.minor.patch`, with an optional `v` and a pre-release tag that takes no part in ordering.
    static func parseVersion(_ version: String) throws -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: "\\Av?([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-[0-9A-Za-z.-]+)?\\z"),
              let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) else {
            throw CraftUpdateFailure("Invalid semantic version: \(version)")
        }
        return (1...3).map { Double((version as NSString).substring(with: match.range(at: $0))) ?? 0 }
    }

    /// 1 when `left` is newer than `right`, -1 when older, 0 when the same.
    static func compare(_ left: String, _ right: String) throws -> Int {
        let a = try parseVersion(left), b = try parseVersion(right)
        for index in 0..<3 where a[index] != b[index] { return a[index] > b[index] ? 1 : a[index] < b[index] ? -1 : 0 }
        return 0
    }

    /// HTTPS, or plain HTTP to this machine (a development feed).
    @discardableResult static func assertSecure(_ value: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw CraftUpdateFailure("Updates require HTTPS outside loopback development")
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { throw CraftUpdateFailure("Updates require HTTPS outside loopback development") }
        return url
    }

    /// A string as JavaScript's `JSON.stringify` writes it: only `"`, `\` and the control characters
    /// are escaped, everything else stays as it is.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `<feedUrl>/darwin/<arch>`, with the channel (unless `stable`) and the running version, so the
    /// feed can answer 204 for "nothing newer".
    static func feedURL(_ feed: String, architecture: String, channel: String, currentVersion: String) throws -> URL {
        var base = feed
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: "\(base)/\(platform)/\(architecture)") else { throw CraftUpdateFailure("The update feed is not a URL: \(feed)") }
        var items = components.queryItems ?? []
        if !channel.isEmpty, channel != "stable" { items.append(URLQueryItem(name: "channel", value: channel)) }
        if !currentVersion.isEmpty { items.append(URLQueryItem(name: "current", value: currentVersion)) }
        components.queryItems = items.isEmpty ? nil : items
        // A `+` in a query is a space to a form decoder.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw CraftUpdateFailure("The update feed is not a URL: \(feed)") }
        return try assertSecure(url.absoluteString)
    }

    /// What a feed's answer means for this app: the manifest when it is a newer build for this
    /// architecture, signed by a trusted key and downloadable over a secure URL; nil when it is not newer.
    static func accept(_ json: Any?, trustedKeys: [String: String], currentVersion: String, architecture: String = CraftUpdateRules.architecture) throws -> CraftUpdateManifest? {
        let manifest = try CraftUpdateManifest(json)
        try manifest.verify(trustedKeys: trustedKeys)
        guard manifest.platform == platform, manifest.architecture == architecture else {
            throw CraftUpdateFailure("Update is built for \(manifest.platform)-\(manifest.architecture), not this app's \(platform)-\(architecture)")
        }
        guard try compare(manifest.version, currentVersion) > 0 else { return nil }
        try assertSecure(manifest.url)
        return manifest
    }
}

/// One signed update: what to download, what it must hash to, and who signed that statement.
struct CraftUpdateManifest {
    let version: String
    let url: String
    let sha256: String
    let size: Int64
    let sourceRevision: String
    let platform: String
    let architecture: String
    let signingKeyId: String
    let signature: String
    let publishedAt: String?
    let notes: String?

    init(_ input: Any?) throws {
        guard let object = input as? [String: Any] else { throw CraftUpdateFailure("Update manifest must be an object") }
        let version = object["version"] as? String ?? ""
        _ = try CraftUpdateRules.parseVersion(version)
        guard let url = object["url"] as? String else { throw CraftUpdateFailure("Update manifest requires a URL") }
        guard let sha256 = object["sha256"] as? String, CraftUpdateRules.matches("[a-f0-9]{64}", sha256, caseInsensitive: true) else { throw CraftUpdateFailure("Update manifest requires a SHA-256 checksum") }
        // A whole number JavaScript can hold exactly.
        guard !(object["size"] is Bool), let number = object["size"] as? Double,
              let size = Int64(exactly: number), size >= 0, size <= 9_007_199_254_740_991 else { throw CraftUpdateFailure("Update manifest requires a non-negative integer size") }
        guard let revision = object["sourceRevision"] as? String, CraftUpdateRules.matches("[0-9a-f]{40}", revision) else { throw CraftUpdateFailure("Update manifest requires a full source revision") }
        guard let platform = object["platform"] as? String, ["darwin", "linux", "win32"].contains(platform) else { throw CraftUpdateFailure("Update manifest requires a supported platform identifier") }
        guard let architecture = object["architecture"] as? String, CraftUpdateRules.matches("[a-z0-9_-]+", architecture) else { throw CraftUpdateFailure("Update manifest requires an architecture") }
        guard let key = object["signingKeyId"] as? String, CraftUpdateRules.matches("[a-zA-Z0-9._-]+", key) else { throw CraftUpdateFailure("Update manifest requires a signing key ID") }
        guard let signature = object["signature"] as? String, CraftUpdateRules.matches("[A-Za-z0-9_-]+", signature) else { throw CraftUpdateFailure("Update manifest requires an Ed25519 signature") }
        func optional(_ name: String) throws -> String? {
            guard let value = object[name], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw CraftUpdateFailure("Update manifest has an invalid \(name)") }
            // An empty string signs as null, as `publishedAt || null` does.
            return text.isEmpty ? nil : text
        }
        self.version = version; self.url = url; self.sha256 = sha256; self.size = size; sourceRevision = revision
        self.platform = platform; self.architecture = architecture; signingKeyId = key; self.signature = signature
        publishedAt = try optional("publishedAt"); notes = try optional("notes")
    }

    /// The bytes under the signature: `JSON.stringify` of these ten fields, in this order, with no
    /// whitespace, the checksum in lower case and null for an absent date or notes.
    var payload: Data {
        let text = CraftUpdateRules.jsonString
        return Data(("{\"version\":\(text(version)),\"url\":\(text(url)),\"sha256\":\(text(sha256.lowercased())),\"size\":\(size)"
            + ",\"sourceRevision\":\(text(sourceRevision)),\"platform\":\(text(platform)),\"architecture\":\(text(architecture))"
            + ",\"signingKeyId\":\(text(signingKeyId)),\"publishedAt\":\(publishedAt.map(text) ?? "null"),\"notes\":\(notes.map(text) ?? "null")}").utf8)
    }

    static func base64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// An Ed25519 public key as SubjectPublicKeyInfo DER: this header, then the 32 key bytes.
    private static let spkiHeader = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])

    /// The signature is by the key the manifest names, and the app trusts that key.
    func verify(trustedKeys: [String: String]) throws {
        guard let encoded = trustedKeys[signingKeyId] else { throw CraftUpdateFailure("Update signing key is not trusted: \(signingKeyId)") }
        let prefix = "ed25519-public:"
        guard encoded.hasPrefix(prefix) else { throw CraftUpdateFailure("Update signing key has an invalid encoding") }
        guard let der = Self.base64url(String(encoded.dropFirst(prefix.count))), der.count == Self.spkiHeader.count + 32, der.prefix(Self.spkiHeader.count) == Self.spkiHeader,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32)),
              let signature = Self.base64url(signature), signature.count == 64,
              key.isValidSignature(signature, for: payload) else { throw CraftUpdateFailure("Update manifest signature verification failed") }
    }
}

/// `craft.updater`: asks the app's update feed for a newer build, downloads it, checks it against
/// its signed manifest and against the running app's own code signature, swaps the bundle and
/// starts the new version. State lives on the main thread; `status()` answers on any.
final class CraftMacUpdater: NSObject, URLSessionDownloadDelegate {
    /// `updates` in `craft-app.json`.
    struct Config {
        let feedURL: String
        let keys: [String: String]
        let channel: String
        let checkEveryHours: Double
        init?(_ raw: Any?) {
            guard let raw = raw as? [String: Any], let feed = raw["feedUrl"] as? String, !feed.isEmpty else { return nil }
            feedURL = feed
            keys = (raw["publicKeys"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            channel = raw["channel"] as? String ?? "stable"
            checkEveryHours = (raw["checkEveryHours"] as? NSNumber)?.doubleValue ?? 24
        }
    }

    /// Whether this copy can replace itself, and whether it may look for updates at all.
    struct Installation {
        let selfUpdating: Bool
        /// The store, not the app, updates this copy: no feed is ever asked.
        let inert: Bool
        let reason: String?
    }

    let config: Config?
    let currentVersion: String
    let bundle: URL
    /// The test driver replaces an ad hoc signed fixture; nothing else may.
    let allowAdHoc: Bool
    let installation: Installation
    /// Every state and progress change, on the main thread.
    var onChange: (([String: Any]) -> Void)?

    private var state: String
    private var manifest: CraftUpdateManifest?
    private var failure: String?
    private var progress: Double = 0
    private var publishedProgress: Double = 0
    private var lastCheckedAt: String?
    private var busy = false
    private var waiters: [([String: Any]) -> Void] = []
    /// Installs asked for while a check was in flight (the hourly one, say): they run when it lands.
    private var queuedInstalls: [([String: Any]) -> Void] = []
    private var timer: Timer?
    private var download: (task: Int, manifest: CraftUpdateManifest, staged: URL?, failure: String?)?
    private let lock = NSLock()
    private var snapshot: [String: Any] = [:]
    private let worker = DispatchQueue(label: "craft.updater", qos: .utility)
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    init(config raw: Any?, currentVersion: String, bundle: URL = Bundle.main.bundleURL, allowAdHoc: Bool) {
        config = Config(raw)
        self.currentVersion = currentVersion
        self.bundle = bundle.standardizedFileURL
        self.allowAdHoc = allowAdHoc
        installation = Self.installation(config: config, bundle: self.bundle, allowAdHoc: allowAdHoc)
        state = config == nil || installation.inert ? "unavailable" : "idle"
        super.init()
        snapshot = describe()
    }

    // MARK: What this copy is

    private static var sandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true
    }

    static func installation(config: Config?, bundle: URL, allowAdHoc: Bool) -> Installation {
        guard config != nil else { return Installation(selfUpdating: false, inert: true, reason: "This app has no update feed.") }
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return Installation(selfUpdating: false, inert: true, reason: "This copy came from the App Store, which installs its updates.")
        }
        if sandboxed { return Installation(selfUpdating: false, inert: true, reason: "This copy runs in the App Sandbox and cannot replace itself. Its store installs its updates.") }
        guard bundle.pathExtension == "app" else { return Installation(selfUpdating: false, inert: false, reason: "This copy is not running from an app bundle, so there is nothing to replace.") }
        if bundle.path.contains("/AppTranslocation/") {
            return Installation(selfUpdating: false, inert: false, reason: "macOS is running this app from a temporary read-only copy. Move it to the Applications folder and open it again to install updates.")
        }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return Installation(selfUpdating: false, inert: false, reason: "This app is on a read-only volume, such as a disk image. Copy it to the Applications folder to install updates.")
        }
        let folder = bundle.deletingLastPathComponent().path
        guard access(folder, W_OK) == 0 else { return Installation(selfUpdating: false, inert: false, reason: "This account cannot change \(folder), the folder the app is in, so the app cannot replace itself.") }
        if !allowAdHoc, runningCode().map(signer)?.team == nil {
            return Installation(selfUpdating: false, inert: false, reason: "This copy is not signed with a Developer ID, so an update cannot be checked against it.")
        }
        return Installation(selfUpdating: true, inert: false, reason: nil)
    }

    // MARK: Status

    /// `UpdateStatus`, from any thread.
    func status() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return snapshot }

    private func describe() -> [String: Any] {
        var status: [String: Any] = ["currentVersion": currentVersion, "state": state, "selfUpdating": installation.selfUpdating]
        if let reason = installation.reason { status["reason"] = reason }
        if let manifest {
            status["version"] = manifest.version
            if let notes = manifest.notes { status["notes"] = notes }
            if let published = manifest.publishedAt { status["publishedAt"] = published }
        }
        if state == "downloading" { status["progress"] = progress }
        if let failure { status["error"] = failure }
        if let lastCheckedAt { status["lastCheckedAt"] = lastCheckedAt }
        return status
    }

    private func publish() {
        let status = describe()
        lock.lock(); snapshot = status; lock.unlock()
        publishedProgress = progress
        onChange?(status)
    }

    /// One check or install runs at a time; a call made meanwhile gets the same answer.
    private func begin(_ replies: [([String: Any]) -> Void]) { busy = true; waiters = replies }

    private func finish(_ error: Error? = nil) {
        if let error {
            state = "error"
            failure = (error as? CraftUpdateFailure)?.message ?? error.localizedDescription
        }
        busy = false; download = nil
        publish()
        let waiting = waiters; waiters.removeAll()
        let status = describe()
        waiting.forEach { $0(status) }
        if !busy, !queuedInstalls.isEmpty {
            let queued = queuedInstalls; queuedInstalls.removeAll()
            install(queued)
        }
    }

    // MARK: Checking

    /// The check on launch, and one every `checkEveryHours` after (0 turns the timer off).
    func start() {
        guard let config, !installation.inert else { return }
        check()
        guard config.checkEveryHours > 0, timer == nil else { return }
        let interval = config.checkEveryHours * 3600
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks the feed. Never fails: a failure is the `error` state.
    func check(_ reply: @escaping ([String: Any]) -> Void = { _ in }) {
        guard let config, !installation.inert else { reply(status()); return }
        if busy { waiters.append(reply); return }
        // An update already in place is not looked for again; the next launch runs it.
        if state == "installed" { reply(status()); return }
        begin([reply])
        state = "checking"; failure = nil; publish()
        do {
            let url = try CraftUpdateRules.feedURL(config.feedURL, architecture: CraftUpdateRules.architecture, channel: config.channel, currentVersion: currentVersion)
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            session.dataTask(with: request) { [weak self] data, response, error in self?.checked(data, response, error, keys: config.keys) }.resume()
        } catch { finish(error) }
    }

    private func checked(_ data: Data?, _ response: URLResponse?, _ error: Error?, keys: [String: String]) {
        do {
            if let error { throw CraftUpdateFailure("Update check failed: \(error.localizedDescription)") }
            guard let http = response as? HTTPURLResponse else { throw CraftUpdateFailure("Update check failed: the feed did not answer over HTTP") }
            // The feed's way of saying "nothing newer than what you told me you run".
            if http.statusCode == 204 { manifest = nil } else {
                guard (200..<300).contains(http.statusCode) else { throw CraftUpdateFailure("Update check failed with HTTP \(http.statusCode)") }
                guard let data, data.count <= 1 << 20 else { throw CraftUpdateFailure("The update feed did not answer with a manifest") }
                manifest = try CraftUpdateRules.accept(CraftUpdateJSON.parse(data), trustedKeys: keys, currentVersion: currentVersion)
            }
            state = manifest == nil ? "current" : "available"
            lastCheckedAt = Self.timestamp()
            finish()
        } catch { finish(error) }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Installing

    /// Downloads, verifies and swaps in what `check` found. Answers at `installed` or `error`.
    func install(_ reply: @escaping ([String: Any]) -> Void = { _ in }) {
        guard config != nil, !installation.inert else { reply(status()); return }
        if busy {
            if state == "checking" { queuedInstalls.append(reply) } else { waiters.append(reply) }
            return
        }
        install([reply])
    }

    private func install(_ replies: [([String: Any]) -> Void]) {
        guard let config else { return }
        if state == "installed" { let status = status(); replies.forEach { $0(status) }; return }
        begin(replies)
        guard state == "available", let manifest else { finish(CraftUpdateFailure("There is no update to install. Check first.")); return }
        guard installation.selfUpdating else { finish(CraftUpdateFailure(installation.reason ?? "This copy cannot replace itself.")); return }
        do {
            try manifest.verify(trustedKeys: config.keys)
            let url = try CraftUpdateRules.assertSecure(manifest.url)
            state = "downloading"; failure = nil; progress = 0; publish()
            let task = session.downloadTask(with: URLRequest(url: url))
            download = (task.taskIdentifier, manifest, nil, nil)
            task.resume()
        } catch { finish(error) }
    }

    /// A redirect is followed only to another secure address: HTTPS must not end at plain HTTP.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let secure = request.url.map { (try? CraftUpdateRules.assertSecure($0.absoluteString)) != nil } ?? false
        completionHandler(secure ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard var current = download, current.task == downloadTask.taskIdentifier, current.failure == nil else { return }
        // More than the manifest promised is not this update: stop before the disk fills.
        if totalBytesWritten > current.manifest.size {
            current.failure = "Update size mismatch: expected \(current.manifest.size), received more"
            download = current
            downloadTask.cancel()
            return
        }
        progress = current.manifest.size > 0 ? min(1, Double(totalBytesWritten) / Double(current.manifest.size)) : 1
        if progress - publishedProgress >= 0.01 || (progress >= 1 && publishedProgress < 1) { publish() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard var current = download, current.task == downloadTask.taskIdentifier else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) { current.failure = "Update download failed with HTTP \(code)" } else {
            // The file at `location` is gone once this returns.
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("craft-update-\(UUID().uuidString).zip")
            do { try FileManager.default.moveItem(at: location, to: staged); current.staged = staged }
            catch { current.failure = "Update download could not be kept: \(error.localizedDescription)" }
        }
        download = current
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let current = download, current.task == task.taskIdentifier else { return }
        if let failure = current.failure { finish(CraftUpdateFailure(failure)); return }
        if let error { finish(CraftUpdateFailure("Update download failed: \(error.localizedDescription)")); return }
        guard let staged = current.staged else { finish(CraftUpdateFailure("Update download failed")); return }
        state = "installing"; publish()
        let bundle = bundle, allowAdHoc = allowAdHoc, manifest = current.manifest
        worker.async {
            var failed: Error?
            do {
                try Self.verifyDownload(staged, manifest: manifest)
                try Self.replace(bundle: bundle, archive: staged, allowAdHoc: allowAdHoc)
            } catch { failed = error }
            try? FileManager.default.removeItem(at: staged)
            DispatchQueue.main.async {
                if failed == nil { self.state = "installed" }
                self.finish(failed)
            }
        }
    }

    /// The download is the file the manifest was signed for: its size, then its SHA-256, read in pieces.
    static func verifyDownload(_ file: URL, manifest: CraftUpdateManifest) throws {
        let received = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard received == manifest.size else { throw CraftUpdateFailure("Update size mismatch: expected \(manifest.size), received \(received)") }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw CraftUpdateFailure("The downloaded update could not be read") }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == manifest.sha256.lowercased() else { throw CraftUpdateFailure("Update checksum mismatch") }
    }

    // MARK: Code signatures

    struct Signer { let identifier: String?; let team: String? }

    static func signer(_ code: SecStaticCode) -> Signer {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let values = info as? [String: Any] else { return Signer(identifier: nil, team: nil) }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        return Signer(identifier: values[kSecCodeInfoIdentifier as String] as? String, team: team?.isEmpty == false ? team : nil)
    }

    /// The code this process is running, as signed.
    static func runningCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var fixed: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &fixed) == errSecSuccess else { return nil }
        return fixed
    }

    /// Whether `next` may replace the running app: its signature has to be intact, every nested
    /// binary included, and it has to be the same app (identifier) from the same developer (a
    /// certificate Apple issued to the same team). A manifest signed with a stolen update key
    /// still cannot install someone else's app over this one. A running app with no team (an ad
    /// hoc development build) has no signer to compare with and is replaced only under the test
    /// driver, by a bundle with an intact signature and the same identifier.
    static func assertTrusted(next: URL, allowAdHoc: Bool) throws {
        guard let current = runningCode().map(signer), let identifier = current.identifier else { throw CraftUpdateFailure("The running app has no code signature, so an update cannot be checked against it.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(next as CFURL, [], &code) == errSecSuccess, let code else { throw CraftUpdateFailure("The update's signature could not be read.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        func validate(_ requirement: SecRequirement?) -> String? {
            var error: Unmanaged<CFError>?
            guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) != errSecSuccess else { return nil }
            return error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "it does not verify"
        }
        if let problem = validate(nil) { throw CraftUpdateFailure("The update's signature is not valid: \(problem)") }
        let incoming = signer(code)
        guard incoming.identifier == identifier else { throw CraftUpdateFailure("The update is a different app (\(incoming.identifier ?? "unknown")), not \(identifier).") }
        guard let team = current.team else {
            guard allowAdHoc else { throw CraftUpdateFailure("The running app is not signed with a Developer ID, so an update cannot be checked against it.") }
            guard incoming.team == nil else { throw CraftUpdateFailure("The update is signed by \(incoming.team ?? ""), and this app by no one.") }
            return
        }
        guard incoming.team == team else { throw CraftUpdateFailure("The update is signed by \(incoming.team ?? "no one"), not by this app's team \(team).") }
        // The team in a signature is what its signer wrote there; the certificate is what Apple issued.
        guard CraftUpdateRules.matches("[A-Za-z0-9.-]+", identifier), CraftUpdateRules.matches("[A-Za-z0-9]+", team) else { throw CraftUpdateFailure("The running app's signature cannot be compared with an update's.") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw CraftUpdateFailure("The running app's signature cannot be compared with an update's.") }
        if let problem = validate(requirement) { throw CraftUpdateFailure("The update was not signed by this app's developer: \(problem)") }
    }

    // MARK: Swapping the bundle

    /// Replaces `bundle` with the app zipped in `archive`. Unpacked beside the bundle, so the swap
    /// stays on one volume: the two exchange places in one step where the file system can do that,
    /// else the old bundle is moved aside and put back if the new one cannot take its place. A
    /// failure at any point leaves the app that was there, working.
    static func replace(bundle: URL, archive: URL, allowAdHoc: Bool) throws {
        let files = FileManager.default
        let scratch = bundle.deletingLastPathComponent().appendingPathComponent(".update-\(UUID().uuidString)", isDirectory: true)
        do { try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw CraftUpdateFailure("The update could not be unpacked beside the app: \(error.localizedDescription)") }
        defer { try? files.removeItem(at: scratch) }
        // ditto keeps the signature's extended attributes and symlinks.
        let ditto = Process(), errors = Pipe()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, scratch.path]
        ditto.standardOutput = FileHandle.nullDevice; ditto.standardError = errors
        do { try ditto.run() } catch { throw CraftUpdateFailure("Unpacking the update failed: \(error.localizedDescription)") }
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CraftUpdateFailure("Unpacking the update failed: \(complaint)") }
        let unpacked = ((try? files.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []).filter { $0.pathExtension == "app" }
        guard unpacked.count == 1, let next = unpacked.first else { throw CraftUpdateFailure("The update archive holds \(unpacked.count) apps; it has to hold exactly one.") }
        let kind = try? next.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind?.isDirectory == true, kind?.isSymbolicLink != true else { throw CraftUpdateFailure("The update archive does not hold an app bundle.") }
        try assertTrusted(next: next, allowAdHoc: allowAdHoc)
        try swap(next, into: bundle)
    }

    /// Puts `next` where `bundle` is. `exchange` false skips the one-step exchange, as a volume
    /// that cannot do it would.
    static func swap(_ next: URL, into bundle: URL, exchange: Bool = true) throws {
        let files = FileManager.default
        // Exchanged in one step: there is no moment with no app at its path. The old bundle is
        // then the one in the scratch folder, and goes with it.
        if exchange, renamex_np(next.path, bundle.path, UInt32(RENAME_SWAP)) == 0 { return }
        let aside = URL(fileURLWithPath: bundle.path + ".previous-\(getpid())")
        try? files.removeItem(at: aside)
        guard rename(bundle.path, aside.path) == 0 else { throw CraftUpdateFailure("The app could not be moved aside for its update: \(String(cString: strerror(errno)))") }
        guard rename(next.path, bundle.path) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = rename(aside.path, bundle.path)
            throw CraftUpdateFailure("The update could not take the app's place: \(reason)")
        }
        try? files.removeItem(at: aside)
    }

    // MARK: Relaunch

    /// Starts the installed version once this process has gone: a detached shell waits for it to
    /// exit, then `/usr/bin/open -n` opens the bundle, with the arguments this launch had. Nil when
    /// it is waiting, and the caller quits; else why there is nothing to start.
    func relaunch() -> String? {
        guard state == "installed" else { return "No update is installed." }
        let script = "pid=$1; app=$2; shift 2; while /bin/kill -0 \"$pid\" 2>/dev/null; do /bin/sleep 0.1; done; "
            + "if [ $# -gt 0 ]; then exec /usr/bin/open -n \"$app\" --args \"$@\"; else exec /usr/bin/open -n \"$app\"; fi"
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", script, "craft-relaunch", String(getpid()), bundle.path] + CommandLine.arguments.dropFirst()
        waiter.standardInput = FileHandle.nullDevice; waiter.standardOutput = FileHandle.nullDevice; waiter.standardError = FileHandle.nullDevice
        do { try waiter.run() } catch { return "The new version could not be started: \(error.localizedDescription)" }
        return nil
    }
}
