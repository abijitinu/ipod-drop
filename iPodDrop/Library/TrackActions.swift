import AppKit
import SwiftUI

/// The right-click menu for any set of songs: table rows, album and book covers,
/// artists and genres. Dialogs it needs are shown by the library window.
struct TrackActionsMenu: View {
    private let store = LibraryStore.shared
    /// Songs in display order.
    let ids: [String]
    /// The playlist being viewed, if any (enables "Remove from Playlist").
    var playlist: Playlist?

    private var tracks: [Track] { ids.compactMap { store.tracksByID[$0] } }

    var body: some View {
        let blocked = store.editBlocker != nil
        if !ids.isEmpty {
            Button("Play", systemImage: "play.fill") { PlayerController.shared.play(tracks) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                PlayerController.shared.playNext(tracks)
            }
            Button("Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") {
                PlayerController.shared.addToQueue(tracks)
            }
            Divider()
            Button("Get Info", systemImage: "info.circle") { store.infoRequest = Set(ids) }
            Button(ids.count == 1 ? "Fix Info…" : "Fix Info for \(ids.count) Songs…", systemImage: "wand.and.sparkles") {
                store.fixInfoRequest = ids
            }
            .disabled(blocked)

            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                Button("New Playlist…", systemImage: "plus") { store.newPlaylistRequest = ids }
                if !store.regularPlaylists.isEmpty { Divider() }
                ForEach(store.regularPlaylists) { target in
                    Button(target.name) { Task { await store.add(ids, to: target) } }
                        .disabled(target.id == playlist?.id)
                }
            }
            .disabled(blocked)

            if let playlist {
                Button("Remove from Playlist", systemImage: "minus.circle") {
                    Task { await store.remove(Set(ids), from: playlist) }
                }
                .disabled(blocked)
            }

            Divider()

            Menu("Copy", systemImage: "doc.on.doc") {
                Button("Title") { copy(tracks.map(\.displayTitle)) }
                Button("Artist – Title") { copy(tracks.map { "\($0.displayArtist) – \($0.displayTitle)" }) }
                Button("Album") { copy(Array(Set(tracks.map(\.displayAlbum))).sorted()) }
            }

            Divider()

            Button(ids.count == 1 ? "Remove from iPod…" : "Remove \(ids.count) Songs from iPod…",
                   systemImage: "trash", role: .destructive) {
                store.removalRequest = ids
            }
            .disabled(blocked)
        }
    }

    private func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// Drag payload for several songs at once (album covers, artist rows).
extension TrackDrag {
    static func payload(_ ids: [String]) -> String {
        ids.map(payload).joined(separator: "\n")
    }
}
