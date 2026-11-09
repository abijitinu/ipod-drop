import AVFoundation
import AppKit
import MediaPlayer
import Observation

/// Plays songs straight from the mounted iPod, with an Up Next queue.
/// Also answers the keyboard's media keys and Control Center's Now Playing.
@Observable
final class PlayerController {
    static let shared = PlayerController()

    enum Repeat: String { case off, all, one }

    private(set) var queue: [Track] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var shuffle = false { didSet { reshuffle() } }
    var repeatMode: Repeat = .off
    var volume: Float = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 0.8 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }
    /// Set while the user drags the scrubber, so time updates don't fight it.
    var isScrubbing = false

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var upNext: [Track] { index.map { Array(queue.dropFirst($0 + 1)) } ?? [] }

    private let player = AVPlayer()
    private var originalOrder: [Track] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var artwork: NSImage?

    private init() {
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.finishedTrack()
            }
        }
        setUpRemoteCommands()
    }

    // MARK: Queue

    /// Play `tracks` in order, starting with `start` (or the first one).
    func play(_ tracks: [Track], startingAt start: Track.ID? = nil) {
        guard !tracks.isEmpty else { return }
        originalOrder = tracks
        let first = start.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        if shuffle {
            var rest = tracks
            let chosen = rest.remove(at: first)
            queue = [chosen] + rest.shuffled()
            load(0)
        } else {
            queue = tracks
            load(first)
        }
    }

    /// Insert songs right after the current one.
    func playNext(_ tracks: [Track]) {
        guard let index else { play(tracks); return }
        queue.insert(contentsOf: tracks, at: index + 1)
        originalOrder.append(contentsOf: tracks)
    }

    /// Add songs to the end of the queue.
    func addToQueue(_ tracks: [Track]) {
        guard index != nil else { play(tracks); return }
        queue.append(contentsOf: tracks)
        originalOrder.append(contentsOf: tracks)
    }

    func jump(to position: Int) {
        guard queue.indices.contains(position) else { return }
        load(position)
    }

    private func reshuffle() {
        guard let current else { return }
        if shuffle {
            queue = [current] + queue.filter { $0.id != current.id }.shuffled()
            index = 0
        } else if !originalOrder.isEmpty {
            queue = originalOrder
            index = originalOrder.firstIndex { $0.id == current.id } ?? 0
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if current == nil {
            // Nothing queued yet: start the library from the top.
            play(LibraryStore.shared.tracks.sorted { ($0.artist, $0.album, $0.trackNumber) < ($1.artist, $1.album, $1.trackNumber) })
            return
        }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player.currentItem != nil else { if let index { load(index) }; return }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard let index else { return }
        if index + 1 < queue.count {
            load(index + 1)
        } else if repeatMode == .all, !queue.isEmpty {
            load(0)
        } else {
            stop(keepQueue: true)
        }
    }

    /// Restart the song if it's been playing a few seconds, else go back one.
    func previous() {
        guard let index else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(index - 1)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
        updateNowPlaying()
    }

    /// Stop and release the file (needed before the iPod can eject).
    func stop(keepQueue: Bool = false) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        if !keepQueue {
            queue = []
            originalOrder = []
            index = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Called when the library reloads: drop songs that are no longer on the iPod.
    func libraryChanged(_ tracks: [String: Track]) {
        guard !queue.isEmpty else { return }
        let playingID = current?.id
        queue = queue.compactMap { tracks[$0.id] }
        originalOrder = originalOrder.compactMap { tracks[$0.id] }
        if let playingID, let position = queue.firstIndex(where: { $0.id == playingID }) {
            index = position
        } else if playingID != nil {
            stop()  // the playing song was removed
        }
    }

    // MARK: Internals

    private func url(for track: Track) -> URL? {
        guard let mount = LibraryStore.shared.device.mountPath, !track.location.isEmpty else { return nil }
        let relative = track.location.replacingOccurrences(of: ":", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(filePath: mount, directoryHint: .isDirectory).appending(path: relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load(_ position: Int) {
        guard queue.indices.contains(position) else { return }
        index = position
        let track = queue[position]
        guard let url = url(for: track) else {
            LibraryStore.shared.lastError = "Couldn't find “\(track.displayTitle)” on the iPod."
            stop(keepQueue: true)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        duration = Double(track.lengthMs) / 1000
        currentTime = 0
        player.play()
        isPlaying = true
        artwork = nil
        updateNowPlaying()
        Task {
            artwork = await LibraryStore.shared.artwork(track.artworkId, pixels: 600)
            updateNowPlaying()
        }
    }

    private func finishedTrack() {
        if repeatMode == .one, let index {
            load(index)
        } else {
            next()
        }
    }

    private func tick(_ time: CMTime) {
        // A tick can still arrive just after stop(); with no song loaded, stay at 0:00.
        guard !isScrubbing, time.isNumeric, player.currentItem != nil else { return }
        currentTime = time.seconds
        if let item = player.currentItem, item.duration.isNumeric, item.duration.seconds > 0 {
            duration = item.duration.seconds
        }
    }

    // MARK: System Now Playing

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(artwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// MediaPlayer asks for artwork on a background queue, so the closure must not
    /// be tied to the main actor (doing so crashed on 2026-10-19).
    private nonisolated static func nowPlayingArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Media keys and Control Center. Handlers can run off the main thread, so they
    /// only hop back to the main actor.
    private func setUpRemoteCommands() {
        Self.registerRemoteCommands { [weak self] action in
            Task { @MainActor in
                guard let self else { return }
                switch action {
                case .play: self.resume()
                case .pause: self.pause()
                case .toggle: self.togglePlayPause()
                case .next: self.next()
                case .previous: self.previous()
                case .seek(let position): self.seek(to: position)
                }
            }
        }
    }

    nonisolated enum RemoteAction: Sendable {
        case play, pause, toggle, next, previous
        case seek(Double)
    }

    private nonisolated static func registerRemoteCommands(_ handle: @escaping @Sendable (RemoteAction) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable _ in handle(.play); return .success }
        center.pauseCommand.addTarget { @Sendable _ in handle(.pause); return .success }
        center.togglePlayPauseCommand.addTarget { @Sendable _ in handle(.toggle); return .success }
        center.nextTrackCommand.addTarget { @Sendable _ in handle(.next); return .success }
        center.previousTrackCommand.addTarget { @Sendable _ in handle(.previous); return .success }
        center.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handle(.seek(event.positionTime))
            return .success
        }
    }
}
