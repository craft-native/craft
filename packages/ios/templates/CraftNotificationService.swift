import Foundation
import ImageIO
import UserNotifications

/// A separate extension process: no app runtime, shared container or JS required.
final class CraftNotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: CraftRemoteNotificationDelivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let next = CraftRemoteNotificationDelivery()
        lock.lock()
        let previous = delivery
        delivery = next
        lock.unlock()
        previous?.expire()
        next.start(request.content, completion: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let current = delivery
        lock.unlock()
        current?.expire()
    }
}

/// Serial streaming downloads bound both disk use and the extension's lifetime.
/// Any failure returns the original alert, without partially attached media.
final class CraftRemoteNotificationDelivery: NSObject, URLSessionDataDelegate {
    static let maximumBytes = 10 * 1024 * 1024
    private let queue = DispatchQueue(label: "craft.notification-service")
    private let configuration: URLSessionConfiguration
    private let root: URL
    private let timeout: TimeInterval
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var original: UNNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?
    private var expired = false
    private var entries: [(String, URL)] = []
    private var attachments: [UNNotificationAttachment] = []
    private var folder: URL?
    private var file: URL?
    private var stream: FileHandle?
    private var received = 0

    init(configuration: URLSessionConfiguration = .ephemeral,
         root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("craft-remote-notifications", isDirectory: true),
         timeout: TimeInterval = 25) {
        self.configuration = configuration
        self.root = root
        self.timeout = timeout
        super.init()
    }

    static func permitted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    func start(_ content: UNNotificationContent, completion: @escaping (UNNotificationContent) -> Void) {
        queue.async {
            self.original = content
            self.handler = completion
            guard !self.expired, let raw = content.userInfo["craftAttachments"] as? [[String: Any]],
                  !raw.isEmpty, raw.count <= 10 else { self.finish(false); return }
            var ids = Set<String>()
            for item in raw {
                guard let id = item["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      id.utf8.count <= 128, ids.insert(id).inserted,
                      let string = item["url"] as? String, let url = URL(string: string), Self.permitted(url) else {
                    self.finish(false); return
                }
                self.entries.append((id, url))
            }
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                // Successful handoffs must outlive the handler: iOS validates and
                // moves their files AFTER the extension finishes. Sweep only old
                // UUID folders, never another delivery still in flight.
                for url in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: [.creationDateKey]) {
                    if UUID(uuidString: url.lastPathComponent) != nil,
                       let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       created < Date().addingTimeInterval(-86_400) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                let folder = self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.folder = folder
            } catch { self.finish(false); return }
            self.configuration.httpCookieStorage = nil
            self.configuration.httpShouldSetCookies = false
            self.configuration.urlCredentialStorage = nil
            self.configuration.urlCache = nil
            self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.configuration.timeoutIntervalForRequest = self.timeout
            self.configuration.timeoutIntervalForResource = self.timeout
            self.session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: nil)
            let deadline = DispatchWorkItem { [weak self] in self?.finish(false) }
            self.deadline = deadline
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
            self.downloadNext()
        }
    }

    func expire() {
        queue.async { self.expired = true; self.finish(false) }
    }

    private func downloadNext() {
        guard attachments.count < entries.count else { finish(true); return }
        file = nil
        task = session?.dataTask(with: entries[attachments.count].1)
        task?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        queue.async {
            guard self.handler != nil, let url = request.url, Self.permitted(url) else {
                completionHandler(nil); self.finish(false); return
            }
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            let formats = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif",
                           "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/wav": "wav", "audio/x-wav": "wav",
                           "audio/aiff": "aiff", "audio/x-aiff": "aiff", "video/mp4": "mp4", "video/mpeg": "mpeg", "video/x-msvideo": "avi"]
            guard self.handler != nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let url = response.url, Self.permitted(url),
                  let suffix = formats[response.mimeType?.lowercased() ?? ""], let folder = self.folder,
                  response.expectedContentLength <= Int64(Self.maximumBytes - self.received) else {
                completionHandler(.cancel); self.finish(false); return
            }
            let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
            do {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                self.file = file
                self.stream = try FileHandle(forWritingTo: file)
                completionHandler(.allow)
            } catch { completionHandler(.cancel); self.finish(false) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Backpressure the delegate queue: do not retain an unbounded queue of
        // Data chunks from a fast/chunked server while disk writes catch up.
        queue.sync {
            guard self.handler != nil else { return }
            guard data.count <= Self.maximumBytes - self.received, let stream = self.stream else { self.finish(false); return }
            do { try stream.write(contentsOf: data); self.received += data.count }
            catch { self.finish(false) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard self.handler != nil else { return }
            do {
                try self.stream?.close()
                self.stream = nil
                guard error == nil, let file = self.file else { self.finish(false); return }
                if ["jpg", "png", "gif"].contains(file.pathExtension) {
                    guard let image = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(image) > 0,
                          CGImageSourceGetStatus(image) == .statusComplete else { self.finish(false); return }
                }
                let attachment = try UNNotificationAttachment(identifier: self.entries[self.attachments.count].0, url: file, options: nil)
                self.attachments.append(attachment)
                self.downloadNext()
            } catch { self.finish(false) }
        }
    }

    private func finish(_ success: Bool) {
        guard let handler, let original else { return }
        self.handler = nil
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        try? stream?.close()
        stream = nil
        if success, let content = original.mutableCopy() as? UNMutableNotificationContent {
            content.attachments = original.attachments + attachments
            handler(content)
            // No acknowledgement exists here. Leave successful files for iOS.
        } else {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            handler(original)
        }
    }
}
