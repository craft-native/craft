import Foundation

/// The opt-in frame trace shares one append-only file for this app process.
enum CraftFramePacingLog {
    static func open(in directory: URL) throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("craft-frame-pacing.log")
        if !manager.fileExists(atPath: url.path),
           !manager.createFile(atPath: url.path, contents: nil) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        return handle
    }
}
