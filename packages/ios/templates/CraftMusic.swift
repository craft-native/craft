#if CRAFT_APPLE_MUSIC
import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// A music call that did not happen: the message a page sees, and the
/// bridge's error code.
struct CraftMusicError: Error {
    let message: String
    var code: String = "CRAFT_ERROR"
}

/// The song a player has up, whoever the player is.
struct CraftMusicItem {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval
    /// The artwork drawn at about `size`, or nil when the song has none.
    let artwork: (CGSize) -> UIImage?
}

/// The slice of MPMusicPlayerController the bridge uses, so the simulator,
/// whose Music app has nothing to play, can stand a fake in for it.
protocol CraftMusicPlayer: AnyObject {
    /// "appleMusic" for the Music app, "simulated" for the fake.
    var source: String { get }
    var item: CraftMusicItem? { get }
    var playbackState: MPMusicPlaybackState { get }
    var currentPlaybackTime: TimeInterval { get }
    /// Called on main whenever the song or the playback state changes.
    var onChange: (() -> Void)? { get set }
    /// Sound this player makes that iOS cannot see as another app's: only
    /// the simulator's stand-in, which plays nothing yet should read like
    /// the Music app playing. Read before access is allowed, so the real
    /// player answers false without touching the Music app.
    var soundsLikeOtherAudio: Bool { get }
    func play()
    func pause()
    func skipToNextItem()
    func skipToPreviousItem()
    func skipToBeginning()
    func startObserving()
    func stopObserving()
}

/// What the Music app is playing, and its transport: the page's
/// `craft.music` (CraftApp.swift).
///
/// Through `MPMusicPlayerController.systemMusicPlayer`, which is the Music
/// app's own queue: what it plays, this sees and steers, and nothing else.
/// iOS gives no app another player's controls, so while Spotify or a podcast
/// app plays, `title` is null and `otherAudioPlaying` is true; a page should
/// say so rather than show controls that do nothing.
///
/// Media library access is asked for only by `requestAuthorization`, which a
/// page calls when the person chooses to see their music; until then the
/// player is not touched at all, so nothing is read without consent.
///
/// Everything here runs on main: MediaPlayer wants it, and every caller hops
/// there first.
final class CraftMusic {
    typealias Listener = ([String: Any]) -> Void

    static let shared = CraftMusic()

    /// The longest side of the artwork a page is sent, in pixels. Small on
    /// purpose: it is a thumbnail beside a title, and it crosses the bridge as
    /// base64 on every change.
    static let artworkPixels: CGFloat = 120

    private lazy var player: CraftMusicPlayer = {
        let player = CraftMusic.makePlayer()
        player.onChange = { [weak self] in self?.playerDidChange() }
        return player
    }()

    private var listener: Listener?
    private var observing = false
    private var changeScheduled = false
    private var foregroundObserver: NSObjectProtocol?
    private var artworkCache: (id: String, dataURL: String?)?

    /// The real player, or on the simulator the fake when the
    /// `CraftFakeMusicPlayer` default is set: as a launch argument
    /// (`-CraftFakeMusicPlayer YES`) or with
    /// `xcrun simctl spawn booted defaults write <bundle id> CraftFakeMusicPlayer -bool YES`.
    private static func makePlayer() -> CraftMusicPlayer {
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "CraftFakeMusicPlayer") { return CraftFakeMusicPlayer() }
        #endif
        return CraftSystemMusicPlayer()
    }

    // MARK: Authorization

    static func authorizationName(_ status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "denied"
        }
    }

    var authorization: String { Self.authorizationName(MPMediaLibrary.authorizationStatus()) }
    var isAuthorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    /// Ask once; iOS answers from memory after that. Resolves with the
    /// status's name.
    func requestAuthorization(completion: @escaping (String) -> Void) {
        guard MPMediaLibrary.authorizationStatus() == .notDetermined else {
            completion(authorization)
            return
        }
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(Self.authorizationName(status))
                // A page that was already listening hears what there is now.
                if status == .authorized, self.observing { self.startPlayerObservation() }
            }
        }
    }

    // MARK: Now playing

    static func playbackStateName(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused: return "paused"
        case .interrupted: return "interrupted"
        case .seekingForward: return "seekingForward"
        case .seekingBackward: return "seekingBackward"
        @unknown default: return "stopped"
        }
    }

    /// Everything a page shows about the music, in one answer. Without
    /// access, only what can be said without touching the player.
    func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "available": true,
            "authorization": authorization,
            "otherAudioPlaying": AVAudioSession.sharedInstance().isOtherAudioPlaying || player.soundsLikeOtherAudio,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "source": NSNull(),
            "playbackState": "unknown",
            "isPlaying": false,
            "itemId": NSNull(),
            "title": NSNull(),
            "artist": NSNull(),
            "album": NSNull(),
            "duration": NSNull(),
            "position": NSNull(),
            "artworkDataURL": NSNull(),
        ]
        guard isAuthorized else { return result }

        let player = self.player
        let state = player.playbackState
        result["source"] = player.source
        result["playbackState"] = Self.playbackStateName(state)
        result["isPlaying"] = state == .playing || state == .seekingForward || state == .seekingBackward
        guard let item = player.item else { return result }

        result["itemId"] = item.id
        result["title"] = Self.orNull(item.title)
        result["artist"] = Self.orNull(item.artist)
        result["album"] = Self.orNull(item.album)
        result["duration"] = Self.orNull(item.duration.isFinite && item.duration > 0 ? item.duration : nil)
        let position = player.currentPlaybackTime
        result["position"] = Self.orNull(position.isFinite && position >= 0 ? position : nil)
        result["artworkDataURL"] = Self.orNull(artworkDataURL(for: item))
        return result
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// A small JPEG of the artwork as a data URL, drawn once per song.
    private func artworkDataURL(for item: CraftMusicItem) -> String? {
        if let cached = artworkCache, cached.id == item.id { return cached.dataURL }
        let side = Self.artworkPixels
        var dataURL: String?
        if let image = item.artwork(CGSize(width: side, height: side)) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let fitted = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                // Fill the square, as a cover does, cropping the long side.
                let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }
            if let jpeg = fitted.jpegData(compressionQuality: 0.75) {
                dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
        }
        artworkCache = (item.id, dataURL)
        return dataURL
    }

    // MARK: Transport

    /// play, pause, togglePlayPause, skipToNext or skipToPrevious. Resolves
    /// with the snapshot a moment later, once the Music app has moved, so a
    /// page can show the outcome without waiting for the change event.
    ///
    /// skipToPrevious behaves like the Music app's own back button: more
    /// than `restartAfter` seconds into a song (3 unless given) it goes back
    /// to the start of that song; 0 always goes to the previous one.
    func control(_ command: String, restartAfter: Double?, completion: @escaping (Result<[String: Any], CraftMusicError>) -> Void) {
        guard isAuthorized else {
            completion(.failure(CraftMusicError(message: "Music access has not been allowed", code: "NOT_AUTHORIZED")))
            return
        }
        let player = self.player
        switch command {
        case "play":
            player.play()
        case "pause":
            player.pause()
        case "togglePlayPause":
            if player.playbackState == .playing { player.pause() } else { player.play() }
        case "skipToNext":
            player.skipToNextItem()
        case "skipToPrevious":
            let threshold = max(restartAfter ?? 3, 0)
            if threshold > 0, player.currentPlaybackTime > threshold { player.skipToBeginning() } else { player.skipToPreviousItem() }
        default:
            completion(.failure(CraftMusicError(message: "Unknown music command: \(command)", code: "INVALID_ARGUMENT")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            completion(.success(self.snapshot()))
        }
    }

    // MARK: Change events

    /// Hear every change of song or playback state as a snapshot, or stop
    /// hearing them (`nil`). One listener: the web view's page.
    func observe(_ listener: Listener?) {
        self.listener = listener
        if listener != nil, !observing {
            observing = true
            if isAuthorized { startPlayerObservation() }
            // Notifications stop while the app is suspended; coming back,
            // the page hears where the music is now.
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.playerDidChange() }
        } else if listener == nil, observing {
            observing = false
            if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
            foregroundObserver = nil
            if isAuthorized { player.stopObserving() }
        }
    }

    private func startPlayerObservation() {
        player.startObserving()
    }

    /// A song change arrives as two or three notifications at once; the page
    /// gets one snapshot for them.
    private func playerDidChange() {
        guard observing, !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.changeScheduled = false
            guard self.observing, let listener = self.listener else { return }
            listener(self.snapshot())
        }
    }
}

// MARK: - The Music app

/// `MPMusicPlayerController.systemMusicPlayer`: the Music app's queue.
final class CraftSystemMusicPlayer: CraftMusicPlayer {
    let source = "appleMusic"
    let soundsLikeOtherAudio = false
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var player: MPMusicPlayerController { MPMusicPlayerController.systemMusicPlayer }

    var item: CraftMusicItem? {
        guard let item = player.nowPlayingItem else { return nil }
        // A song streamed from the catalog and not in the library has no
        // persistent ID; its store ID, or what it is called, still tells one
        // song from the next.
        let id: String
        if item.persistentID != 0 { id = String(item.persistentID) }
        else if !item.playbackStoreID.isEmpty && item.playbackStoreID != "0" { id = "store:" + item.playbackStoreID }
        else { id = "title:" + (item.title ?? "") + "|" + (item.artist ?? "") }
        let artwork = item.artwork
        return CraftMusicItem(
            id: id,
            title: item.title,
            artist: item.artist ?? item.albumArtist,
            album: item.albumTitle,
            duration: item.playbackDuration,
            artwork: { size in artwork?.image(at: size) }
        )
    }

    var playbackState: MPMusicPlaybackState { player.playbackState }
    var currentPlaybackTime: TimeInterval { player.currentPlaybackTime }

    func play() { player.play() }
    func pause() { player.pause() }
    func skipToNextItem() { player.skipToNextItem() }
    func skipToPreviousItem() { player.skipToPreviousItem() }
    func skipToBeginning() { player.skipToBeginning() }

    func startObserving() {
        guard observers.isEmpty else { return }
        let player = self.player
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in self?.onChange?() })
        }
    }

    func stopObserving() {
        guard !observers.isEmpty else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player.endGeneratingPlaybackNotifications()
    }
}

// MARK: - The simulator's stand-in

/// Three made-up songs that play (from launch), pause and skip like the Music
/// app, and count as other audio while they play, so the
/// bridge, a page's offer, its bar and its events can be tried in the simulator.
/// Never used on a device (see `CraftMusic.makePlayer`).
final class CraftFakeMusicPlayer: CraftMusicPlayer {
    let source = "simulated"
    var onChange: (() -> Void)?
    private var observing = false

    private let songs: [(title: String, artist: String, album: String, duration: TimeInterval, hue: CGFloat)] = [
        ("Intervals", "The Pacers", "Tempo Run", 214, 0.02),
        ("Long Way Home", "Zone Two", "Base Miles", 251, 0.58),
        ("Cooldown", "Recovery Club", "Easy Days", 187, 0.33),
    ]
    private var index = 0
    /// Playing from the start, as when someone opens the app with music on:
    /// that is what a page offering its controls waits for.
    private var state: MPMusicPlaybackState = .playing
    /// Where the song was when it last started or stopped, and when that was.
    private var offset: TimeInterval = 0
    private var startedAt: Date? = Date()

    var soundsLikeOtherAudio: Bool { state == .playing }

    var item: CraftMusicItem? {
        let song = songs[index]
        return CraftMusicItem(
            id: "simulated-\(index)",
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.duration,
            artwork: { size in
                UIGraphicsImageRenderer(size: size).image { context in
                    UIColor(hue: song.hue, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            }
        )
    }

    var playbackState: MPMusicPlaybackState { state }
    var currentPlaybackTime: TimeInterval {
        guard let startedAt = startedAt else { return offset }
        return min(offset + Date().timeIntervalSince(startedAt), songs[index].duration)
    }

    func play() {
        guard state != .playing else { return }
        state = .playing
        startedAt = Date()
        changed()
    }

    func pause() {
        guard state == .playing else { return }
        offset = currentPlaybackTime
        startedAt = nil
        state = .paused
        changed()
    }

    func skipToNextItem() { move(to: (index + 1) % songs.count) }
    func skipToPreviousItem() { move(to: (index + songs.count - 1) % songs.count) }

    func skipToBeginning() {
        offset = 0
        if state == .playing { startedAt = Date() }
        changed()
    }

    func startObserving() { observing = true }
    func stopObserving() { observing = false }

    private func move(to next: Int) {
        index = next
        offset = 0
        startedAt = state == .playing ? Date() : nil
        changed()
    }

    private func changed() {
        guard observing else { return }
        DispatchQueue.main.async { self.onChange?() }
    }
}
#else
import Foundation

// Keep the bridge callable without linking the permission-dependent player.
// Runtime config changes cannot turn an API back on after it was compiled out.
struct CraftMusicError: Error {
    let message: String
    var code: String = "CAPABILITY_DISABLED"
}

final class CraftMusic {
    typealias Listener = ([String: Any]) -> Void
    static let shared = CraftMusic()
    var authorization: String { "unsupported" }
    func requestAuthorization(completion: @escaping (String) -> Void) { completion("unsupported") }
    func snapshot() -> [String: Any] { ["available": false, "authorization": "unsupported"] }
    func observe(_ listener: Listener?) {}
    func control(_ command: String, restartAfter: Double?, completion: @escaping (Result<[String: Any], CraftMusicError>) -> Void) {
        completion(.failure(CraftMusicError(message: "Apple Music was not enabled when this app was built")))
    }
}
#endif
