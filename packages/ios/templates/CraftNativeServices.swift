import AVFoundation
import Foundation
import LinkPresentation
import UIKit
import UserNotifications

// Services native screens reach through `craft.speech`, `craft.audio`,
// `craft.push` and a streaming `fetch` (CraftNativeScreen.swift). Speech and
// push are the app's, shared by every screen; sounds and streams belong to the
// screen that started them and end when it closes.

// MARK: - Speech

/// `craft.speech` on a native screen: AVSpeechSynthesizer, set up the way the
/// page's own speech is (CraftApp.swift). The music ducks rather than stops,
/// the silent switch does not mute a cue, and the session is handed back once
/// nothing has been said for a moment.
///
/// Three things a workout's countdown ("3", "2", "1", a second apart) needs:
/// - An interrupting cue is never lost. AVSpeechSynthesizer can drop an
///   utterance handed to it straight after `stopSpeaking(at: .immediate)`,
///   so a cue that cuts another off speaks on a fresh synthesizer while the
///   stopped one winds down.
/// - The session stays claimed for `releaseAfterSilence` after the last word,
///   so the music ducks once for a countdown instead of swelling back up
///   between every number, and the next number does not wait on the audio
///   hardware again.
/// - Activating and deactivating the session blocks until the hardware
///   answers, so it happens on a queue of its own, never the main thread the
///   screens' JavaScript and their timers run on.
final class CraftNativeSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = CraftNativeSpeech()
    /// How long the session is kept after the last word.
    static let releaseAfterSilence: TimeInterval = 1.5

    private var synthesizer = AVSpeechSynthesizer()
    /// Synthesizers stopped by an interruption, kept until they report it.
    private var retired: [AVSpeechSynthesizer] = []
    private var pending: [(utterance: AVSpeechUtterance, done: (Bool) -> Void)] = []
    private var pendingRelease: DispatchWorkItem?
    /// The audio session's work, in order. `sessionToRestore` is only touched here.
    private let sessionQueue = DispatchQueue(label: "dev.craft.native.speech-session")
    private var sessionToRestore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Says `text`; `done` hears true once it was spoken, false when it was
    /// stopped or interrupted. With `interrupt` false it waits its turn behind
    /// what is being said. `pitch` is 0.5 to 2 (1 is the voice's own), and
    /// `preDelay` is seconds of quiet before the words, after whatever was
    /// said before them. Main thread.
    func speak(_ text: String, language: String?, rate: Double?, pitch: Double? = nil, preDelay: Double? = nil, interrupt: Bool, done: @escaping (Bool) -> Void) {
        pendingRelease?.cancel()
        pendingRelease = nil
        if interrupt, cancelPending() { retireSynthesizer() }
        let utterance = Self.utterance(text, language: language, rate: rate, pitch: pitch, preDelay: preDelay)
        pending.append((utterance, done))
        holdsSession = true
        sessionQueue.async {
            self.claimSession()
            DispatchQueue.main.async {
                // Stopped while the session was being set up: say nothing.
                guard self.pending.contains(where: { $0.utterance === utterance }) else { return }
                self.synthesizer.speak(utterance)
            }
        }
    }

    /// Whether speech has the audio session, or is about to: a sound or a
    /// video starting meanwhile leaves the category to speech, which hands it
    /// over when it lets go (`CraftNativeSounds.reclaimSessionIfPlaying`).
    /// Main thread.
    private(set) var holdsSession = false

    /// One utterance, set up the same way for a native screen and the page
    /// (CraftApp.swift): the rate on AVSpeechUtterance's scale, the pitch,
    /// the quiet before it, and the best voice installed for the language.
    static func utterance(_ text: String, language: String?, rate: Double?, pitch: Double?, preDelay: Double?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = utteranceRate(rate ?? 1)
        let wantedPitch = pitch.flatMap { $0.isFinite ? $0 : nil } ?? 1
        utterance.pitchMultiplier = Float(min(max(wantedPitch, 0.5), 2))
        let quiet = preDelay.flatMap { $0.isFinite ? $0 : nil } ?? 0
        utterance.preUtteranceDelay = min(max(quiet, 0), 5)
        // An unknown language finds no voice, and a nil voice is the device's own.
        if let voice = bestVoice(for: language) { utterance.voice = voice }
        return utterance
    }

    private static var voices: [String: AVSpeechSynthesisVoice] = [:]
    private static var voicesObserver: NSObjectProtocol?

    /// The best voice on this phone for `language` (the device's own when
    /// nil): a premium voice when one is installed, else an enhanced one,
    /// else the compact voice iOS would pick. Among voices of one quality the
    /// one sharing the default voice's name wins ("Anna (Enhanced)" over
    /// another enhanced voice when Anna is the default), so a download in
    /// Settings changes how a voice sounds, not who it is. Novelty voices and
    /// the person's own Personal Voice are never picked. Remembered per
    /// language until the installed voices change. Main thread.
    static func bestVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        let wanted = (language?.isEmpty == false ? language! : AVSpeechSynthesisVoice.currentLanguageCode())
        if let known = voices[wanted] { return known }
        if voicesObserver == nil {
            if #available(iOS 17.0, *) {
                voicesObserver = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { _ in
                    CraftNativeSpeech.voices.removeAll()
                }
            }
        }
        guard let standard = AVSpeechSynthesisVoice(language: wanted) else { return nil }
        let name = Self.baseName(standard.name)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.language == standard.language else { return false }
            if #available(iOS 17.0, *) {
                if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) { return false }
            }
            return true
        }
        let best = candidates.max { lhs, rhs in
            let left = (lhs.quality.rawValue, Self.baseName(lhs.name) == name ? 1 : 0, lhs.identifier == standard.identifier ? 1 : 0)
            let right = (rhs.quality.rawValue, Self.baseName(rhs.name) == name ? 1 : 0, rhs.identifier == standard.identifier ? 1 : 0)
            if left != right { return left < right }
            // Stable between launches: the same voice every time.
            return lhs.identifier > rhs.identifier
        } ?? standard
        let chosen = best.quality.rawValue >= standard.quality.rawValue ? best : standard
        voices[wanted] = chosen
        return chosen
    }

    /// "Anna (Enhanced)" and "Anna (Premium)" are both Anna.
    private static func baseName(_ name: String) -> String {
        name.components(separatedBy: " (").first ?? name
    }

    func stop() {
        // When something was sounding, its didCancel hands the session back
        // once the audio has stopped; deactivating before that fails as busy.
        if !cancelPending() { releaseSessionIfSilent() }
    }

    /// Settles every waiting call false. Returns whether anything was sounding.
    @discardableResult
    private func cancelPending() -> Bool {
        let waiting = pending
        pending.removeAll()
        let sounding = synthesizer.isSpeaking || synthesizer.isPaused
        if sounding { synthesizer.stopSpeaking(at: .immediate) }
        waiting.forEach { $0.done(false) }
        return sounding
    }

    /// The stopped synthesizer winds down on its own; the next cue gets a new one.
    private func retireSynthesizer() {
        retired.append(synthesizer)
        let fresh = AVSpeechSynthesizer()
        fresh.delegate = self
        synthesizer = fresh
    }

    /// The page's rate, where 1 is normal, on AVSpeechUtterance's scale, for
    /// a native screen and the page alike.
    ///
    /// Apple's scale is not linear in speed: the default sits at 0.5 and the
    /// maximum is far faster than twice that. So a slower rate scales the
    /// default down in proportion, and a faster one climbs toward the maximum
    /// at half the slope, which keeps 2 brisk but intelligible.
    static func utteranceRate(_ rate: Double) -> Float {
        let requested = Float(min(max(rate.isFinite ? rate : 1, 0.5), 2))
        let normal = AVSpeechUtteranceDefaultSpeechRate
        let mapped = requested <= 1
            ? normal * requested
            : normal + (AVSpeechUtteranceMaximumSpeechRate - normal) * (requested - 1) / 2
        return min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Session queue.
    private func claimSession() {
        guard sessionToRestore == nil else { return }
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            sessionToRestore = previous
        } catch {
            // Still speak, through whatever session the app has.
            NSLog("[craft native] speech audio session failed: %@", error.localizedDescription)
        }
    }

    /// Hand the session back once nothing has been said for a moment. Main thread.
    private func releaseSessionIfSilent(retry: Bool = true, after delay: TimeInterval = CraftNativeSpeech.releaseAfterSilence) {
        guard pending.isEmpty else { return }
        pendingRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRelease = nil
            guard self.pending.isEmpty, !self.synthesizer.isSpeaking else { return }
            let soundsPlaying = CraftNativeSounds.isPlaying
            self.sessionQueue.async {
                guard let previous = self.sessionToRestore else {
                    // The claim failed: there is nothing to hand back.
                    DispatchQueue.main.async {
                        guard self.pending.isEmpty else { return }
                        self.holdsSession = false
                        CraftNativeSounds.reclaimSessionIfPlaying(handedBack: nil)
                    }
                    return
                }
                let session = AVAudioSession.sharedInstance()
                do {
                    // Deactivating ends the ducking. A video or a sound still
                    // playing keeps it busy; the category put back below
                    // carries no ducking, so the music comes back up anyway.
                    if !soundsPlaying {
                        try session.setActive(false, options: .notifyOthersOnDeactivation)
                    }
                } catch {
                    // Busy: the last of the audio has not drained, or the app
                    // plays something of its own. Once more shortly covers the first.
                    if retry {
                        DispatchQueue.main.async { self.releaseSessionIfSilent(retry: false, after: 0.5) }
                        return
                    }
                }
                self.sessionToRestore = nil
                try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
                DispatchQueue.main.async {
                    // A cue that came in meanwhile claims the session again.
                    if self.pending.isEmpty { self.holdsSession = false }
                    CraftNativeSounds.reclaimSessionIfPlaying(handedBack: previous)
                }
            }
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finished(_ synthesizer: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance, spoken: Bool) {
        if let index = pending.firstIndex(where: { $0.utterance === utterance }) {
            pending.remove(at: index).done(spoken)
        }
        if synthesizer !== self.synthesizer, !synthesizer.isSpeaking {
            retired.removeAll { $0 === synthesizer }
        }
        releaseSessionIfSilent()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished(synthesizer, utterance, spoken: true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished(synthesizer, utterance, spoken: false) }
    }
}

// MARK: - Background sound

/// `craft.audio` on a native screen: sounds that play under the screen, such
/// as rain under a breathing exercise. Each loops without a gap when asked
/// (AVPlayerLooper), fades in and out, and stops when its screen closes.
///
/// The session is `.ambient`: it mixes with the person's music and the silent
/// switch mutes it, as a game's background sound is muted. A sound that must
/// be heard through the switch asks with `respectSilentSwitch: false`.
final class CraftNativeSounds {
    private final class Sound {
        let player: AVQueuePlayer
        var looper: AVPlayerLooper?
        var observation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var fade: Timer?
        /// The volume asked for; a fade in or out moves toward or away from it.
        var volume: Float
        var paused = false
        var interrupted = false
        var pending: ((Result<Any, CraftNativeActionError>) -> Void)?

        init(player: AVQueuePlayer, volume: Float) {
            self.player = player
            self.volume = volume
        }

        func settle(_ result: Result<Any, CraftNativeActionError>) {
            let answer = pending
            pending = nil
            answer?(result)
        }

        func end() {
            fade?.invalidate()
            fade = nil
            observation?.invalidate()
            observation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            looper?.disableLooping()
            looper = nil
            player.pause()
            player.removeAllItems()
        }
    }

    /// Every screen's sounds, so the session is handed back when the last one
    /// anywhere stops, and taken again after speech handed it back.
    private static var playing = 0
    private static var sessionToRestore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private static var category: AVAudioSession.Category = .ambient

    private var sounds: [String: Sound] = [:]
    /// AVAudioSession belongs to the app, not to a screen. Observe for the
    /// process lifetime once sounds are used, including gaps between screens.
    /// Weak membership must not keep a disposed screen's service alive.
    private static let services = NSHashTable<CraftNativeSounds>.weakObjects()
    private static var sessionInterrupted = false
    private static let interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main,
    ) { note in CraftNativeSounds.handleInterruption(note) }
    /// `{ id, event: "ended" | "error", message? }` to the screen's script.
    var emit: (([String: Any]) -> Void)?

    init() {
        _ = Self.interruptionObserver
        Self.services.add(self)
    }

    /// Sound services and their playback controls are used on main.
    private static func handleInterruption(_ note: Notification) {
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        if type == AVAudioSession.InterruptionType.began.rawValue {
            sessionInterrupted = true
            services.allObjects.forEach { service in
                service.sounds.values.forEach { sound in
                    guard !sound.paused else { return }
                    sound.interrupted = true
                    sound.player.pause()
                }
            }
            return
        }
        guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
        sessionInterrupted = false
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let shouldResume = options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
        services.allObjects.forEach { service in
            service.sounds.values.forEach { sound in
                guard sound.interrupted else { return }
                sound.interrupted = false
                // Without permission to auto-resume, keep a resumable paused
                // handle. A later unrelated interruption must not restart it.
                sound.paused = !shouldResume
                if shouldResume { sound.player.play() }
            }
        }
    }

    /// Starts `url`. `answer` hears once it plays (or could not be loaded).
    func play(id: String, url: URL, options: [String: Any], answer: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        stop(id: id, fadeOut: 0)
        let loop = options["loop"] as? Bool ?? false
        let volumeValue = craftNativeNumber(options["volume"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil } ?? 1
        let fadeInValue = craftNativeNumber(options["fadeIn"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let volume = Float(min(max(volumeValue, 0), 1))
        let fadeIn = max(0, fadeInValue) / 1000
        Self.claimSession(respectSilentSwitch: options["respectSilentSwitch"] as? Bool ?? true)
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        let sound = Sound(player: player, volume: volume)
        sound.interrupted = Self.sessionInterrupted
        sound.pending = answer
        sounds[id] = sound
        let failed: (String) -> Void = { [weak self, weak sound] message in
            guard let self, let sound, self.sounds[id] === sound else { return }
            self.remove(id, result: .failure(CraftNativeActionError(code: "AUDIO_ERROR", message: message)))
            self.emit?(["id": id, "event": "error", "message": message])
        }
        if loop {
            let looper = AVPlayerLooper(player: player, templateItem: item)
            sound.looper = looper
            sound.observation = looper.observe(\.status, options: [.initial, .new]) { [weak self, weak sound] looper, _ in
                DispatchQueue.main.async {
                    guard let self, let sound, self.sounds[id] === sound else { return }
                    if looper.status == .ready { sound.settle(.success(true)) }
                    else if looper.status == .failed { failed(looper.error?.localizedDescription ?? "The sound could not be played") }
                }
            }
        } else {
            player.insert(item, after: nil)
            sound.observation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak sound] item, _ in
                DispatchQueue.main.async {
                    guard let self, let sound, self.sounds[id] === sound else { return }
                    if item.status == .readyToPlay { sound.settle(.success(true)) }
                    else if item.status == .failed { failed(item.error?.localizedDescription ?? "The sound could not be played") }
                }
            }
            sound.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak sound] _ in
                guard let self, let sound, self.sounds[id] === sound else { return }
                self.remove(id)
                self.emit?(["id": id, "event": "ended"])
            }
        }
        player.volume = fadeIn > 0 ? 0 : volume
        if !Self.sessionInterrupted { player.play() }
        if fadeIn > 0 { ramp(sound, to: volume, over: fadeIn) }
    }

    @discardableResult
    func pause(id: String) -> Bool {
        guard let sound = sounds[id] else { return false }
        sound.paused = true
        sound.interrupted = false
        sound.fade?.invalidate()
        sound.player.pause()
        return true
    }

    @discardableResult
    func resume(id: String) -> Bool {
        guard !Self.sessionInterrupted, let sound = sounds[id], sound.paused else { return false }
        sound.paused = false
        sound.interrupted = false
        sound.player.volume = sound.volume
        sound.player.play()
        return true
    }

    /// Changes the volume, over `fade` seconds when given.
    @discardableResult
    func setVolume(id: String, volume: Double, fade: Double) -> Bool {
        guard let sound = sounds[id] else { return false }
        sound.volume = Float(min(max(volume, 0), 1))
        if fade > 0, !sound.paused { ramp(sound, to: sound.volume, over: fade) }
        else { sound.fade?.invalidate(); sound.player.volume = sound.volume }
        return true
    }

    /// Stops the sound, fading it out over `fadeOut` seconds first.
    @discardableResult
    func stop(id: String, fadeOut: Double) -> Bool {
        guard let sound = sounds[id] else { return false }
        guard fadeOut > 0, !sound.paused else { remove(id); return true }
        ramp(sound, to: 0, over: fadeOut) { [weak self, weak sound] in
            guard let self, let sound, self.sounds[id] === sound else { return }
            self.remove(id)
        }
        return true
    }

    @discardableResult
    func stopAll(fadeOut: Double) -> Bool {
        for id in Array(sounds.keys) { stop(id: id, fadeOut: fadeOut) }
        return true
    }

    /// The screen closed: everything stops at once.
    func close() {
        for id in Array(sounds.keys) { remove(id) }
    }

    private func remove(_ id: String, result: Result<Any, CraftNativeActionError> = .failure(CraftNativeActionError(code: "CANCELLED", message: "Audio playback was stopped or replaced"))) {
        guard let sound = sounds.removeValue(forKey: id) else { return }
        sound.end()
        Self.releaseSession()
        // Settle after removing the old handle and releasing its resources so
        // a completion can safely start another sound with the same id.
        sound.settle(result)
    }

    /// Moves the volume in steps on the main run loop, a 30th of a second
    /// apart: AVPlayer has no fade of its own for a playing item.
    private func ramp(_ sound: Sound, to target: Float, over seconds: Double, then done: (() -> Void)? = nil) {
        sound.fade?.invalidate()
        let start = sound.player.volume
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak sound] timer in
            guard let sound else { timer.invalidate(); return }
            let progress = Float(min(1, (CACurrentMediaTime() - began) / seconds))
            sound.player.volume = start + (target - start) * progress
            if progress >= 1 {
                timer.invalidate()
                sound.fade = nil
                done?()
            }
        }
        sound.fade = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Whether a sound, a native screen's Web Audio or a video is playing.
    static var isPlaying: Bool { playing > 0 }
    /// A sound started while speech held the session: speech's category was
    /// left alone (it plays too, ducking the music under the cue), and the
    /// category to put back later is the one speech hands back.
    private static var claimedUnderSpeech = false

    /// Takes the session for one more playing sound. Native screens' Web
    /// Audio (CraftWebAudio.swift) and videos (CraftNativeScreen.swift) count
    /// here too, so speech hands the session back to whichever of them still
    /// plays. Main thread.
    static func claimSession(respectSilentSwitch: Bool) {
        playing += 1
        // Playback outranks ambient: a video heard through the silent switch
        // is not muted by a breathing exercise's rain starting after it.
        category = respectSilentSwitch && (playing == 1 || category == .ambient) ? .ambient : .playback
        if CraftNativeSpeech.shared.holdsSession {
            if sessionToRestore == nil { claimedUnderSpeech = true }
            return
        }
        let session = AVAudioSession.sharedInstance()
        if sessionToRestore == nil { sessionToRestore = (session.category, session.mode, session.categoryOptions) }
        do {
            try session.setCategory(category, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[craft native] sound audio session failed: %@", error.localizedDescription)
        }
    }

    static func releaseSession() {
        playing = max(0, playing - 1)
        guard playing == 0 else { return }
        if claimedUnderSpeech {
            // Speech still holds the session and puts its own back.
            claimedUnderSpeech = false
            return
        }
        guard let previous = sessionToRestore else { return }
        sessionToRestore = nil
        if CraftNativeSpeech.shared.holdsSession { return }
        try? AVAudioSession.sharedInstance().setCategory(previous.0, mode: previous.1, options: previous.2)
    }

    /// Speech handed the session back with the category it found
    /// (`handedBack`, nil when it never took it), which may predate a sound
    /// started while it spoke: take it again for the sound. Main thread.
    static func reclaimSessionIfPlaying(handedBack: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?) {
        if claimedUnderSpeech {
            claimedUnderSpeech = false
            let session = AVAudioSession.sharedInstance()
            sessionToRestore = handedBack ?? (session.category, session.mode, session.categoryOptions)
            if playing > 0 { try? session.setActive(true) }
        }
        guard playing > 0 else { return }
        try? AVAudioSession.sharedInstance().setCategory(category, mode: .default, options: [.mixWithOthers])
    }
}

// MARK: - Streaming responses

/// A `fetch` whose response is read as it arrives, such as a server-sent
/// event stream (`Accept: text/event-stream`). The head answers the screen's
/// request; every piece of the body after it goes to the script as text, and
/// the end or the failure last. Streams belong to their screen and close with
/// it.
final class CraftNativeEventStreams: NSObject, URLSessionDataDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // A quiet stream is still open: the idle limit is generous, and the
        // whole response has none worth the name.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private var started = false
    private var tasks: [String: URLSessionDataTask] = [:]
    private var streamIds: [Int: String] = [:]
    private var heads: [String: (Result<Any, CraftNativeActionError>) -> Void] = [:]
    /// The bytes of a character split across two pieces, until the rest comes.
    private var carry: [String: Data] = [:]
    /// `{ id, chunk }`, then `{ id, done: true }` or `{ id, error }`.
    var emit: (([String: Any]) -> Void)?

    func open(id: String, options: [String: Any], answer: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        guard !id.isEmpty, tasks[id] == nil,
              let address = options["url"] as? String, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else {
            answer(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "A streaming fetch needs an id and an absolute http or https URL")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        for (name, value) in options["headers"] as? [String: Any] ?? [:] {
            if let value = value as? String { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        started = true
        let task = session.dataTask(with: request)
        tasks[id] = task
        streamIds[task.taskIdentifier] = id
        heads[id] = answer
        task.resume()
    }

    /// The script stopped reading: the transfer ends, and nothing more is sent.
    func cancel(id: String) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        streamIds.removeValue(forKey: task.taskIdentifier)
        heads.removeValue(forKey: id)?(.failure(CraftNativeActionError(code: "CANCELLED", message: "The request was aborted")))
        carry.removeValue(forKey: id)
        task.cancel()
    }

    /// The screen closed. The session holds its delegate until invalidated.
    func close() {
        tasks.removeAll()
        streamIds.removeAll()
        heads.removeAll()
        carry.removeAll()
        if started { session.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = streamIds[dataTask.taskIdentifier], let answer = heads.removeValue(forKey: id) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            answer(.failure(CraftNativeActionError(code: "NETWORK_ERROR", message: "fetch received a response that is not HTTP")))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
        completionHandler(.allow)
        answer(.success([
            "url": http.url?.absoluteString ?? "",
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "headers": headers,
            "redirected": http.url != dataTask.originalRequest?.url,
        ]))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = streamIds[dataTask.taskIdentifier] else { return }
        let (text, rest) = Self.decodeUTF8((carry[id] ?? Data()) + data)
        carry[id] = rest.isEmpty ? nil : rest
        if !text.isEmpty { emit?(["id": id, "chunk": text]) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = streamIds.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: id)
        carry.removeValue(forKey: id)
        if let answer = heads.removeValue(forKey: id) {
            let code = (error as? URLError)?.code == .timedOut ? "TIMEOUT" : "NETWORK_ERROR"
            answer(.failure(CraftNativeActionError(code: code, message: error?.localizedDescription ?? "Network request failed")))
            return
        }
        if let error { emit?(["id": id, "error": error.localizedDescription]) }
        else { emit?(["id": id, "done": true]) }
    }

    /// The text in `data`, and the bytes at its end that only begin a
    /// character (kept for the next piece). Invalid bytes read as U+FFFD.
    static func decodeUTF8(_ data: Data) -> (String, Data) {
        let bytes = [UInt8](data)
        var cut = bytes.count
        // Up to three bytes back for the lead byte of an unfinished character.
        var back = 1
        while back <= min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if length > back { cut = bytes.count - back }
            break
        }
        return (String(decoding: bytes[0..<cut], as: UTF8.self), Data(bytes[cut...]))
    }
}

// MARK: - Push

/// `craft.push` on a native screen: the same permission and device token the
/// page's `craft.registerPush` gets. The token arrives at the app delegate,
/// which posts `craftPushToken`; every screen hears it.
enum CraftNativePush {
    private static var waiting: [(Result<Any, CraftNativeActionError>) -> Void] = []
    private static var observers: [NSObjectProtocol] = []
    private static var deadline: DispatchWorkItem?
    /// APNs answers in a second or two; it is given this long.
    private static let registrationSeconds: Double = 20

    /// `granted`, `denied` or `undetermined`, without asking.
    static func status(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = "granted"
            case .denied: status = "denied"
            default: status = "undetermined"
            }
            DispatchQueue.main.async { done(status) }
        }
    }

    /// Asks once, if iOS has not been answered yet; the answer either way.
    static func requestPermission(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            status(done)
        }
    }

    /// The device token, asking for permission first if it was never asked.
    static func register(_ done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                guard granted else {
                    done(.failure(CraftNativeActionError(code: "PERMISSION_DENIED", message: error?.localizedDescription ?? "Notification permission denied")))
                    return
                }
                waiting.append(done)
                guard waiting.count == 1 else { return }
                observe()
                let timeout = DispatchWorkItem {
                    settle(.failure(CraftNativeActionError(code: "TIMEOUT", message: "APNs did not answer within \(Int(registrationSeconds))s")))
                }
                deadline = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + registrationSeconds, execute: timeout)
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private static func observe() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .craftPushToken, object: nil, queue: .main) { note in
            guard let token = note.object as? String else { return }
            settle(.success(token))
        })
        observers.append(NotificationCenter.default.addObserver(forName: .craftPushRegistrationError, object: nil, queue: .main) { note in
            settle(.failure(CraftNativeActionError(code: "PUSH_REGISTRATION_ERROR", message: note.object as? String ?? "Push registration failed")))
        })
    }

    private static func settle(_ result: Result<Any, CraftNativeActionError>) {
        deadline?.cancel()
        deadline = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let callers = waiting
        waiting.removeAll()
        callers.forEach { $0(result) }
    }
}

// MARK: - Share sheet

/// A URL stays a URL in Messages and AirDrop. Its title belongs in the
/// system preview and mail subject, rather than becoming a second text item.
///
/// Copy is the exception: it writes the address as text. A URL-only
/// pasteboard item has no textual representation, so `UIPasteboard.string`
/// is nil, a web page's `navigator.clipboard.readText()` gets nothing, and
/// so does the simulator's `pbpaste` - the shared link copied as nothing
/// anywhere text is read. Text that is an address is still detected as a
/// link wherever it is pasted.
final class CraftShareLink: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        activityType == .copyToPasteboard ? url.absoluteString : url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        if !title.isEmpty { metadata.title = title }
        return metadata
    }
}

/// `craft.share` on a native screen: the system share sheet with the page's
/// options (`title`, `text`, `url`, `files`), plus `image`, a picture by URL
/// that is shared as the picture rather than as its address. Answers true
/// once something was shared, false when the sheet was dismissed.
enum CraftNativeShare {
    static func share(_ options: [String: Any], done: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        var items: [Any] = []
        let title = options["title"] as? String ?? ""
        if let text = options["text"] as? String, !text.isEmpty { items.append(text) }
        if let address = options["url"] as? String, let url = URL(string: address) {
            items.append(CraftShareLink(url: url, title: title))
        } else if !title.isEmpty { items.append(title) }
        // A path or file URL, or a file craft.files made (`{ path, name }`).
        let files = (options["files"] as? [Any] ?? []).compactMap { item -> String? in
            item as? String ?? (item as? [String: Any])?["path"] as? String
        }
        for file in files {
            if let url = URL(string: file), url.isFileURL { items.append(url) }
            else if FileManager.default.fileExists(atPath: file) { items.append(URL(fileURLWithPath: file)) }
        }
        let present: ([Any]) -> Void = { items in
            guard !items.isEmpty else {
                done(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "Nothing to share")))
                return
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, completed, _, error in
                if let error { done(.failure(CraftNativeActionError(code: "SHARE_ERROR", message: error.localizedDescription))) }
                else { done(.success(completed)) }
            }
            if !CraftPresenter.present(sheet, from: nil, anchor: CraftPresenter.rect(options["anchor"])) {
                done(.failure(CraftNativeActionError(code: "SHARE_ERROR", message: "Unable to present the share sheet")))
            }
        }
        guard let address = options["image"] as? String, let url = URL(string: address) else {
            DispatchQueue.main.async { present(items) }
            return
        }
        // The picture itself, so Messages and Photos get an image.
        let load: (Data?) -> Void = { data in
            DispatchQueue.main.async {
                guard let data, let image = UIImage(data: data) else {
                    done(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "The image to share could not be loaded")))
                    return
                }
                present([image] + items)
            }
        }
        if address.hasPrefix("data:image/"), let comma = address.firstIndex(of: ",") {
            load(Data(base64Encoded: String(address[address.index(after: comma)...])))
        } else if url.isFileURL {
            load(try? Data(contentsOf: url))
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in load(data) }.resume()
        }
    }
}
