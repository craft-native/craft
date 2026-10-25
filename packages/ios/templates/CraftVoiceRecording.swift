import AVFoundation
import Foundation
import UIKit

protocol CraftVoiceRecorder: AnyObject {
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}
extension AVAudioRecorder: CraftVoiceRecorder {}

/// The main thread owns requests; audio and encoder work belong to one serial
/// queue. Cancellation invalidates a request immediately, even while AVFoundation
/// is starting, so a late permission/encoder answer cannot resurrect it.
final class CraftVoiceRecording {
    static let shared = CraftVoiceRecording()
    private final class Session {
        let key: String
        var file: URL?
        var recorder: CraftVoiceRecorder? // audio queue only
        var completion: ((Result<Any, CraftNativeActionError>) -> Void)? // main only
        var deadline: DispatchWorkItem?
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
    private let audioQueue: DispatchQueue
    private let permission: (@escaping (Bool) -> Void) -> Void
    private let makeRecorder: (URL) throws -> CraftVoiceRecorder
    private let deactivate: () -> Void
    private let startupTimeout: TimeInterval
    private var backgroundObserver: NSObjectProtocol?

    init(audioQueue: DispatchQueue = DispatchQueue(label: "craft.voice-recording", qos: .userInitiated),
         startupTimeout: TimeInterval = 15,
         permission: @escaping (@escaping (Bool) -> Void) -> Void = { AVAudioSession.sharedInstance().requestRecordPermission($0) },
         makeRecorder: @escaping (URL) throws -> CraftVoiceRecorder = { file in
             let session = AVAudioSession.sharedInstance()
             try session.setCategory(.record, mode: .measurement)
             try session.setActive(true)
             return try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
         },
         deactivate: @escaping () -> Void = { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }) {
        self.audioQueue = audioQueue
        self.startupTimeout = startupTimeout
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
        deactivate()
    }

    private func clear(_ error: CraftNativeActionError = CraftNativeActionError(code: "RECORDING_CANCELLED", message: "Recording was cancelled")) {
        guard let session = current else { return }
        current = nil
        session.invalidate()
        session.finish(.failure(error))
        audioQueue.async { self.erase(session) }
    }

    func perform(method: String, args: [Any], isActive: @escaping () -> Bool = { true }, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        DispatchQueue.main.async { self.performOnMain(method: method, args: args, isActive: isActive, completion: completion) }
    }

    private func performOnMain(method: String, args: [Any], isActive: @escaping () -> Bool, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        func fail(_ code: String, _ message: String) { completion(.failure(CraftNativeActionError(code: code, message: message))) }
        guard let key = args.first as? String, UUID(uuidString: key) != nil else { fail("INVALID_ARGUMENT", "A recording owner UUID is required"); return }
        if method == "cancel" {
            if current?.key == key { clear() }
            completion(.success(true))
            return
        }
        if method == "stop" {
            guard let session = current, session.key == key, let file = session.file else { fail("RECORDING_NOT_FOUND", "This recording is no longer available"); return }
            audioQueue.async {
                guard !session.isCancelled else { return DispatchQueue.main.async { fail("RECORDING_CANCELLED", "Recording was cancelled") } }
                session.recorder?.stop()
                session.recorder = nil
                self.deactivate()
                let result: Result<Any, CraftNativeActionError>
                if let audio = try? AVAudioFile(forReading: file), audio.length > 0 {
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    result = .success(CraftNativeFiles.describe(file, type: "audio/mp4", extra: ["durationSeconds": duration]))
                } else {
                    result = .failure(CraftNativeActionError(code: "EMPTY_RECORDING", message: "The recording was empty"))
                }
                DispatchQueue.main.async {
                    guard self.current === session, isActive(), !session.isCancelled else {
                        if self.current === session { self.clear() }
                        fail("RECORDING_CANCELLED", "Recording was cancelled")
                        return
                    }
                    if case .failure = result { self.clear() }
                    completion(result)
                }
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
                do { session.file = try CraftNativeFiles.newFile(named: "voice-feedback.m4a") }
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
