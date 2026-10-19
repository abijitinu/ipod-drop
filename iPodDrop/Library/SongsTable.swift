import SwiftUI

/// A sortable song list. Right-click for every song action; rows drag onto playlists;
/// Finder files dropped here are sent to the iPod (into the playlist when one is shown).
struct SongsTable: View {
    private let store = LibraryStore.shared
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool
    var playlist: Playlist?

    @State private var sortOrder: [KeyPathComparator<Track>]
    @State private var isTargeted = false

    init(tracks: [Track], selection: Binding<Set<Track.ID>>, showInspector: Binding<Bool>,
         playlist: Playlist? = nil,
         initialSort: [KeyPathComparator<Track>]? = nil) {
        self.tracks = tracks
        _selection = selection
        _showInspector = showInspector
        self.playlist = playlist
        // nil = artist, album, track order; [] = keep the given order (playlists, albums)
        _sortOrder = State(initialValue: initialSort
            ?? [KeyPathComparator(\.artist), KeyPathComparator(\.album), KeyPathComparator(\.trackNumber)])
    }

    private var rows: [Track] {
        sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }

    /// Selected ids in on-screen order, so playlists keep the order you see.
    private func ordered(_ ids: Set<Track.ID>) -> [String] {
        rows.map(\.id).filter(ids.contains)
    }

    var body: some View {
        Table(of: Track.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 8) {
                    ArtworkView(artworkID: track.artworkId, size: 26, cornerRadius: 4, seed: track.album)
                    Text(track.displayTitle).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist", value: \.artist) { Text($0.artist).lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.album) { Text($0.album).lineLimit(1) }
                .width(min: 100, ideal: 200)
            TableColumn("Time", value: \.lengthMs) { track in
                Text(Format.duration(ms: track.lengthMs)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(56)
            TableColumn("Genre", value: \.genre) { Text($0.genre).lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 100)
            TableColumn("Year", value: \.year) { track in
                Text(track.year > 0 ? String(track.year) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(track.playCount) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)
        } rows: {
            ForEach(rows) { track in
                TableRow(track)
                    .draggable(TrackDrag.payload(track.id))
            }
        }
        // Right-click: acts on the selection, or on the clicked row if it isn't selected.
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            TrackActionsMenu(ids: ordered(ids), playlist: playlist)
        } primaryAction: { ids in
            // Double-click / Return plays: the clicked song, then the rest of this list.
            if ids.count == 1, let id = ids.first {
                PlayerController.shared.play(rows, startingAt: id)
            } else {
                PlayerController.shared.play(rows.filter { ids.contains($0.id) })
            }
        }
        .onKeyPress(.space) {
            PlayerController.shared.togglePlayPause()
            return .handled
        }
        .onDeleteCommand {
            if !selection.isEmpty, store.editBlocker == nil { store.removalRequest = ordered(selection) }
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label(playlist == nil ? "No Songs" : "Empty Playlist", systemImage: "music.note")
                } description: {
                    Text("Drag music here from Finder, or drop it on the iPod icon in the menu bar.")
                }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let playlist {
                store.send(urls, to: .playlist(id: playlist.id, name: playlist.name))
            } else {
                store.send(urls, to: .library)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
