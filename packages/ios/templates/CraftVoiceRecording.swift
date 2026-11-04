import AVFoundation
import Foundation
import UIKit

protocol CraftVoiceRecorder: AnyObject {
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}
#if CRAFT_PERMISSION_MICROPHONE
extension AVAudioRecorder: CraftVoiceRecorder {}
#endif

/// The main thread owns requests; audio and encoder work belong to one serial
/// queue. Cancellation invalidates a request immediately, even while AVFoundation
/// is starting, so a late permission/encoder answer cannot resurrect it.
final class CraftVoiceRecording {
    static let shared = CraftVoiceRecording()
    private static let fileQueue = DispatchQueue(label: "craft.voice-recording-files", qos: .utility)
    private static let launchCleanup: Void = discardAbandonedRecordings(includeLegacy: false)
    private static let legacyCleanup: Void = discardAbandonedRecordings()
    private static let folderName = "voice-recordings"

    /// Temporary voice files have a launch lifetime, unlike picked files and
    /// downloads. Run once across all screens, without touching audio hardware.
    static func prepareForLaunch(includeLegacy: Bool = true) {
        _ = launchCleanup
        if includeLegacy { _ = legacyCleanup }
    }

    static func discardAbandonedRecordings(in root: URL = CraftNativeFiles.root, includeLegacy: Bool = true) {
        let fm = FileManager.default
        // Also migrate the recorder's earlier UUID folders at craft-files' root.
        let voice = root.appendingPathComponent(folderName, isDirectory: true)
        for scope in includeLegacy ? [root, voice] : [voice] {
            guard (try? scope.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
            let folders = (try? fm.contentsOfDirectory(at: scope, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            for folder in folders {
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
                let file = folder.appendingPathComponent("voice-feedback.m4a")
                let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                try? fm.removeItem(at: file)
                if (try? fm.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? fm.removeItem(at: folder) }
            }
        }
    }

    private static func newRecordingFile() throws -> URL {
        prepareForLaunch()
        let root = CraftNativeFiles.root.appendingPathComponent(folderName, isDirectory: true)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("voice-feedback.m4a")
        do {
            // An owned placeholder lets cancellation erase the path even when
            // AVFoundation has not finished constructing its recorder yet.
            try Data().write(to: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    private final class Session {
        let key: String
        var file: URL?
        var recorder: CraftVoiceRecorder? // audio queue only
        var completion: ((Result<Any, CraftNativeActionError>) -> Void)? // main only
        var deadline: DispatchWorkItem?
        var stopping = false // main only
        private let lock = NSLock()
        private var cancelled = false
        init(key: String, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
            self.key = key
            self.completion = completion
        }
        var isCancelled: Bool { lock.withLock { cancelled } }
        func invalidate() { lock.withLock { cancelled = true } }
        func finish(_ result: Result<Any, CraftNativeActionError>) {
            deadline?.cancel()
            deadline = nil
            let done = completion
            completion = nil
            done?(result)
        }
    }
    private var current: Session?
    /// Each microphone step in the unified log (`subsystem == "craft.native"`,
    /// category `voice-recording`), so a recording that never finished says
    /// whether its stop arrived, and where AVFoundation held it.
    private static func trace(_ message: String) {
        CraftNativeConsole.write("info", category: "voice-recording", message: message)
    }
    private let audioQueue: DispatchQueue
    private let permission: (@escaping (Bool) -> Void) -> Void
    private let makeRecorder: (URL) throws -> CraftVoiceRecorder
    private let deactivate: () -> Void
    /// Releasing the audio session runs here, never on `audioQueue`: a
    /// deactivation that stalls (seen on simulators with a virtual input)
    /// must not hold the next recording's start or stop behind it.
    private let releaseQueue = DispatchQueue(label: "craft.voice-recording-release", qos: .utility)
    private let generationLock = NSLock()
    private var generation = 0
    private let startupTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    struct FileRemovalReceipt: Encodable {
        let queueMilliseconds: Double
        let removalMilliseconds: Double
        let ownedBefore: Bool
        let removed: Bool
        let existsAfter: Bool
    }
    // Internal observation of the real deletion, not a replacement filesystem.
    private let fileRemovalObserved: ((FileRemovalReceipt) -> Void)?
    private var backgroundObserver: NSObjectProtocol?

    init(audioQueue: DispatchQueue = DispatchQueue(label: "craft.voice-recording", qos: .userInitiated),
         startupTimeout: TimeInterval = 15,
         stopTimeout: TimeInterval = 10,
         fileRemovalObserved: ((FileRemovalReceipt) -> Void)? = nil,
         permission: @escaping (@escaping (Bool) -> Void) -> Void = { answer in
             #if CRAFT_PERMISSION_MICROPHONE
             AVAudioSession.sharedInstance().requestRecordPermission(answer)
             #else
             answer(false)
             #endif
         },
         makeRecorder: @escaping (URL) throws -> CraftVoiceRecorder = { file in
             #if CRAFT_PERMISSION_MICROPHONE
             let session = AVAudioSession.sharedInstance()
             try session.setCategory(.record, mode: .measurement)
             try session.setActive(true)
             return try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
             #else
             throw NSError(domain: "CraftVoiceRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone was not enabled when this app was built"])
             #endif
         },
         deactivate: @escaping () -> Void = { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }) {
        Self.prepareForLaunch()
        self.audioQueue = audioQueue
        self.startupTimeout = startupTimeout
        self.stopTimeout = stopTimeout
        self.fileRemovalObserved = fileRemovalObserved
        self.permission = permission
        self.makeRecorder = makeRecorder
        self.deactivate = deactivate
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.clear() }
    }

    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }

    private func erase(_ session: Session) {
        session.recorder?.stop()
        session.recorder = nil
        if let file = session.file { CraftNativeFiles.remove(file.path) }
        releaseAudioSession()
    }

    /// Deactivate off the recording queue, and not at all once a newer
    /// recording has started: it would only take the microphone from it.
    private func releaseAudioSession() {
        let mine = generationLock.withLock { generation }
        releaseQueue.async { [weak self] in
            guard let self, self.generationLock.withLock({ self.generation }) == mine else { return }
            self.deactivate()
        }
    }

    private func clear(_ error: CraftNativeActionError = CraftNativeActionError(code: "RECORDING_CANCELLED", message: "Recording was cancelled")) {
        guard let session = current else { return }
        current = nil
        session.invalidate()
        session.finish(.failure(error))
        if let file = session.file {
            // A stalled encoder must not hold deletion behind its audio queue.
            let queued = ProcessInfo.processInfo.systemUptime
            let observed = fileRemovalObserved
            Self.trace("cancel \(session.key.prefix(8)): file removal queued")
            Self.fileQueue.async {
                let began = ProcessInfo.processInfo.systemUptime
                let owned = CraftNativeFiles.owned(file.path) != nil
                let removed = CraftNativeFiles.remove(file.path)
                let receipt = FileRemovalReceipt(
                    queueMilliseconds: (began - queued) * 1000,
                    removalMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                    ownedBefore: owned, removed: removed,
                    existsAfter: FileManager.default.fileExists(atPath: file.path))
                // No path or recording content is included in diagnostics.
                if let json = try? JSONEncoder().encode(receipt), let text = String(data: json, encoding: .utf8) {
                    Self.trace("cancel \(session.key.prefix(8)): file removal \(text)")
                }
                observed?(receipt)
            }
        }
        audioQueue.async { self.erase(session) }
    }

    func perform(method: String, args: [Any], isActive: @escaping () -> Bool = { true }, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        DispatchQueue.main.async { self.performOnMain(method: method, args: args, isActive: isActive, completion: completion) }
    }

    private func performOnMain(method: String, args: [Any], isActive: @escaping () -> Bool, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        func fail(_ code: String, _ message: String) { completion(.failure(CraftNativeActionError(code: code, message: message))) }
        guard let key = args.first as? String, UUID(uuidString: key) != nil else { fail("INVALID_ARGUMENT", "A recording owner UUID is required"); return }
        Self.trace("\(method) \(key.prefix(8)) (current \(current.map { String($0.key.prefix(8)) } ?? "none"))")
        if method == "cancel" {
            if current?.key == key { clear() }
            completion(.success(true))
            return
        }
        if method == "stop" {
            guard let session = current, session.key == key, let file = session.file else { fail("RECORDING_NOT_FOUND", "This recording is no longer available"); return }
            guard !session.stopping else { fail("RECORDING_BUSY", "This recording is already finishing"); return }
            session.stopping = true
            // Answered exactly once: by the encoder's result, or by the
            // deadline when AVFoundation never returns (a stalled encoder or
            // audio route), which then erases the recording like a cancel.
            var settled = false
            var timeout: DispatchWorkItem?
            func settle(_ result: Result<Any, CraftNativeActionError>) {
                timeout?.cancel()
                guard !settled else { return }
                settled = true
                completion(result)
            }
            let late = CraftNativeActionError(code: "RECORDING_TIMEOUT", message: "The recording took too long to finish. Please try again.")
            timeout = DispatchWorkItem { [weak self] in
                guard !settled else { return }
                Self.trace("stop \(key.prefix(8)) timed out waiting for the encoder")
                if let self, self.current === session { self.clear(late) }
                settle(.failure(late))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + stopTimeout, execute: timeout!)
            audioQueue.async {
                guard !session.isCancelled else {
                    return DispatchQueue.main.async { settle(.failure(CraftNativeActionError(code: "RECORDING_CANCELLED", message: "Recording was cancelled"))) }
                }
                session.recorder?.stop()
                session.recorder = nil
                Self.trace("stop \(key.prefix(8)): encoder stopped")
                // Read the finished file before releasing the audio session:
                // the answer must not wait on a deactivation that can stall.
                let result: Result<Any, CraftNativeActionError>
                if let audio = try? AVAudioFile(forReading: file), audio.length > 0 {
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    result = .success(CraftNativeFiles.describe(file, type: "audio/mp4", extra: ["durationSeconds": duration]))
                } else {
                    result = .failure(CraftNativeActionError(code: "EMPTY_RECORDING", message: "The recording was empty"))
                }
                DispatchQueue.main.async {
                    guard !settled else { return }
                    guard self.current === session, isActive(), !session.isCancelled else {
                        if self.current === session { self.clear() }
                        settle(.failure(CraftNativeActionError(code: "RECORDING_CANCELLED", message: "Recording was cancelled")))
                        return
                    }
                    if case .failure = result { self.clear() }
                    Self.trace("stop \(key.prefix(8)) answered")
                    settle(result)
                }
                self.releaseAudioSession()
            }
            return
        }
        guard method == "start" else { fail("UNKNOWN_ACTION", "Unknown voice recording action"); return }
        guard isActive() else { fail("RECORDING_CANCELLED", "The requesting screen has closed"); return }
        guard current == nil else { fail("RECORDING_BUSY", "Another microphone session is still active"); return }
        let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
        let seconds = (options["maxSeconds"] as? NSNumber)?.doubleValue ?? 300
        guard seconds.isFinite, seconds >= 1, seconds <= 300 else { fail("INVALID_ARGUMENT", "Recordings are limited to five minutes"); return }
        let session = Session(key: key, completion: completion)
        current = session
        permission { allowed in
            DispatchQueue.main.async {
                guard self.current === session, isActive() else {
                    if self.current === session { self.clear() }
                    session.finish(.failure(CraftNativeActionError(code: "RECORDING_CANCELLED", message: "Recording was cancelled")))
                    return
                }
                guard allowed else { self.clear(CraftNativeActionError(code: "PERMISSION_DENIED", message: "Microphone permission was refused")); return }
                do { session.file = try Self.newRecordingFile() }
                catch { self.clear(CraftNativeActionError(code: "RECORDING_FAILED", message: "The recording file could not be created")); return }
                guard let file = session.file else { return }
                let deadline = DispatchWorkItem { [weak host = self] in
                    guard let host, host.current === session else { return }
                    host.clear(CraftNativeActionError(code: "RECORDING_TIMEOUT", message: "The microphone took too long to start. Please try again."))
                }
                session.deadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + self.startupTimeout, execute: deadline)
                self.audioQueue.async {
                    do {
                        guard !session.isCancelled else { return }
                        self.generationLock.withLock { self.generation += 1 }
                        session.recorder = try self.makeRecorder(file)
                        guard !session.isCancelled else { self.erase(session); return }
                        guard session.recorder?.record(forDuration: max(0.5, seconds - 0.25)) == true else {
                            throw CraftNativeActionError(code: "RECORDING_FAILED", message: "The microphone could not start")
                        }
                        guard !session.isCancelled else { self.erase(session); return }
                        DispatchQueue.main.async {
                            guard self.current === session, isActive() else {
                                if self.current === session { self.clear() }
                                return
                            }
                            Self.trace("start \(key.prefix(8)): recording")
                            session.finish(.success(true))
                        }
                    }
                    catch {
                        DispatchQueue.main.async {
                            if self.current === session { self.clear(CraftNativeActionError(code: "RECORDING_FAILED", message: "The microphone could not start")) }
                        }
                    }
                }
            }
        }
    }
}
