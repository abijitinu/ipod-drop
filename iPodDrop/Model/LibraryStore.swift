import AppKit
import Foundation
import Observation

/// App-wide state mirrored from the engine. Every change to the iPod goes through here.
@Observable
final class LibraryStore {
    /// One store for the whole app. Views use this directly instead of the SwiftUI
    /// environment: table cells and drop targets are hosted in separate AppKit views
    /// that don't always inherit custom environment values, and a missing
    /// `@Environment(LibraryStore.self)` traps (crashed 2026-10-19).
    static let shared = LibraryStore()

    let engine = EngineClient()

    private(set) var device = DeviceStatus.disconnected
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    private(set) var tracksByID: [String: Track] = [:]
    private(set) var hasLoaded = false

    var sendTarget: SendTarget = .library
    private(set) var activity: Activity?
    private(set) var sendLog: [SendItem] = []
    var lastError: String? {
        didSet { if let lastError { record(lastError) } }
    }
    /// The last few problems, for error reports.
    private(set) var recentErrors: [(date: Date, message: String)] = []
    /// Shows the Add Music sheet in the library window (toolbar +, ⌘O, popover click).
    var showAddMusic = false
    /// Shows the Recently Removed sheet (copies of songs removed from the iPod).
    var showRecentlyRemoved = false
    /// Shows the first-run guide (once, or from the Help menu).
    var showWelcome = !UserDefaults.standard.bool(forKey: WelcomeSheet.seenKey)
    // Requests from any right-click menu, presented by the library window.
    /// Songs waiting for "Remove from iPod" confirmation.
    var removalRequest: [String]?
    /// Songs to put in a playlist that still needs a name.
    var newPlaylistRequest: [String]?
    /// Songs to show in the inspector.
    var infoRequest: Set<String>?
    /// Playlist waiting for a new name / delete confirmation.
    var renameRequest: Playlist?
    var deleteRequest: Playlist?
    /// Songs to look up in the iTunes catalogue (Fix Info sheet).
    var fixInfoRequest: [String]?


    private var refreshing = false
    private var refreshAgain = false
    private var artwork: [String: NSImage] = [:]
    private var artworkTasks: [String: Task<NSImage?, Never>] = [:]
    private var clearActivityTask: Task<Void, Never>?
    // Progress arrives up to hundreds of times a second during a save; the UI shows
    // at most ~10 updates a second (the newest one always lands).
    private var pendingProgress: Activity?
    private var progressFlush: Task<Void, Never>?
    private var lastProgressUpdate = Date.distantPast

    private init() {
        engine.onEvent = { [weak self] method, data in self?.handle(method, data) }
        engine.start()
    }

    // MARK: Marked for Removal (songs rated 1 star)

    static let markedPlaylistName = "Marked for Removal"
    /// Settings keys; the playlist is on by default, removing without asking is off.
    static let markedPlaylistKey = "markedPlaylist"
    static let autoRemoveMarkedKey = "autoRemoveMarked"

    /// Songs rated 1 star, on the iPod or here: the ones waiting to be removed.
    var markedTracks: [Track] { tracks.filter { (1...20).contains($0.rating) } }
    /// The review banner was closed for this connection.
    var markedBannerDismissed = false

    /// Once per connection: make sure the iPod has its live "Marked for Removal"
    /// playlist, and remove marked songs if the person chose that.
    private func connectedForMarked() {
        markedBannerDismissed = false
        let defaults = UserDefaults.standard
        let wantsPlaylist = defaults.object(forKey: Self.markedPlaylistKey) as? Bool ?? true
        let autoRemove = defaults.bool(forKey: Self.autoRemoveMarkedKey)
        let hasPlaylist = playlists.contains { $0.kind == "smart" && $0.name == Self.markedPlaylistName }
        guard editBlocker == nil, (wantsPlaylist && !hasPlaylist) || (autoRemove && !markedTracks.isEmpty) else { return }
        Task {
            if wantsPlaylist && !hasPlaylist { await perform("playlist.ensureMarked", [:]) }
            if autoRemove { await removeMarked() }
        }
    }

    /// Remove every song rated 1 star from the iPod (after confirmation, or automatically).
    func removeMarked() async {
        let ids = markedTracks.map(\.id)
        guard !ids.isEmpty else { return }
        await removeFromIPod(ids)
    }

    /// Songs added in the last 90 days, newest first (Recently Added, shown by day).
    var recentlyAdded: [Track] {
        let since = Int(Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970)
        return tracks.filter { $0.dateAdded >= since }.sorted { $0.dateAdded > $1.dateAdded }
    }

    var regularPlaylists: [Playlist] {
        playlists.filter(\.isRegular).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isBusy: Bool { activity?.isWorking ?? false }


    /// Whether edits can be made right now; the reason when they can't.
    var editBlocker: String? {
        if !device.connected { return "Connect your iPod to make changes." }
        if device.otherWriter { return "Quit iOpenPod to make changes here." }
        return nil
    }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIds.compactMap { tracksByID[$0] }
    }

    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: Events

    private func handle(_ method: String, _ data: Data) {
        let decoder = JSONDecoder()
        switch method {
        case "device.changed":
            guard let status = try? decoder.decode(DeviceStatus.self, from: data) else { return }
            let wasConnected = device.connected
            device = status
            if !status.connected {
                tracks = []; playlists = []; tracksByID = [:]
                PlayerController.shared.stop()
                hasLoaded = false
                artwork.removeAll()
            } else if !wasConnected {
                Task { await refresh() }
            }
        case "library.changed":
            artwork.removeAll()  // artwork ids are only valid within one library generation
            artworkTasks.removeAll()
            Task { await refresh() }
        case "send.queued":
            guard let event = try? decoder.decode(QueuedEvent.self, from: data) else { return }
            setActivity(Activity(phase: .importing, done: 0, total: event.files))
        case "send.progress":
            guard let event = try? decoder.decode(ProgressEvent.self, from: data) else { return }
            updateProgress(Activity(phase: .importing, done: event.done, total: event.total,
                                    item: (pendingProgress ?? activity)?.item))
        case "send.item":
            guard let event = try? decoder.decode(SendItemEvent.self, from: data) else { return }
            let state = SendItem.State(rawValue: event.state) ?? .ready
            if state == .converting || state == .queued, var current = pendingProgress ?? activity,
               current.phase == .importing {
                current.item = (event.file as NSString).deletingPathExtension  // the file being read or converted
                updateProgress(current)
            }
            if let index = sendLog.firstIndex(where: { $0.file == event.file && $0.state == .converting }) {
                sendLog[index].state = state
                sendLog[index].detail = event.detail
            } else {
                sendLog.insert(SendItem(file: event.file, state: state, detail: event.detail), at: 0)
                if sendLog.count > 60 { sendLog.removeLast(sendLog.count - 60) }
            }
        case "write.state":
            guard let event = try? decoder.decode(WriteStateEvent.self, from: data) else { return }
            switch event.state {
            case "saving": setActivity(Activity(phase: .saving, percent: 0))
            case "failed": finish(.failed(event.message ?? "Couldn't write to the iPod."))
            case "saved":
                // Ends every save, including deletes, renames and info edits. (A send's
                // own summary follows and replaces this.) Without it the status stayed
                // on "Writing to iPod…", which blocked Eject and Quit.
                finish(.done("Saved. Eject the iPod to see the changes on it."))
            default: break
            }
        case "write.progress":
            guard let event = try? decoder.decode(WriteProgressEvent.self, from: data),
                  activity?.phase == .saving else { return }
            updateProgress(Activity(phase: .saving, percent: event.percent, label: event.label,
                                 item: event.item, stepDone: event.done, stepTotal: event.total))
        case "keep.progress":
            guard let event = try? decoder.decode(KeepProgressEvent.self, from: data) else { return }
            let step = Activity(phase: .saving, percent: event.total > 0 ? event.done * 100 / event.total : nil,
                                label: "Keeping copies on your Mac", item: event.item,
                                stepDone: event.done, stepTotal: event.total)
            if activity?.isWorking == true { updateProgress(step) } else { setActivity(step) }
        case "device.error":
            if let event = try? decoder.decode(MessageEvent.self, from: data) { lastError = event.message }
        case "engine.restarting":
            lastError = "The iPod engine restarted. Your last change may not have been saved."
            if isBusy { setActivity(nil) }
        default:
            break
        }
    }

    func refresh() async {
        guard device.connected else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                let firstLoad = !hasLoaded
                let snapshot = try await engine.call("library.snapshot", as: LibrarySnapshot.self)
                tracks = snapshot.tracks
                playlists = snapshot.playlists
                tracksByID = Dictionary(snapshot.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                PlayerController.shared.libraryChanged(tracksByID)
                device = snapshot.device
                hasLoaded = true
                reconcileSendTarget()
                if firstLoad { connectedForMarked() }
            } catch {
                lastError = error.localizedDescription
            }
        } while refreshAgain
    }

    /// Playlist ids can change after a save; keep the chosen target by name.
    private func reconcileSendTarget() {
        switch sendTarget {
        case .library:
            break
        case .playlist(let id, let name):
            if let match = playlist(id: id) ?? regularPlaylists.first(where: { $0.name == name }) {
                sendTarget = .playlist(id: match.id, name: match.name)
            } else {
                sendTarget = .library
            }
        case .newPlaylist(let name):
            if let match = regularPlaylists.first(where: { $0.name == name }) {
                sendTarget = .playlist(id: match.id, name: match.name)
            }
        }
    }

    // MARK: Send

    func send(_ urls: [URL], to target: SendTarget? = nil) {
        let target = target ?? sendTarget
        guard !urls.isEmpty else { return }
        if let blocker = editBlocker { lastError = blocker; return }
        var params: [String: Any] = ["paths": urls.map(\.path)]
        switch target {
        case .library: break
        case .playlist(let id, _): params["playlistId"] = id
        case .newPlaylist(let name): params["newPlaylist"] = name
        }
        clearActivityTask?.cancel()
        Task {
            do {
                let result = try await engine.call("send.add", params, as: SendResult.self)
                finish(.done(Self.summary(result)))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    private static func summary(_ r: SendResult) -> String {
        var parts: [String] = []
        if r.added > 0 { parts.append("Added \(r.added) song\(r.added == 1 ? "" : "s")") }
        if r.skipped > 0 { parts.append("\(r.skipped) already on iPod") }
        if r.failed > 0 { parts.append("\(r.failed) failed") }
        var text = parts.isEmpty ? "Nothing to add" : parts.joined(separator: ", ")
        if let playlist = r.playlist { text += " · \(playlist)" }
        return text
    }

    /// Show a new state now (start, finish, failure), dropping any queued progress.
    private func setActivity(_ value: Activity?) {
        clearActivityTask?.cancel()
        progressFlush?.cancel()
        progressFlush = nil
        pendingProgress = nil
        activity = value
        lastProgressUpdate = Date()
    }

    /// A progress step: shown now if the last one was a while ago, else coalesced.
    private func updateProgress(_ value: Activity) {
        guard Date().timeIntervalSince(lastProgressUpdate) < 0.1 else {
            pendingProgress = nil
            activity = value
            lastProgressUpdate = Date()
            return
        }
        pendingProgress = value
        guard progressFlush == nil else { return }
        progressFlush = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            progressFlush = nil
            if let pending = pendingProgress {
                pendingProgress = nil
                activity = pending
                lastProgressUpdate = Date()
            }
        }
    }

    private func record(_ message: String) {
        recentErrors.append((Date(), message))
        if recentErrors.count > 20 { recentErrors.removeFirst(recentErrors.count - 20) }
    }

    private func finish(_ phase: Activity.Phase) {
        if case .failed(let message) = phase { record(message) }
        setActivity(Activity(phase: phase))
        clearActivityTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if activity?.isWorking == false { activity = nil }
        }
    }

    // MARK: Library edits

    /// Run one engine edit; reports failures and returns whether it worked.
    @discardableResult
    func perform(_ method: String, _ params: [String: Any]) async -> Bool {
        if let blocker = editBlocker { lastError = blocker; return false }
        do {
            try await engine.send(method, params)
            return true
        } catch {
            lastError = error.localizedDescription
            if isBusy { finish(.failed(error.localizedDescription)) }
            return false
        }
    }

    func createPlaylist(named name: String, with trackIDs: [String] = []) async -> Bool {
        await perform("playlist.create", ["name": name, "trackIds": trackIDs])
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) async {
        await perform("playlist.rename", ["id": playlist.id, "name": name])
    }

    func deletePlaylist(_ playlist: Playlist) async {
        await perform("playlist.delete", ["id": playlist.id])
    }

    func add(_ trackIDs: [String], to playlist: Playlist) async {
        await perform("playlist.addTracks", ["id": playlist.id, "trackIds": trackIDs])
    }

    func remove(_ trackIDs: Set<String>, from playlist: Playlist) async {
        let remaining = playlist.trackIds.filter { !trackIDs.contains($0) }
        await perform("playlist.setTracks", ["id": playlist.id, "trackIds": remaining])
    }

    func edit(_ trackIDs: [String], fields: [String: Any]) async -> Bool {
        guard !fields.isEmpty else { return true }
        return await perform("tracks.edit", ["ids": trackIDs, "fields": fields])
    }

    /// Per-song field changes and cover art, saved to the iPod in one write.
    func editMany(_ items: [[String: Any]]) async -> Bool {
        await perform("tracks.editMany", ["items": items])
    }

    static let keepRemovedCopiesKey = "keepRemovedCopies"
    /// Copies of removed songs stay on the Mac for 30 days (on unless turned off).
    static var keepsRemovedCopies: Bool {
        UserDefaults.standard.object(forKey: keepRemovedCopiesKey) as? Bool ?? true
    }
    static let recentlyRemovedFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Music/iPod Drop/Recently Removed", directoryHint: .isDirectory)

    /// Remove songs from the iPod (copies are kept on the Mac first, if that's on).
    @discardableResult
    func removeFromIPod(_ trackIDs: some Collection<String>) async -> Bool {
        if let blocker = editBlocker { lastError = blocker; return false }
        do {
            let result = try await engine.call("tracks.remove",
                                               ["ids": Array(trackIDs), "keepCopies": Self.keepsRemovedCopies],
                                               as: RemoveResult.self)
            var message = "Removed \(Format.songs(result.removed)) from the iPod."
            if let kept = result.kept, kept > 0 {
                message += " Copies are in Recently Removed for 30 days."
            } else if Self.keepsRemovedCopies, (result.notKept ?? 0) > 0 {
                message += " Not enough space on this Mac to keep copies."
            }
            finish(.done(message))
            return true
        } catch {
            lastError = error.localizedDescription
            if isBusy { finish(.failed(error.localizedDescription)) }
            return false
        }
    }

    enum RecoveryChoice: String { case restore, keep }

    /// Answer an interrupted save so the iPod can open again.
    func recover(_ choice: RecoveryChoice) {
        lastError = nil
        Task {
            do {
                try await engine.send("device.recover", ["choice": choice.rawValue])
                finish(.done(choice == .restore ? "Restored the iPod's library from before the unfinished change."
                                                : "Kept the iPod as it is."))
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Open a different connected iPod. The library reloads through `library.changed`.
    func selectDevice(_ device: DeviceInfo) {
        guard !device.active else { return }
        Task {
            do {
                try await engine.send("device.select", ["id": device.id])
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func eject() {
        PlayerController.shared.stop()  // an open file would stop the iPod from unmounting
        let name = device.name ?? "iPod"
        lastError = nil
        // The engine retries for a few seconds if macOS is briefly using the iPod.
        setActivity(Activity(phase: .saving, label: "Ejecting \(name)…"))
        Task {
            do {
                try await engine.send("device.eject")
                finish(.done("\(name) is ejected. You can unplug it now."))
            } catch {
                setActivity(nil)
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Artwork

    /// Cover art decoded from the iPod, cached for this library generation.
    func artwork(_ artworkID: Int, pixels: Int) async -> NSImage? {
        guard artworkID > 0, device.connected else { return nil }
        let bucket = [96, 192, 384, 600].first { $0 >= pixels } ?? 600
        let key = "\(artworkID)-\(bucket)"
        if let image = artwork[key] { return image }
        if let task = artworkTasks[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let result = try? await engine.call("library.artwork", ["artworkId": artworkID, "size": bucket], as: ArtworkResult.self),
                  let path = result.path
            else { return nil }
            return NSImage(contentsOfFile: path)
        }
        artworkTasks[key] = task
        let image = await task.value
        artworkTasks[key] = nil
        if let image { artwork[key] = image }
        return image
    }
}
