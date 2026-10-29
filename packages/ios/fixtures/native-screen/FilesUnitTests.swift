import Darwin
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Network
import XCTest
@testable import NativeRender

/// craft.files' disk side: the files it makes, the JPEG a picked photo becomes,
/// the multipart body a screen's FormData is sent as, and a refused download.
/// System picker gestures are covered by NativeRenderUITests; lifecycle races
/// and the disk work after a provider answers are tested here.
@MainActor
final class FilesUnitTests: XCTestCase {
    func testDocumentPickerCancellationIgnoresLateSelectionAndDuplicateCallbacks() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString).mp4")
        try Data("late provider bytes".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try importFolders()
        for video in [false, true] {
            var answers = 0
            let completed = expectation(description: "picker cancellation")
            let delegate = CraftNativeFiles.DocumentDelegate(limit: 1024, video: video, requestToken: nil, isCancelled: { false }) { result in
                answers += 1
                guard case .success(let value) = result else { return XCTFail("user cancellation must resolve") }
                if video { XCTAssertTrue(value is NSNull) }
                else { XCTAssertEqual((value as? [Any])?.count, 0) }
                completed.fulfill()
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
            delegate.documentPickerWasCancelled(picker)
            delegate.documentPicker(picker, didPickDocumentsAt: [source])
            delegate.documentPickerWasCancelled(picker)
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(answers, 1)
        }
        XCTAssertEqual(try importFolders(), before)
    }

    func testDocumentPickerRequestCancellationDrainsTokenAndIgnoresLateProvider() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("disposed-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 256 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try importFolders()
        for video in [false, true] {
            let token = UUID().uuidString
            let completed = expectation(description: "cancelled delegate settles")
            var answers = 0
            let delegate = CraftNativeFiles.DocumentDelegate(limit: 1024 * 1024, video: video, requestToken: token,
                isCancelled: { CraftNativeActions.isCancelled(token) }) { result in
                answers += 1
                CraftNativeActions.completeFile(token, result) { _ in XCTFail("disposed screen received a result") }
                DispatchQueue.main.async { completed.fulfill() }
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
            CraftNativeActions.cancel(requestToken: token)
            delegate.cancel()
            delegate.cancel()
            delegate.documentPicker(picker, didPickDocumentsAt: [source])
            delegate.documentPickerWasCancelled(picker)
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(answers, 1)
            XCTAssertFalse(CraftNativeActions.isCancelled(token))
        }
        XCTAssertEqual(try importFolders(), before)
    }

    func testDocumentPickerCancellationDuringSelectionCleansOwnedFilesBeforeDrainingToken() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("selected-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 4 * 1024 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try importFolders()
        for video in [false, true] {
            let token = UUID().uuidString
            let completed = expectation(description: "copy cancellation cleanup")
            let delegate = CraftNativeFiles.DocumentDelegate(limit: 8 * 1024 * 1024, video: video, requestToken: token,
                isCancelled: { CraftNativeActions.isCancelled(token) }) { result in
                CraftNativeActions.completeFile(token, result) { _ in XCTFail("cancelled selection delivered") }
                DispatchQueue.main.async { completed.fulfill() }
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
            delegate.documentPicker(picker, didPickDocumentsAt: [source])
            CraftNativeActions.cancel(requestToken: token)
            delegate.cancel()
            XCTAssertTrue(CraftNativeActions.isCancelled(token), "worker still owns cancellation until delivery")
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertFalse(CraftNativeActions.isCancelled(token))
            XCTAssertEqual(try importFolders(), before)
        }
    }

    private func importFolders() throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: CraftNativeFiles.root.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(at: CraftNativeFiles.root, includingPropertiesForKeys: nil))
    }

    private func stagedImport(_ name: String) -> URL? {
        (try? importFolders())?.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func assertImportFailure(_ result: Result<Any, CraftNativeActionError>, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("import unexpectedly succeeded", file: file, line: line)
        }
        XCTAssertEqual(error.code, code, file: file, line: line)
    }

    func testImportsRejectDirectoriesFIFOsAndSymlinksWithoutCreatingOwnedFiles() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source) }
        let directory = source.appendingPathComponent("folder.mp4", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a video".utf8).write(to: directory.appendingPathComponent("child"))
        let fifo = source.appendingPathComponent("pipe.mp4")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        let regular = source.appendingPathComponent("regular.mp4")
        try Data([1, 2, 3]).write(to: regular)
        let symlink = source.appendingPathComponent("link.mp4")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: regular)
        let before = try importFolders()
        for url in [directory, fifo] {
            assertImportFailure(CraftNativeFiles.copyFile(url, limit: 1024), "INVALID_FILE")
            assertImportFailure(CraftNativeFiles.copyVideo(url, limit: 1024), "INVALID_FILE")
        }
        assertImportFailure(CraftNativeFiles.copyFile(symlink, limit: 1024), "READ_ERROR")
        assertImportFailure(CraftNativeFiles.copyVideo(symlink, limit: 1024), "READ_ERROR")
        XCTAssertEqual(try importFolders(), before)
        XCTAssertEqual(try Data(contentsOf: regular), Data([1, 2, 3]))
    }

    func testDocumentAndVideoCopiesAcceptExactLimitAndRejectEmptyOrOversizedFiles() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = Data(repeating: 0x5a, count: 128 * 1024)
        for video in [false, true] {
            try bytes.write(to: source)
            let copy: (Int) -> Result<Any, CraftNativeActionError> = { limit in
                video ? CraftNativeFiles.copyVideo(source, limit: limit) : CraftNativeFiles.copyFile(source, limit: limit)
            }
            let before = try importFolders()
            let value = try copy(bytes.count).get()
            let info = try XCTUnwrap(value as? [String: Any])
            let path = try XCTUnwrap(info["path"] as? String)
            XCTAssertEqual(info["size"] as? Int, bytes.count)
            XCTAssertEqual(info["type"] as? String, "video/mp4")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            XCTAssertTrue(CraftNativeFiles.remove(path))
            assertImportFailure(copy(bytes.count - 1), "FILE_TOO_LARGE")
            assertImportFailure(copy(0), "FILE_TOO_LARGE")
            try Data().write(to: source)
            assertImportFailure(copy(bytes.count), "FILE_TOO_LARGE")
            XCTAssertEqual(try importFolders(), before)
        }
        assertImportFailure(CraftNativeFiles.copyVideo(source.deletingPathExtension().appendingPathExtension("txt"), limit: 1024), "INVALID_VIDEO")
    }

    func testGrowingDocumentAndVideoCannotExceedLimitDuringCopy() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("growing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        for video in [false, true] {
            try Data(repeating: 1, count: 128 * 1024).write(to: source)
            let before = try importFolders()
            var grew = false
            var largestStagedSize = 0
            // The cancellation predicate runs on the copying thread. Append
            // real bytes after the first chunk, without sleeps or fake streams.
            let checkpoint: () -> Bool = {
                guard let staged = self.stagedImport(source.lastPathComponent) else { return false }
                let size = ((try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber)?.intValue ?? 0
                largestStagedSize = max(largestStagedSize, size)
                if size > 0 && !grew {
                    do {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        try writer.seekToEnd()
                        try writer.write(contentsOf: Data(repeating: 2, count: 128 * 1024))
                        grew = true
                    } catch { XCTFail("could not grow source: \(error)") }
                }
                return false
            }
            let result = video
                ? CraftNativeFiles.copyVideo(source, limit: 128 * 1024, isCancelled: checkpoint)
                : CraftNativeFiles.copyFile(source, limit: 128 * 1024, isCancelled: checkpoint)
            assertImportFailure(result, "FILE_TOO_LARGE")
            XCTAssertTrue(grew)
            XCTAssertEqual(largestStagedSize, 128 * 1024)
            XCTAssertEqual(try importFolders(), before, "partial copy and staging directory must be removed")
        }
    }

    func testCancellationStopsPartialDocumentAndVideoCopiesAndAllowsRetry() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).mp4")
        let bytes = Data(repeating: 7, count: 256 * 1024)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        for video in [false, true] {
            let before = try importFolders()
            let token = UUID().uuidString
            var copiedBeforeCancellation = 0
            let cancelled: () -> Bool = {
                if let staged = self.stagedImport(source.lastPathComponent),
                   let size = (try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber,
                   size.intValue > 0 {
                    copiedBeforeCancellation = size.intValue
                    CraftNativeActions.cancel(requestToken: token)
                }
                return CraftNativeActions.isCancelled(token)
            }
            let result = video
                ? CraftNativeFiles.copyVideo(source, limit: bytes.count, isCancelled: cancelled)
                : CraftNativeFiles.copyFile(source, limit: bytes.count, isCancelled: cancelled)
            assertImportFailure(result, "CANCELLED")
            XCTAssertEqual(copiedBeforeCancellation, 64 * 1024, "stop after the first bounded chunk")
            XCTAssertTrue(CraftNativeActions.isCancelled(token), "polling must not consume cancellation")
            XCTAssertEqual(try importFolders(), before)
            CraftNativeActions.completeFile(token, result) { _ in XCTFail("cancelled request was delivered") }
            let drained = expectation(description: "delivery drains cancellation")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 2)
            XCTAssertFalse(CraftNativeActions.isCancelled(token))
            let retried = try CraftNativeFiles.copyVideo(source, limit: bytes.count).get()
            let path = try XCTUnwrap((retried as? [String: Any])?["path"] as? String)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            XCTAssertTrue(CraftNativeFiles.remove(path))
            XCTAssertEqual(try importFolders(), before)
        }
    }

    func testPrecancelledImportsDoNotAllocateFilesOrOpenPicker() throws {
        let source = URL(fileURLWithPath: "/missing.mp4")
        let before = try importFolders()
        for _ in 0..<3 {
            assertImportFailure(CraftNativeFiles.copyFile(source, limit: 1, isCancelled: { true }), "CANCELLED")
            assertImportFailure(CraftNativeFiles.copyVideo(source, limit: 1, isCancelled: { true }), "CANCELLED")
            var completions = 0
            CraftNativeFiles.pickFile([:], isCancelled: { true }) { self.assertImportFailure($0, "CANCELLED"); completions += 1 }
            CraftNativeFiles.pickVideo([:], isCancelled: { true }) { self.assertImportFailure($0, "CANCELLED"); completions += 1 }
            XCTAssertEqual(completions, 2)
        }
        XCTAssertEqual(try importFolders(), before)
    }

    func testMultiFileSelectionRollsBackEarlierFilesOnCancellationOrReadFailure() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source) }
        let first = source.appendingPathComponent("first-\(UUID().uuidString).txt")
        let second = source.appendingPathComponent("second-\(UUID().uuidString).txt")
        try Data([1]).write(to: first)
        try Data(repeating: 2, count: 256 * 1024).write(to: second)
        let before = try importFolders()
        var sawFirstAndPartialSecond = false
        let result = CraftNativeFiles.copyFiles([first, second], limit: 256 * 1024, isCancelled: {
            guard self.stagedImport(first.lastPathComponent) != nil,
                  let partial = self.stagedImport(second.lastPathComponent),
                  let size = (try? fm.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber,
                  size.intValue > 0 else { return false }
            sawFirstAndPartialSecond = true
            return true
        })
        assertImportFailure(result, "CANCELLED")
        XCTAssertTrue(sawFirstAndPartialSecond)
        XCTAssertEqual(try importFolders(), before)
        try fm.removeItem(at: second)
        assertImportFailure(CraftNativeFiles.copyFiles([first, second], limit: 256 * 1024), "READ_ERROR")
        XCTAssertEqual(try importFolders(), before)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
    }

    private func removeThroughCapability(_ path: String) async throws -> Bool {
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            CraftNativeActions.perform(requestToken: UUID().uuidString, version: craftNativeCapabilityProtocolVersion,
                module: "Files", method: "remove", args: [path], config: CraftConfig()) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        return try XCTUnwrap(result as? Bool)
    }

    func testFileRemovalReportsPermissionFailureAndAllowsRetry() async throws {
        let fm = FileManager.default
        let file = try CraftNativeFiles.newFile(named: "denied.txt")
        let folder = file.deletingLastPathComponent()
        let bytes = Data("keep until deletion succeeds".utf8)
        try bytes.write(to: file)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? fm.removeItem(at: folder)
        }
        // Real filesystem denial, not an injected successful/no-op remover.
        // The file stays readable, so ownership succeeds before unlink fails.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertNotNil(CraftNativeFiles.owned(file.path))
        let denied = try await removeThroughCapability(file.path)
        XCTAssertFalse(denied, "a refused deletion must not report success")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let retried = try await removeThroughCapability(file.path)
        XCTAssertTrue(retried)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        let repeated = try await removeThroughCapability(file.path)
        XCTAssertFalse(repeated)
    }

    func testFileRemovalPreservesSiblingsAndOnlyPrunesAnEmptyParent() async throws {
        let fm = FileManager.default
        let file = try CraftNativeFiles.newFile(named: "remove.txt")
        let folder = file.deletingLastPathComponent()
        let sibling = folder.appendingPathComponent("keep.txt")
        defer { try? fm.removeItem(at: folder) }
        try Data("remove".utf8).write(to: file)
        try Data("unrelated".utf8).write(to: sibling)
        let removed = try await removeThroughCapability(file.path)
        XCTAssertTrue(removed)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("unrelated".utf8))
        let lastRemoved = try await removeThroughCapability(sibling.path)
        XCTAssertTrue(lastRemoved)
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testFileRemovalNeverDeletesTheSharedRoot() async throws {
        let fm = FileManager.default
        let other = try CraftNativeFiles.newFile(named: "other.txt")
        let direct = CraftNativeFiles.root.appendingPathComponent("direct-\(UUID().uuidString).txt")
        defer {
            try? fm.removeItem(at: direct)
            try? fm.removeItem(at: other.deletingLastPathComponent())
        }
        try Data("other import".utf8).write(to: other)
        try Data("direct file".utf8).write(to: direct)
        let removed = try await removeThroughCapability(direct.path)
        XCTAssertTrue(removed)
        XCTAssertFalse(fm.fileExists(atPath: direct.path))
        XCTAssertTrue(fm.fileExists(atPath: CraftNativeFiles.root.path))
        XCTAssertEqual(try Data(contentsOf: other), Data("other import".utf8))
    }

    func testFileRemovalSucceedsEvenWhenEmptyParentCannotBePruned() async throws {
        let fm = FileManager.default
        let outer = try CraftNativeFiles.newFile(named: "unused").deletingLastPathComponent()
        let inner = outer.appendingPathComponent("nested", isDirectory: true)
        let file = inner.appendingPathComponent("remove.txt")
        try fm.createDirectory(at: inner, withIntermediateDirectories: false)
        try Data("remove".utf8).write(to: file)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outer.path)
            try? fm.removeItem(at: outer)
        }
        // The writable inner directory permits unlink, but its read-only
        // parent refuses rmdir. Only the requested file decides the result.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outer.path)
        let removed = try await removeThroughCapability(file.path)
        XCTAssertTrue(removed)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertTrue(fm.fileExists(atPath: inner.path))
    }

    func testFileRemovalRefusesASymlinkEscapingTheOwnedRoot() async throws {
        let fm = FileManager.default
        let alias = try CraftNativeFiles.newFile(named: "alias.txt")
        let outside = fm.temporaryDirectory.appendingPathComponent("outside-removal-\(UUID().uuidString).txt")
        defer {
            try? fm.removeItem(at: alias.deletingLastPathComponent())
            try? fm.removeItem(at: outside)
        }
        try Data("unowned".utf8).write(to: outside)
        try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        let removed = try await removeThroughCapability(alias.path)
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: outside), Data("unowned".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: alias.path), outside.path)
    }

    func testCancelledImportCleanupPreservesSiblingContent() async throws {
        let fm = FileManager.default
        let imported = try CraftNativeFiles.newFile(named: "cancelled.txt")
        let folder = imported.deletingLastPathComponent()
        let sibling = folder.appendingPathComponent("keep.txt")
        defer { try? fm.removeItem(at: folder) }
        try Data("undelivered".utf8).write(to: imported)
        try Data("keep".utf8).write(to: sibling)
        let token = UUID().uuidString
        CraftNativeActions.cancel(requestToken: token)
        CraftNativeActions.completeFile(token, .success(CraftNativeFiles.describe(imported, type: "text/plain"))) { _ in
            XCTFail("cancelled import must not reach the screen")
        }
        let drained = expectation(description: "cancelled import cleanup drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertFalse(fm.fileExists(atPath: imported.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
    }

    func testCancelledImportsDiscardUndeliveredFilesAndTheirDirectories() async throws {
        // The same completion boundary receives a single photo/video descriptor
        // or a document-picker array. Exercise cancellation before and after the
        // result is queued, without pretending to automate the system picker UI.
        for multiple in [false, true] {
            for cancelBeforeCompletion in [false, true] {
                let token = UUID().uuidString
                let files = try (0..<(multiple ? 2 : 1)).map { index in
                    let file = try CraftNativeFiles.newFile(named: "import-\(index).txt")
                    try Data("imported".utf8).write(to: file)
                    return file
                }
                defer { files.forEach { CraftNativeFiles.remove($0.path) } }
                let descriptors = files.map { CraftNativeFiles.describe($0, type: "text/plain") }
                let result: Any = multiple ? descriptors as Any : descriptors[0] as Any
                if cancelBeforeCompletion { CraftNativeActions.cancel(requestToken: token) }
                CraftNativeActions.completeFile(token, .success(result)) { _ in XCTFail("cancelled import must not reach the screen") }
                if !cancelBeforeCompletion { CraftNativeActions.cancel(requestToken: token) }
                let drained = expectation(description: "main delivery queue drained")
                DispatchQueue.main.async { drained.fulfill() }
                await fulfillment(of: [drained], timeout: 2)
                for file in files {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
                }
            }
        }
    }

    func testDeliveredImportRemainsOwnedAndUnrelatedFilesAreNotDiscarded() async throws {
        let file = try CraftNativeFiles.newFile(named: "delivered.txt")
        try Data("keep".utf8).write(to: file)
        defer { CraftNativeFiles.remove(file.path) }
        let delivered = expectation(description: "import delivered")
        CraftNativeActions.completeFile(UUID().uuidString, .success(CraftNativeFiles.describe(file, type: "text/plain"))) { result in
            if case .failure = result { XCTFail("valid import must succeed") }
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNotNil(CraftNativeFiles.owned(file.path))

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("unowned-\(UUID().uuidString).txt")
        try Data("do not delete".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let token = UUID().uuidString
        CraftNativeActions.cancel(requestToken: token)
        CraftNativeActions.completeFile(token, .success(["path": outside.path])) { _ in XCTFail("cancelled completion") }
        let drained = expectation(description: "cancelled delivery drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertNotNil(CraftNativeFiles.owned(file.path))
    }

    func testImportFailureKeepsItsErrorAndCanBeRetried() async throws {
        let token = UUID().uuidString
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("retry-import-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let refused = expectation(description: "read error delivered")
        CraftNativeActions.completeFile(token, CraftNativeFiles.copyFile(source, limit: 1024)) { result in
            if case .failure(let error) = result { XCTAssertEqual(error.code, "READ_ERROR") }
            else { XCTFail("missing source must not succeed") }
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 2)
        try Data("retry".utf8).write(to: source)
        let retried = expectation(description: "retry delivered")
        var copiedPath: String?
        CraftNativeActions.completeFile(UUID().uuidString, CraftNativeFiles.copyFile(source, limit: 1024)) { result in
            if case .success(let value) = result { copiedPath = (value as? [String: Any])?["path"] as? String }
            else { XCTFail("retry must copy the readable source") }
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 2)
        let path = try XCTUnwrap(copiedPath)
        defer { CraftNativeFiles.remove(path) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("retry".utf8))
    }

    func testNamesCarryNoPath() {
        XCTAssertEqual(CraftNativeFiles.safeName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(CraftNativeFiles.safeName(".hidden"), "hidden")
        XCTAssertEqual(CraftNativeFiles.safeName("  "), "file")
        XCTAssertEqual(CraftNativeFiles.jpegName("IMG_1234.HEIC"), "IMG_1234.jpg")
        XCTAssertEqual(CraftNativeFiles.jpegName(nil), "photo.jpg")
    }

    func testOnlyFilesMadeHereAreOwned() throws {
        let made = try CraftNativeFiles.newFile(named: "route.gpx")
        try Data("<gpx/>".utf8).write(to: made)
        XCTAssertEqual(CraftNativeFiles.owned(made.path)?.lastPathComponent, "route.gpx")
        XCTAssertNil(CraftNativeFiles.owned(made.deletingLastPathComponent().path), "a folder is not a file")
        XCTAssertNil(CraftNativeFiles.owned(made.deletingLastPathComponent().appendingPathComponent("../../../Library/Preferences/x.plist").path))
        XCTAssertNil(CraftNativeFiles.owned(Bundle.main.bundlePath + "/Info.plist"))
        XCTAssertTrue(CraftNativeFiles.remove(made.path))
        XCTAssertNil(CraftNativeFiles.owned(made.path))
        XCTAssertFalse(CraftNativeFiles.remove(made.path))
    }

    func testAPhotoBecomesAnUprightJPEGNoLargerThanAsked() throws {
        let size = CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        guard case .success(let value) = CraftNativeFiles.writeJPEG(from: source, maxPixels: 200, quality: 0.8, name: "IMG_1.jpg") else {
            return XCTFail("the photo was not written")
        }
        let info = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(info["type"] as? String, "image/jpeg")
        XCTAssertEqual(info["name"] as? String, "IMG_1.jpg")
        XCTAssertEqual(info["width"] as? Int, 200)
        XCTAssertEqual(info["height"] as? Int, 150)
        let path = try XCTUnwrap(info["path"] as? String)
        XCTAssertGreaterThan(info["size"] as? Int ?? 0, 0)
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.jpeg.identifier)
        XCTAssertTrue(CraftNativeFiles.remove(path))
    }

    func testAGeneralFileIsCopiedWithItsMIMETypeAndLimit() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString).gpx")
        try Data("<gpx/>".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        guard case .success(let value) = CraftNativeFiles.copyFile(source, limit: 1024) else {
            return XCTFail("the selected document was not copied")
        }
        let info = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(info["name"] as? String, source.lastPathComponent)
        XCTAssertEqual(info["type"] as? String, "application/gpx+xml")
        XCTAssertEqual(info["size"] as? Int, 6)
        let path = try XCTUnwrap(info["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("<gpx/>".utf8))
        XCTAssertTrue(CraftNativeFiles.remove(path))

        guard case .failure(let error) = CraftNativeFiles.copyFile(source, limit: 2) else {
            return XCTFail("an oversized document was copied")
        }
        XCTAssertEqual(error.code, "FILE_TOO_LARGE")
    }

    func testAFormIsSentAsMultipartWithItsFile() throws {
        let made = try CraftNativeFiles.newFile(named: "IMG_2.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: made)
        guard case .success(let (bodyURL, boundary)) = CraftNativeFiles.multipart([
            ["name": "caption", "value": "Long run"],
            ["name": "photo", "path": made.path, "filename": "my \"best\".jpg", "type": "image/jpeg"],
        ]) else {
            return XCTFail("the form was refused")
        }
        defer { CraftNativeFiles.remove(bodyURL.path); CraftNativeFiles.remove(made.path) }
        let body = try Data(contentsOf: bodyURL)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(boundary.hasPrefix("craft-"))
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nLong run\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"photo\"; filename=\"my %22best%22.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(body.range(of: Data([0xFF, 0xD8, 0xFF, 0xD9])) != nil, "the file's bytes are in the body")
        XCTAssertTrue(text.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    func testAMultipartFilePreservesEveryStreamingChunk() throws {
        let made = try CraftNativeFiles.newFile(named: "session.mp4")
        // Span multiple 64 KiB production reads, with a partial final chunk.
        let bytes = Data((0..<(64 * 1024 * 3 + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: made)
        defer { CraftNativeFiles.remove(made.path) }
        guard case .success(let (bodyURL, boundary)) = CraftNativeFiles.multipart([
            ["name": "video", "path": made.path, "filename": "session.mp4", "type": "video/mp4"],
        ]) else { return XCTFail("the video form was refused") }
        defer { CraftNativeFiles.remove(bodyURL.path) }
        let body = try Data(contentsOf: bodyURL)
        let header = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"session.mp4\"\r\nContent-Type: video/mp4\r\n\r\n".utf8)
        let trailer = Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertEqual(body, header + bytes + trailer)
    }

    func testAFormNamesNoFileItDidNotMake() {
        guard case .failure(let error) = CraftNativeFiles.multipart([["name": "photo", "path": Bundle.main.bundlePath + "/Info.plist"]]) else {
            return XCTFail("an arbitrary file was read into a form")
        }
        XCTAssertEqual(error.code, "INVALID_ARGUMENT")
        guard case .failure = CraftNativeFiles.multipart([["value": "no name"]]) else {
            return XCTFail("a part with no name was sent")
        }
    }

    func testARefusedDownloadSaysWhyAndKeepsNothing() throws {
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString).json")
        try Data(#"{"error":"Activity not found"}"#.utf8).write(to: body)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/route.gpx")!, statusCode: 404, httpVersion: nil, headerFields: nil))
        let answer = CraftNativeFiles.refusedDownload(at: body, response: response)
        XCTAssertEqual(answer["ok"] as? Bool, false)
        XCTAssertEqual(answer["status"] as? Int, 404)
        XCTAssertEqual(answer["body"] as? String, #"{"error":"Activity not found"}"#)
        XCTAssertNil(answer["path"])
        try? FileManager.default.removeItem(at: body)
    }

    func testWhatAScreenMadeIsWrittenAsTextOrBytes() throws {
        guard case .success(let csv) = CraftNativeFiles.write(name: "health-data.csv", data: "date,steps\n2026-10-12,9120\n", options: ["type": "text/csv"]) else {
            return XCTFail("the CSV was not written")
        }
        let info = try XCTUnwrap(csv as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "health-data.csv")
        XCTAssertEqual(info["type"] as? String, "text/csv")
        let path = try XCTUnwrap(info["path"] as? String)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "date,steps\n2026-10-12,9120\n")
        CraftNativeFiles.remove(path)

        guard case .success(let png) = CraftNativeFiles.write(name: "dot.png", data: "iVBORw0KGgo=", options: ["encoding": "base64"]) else {
            return XCTFail("the bytes were not written")
        }
        XCTAssertEqual((png as? [String: Any])?["size"] as? Int, 8)
        CraftNativeFiles.remove((png as? [String: Any])?["path"] as? String ?? "")

        guard case .failure = CraftNativeFiles.write(name: "", data: "x", options: [:]) else { return XCTFail("a file with no name was written") }
        guard case .failure = CraftNativeFiles.write(name: "x.bin", data: "%%%", options: ["encoding": "base64"]) else { return XCTFail("bad base64 was written") }
        guard case .failure = CraftNativeFiles.write(name: "x.txt", data: 42, options: [:]) else { return XCTFail("a number was written") }
    }

    func testADownloadIsKeptUnderTheServersName() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).tmp")
        try Data("<gpx/>".utf8).write(to: location)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/api/activities/9/gpx")!, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/gpx+xml",
            "Content-Disposition": "attachment; filename=\"2026-10-12-long-run.gpx\"",
        ]))
        guard case .success(let value) = CraftNativeFiles.keepDownload(at: location, response: response, name: nil) else {
            return XCTFail("the download was not kept")
        }
        let info = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "2026-10-12-long-run.gpx")
        XCTAssertEqual(info["type"] as? String, "application/gpx+xml")
        XCTAssertEqual(info["ok"] as? Bool, true)
        XCTAssertEqual(info["status"] as? Int, 200)
        XCTAssertNotNil(CraftNativeFiles.owned(info["path"] as? String ?? ""))
        CraftNativeFiles.remove(info["path"] as? String ?? "")
    }

    func testAnIncompleteOfflineVideoIsNeverPublishedAndCanBeRetried() throws {
        let address = "https://example.com/interrupted-\(UUID().uuidString).mp4"
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location); try? FileManager.default.removeItem(at: CraftNativeMedia.file(for: address)) }
        try Data([1, 2]).write(to: location)
        let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4"])!
        guard case .failure = CraftNativeMedia.store(address, at: location, response: response) else { return XCTFail("truncated video was published") }
        XCTAssertNil(CraftNativeMedia.local(address))
        try Data([1, 2, 3, 4]).write(to: location)
        if case .failure(let error) = CraftNativeMedia.store(address, at: location, response: response) {
            return XCTFail("retry failed: \(error.code): \(error.message)")
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(CraftNativeMedia.local(address))), Data([1, 2, 3, 4]))
    }

    func testOfflineVideoRecognizesWrappedDiskFullErrorsWithoutCallingOtherFailuresFull() {
        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.ENOSPC.rawValue))
        let wrapped = NSError(domain: NSURLErrorDomain, code: URLError.cannotWriteToFile.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                                      userInfo: [NSUnderlyingErrorKey: full])])
        XCTAssertEqual(CraftNativeMedia.errorCode(wrapped, fallback: "NETWORK_ERROR"), "NO_SPACE")
        XCTAssertEqual(CraftNativeMedia.errorCode(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), fallback: "IO_ERROR"), "NO_SPACE")
        XCTAssertEqual(CraftNativeMedia.errorCode(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.EACCES.rawValue)), fallback: "IO_ERROR"), "IO_ERROR")
        XCTAssertEqual(CraftNativeMedia.errorCode(URLError(.notConnectedToInternet), fallback: "NETWORK_ERROR"), "NETWORK_ERROR")
    }

    func testABackgroundTransferFromBeforeASignOutNeverLands() throws {
        let address = "https://example.com/before-sign-out-\(UUID().uuidString).mp4"
        let started = CraftNativeMediaTransfers.shared.currentGeneration
        _ = try CraftNativeMedia.clear()
        XCTAssertFalse(CraftNativeMediaTransfers.shared.isCurrent(started))
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }
        let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4"])!
        let landed = CraftNativeMedia.store(address, at: location, response: response, stillWanted: { CraftNativeMediaTransfers.shared.isCurrent(started) })
        guard case .failure(let error) = landed else { return XCTFail("A signed-out account's video was kept") }
        XCTAssertEqual(error.code, "CANCELLED")
        XCTAssertNil(CraftNativeMedia.local(address))
    }

    func testATransferWhoseKeepWasAnsweredEarlyStillLands() throws {
        let address = "https://example.com/queued-\(UUID().uuidString).mp4"
        defer { try? FileManager.default.removeItem(at: CraftNativeMedia.file(for: address)) }
        // Answered "waiting for Wi-Fi": the flight is gone, the transfer is not.
        let flight = try XCTUnwrap(CraftNativeMedia.begin(address) { _ in })
        CraftNativeMedia.finish(address, flight: flight, .success(["ok": false, "reason": "cellular", "queued": true]))
        XCTAssertFalse(CraftNativeMedia.isWaiting(address, flight: flight))
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([9, 8, 7]).write(to: location)
        let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "3"])!
        let started = CraftNativeMediaTransfers.shared.currentGeneration
        if case .failure(let error) = CraftNativeMedia.store(address, at: location, response: response, stillWanted: { CraftNativeMediaTransfers.shared.isCurrent(started) }) {
            return XCTFail("queued transfer was dropped: \(error.code)")
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(CraftNativeMedia.local(address))), Data([9, 8, 7]))
    }

    func testKeepingAVideoDownloadsItOnTheBackgroundSessionAndAnswers() throws {
        let body = Data("craft-video".utf8)
        let server = try OneFileServer(body: body)
        defer { server.stop() }
        let address = "http://127.0.0.1:\(try server.port())/clip-\(UUID().uuidString).mp4"
        defer { try? FileManager.default.removeItem(at: CraftNativeMedia.file(for: address)) }
        let answered = expectation(description: "the keep is answered")
        var answer: Result<Any, CraftNativeActionError>?
        let flight = try XCTUnwrap(CraftNativeMedia.begin(address) { answer = $0; answered.fulfill() })
        let task = CraftNativeMediaTransfers.shared.start(URLRequest(url: URL(string: address)!), address: address, flight: flight, wifiOnly: false)
        XCTAssertEqual(task.taskDescription, address)
        wait(for: [answered], timeout: 30)
        guard case .success(let value)? = answer, let info = value as? [String: Any] else { return XCTFail("keep failed: \(String(describing: answer))") }
        XCTAssertEqual(info["ok"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(CraftNativeMedia.local(address))), body)
        // A second keep answers from the copy, whatever the network.
        XCTAssertNotNil(CraftNativeMedia.local(address))
    }

    func testClearingVideosInvalidatesOldTransfersWithoutLosingANewTransferForTheSameURL() throws {
        let address = "https://example.com/account-\(UUID().uuidString).mp4"
        var cancelled = false
        let old = try XCTUnwrap(CraftNativeMedia.begin(address) {
            if case .failure(let error) = $0 { cancelled = error.code == "CANCELLED" }
        })
        _ = try CraftNativeMedia.clear()
        XCTAssertTrue(cancelled)
        var finished = false
        let fresh = try XCTUnwrap(CraftNativeMedia.begin(address) { if case .success = $0 { finished = true } })
        let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4"])!
        let before = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: before)
        defer { try? FileManager.default.removeItem(at: before) }
        let denied = CraftNativeMedia.store(address, at: before, response: response, flight: old)
        guard case .failure(let error) = denied else { return XCTFail("Old account's video was published") }
        XCTAssertEqual(error.code, "CANCELLED")
        CraftNativeMedia.finish(address, flight: old, denied)
        let after = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([5, 6, 7, 8]).write(to: after)
        CraftNativeMedia.finish(address, flight: fresh, CraftNativeMedia.store(address, at: after, response: response, flight: fresh))
        XCTAssertTrue(finished)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(CraftNativeMedia.local(address))), Data([5, 6, 7, 8]))
        _ = try CraftNativeMedia.clear()
    }

    func testAnUnsolicitedPartialOrEmptyVideoIsNeverPublished() throws {
        for status in [200, 206] {
            let address = "https://example.com/empty-\(UUID().uuidString).mp4"
            let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data().write(to: location)
            defer { try? FileManager.default.removeItem(at: location) }
            let response = HTTPURLResponse(url: URL(string: address)!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "0"])!
            _ = CraftNativeMedia.store(address, at: location, response: response)
            XCTAssertNil(CraftNativeMedia.local(address))
        }
    }

}

/// A one-file HTTP server on 127.0.0.1 for the background transfer test.
private final class OneFileServer {
    private let listener: NWListener
    private let ready = DispatchSemaphore(value: 0)

    init(body: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                reply.append(body)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    func port() throws -> UInt16 {
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        return port
    }

    func stop() { listener.cancel() }
}
