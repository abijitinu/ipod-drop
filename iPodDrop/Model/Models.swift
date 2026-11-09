import Foundation

nonisolated struct Track: Decodable, Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: Int
    var trackNumber: Int
    var totalTracks: Int
    var discNumber: Int
    var totalDiscs: Int
    var composer: String
    var comment: String
    var compilation: Bool
    var lengthMs: Int
    var sizeBytes: Int
    var bitrateKbps: Int
    var sampleRateHz: Int
    var fileFormat: String
    var playCount: Int
    var rating: Int
    var artworkId: Int
    var dateAdded: Int
    var lastPlayed: Int
    var isAudio: Bool
    /// File on the iPod, relative to its mount point (e.g. iPod_Control/Music/F12/ABCD.mp3).
    var location: String

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    /// Album grouping uses the album artist when present, like the iPod itself.
    var albumOwner: String { albumArtist.isEmpty ? displayArtist : albumArtist }
    var stars: Int { rating / 20 }

    /// Placeholder text counts as missing ("Unknown Artist", "Track 01" and the like).
    static func isMissing(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty || v.hasPrefix("unknown") || v == "untitled" || v.range(of: #"^track ?\d+$"#, options: .regularExpression) != nil
    }

    /// Has everything Fix Info can fill in: names, genre, year, track number and cover art.
    var hasCompleteInfo: Bool {
        !Self.isMissing(title) && !Self.isMissing(artist) && !Self.isMissing(album) && !Self.isMissing(genre)
            && year > 0 && trackNumber > 0 && artworkId > 0
    }

}

nonisolated struct Playlist: Decodable, Identifiable, Hashable {
    let id: String
    var name: String
    var kind: String
    var parentId: String?
    var system: Bool
    var trackIds: [String]

    var isRegular: Bool { kind == "playlist" && !system }
}

nonisolated struct DeviceStatus: Decodable, Equatable {
    var connected: Bool
    var searching: Bool
    var busy: Bool
    var otherWriter: Bool
    /// Every mounted iPod-like volume, and iPods on USB that aren't usable as a disk.
    var devices: [DeviceInfo]
    var unmounted: [UnmountedIPod]
    var id: String?
    var name: String?
    var model: String?
    /// Product photo of the open iPod's exact model and colour.
    var image: String?
    /// Where the open iPod is mounted; songs play straight from here.
    var mountPath: String?
    var songs: Int?
    var totalBytes: Int64?
    var availableBytes: Int64?
    var generation: Int?
    /// An earlier save to this iPod didn't finish; it opens once you restore or keep.
    var recovery: RecoveryState?

    static let disconnected = DeviceStatus(connected: false, searching: true, busy: false, otherWriter: false,
                                           devices: [], unmounted: [])

    /// iPods that can be opened but aren't the one open now.
    var otherReadyDevices: [DeviceInfo] { devices.filter { $0.ready && !$0.active } }
    /// iPods that are plugged in but can't be used, with the reason.
    var problems: [DeviceProblem] {
        devices.filter { !$0.ready }.map { DeviceProblem(name: $0.displayName, message: $0.message, image: $0.image) }
            + unmounted.map { DeviceProblem(name: $0.name, message: $0.message, image: $0.image) }
    }

    var usedFraction: Double {
        guard let total = totalBytes, let free = availableBytes, total > 0 else { return 0 }
        return Double(total - free) / Double(total)
    }
}

nonisolated struct RecoveryState: Decodable, Equatable {
    var busy: Bool
    var error: String?
}

nonisolated struct DeviceInfo: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var model: String
    var image: String?
    var ready: Bool
    var active: Bool
    var message: String
    var totalBytes: Int64
    var availableBytes: Int64

    var displayName: String { model.isEmpty || model == name ? name : "\(name) · \(model)" }
}

nonisolated struct UnmountedIPod: Decodable, Equatable {
    var name: String
    var serial: String
    var kind: String
    var message: String
    var image: String?
}

nonisolated struct DeviceProblem: Equatable, Identifiable {
    var id: String { name + message }
    var name: String
    var message: String
    var image: String?
}

nonisolated struct LibrarySnapshot: Decodable {
    var generation: Int
    var device: DeviceStatus
    var tracks: [Track]
    var playlists: [Playlist]
}

nonisolated struct SendResult: Decodable {
    var added: Int
    var skipped: Int
    var failed: Int
    var playlist: String?
    var saved: Bool
}

nonisolated struct RemoveResult: Decodable {
    var removed: Int
    /// Copies kept on the Mac (Recently Removed), when keeping copies was on.
    var kept: Int?
    var notKept: Int?
}

nonisolated struct KeepProgressEvent: Decodable { var done: Int; var total: Int; var item: String? }

nonisolated struct ArtworkResult: Decodable {
    var path: String?
}

/// One file in the Send activity log.
nonisolated struct SendItem: Identifiable, Equatable {
    enum State: String {
        case queued, converting, ready, converted, existing, skipped, failed, saved
    }

    let id = UUID()
    var file: String
    var state: State
    var detail: String

    var symbol: String {
        switch state {
        case .queued: "clock"
        case .converting: "arrow.triangle.2.circlepath"
        case .ready, .converted: "checkmark.circle"
        case .saved: "checkmark.circle.fill"
        case .existing: "equal.circle"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var caption: String {
        switch state {
        case .queued: "Waiting"
        case .converting: "Converting…"
        case .ready: detail
        case .converted: "Converted · \(detail)"
        case .saved: detail
        case .existing: "Already on iPod"
        case .skipped: detail
        case .failed: detail
        }
    }
}

/// Where dropped music goes.
nonisolated enum SendTarget: Hashable {
    case library
    case playlist(id: String, name: String)
    case newPlaylist(name: String)

    var name: String? {
        switch self {
        case .library: nil
        case .playlist(_, let name), .newPlaylist(let name): name
        }
    }
}

/// The current Send or save operation, for progress UI.
nonisolated struct Activity: Equatable {
    enum Phase: Equatable {
        /// Reading and converting dropped files, before anything is written.
        case importing
        /// Writing the library to the iPod.
        case saving
        case done(String)
        case failed(String)
    }

    var phase: Phase
    /// Files prepared so far (importing).
    var done = 0
    var total = 0
    /// Overall progress of the save, 0...100 (saving).
    var percent: Int?
    /// What the save is doing right now, e.g. "Copying to the iPod".
    var label: String?
    /// The song being worked on, e.g. "Toxic — Britney Spears".
    var item: String?
    /// Files done in the current step and how many it has (saving), when known.
    var stepDone: Int?
    var stepTotal: Int?

    var isWorking: Bool {
        switch phase {
        case .importing, .saving: true
        default: false
        }
    }

    /// 0...1 when the amount of work is known.
    var fraction: Double? {
        switch phase {
        case .importing: total > 0 ? Double(min(done, total)) / Double(total) : nil
        case .saving: percent.map { Double($0) / 100 }
        default: nil
        }
    }

    var title: String {
        switch phase {
        case .importing: "Preparing songs"
        case .saving: label ?? "Writing to iPod"
        case .done(let message), .failed(let message): message
        }
    }

    /// "12 of 1,000 files" / "3 of 44 songs" for the step under way.
    var countText: String? {
        switch phase {
        case .importing:
            return total > 1 ? "\(min(done, total).formatted()) of \(total.formatted()) songs prepared" : nil
        case .saving:
            guard let total = stepTotal, total > 1, let done = stepDone else { return nil }
            return "\(min(done, total).formatted()) of \(total.formatted()) files"
        default:
            return nil
        }
    }

    /// "42%" while working, when known.
    var percentText: String? {
        fraction.map { "\(Int(($0 * 100).rounded()))%" }
    }

    /// Short text for the menu bar badge.
    var badge: String {
        switch phase {
        case .importing, .saving: percentText ?? "…"
        case .done: "✓"
        case .failed: "!"
        }
    }
}

nonisolated struct SendItemEvent: Decodable { var file: String; var state: String; var detail: String }
nonisolated struct ProgressEvent: Decodable { var done: Int; var total: Int }
nonisolated struct WriteStateEvent: Decodable { var state: String; var message: String? }
nonisolated struct WriteProgressEvent: Decodable {
    var percent: Int; var label: String; var item: String?; var done: Int?; var total: Int?
}
nonisolated struct MessageEvent: Decodable { var message: String }
nonisolated struct QueuedEvent: Decodable { var files: Int }

