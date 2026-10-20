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

    private init() {
        engine.onEvent = { [weak self] method, data in self?.handle(method, data) }
        engine.start()
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
            setActivity(Activity(phase: .importing, done: event.done, total: event.total))
        case "send.item":
            guard let event = try? decoder.decode(SendItemEvent.self, from: data) else { return }
            let state = SendItem.State(rawValue: event.state) ?? .ready
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
            setActivity(Activity(phase: .saving, percent: event.percent, label: event.label))
        case "device.error":
            if let event = try? decoder.decode(MessageEvent.self, from: data) { lastError = event.message }
        case "engine.restarting":
            lastError = "The iPod engine restarted. Your last change may not have been saved."
            if isBusy { activity = nil }
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
                let snapshot = try await engine.call("library.snapshot", as: LibrarySnapshot.self)
                tracks = snapshot.tracks
                playlists = snapshot.playlists
                tracksByID = Dictionary(snapshot.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                PlayerController.shared.libraryChanged(tracksByID)
                device = snapshot.device
                hasLoaded = true
                reconcileSendTarget()
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

    private func setActivity(_ value: Activity) {
        clearActivityTask?.cancel()
        activity = value
    }

    private func record(_ message: String) {
        recentErrors.append((Date(), message))
        if recentErrors.count > 20 { recentErrors.removeFirst(recentErrors.count - 20) }
    }

    private func finish(_ phase: Activity.Phase) {
        if case .failed(let message) = phase { record(message) }
        activity = Activity(phase: phase)
        clearActivityTask?.cancel()
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

    func removeFromIPod(_ trackIDs: Set<String>) async {
        await perform("tracks.remove", ["ids": Array(trackIDs)])
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
                activity = nil
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
