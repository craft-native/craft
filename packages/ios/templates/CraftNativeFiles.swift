import CryptoKit
import Foundation
import ImageIO
import Network
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// `craft.files` on a native screen: a photo picked from the library (or taken
// with the camera), a file downloaded for the share sheet, and those files
// sent as a multipart form through the screen's `fetch`.
//
// A file is a path in the app's temporary directory (tmp/craft-files/<id>/
// <name>), described to JavaScript as `{ path, name, type, size }`. Its bytes
// never cross the bridge: a picked photo goes from the picker to disk to the
// upload without becoming a base64 string in JavaScriptCore, so a photo costs
// what its file costs rather than a third more, twice over, in the screen's
// memory. `fetch` and the share sheet take the path; only files made here are
// read back for a form, so a screen cannot post an arbitrary file of the app's.

enum CraftNativeFiles {
    /// The longest side of a picked photo unless the screen asks otherwise:
    /// sharp on any phone screen and in a share card, a few hundred kilobytes
    /// as JPEG, where the original can be 48 megapixels of HEIC.
    static let defaultMaxPixels = 2048
    static let largestMaxPixels = 8192
    static let defaultQuality = 0.85
    /// The part of a refused download's answer handed back, for its error.
    static let errorBodyLimit = 64 * 1024

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("craft-files", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var swept = false
    /// The picker on screen, kept alive until it answers. One at a time.
    private static var activePicker: NSObject?

    // MARK: Files of our own

    /// A new file called `name`, in a folder of its own so two files can share
    /// a name (the share sheet shows it).
    static func newFile(named name: String) throws -> URL {
        sweepOnce()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(safeName(name))
    }

    /// The file at `path` when it is one made here and still there, else nil.
    static func owned(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(base),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    /// A file name with no path in it.
    static func safeName(_ name: String) -> String {
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}\r\n"))
        var cleaned = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    static func describe(_ url: URL, type: String, extra: [String: Any] = [:]) -> [String: Any] {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        var info: [String: Any] = ["path": url.path, "name": url.lastPathComponent, "type": type, "size": size]
        for (key, value) in extra { info[key] = value }
        return info
    }

    /// Forget a file made here. True when there was one.
    @discardableResult
    static func remove(_ path: String) -> Bool {
        guard let url = owned(path) else { return false }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return true
    }

    /// Files from earlier launches that nobody removed: the system clears tmp
    /// eventually, this clears what is a day old the first time a file is made.
    private static func sweepOnce() {
        lock.lock()
        let first = !swept
        swept = true
        lock.unlock()
        guard first else { return }
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            // Only generic per-file folders: private voice captures have their
            // own launch lifetime and must not be swept during a live recording.
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < dayAgo { try? fm.removeItem(at: folder) }
        }
    }

    // MARK: Picking a photo

    /// A photo from the library (PHPickerViewController: no permission asked,
    /// the person sees only the picker) or, with `source: 'camera'` and the
    /// camera enabled, a new one (UIImagePickerController). Saved as a JPEG no
    /// larger than `maxPixels` on its longest side, upright, with no metadata
    /// (no location) left in it. Answers the file, or null when the person
    /// closed the picker. Main thread.
    static func pickImage(_ options: [String: Any], cameraEnabled: Bool, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        let maxPixels = craftNativeNumber(options["maxPixels"])
            .map { $0.doubleValue }
            .flatMap { value in
                guard value.isFinite else { return nil }
                return Int(max(64, min(Double(largestMaxPixels), value)))
            } ?? defaultMaxPixels
        let quality = min(1, max(0.1, craftNativeNumber(options["quality"])
            .map { $0.doubleValue }
            .flatMap { $0.isFinite ? $0 : nil } ?? defaultQuality))
        let source = options["source"] as? String ?? "library"
        guard activePicker == nil else {
            done(.failure(CraftNativeActionError(code: "BUSY", message: "A picker is already open")))
            return
        }
        let finish: (Result<Any, CraftNativeActionError>) -> Void = { result in
            DispatchQueue.main.async {
                activePicker = nil
                done(result)
            }
        }

        if source == "camera" {
            guard cameraEnabled else {
                done(.failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "The camera is disabled")))
                return
            }
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                done(.failure(CraftNativeActionError(code: "UNAVAILABLE", message: "This device has no camera")))
                return
            }
            let delegate = CameraDelegate(maxPixels: maxPixels, quality: quality, done: finish)
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = delegate
            activePicker = delegate
            if !CraftPresenter.present(picker, from: nil) {
                activePicker = nil
                done(.failure(CraftNativeActionError(code: "PICKER_ERROR", message: "Unable to present the camera")))
            }
            return
        }
        guard source == "library" else {
            done(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.pickImage source is 'library' or 'camera'")))
            return
        }

        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        // The file as it is (HEIC stays HEIC): it is decoded once, below, at the size wanted.
        configuration.preferredAssetRepresentationMode = .current
        let delegate = LibraryDelegate(maxPixels: maxPixels, quality: quality, done: finish)
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = delegate
        activePicker = delegate
        if !CraftPresenter.present(picker, from: nil) {
            activePicker = nil
            done(.failure(CraftNativeActionError(code: "PICKER_ERROR", message: "Unable to present the photo picker")))
        }
    }

    /// Decode `source` at no more than `maxPixels` on its longest side, turned
    /// upright, and write it as a JPEG. ImageIO's thumbnail reads only what
    /// that size needs, so a huge original never sits in memory whole.
    static func writeJPEG(from source: CGImageSource, maxPixels: Int, quality: Double, name: String) -> Result<Any, CraftNativeActionError> {
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else {
            return .failure(CraftNativeActionError(code: "DECODE_ERROR", message: "The photo could not be read"))
        }
        return writeJPEG(image, quality: quality, name: name)
    }

    static func writeJPEG(_ image: CGImage, quality: Double, name: String) -> Result<Any, CraftNativeActionError> {
        do {
            let url = try newFile(named: name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                return .failure(CraftNativeActionError(code: "WRITE_ERROR", message: "The photo could not be saved"))
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                return .failure(CraftNativeActionError(code: "WRITE_ERROR", message: "The photo could not be saved"))
            }
            return .success(describe(url, type: "image/jpeg", extra: ["width": image.width, "height": image.height]))
        } catch {
            return .failure(CraftNativeActionError(code: "WRITE_ERROR", message: error.localizedDescription))
        }
    }

    /// `IMG_1234.jpg` for the picker's `IMG_1234`, `photo.jpg` without one.
    static func jpegName(_ suggested: String?) -> String {
        var base = safeName(suggested ?? "photo")
        if let dot = base.lastIndex(of: "."), dot > base.startIndex { base = String(base[..<dot]) }
        return "\(base).jpg"
    }

    private final class LibraryDelegate: NSObject, PHPickerViewControllerDelegate {
        let maxPixels: Int
        let quality: Double
        let done: (Result<Any, CraftNativeActionError>) -> Void

        init(maxPixels: Int, quality: Double, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
            self.maxPixels = maxPixels
            self.quality = quality
            self.done = done
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else {
                done(.success(NSNull()))
                return
            }
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                done(.failure(CraftNativeActionError(code: "DECODE_ERROR", message: "That is not a photo")))
                return
            }
            let name = CraftNativeFiles.jpegName(provider.suggestedName)
            let (maxPixels, quality, done) = (self.maxPixels, self.quality, self.done)
            // The file is only there for the length of this callback.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    done(.failure(CraftNativeActionError(code: "DECODE_ERROR", message: error?.localizedDescription ?? "The photo could not be read")))
                    return
                }
                done(CraftNativeFiles.writeJPEG(from: source, maxPixels: maxPixels, quality: quality, name: name))
            }
        }
    }

    private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let maxPixels: Int
        let quality: Double
        let done: (Result<Any, CraftNativeActionError>) -> Void

        init(maxPixels: Int, quality: Double, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
            self.maxPixels = maxPixels
            self.quality = quality
            self.done = done
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage else {
                done(.failure(CraftNativeActionError(code: "DECODE_ERROR", message: "The photo could not be read")))
                return
            }
            // Drawn at the size wanted, which also turns it upright.
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            let factor = min(1, CGFloat(maxPixels) / max(1, longest))
            let size = CGSize(width: (image.size.width * image.scale * factor).rounded(), height: (image.size.height * image.scale * factor).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let cgImage = drawn.cgImage else {
                done(.failure(CraftNativeActionError(code: "DECODE_ERROR", message: "The photo could not be read")))
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            done(CraftNativeFiles.writeJPEG(cgImage, quality: quality, name: "IMG_\(formatter.string(from: Date())).jpg"))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            done(.success(NSNull()))
        }
    }

    // MARK: Picking a video

    /// System pickers grant access to just the selected video. Copy it while
    /// the provider's URL is valid; no movie bytes cross JavaScriptCore.
    static func pickVideo(_ options: [String: Any], done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        guard activePicker == nil else {
            done(.failure(CraftNativeActionError(code: "BUSY", message: "A picker is already open")))
            return
        }
        let limit = craftNativeNumber(options["maxBytes"])
            .map { $0.doubleValue }
            .flatMap { value in
                guard value.isFinite else { return nil }
                return Int(max(1, min(Double(512 * 1024 * 1024), value)))
            } ?? 512 * 1024 * 1024
        let finish: (Result<Any, CraftNativeActionError>) -> Void = { result in
            DispatchQueue.main.async { activePicker = nil; done(result) }
        }
        if options["source"] as? String == "files" {
            let delegate = VideoDocumentDelegate(limit: limit, done: finish)
            var types: [UTType] = [.movie]
            if let webm = UTType(filenameExtension: "webm") { types.append(webm) }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = delegate
            activePicker = delegate
            if !CraftPresenter.present(picker, from: nil) {
                activePicker = nil
                done(.failure(CraftNativeActionError(code: "PICKER_ERROR", message: "Unable to present the video picker")))
            }
        } else {
            var configuration = PHPickerConfiguration()
            configuration.filter = .videos
            configuration.selectionLimit = 1
            configuration.preferredAssetRepresentationMode = .current
            let delegate = VideoLibraryDelegate(limit: limit, done: finish)
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = delegate
            activePicker = delegate
            if !CraftPresenter.present(picker, from: nil) {
                activePicker = nil
                done(.failure(CraftNativeActionError(code: "PICKER_ERROR", message: "Unable to present the video picker")))
            }
        }
    }

    // MARK: Picking a general file

    /// Pick one or more documents and copy them into app-owned storage while
    /// the security-scoped URLs are valid. `contentTypes` accepts MIME types,
    /// UTIs, or filename extensions; an empty list means any document.
    static func pickFile(_ options: [String: Any], done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        guard activePicker == nil else {
            done(.failure(CraftNativeActionError(code: "BUSY", message: "A picker is already open")))
            return
        }
        let limit = craftNativeNumber(options["maxBytes"])
            .map { $0.doubleValue }
            .flatMap { value in
                guard value.isFinite else { return nil }
                return Int(max(1, min(Double(512 * 1024 * 1024), value)))
            } ?? 512 * 1024 * 1024
        let selectionLimit = craftNativeNumber(options["maxSelections"])
            .map { $0.intValue }
            .map { max(1, min(20, $0)) } ?? 1
        let types: [UTType]
        do {
            types = try documentTypes(options["contentTypes"])
        } catch let error as CraftNativeActionError {
            done(.failure(error))
            return
        } catch {
            done(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.pickFile contentTypes are invalid")))
            return
        }
        let finish: (Result<Any, CraftNativeActionError>) -> Void = { result in
            DispatchQueue.main.async { activePicker = nil; done(result) }
        }
        let delegate = FileDocumentDelegate(limit: limit, done: finish)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = selectionLimit > 1
        picker.delegate = delegate
        activePicker = delegate
        if !CraftPresenter.present(picker, from: nil) {
            activePicker = nil
            done(.failure(CraftNativeActionError(code: "PICKER_ERROR", message: "Unable to present the file picker")))
        }
    }

    /// Resolve an app-supplied content filter without silently broadening it.
    /// A MIME type, UTI, or extension is enough for `UTType`; applications can
    /// therefore ask for `application/pdf`, `com.adobe.pdf`, or `pdf` alike.
    private static func documentTypes(_ value: Any?) throws -> [UTType] {
        guard let value else { return [.item] }
        guard let entries = value as? [Any] else {
            throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.pickFile contentTypes must be an array")
        }
        guard !entries.isEmpty else { return [.item] }
        var types: [UTType] = []
        for entry in entries {
            guard let raw = entry as? String else {
                throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.pickFile contentTypes must be strings")
            }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let type = UTType(mimeType: name) ?? UTType(name) ?? UTType(filenameExtension: name.trimmingCharacters(in: CharacterSet(charactersIn: "."))) else {
                throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.pickFile contentType is not a MIME type, UTI, or extension: \(raw)")
            }
            types.append(type)
        }
        return types
    }

    /// Copy an arbitrary selected document into Craft's private file area and
    /// return the same descriptor used by downloads, writes, and uploads.
    static func copyFile(_ source: URL, limit: Int) -> Result<Any, CraftNativeActionError> {
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let size: Int
            if let fileSize = values.fileSize {
                size = fileSize
            } else {
                size = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.intValue ?? 0
            }
            guard size > 0, size <= limit else {
                return .failure(CraftNativeActionError(code: "FILE_TOO_LARGE", message: "Choose a nonempty file under \(limit / 1024 / 1024)MB."))
            }
            let destination = try newFile(named: source.lastPathComponent)
            do { try FileManager.default.copyItem(at: source, to: destination) }
            catch { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw error }
            let type = mimeType(for: source, contentType: values.contentType)
            return .success(describe(destination, type: type))
        } catch {
            return .failure(CraftNativeActionError(code: "READ_ERROR", message: error.localizedDescription))
        }
    }

    private static func mimeType(for source: URL, contentType: UTType?) -> String {
        let generic = "application/octet-stream"
        if let preferred = contentType?.preferredMIMEType, preferred != generic { return preferred }
        if let preferred = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType, preferred != generic {
            return preferred
        }
        switch source.pathExtension.lowercased() {
        case "gpx": return "application/gpx+xml"
        case "tcx": return "application/vnd.garmin.tcx+xml"
        case "fit": return "application/vnd.ant.fit"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "txt": return "text/plain"
        default: return generic
        }
    }

    private final class FileDocumentDelegate: NSObject, UIDocumentPickerDelegate {
        let limit: Int
        let done: (Result<Any, CraftNativeActionError>) -> Void
        init(limit: Int, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) { self.limit = limit; self.done = done }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(.success([])) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { done(.success([])); return }
            let (limit, done) = (self.limit, self.done)
            DispatchQueue.global(qos: .userInitiated).async {
                var results: [[String: Any]] = []
                for url in urls {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    switch CraftNativeFiles.copyFile(url, limit: limit) {
                    case .success(let value):
                        guard let info = value as? [String: Any] else { done(.failure(CraftNativeActionError(code: "READ_ERROR", message: "The selected file could not be described"))); return }
                        results.append(info)
                    case .failure(let error):
                        results.compactMap { $0["path"] as? String }.forEach { CraftNativeFiles.remove($0) }
                        done(.failure(error))
                        return
                    }
                }
                done(.success(results))
            }
        }
    }

    static func copyVideo(_ source: URL, limit: Int) -> Result<Any, CraftNativeActionError> {
        let ext = source.pathExtension.lowercased()
        let types = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm"]
        guard let type = types[ext] else {
            return .failure(CraftNativeActionError(code: "INVALID_VIDEO", message: "Choose an MP4, MOV or WebM video."))
        }
        do {
            let size = ((try FileManager.default.attributesOfItem(atPath: source.path))[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= limit else {
                return .failure(CraftNativeActionError(code: "FILE_TOO_LARGE", message: "Choose a nonempty video under \(limit / 1024 / 1024)MB."))
            }
            let destination = try newFile(named: source.lastPathComponent)
            do { try FileManager.default.copyItem(at: source, to: destination) }
            catch { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw error }
            return .success(describe(destination, type: type))
        } catch {
            return .failure(CraftNativeActionError(code: "READ_ERROR", message: error.localizedDescription))
        }
    }

    private final class VideoLibraryDelegate: NSObject, PHPickerViewControllerDelegate {
        let limit: Int
        let done: (Result<Any, CraftNativeActionError>) -> Void
        init(limit: Int, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) { self.limit = limit; self.done = done }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { done(.success(NSNull())); return }
            let (limit, done) = (self.limit, self.done)
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url else {
                    done(.failure(CraftNativeActionError(code: "READ_ERROR", message: error?.localizedDescription ?? "The video could not be read")))
                    return
                }
                done(CraftNativeFiles.copyVideo(url, limit: limit))
            }
        }
    }

    private final class VideoDocumentDelegate: NSObject, UIDocumentPickerDelegate {
        let limit: Int
        let done: (Result<Any, CraftNativeActionError>) -> Void
        init(limit: Int, done: @escaping (Result<Any, CraftNativeActionError>) -> Void) { self.limit = limit; self.done = done }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(.success(NSNull())) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { done(.success(NSNull())); return }
            let (limit, done) = (self.limit, self.done)
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                done(CraftNativeFiles.copyVideo(url, limit: limit))
            }
        }
    }

    // MARK: Sending files

    /// A multipart/form-data body from a screen's `FormData`: parts are
    /// `{ name, value }` or `{ name, path, filename?, type? }`, a file made
    /// here. Answers the body and its boundary.
    static func multipart(_ parts: [Any]) -> Result<(URL, String), CraftNativeActionError> {
        let boundary = "craft-\(UUID().uuidString)"
        var temporary: URL?
        do {
            let destination = try newFile(named: "upload.multipart")
            temporary = destination
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            func append(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            for item in parts {
                guard let part = item as? [String: Any], let name = part["name"] as? String else {
                    throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "A form part needs a name")
                }
                try append("--\(boundary)\r\n")
                if let path = part["path"] as? String {
                    guard let url = owned(path) else {
                        throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "A form file must be one craft.files made, and still there")
                    }
                    let filename = (part["filename"] as? String).map(safeName) ?? url.lastPathComponent
                    let type = (part["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
                    try append("Content-Disposition: form-data; name=\"\(quoted(name))\"; filename=\"\(quoted(filename))\"\r\n")
                    try append("Content-Type: \(type.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n\r\n")
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        try output.write(contentsOf: chunk)
                    }
                    try append("\r\n")
                } else {
                    try append("Content-Disposition: form-data; name=\"\(quoted(name))\"\r\n\r\n")
                    try append(part["value"] as? String ?? "")
                    try append("\r\n")
                }
            }
            try append("--\(boundary)--\r\n")
            return .success((destination, boundary))
        } catch {
            if let temporary { remove(temporary.path) }
            return .failure((error as? CraftNativeActionError) ?? CraftNativeActionError(code: "WRITE_ERROR", message: error.localizedDescription))
        }
    }

    /// A name inside a quoted header value, escaped as browsers send it.
    static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Keep a downloaded body as a file made here: the name the screen gave,
    /// else the server's (`Content-Disposition`), else the address's.
    static func keepDownload(at location: URL, response: HTTPURLResponse, name: String?) -> Result<Any, CraftNativeActionError> {
        let chosen = name.flatMap { $0.isEmpty ? nil : $0 } ?? response.suggestedFilename ?? "download"
        do {
            let url = try newFile(named: chosen)
            try FileManager.default.moveItem(at: location, to: url)
            let type = (response.mimeType ?? "application/octet-stream")
            return .success(describe(url, type: type, extra: ["ok": true, "status": response.statusCode]))
        } catch {
            return .failure(CraftNativeActionError(code: "WRITE_ERROR", message: error.localizedDescription))
        }
    }

    /// What a screen made itself (a CSV export, a route it built) written as
    /// a file for the share sheet: `data` is text (`encoding: 'utf8'`, the
    /// default, so a CSV crosses the bridge once and no larger) or base64
    /// (`encoding: 'base64'`, for bytes). What is already on a server is
    /// `download`ed instead, straight to disk.
    static func write(name: String, data: Any?, options: [String: Any]) -> Result<Any, CraftNativeActionError> {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.write needs a file name"))
        }
        guard let text = data as? String else {
            return .failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.write needs its contents as a string"))
        }
        let bytes: Data
        switch options["encoding"] as? String ?? "utf8" {
        case "utf8":
            bytes = Data(text.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: text.filter { !$0.isWhitespace }) else {
                return .failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.write was given base64 it could not read"))
            }
            bytes = decoded
        default:
            return .failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "files.write encoding is 'utf8' or 'base64'"))
        }
        let type = (options["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        do {
            let url = try newFile(named: name)
            try bytes.write(to: url, options: .atomic)
            return .success(describe(url, type: type))
        } catch {
            return .failure(CraftNativeActionError(code: "WRITE_ERROR", message: error.localizedDescription))
        }
    }

    /// A refused download: its status and the start of its answer, so the
    /// screen can say what the server said. No file is kept.
    static func refusedDownload(at location: URL?, response: HTTPURLResponse) -> [String: Any] {
        var text = ""
        if let location, let handle = try? FileHandle(forReadingFrom: location) {
            let data = handle.readData(ofLength: errorBodyLimit)
            try? handle.close()
            text = String(decoding: data, as: UTF8.self)
        }
        return ["ok": false, "status": response.statusCode, "body": text]
    }
}

// `craft.media` on a native screen: video and audio kept on the phone for
// when there is no signal (a gym's basement, a plane). Not tmp/craft-files,
// which iOS and the sweep above both empty: Application Support/craft-media,
// left out of iCloud backups because every file can be fetched again. A file
// is named by its address's SHA-256, so the native `Video` element finds the
// copy of the URL it was given and plays it instead, with no lookup in
// JavaScript. The screen decides what to keep (`keep`) and what to drop
// (`prune`); nothing is evicted behind its back.
enum CraftNativeMedia {
    /// Foundation often wraps ENOSPC inside a URL or Cocoa file error.
    static func errorCode(_ error: Error, fallback: String) -> String {
        var cause: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let current = cause, seen.insert(ObjectIdentifier(current)).inserted {
            if (current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError)
                || (current.domain == NSPOSIXErrorDomain && current.code == Int(POSIXError.Code.ENOSPC.rawValue)) {
                return "NO_SPACE"
            }
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return fallback
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("craft-media", isDirectory: true)
    }

    private static let lock = NSLock()
    /// Addresses being fetched now, so a second `keep` waits for the first.
    private struct Flight {
        let id: UUID
        var waiting: [(Result<Any, CraftNativeActionError>) -> Void]
    }
    private static var inFlight: [String: Flight] = [:]

    /// Where `address`'s copy lives (whether or not it is there yet). The
    /// extension is the address's, because AVPlayer reads the type from it.
    static func file(for address: String) -> URL {
        let digest = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = URL(string: address)?.pathExtension.lowercased() ?? ""
        let safe = ext.range(of: "^[a-z0-9]{1,5}$", options: .regularExpression) != nil ? ext : "bin"
        return root.appendingPathComponent("\(digest).\(safe)")
    }

    /// The copy of `address` on this phone, or nil.
    static func local(_ address: String) -> URL? {
        guard !address.isEmpty else { return nil }
        let url = file(for: address)
        return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 ? url : nil
    }

    static func describe(_ address: String, _ url: URL) -> [String: Any] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["ok": true, "url": address, "path": url.path, "size": size]
    }

    /// A new download's identity, or nil after joining an existing download.
    static func begin(_ address: String, _ done: @escaping (Result<Any, CraftNativeActionError>) -> Void) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if inFlight[address] != nil {
            inFlight[address]!.waiting.append(done)
            return nil
        }
        let id = UUID()
        inFlight[address] = Flight(id: id, waiting: [done])
        return id
    }

    /// Whether `flight` is still the download `address`'s keeps wait for.
    static func isWaiting(_ address: String, flight: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[address]?.id == flight
    }

    static func finish(_ address: String, flight: UUID, _ result: Result<Any, CraftNativeActionError>) {
        lock.lock()
        let waiting = inFlight[address]?.id == flight ? inFlight.removeValue(forKey: address)?.waiting ?? [] : []
        lock.unlock()
        for done in waiting { done(result) }
    }

    /// A finished download moved into place (atomically, so a half-written
    /// file is never played), or a refusal with the server's status.
    static func store(_ address: String, at location: URL, response: HTTPURLResponse, flight: UUID? = nil, stillWanted: (() -> Bool)? = nil) -> Result<Any, CraftNativeActionError> {
        guard response.statusCode == 200 else {
            return .success(["ok": false, "url": address, "status": response.statusCode])
        }
        let fm = FileManager.default
        // Commit and prune share a lock; neither can remove a file being committed.
        lock.lock()
        defer { lock.unlock() }
        if let flight, inFlight[address]?.id != flight {
            return .failure(CraftNativeActionError(code: "CANCELLED", message: "The media cache was cleared"))
        }
        // A background transfer from before the cache was cleared (sign-out).
        if let stillWanted, !stillWanted() {
            return .failure(CraftNativeActionError(code: "CANCELLED", message: "The media cache was cleared"))
        }
        let staging = root.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? fm.removeItem(at: staging) }
        do {
            // URL resource values can retain a previous size when a retry
            // reuses a temporary location. Validate the current file itself.
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            // URLSession normally rejects a truncated transfer; also guard this boundary.
            let expected = response.expectedContentLength
            let encoded = response.value(forHTTPHeaderField: "Content-Encoding")
            if size <= 0 || (encoded == nil && expected >= 0 && size != expected) {
                return .failure(CraftNativeActionError(code: "NETWORK_ERROR", message: "media.keep received an incomplete file"))
            }
            var folder = root
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? folder.setResourceValues(values)
            }
            let target = file(for: address)
            try fm.moveItem(at: location, to: staging)
            _ = try? fm.removeItem(at: target)
            try fm.moveItem(at: staging, to: target)
            return .success(describe(address, target))
        }
        catch {
            return .failure(CraftNativeActionError(code: errorCode(error, fallback: "IO_ERROR"), message: "media.keep could not store the file: \(error.localizedDescription)"))
        }
    }

    /// End an account's cache lifetime.
    static func clear() throws -> Int {
        lock.lock()
        let waiting = inFlight.values.flatMap { $0.waiting }
        inFlight.removeAll()
        // Under the same lock a background transfer commits under: none
        // started before this lands after it.
        CraftNativeMediaTransfers.shared.cancelAll()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        var failure: Error?
        for url in files {
            do { try fm.removeItem(at: url); removed += 1 }
            catch { failure = error }
        }
        lock.unlock()
        for done in waiting { done(.failure(CraftNativeActionError(code: "CANCELLED", message: "The media cache was cleared"))) }
        if let failure { throw failure }
        return removed
    }

    /// Removes every copy whose address is not in `keep`; answers how many.
    static func prune(keep: [String]) -> Int {
        CraftNativeMediaTransfers.shared.cancel(except: keep + Array(inFlightAddresses()))
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(keep.map { file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        let active = Set(inFlight.keys.map { file(for: $0).lastPathComponent })
        for url in files where !wanted.contains(url.lastPathComponent) && !active.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private static func inFlightAddresses() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(inFlight.keys)
    }

    /// What the kept copies come to, in bytes, and how many there are.
    static func usage() -> [String: Any] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let kept = files.filter { $0.pathExtension != "part" }
        let bytes = kept.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ["files": kept.count, "bytes": bytes]
    }
}

/// The downloads `media.keep` starts, on a background URLSession: a transfer
/// carries on while the app is suspended or closed, waits for Wi-Fi when it
/// was asked to, and lands in CraftNativeMedia when it finishes, whether or
/// not anyone is still waiting for it (the address travels with the task as
/// its description, so a transfer outlives the launch that started it).
///
/// A request answers as soon as its file is kept, or at once with
/// `{ ok: false, reason: "cellular" | "offline", queued: true }` when the
/// phone cannot fetch it now: the transfer stays with iOS and finishes on
/// its own, and the next `keep` of that address answers from the copy.
final class CraftNativeMediaTransfers: NSObject, URLSessionDownloadDelegate {
    static let shared = CraftNativeMediaTransfers()
    static var identifier: String { "\(Bundle.main.bundleIdentifier ?? "dev.craft.app").craft-media" }

    /// iOS's handler from relaunching the app for this session's events.
    var backgroundCompletion: (() -> Void)?

    private struct Transfer {
        let address: String
        /// The keep still waiting for this transfer; nil once answered early.
        var flight: UUID?
        let wifiOnly: Bool
        /// Transfers from before the last `clear` must not land.
        let generation: Int
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    /// What each finished download came to, until its task completes.
    private var finished: [Int: Result<Any, CraftNativeActionError>] = [:]
    /// Transfers left running by an earlier launch, by address.
    private var restored: [String: URLSessionDownloadTask] = [:]
    private var generation = 0
    private let monitor = NWPathMonitor()

    /// Made once, at first use: iOS hands this identifier's finished
    /// transfers to whichever session object the app makes with it.
    private(set) var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            for case let task as URLSessionDownloadTask in tasks where task.state == .running || task.state == .suspended {
                if let address = task.taskDescription, self.transfers[task.taskIdentifier] == nil { self.restored[address] = task }
            }
            self.lock.unlock()
        }
        // A connection lost (or only a metered one left for a Wi-Fi-only
        // keep) answers the waiting keeps; their transfers carry on later.
        monitor.pathUpdateHandler = { [weak self] path in self?.release(on: path) }
        monitor.start(queue: DispatchQueue(label: "dev.craft.native.media.path"))
    }

    /// Fetches `request` into the copy for `address`, finishing `flight`.
    func start(_ request: URLRequest, address: String, flight: UUID, wifiOnly: Bool) -> URLSessionTask {
        lock.lock()
        let task: URLSessionDownloadTask
        if let earlier = restored.removeValue(forKey: address), earlier.state == .running || earlier.state == .suspended {
            task = earlier
        }
        else {
            task = session.downloadTask(with: request)
            task.taskDescription = address
        }
        transfers[task.taskIdentifier] = Transfer(address: address, flight: flight, wifiOnly: wifiOnly, generation: generation)
        lock.unlock()
        task.resume()
        release(on: monitor.currentPath)
        return task
    }

    /// Answers the keeps that cannot be fetched on `path`; their transfers stay queued with iOS.
    private func release(on path: NWPath) {
        let offline = path.status != .satisfied
        let metered = path.isExpensive || path.isConstrained
        lock.lock()
        var answered: [(String, UUID, String)] = []
        for (id, transfer) in transfers {
            guard let flight = transfer.flight, offline || (transfer.wifiOnly && metered) else { continue }
            transfers[id]?.flight = nil
            answered.append((transfer.address, flight, offline ? "offline" : "cellular"))
        }
        lock.unlock()
        for (address, flight, reason) in answered {
            CraftNativeMedia.finish(address, flight: flight, .success(["ok": false, "url": address, "reason": reason, "queued": true]))
        }
    }

    /// Stops every transfer: an account's copies are being cleared, and none of its videos may land after.
    func cancelAll() {
        lock.lock()
        generation += 1
        restored.removeAll()
        lock.unlock()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    /// Stops the transfers for addresses no longer wanted.
    func cancel(except keep: [String]) {
        let wanted = Set(keep)
        lock.lock()
        restored = restored.filter { wanted.contains($0.key) }
        lock.unlock()
        session.getAllTasks { tasks in
            for task in tasks where !wanted.contains(task.taskDescription ?? "") { task.cancel() }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let transfer = transfers[downloadTask.taskIdentifier]
        lock.unlock()
        // One left by an earlier launch belongs to the generation this launch began with.
        let started = transfer?.generation ?? 0
        guard let address = transfer?.address ?? downloadTask.taskDescription else { return }
        guard let http = downloadTask.response as? HTTPURLResponse else {
            record(downloadTask, .failure(CraftNativeActionError(code: "NETWORK_ERROR", message: "media.keep received a response that is not HTTP")))
            return
        }
        // The system deletes `location` once this returns: move it now. It
        // lands whether its keep is still waiting or was answered early; only
        // a clear since it started (sign-out) keeps it out.
        record(downloadTask, CraftNativeMedia.store(address, at: location, response: http, stillWanted: { [weak self] in self?.isCurrent(started) ?? false }))
    }

    /// How many times the cache was cleared in this launch; a transfer started before the last clear does not land.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func isCurrent(_ started: Int) -> Bool {
        currentGeneration == started
    }

    private func record(_ task: URLSessionTask, _ result: Result<Any, CraftNativeActionError>) {
        lock.lock()
        finished[task.taskIdentifier] = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        let result = finished.removeValue(forKey: task.taskIdentifier)
        if let address = task.taskDescription, restored[address] === task { restored.removeValue(forKey: address) }
        lock.unlock()
        guard let transfer, let flight = transfer.flight else { return }
        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                CraftNativeMedia.finish(transfer.address, flight: flight, .failure(CraftNativeActionError(code: "CANCELLED", message: "media.keep was cancelled")))
                return
            }
            // Refused only because the connection is metered: not a failure, a wait.
            if let reason = urlError?.networkUnavailableReason, reason == .expensive || reason == .constrained {
                CraftNativeMedia.finish(transfer.address, flight: flight, .success(["ok": false, "url": transfer.address, "reason": "cellular"]))
                return
            }
            let code = urlError?.code == .timedOut ? "TIMEOUT" : "NETWORK_ERROR"
            CraftNativeMedia.finish(transfer.address, flight: flight, .failure(CraftNativeActionError(code: CraftNativeMedia.errorCode(error, fallback: code), message: error.localizedDescription)))
            return
        }
        CraftNativeMedia.finish(transfer.address, flight: flight, result ?? .failure(CraftNativeActionError(code: "NETWORK_ERROR", message: "media.keep finished without a file")))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            let done = self?.backgroundCompletion
            self?.backgroundCompletion = nil
            done?()
        }
    }
}
