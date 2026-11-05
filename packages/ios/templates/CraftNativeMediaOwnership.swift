import Foundation

/// Durable ownership of cached media and background transfers. The media
/// store serializes access to this journal with its file-commit lock.
final class CraftNativeMediaOwnership {
    struct Stamp: Codable, Equatable {
        let epoch: String
        let revision: String
    }

    private struct Journal: Codable {
        var version = 1
        var epoch = UUID().uuidString
        var legacyCopiesAllowed = true
        var revisions: [String: String] = [:]
        var revoked: Set<String> = []
        var authorized: Set<String> = []
    }

    private let url: URL
    private var journal: Journal
    private var persistenceFailure: Error?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            guard journal.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            journal = Journal()
            try persist(journal)
        }
    }

    func permitsLocal(_ identity: String) -> Bool {
        persistenceFailure == nil && !journal.revoked.contains(identity)
            && (journal.legacyCopiesAllowed || journal.authorized.contains(identity))
    }

    func accepts(_ identity: String, stamp: Stamp) -> Bool {
        permitsLocal(identity) && stamp.epoch == journal.epoch
            && stamp.revision == (journal.revisions[identity] ?? "")
    }

    /// A new explicit authorized keep may use this identity again. Old bytes
    /// must be removed before lifting a tombstone, including after a failed
    /// unlink. Its old transfer stamp never becomes current again.
    func activate(_ identity: String, removeRetiredFiles: () throws -> Void) throws -> Stamp {
        if persistenceFailure != nil { try persist(journal) }
        if !permitsLocal(identity) {
            try removeRetiredFiles()
            var next = journal
            next.revoked.remove(identity)
            next.authorized.insert(identity)
            try persist(next)
        }
        return Stamp(epoch: journal.epoch, revision: journal.revisions[identity] ?? "")
    }

    /// Persist before cancelling or unlinking: a task that outlives this
    /// process cannot regain ownership on the next launch.
    func retire(_ identity: String) throws {
        var next = journal
        next.revisions[identity] = UUID().uuidString
        next.revoked.insert(identity)
        try persist(next)
    }

    /// Sign-out invalidates all existing stamps and all copies, even if a
    /// filesystem error prevents unlinking one of them.
    func clear() throws {
        var next = Journal()
        next.legacyCopiesAllowed = false
        try persist(next)
    }

    private func persist(_ next: Journal) throws {
        // A failed journal write is observable and fails closed in this
        // process. A later retire/clear can retry once storage is writable.
        journal = next
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: url, options: .atomic)
            persistenceFailure = nil
        } catch {
            persistenceFailure = error
            throw error
        }
    }
}
