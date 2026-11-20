import SwiftUI

/// A sortable song list. Right-click for every song action; rows drag onto playlists;
/// Finder files dropped here are sent to the iPod (into the playlist when one is shown).
struct SongsTable: View {
    private let store = LibraryStore.shared
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool
    var playlist: Playlist?
    /// Show the songs under a header for each day they were added (Recently Added).
    var groupedByDay = false
    /// Show the songs under these headers instead (Duplicates), in the given order.
    var sections: [TrackSection]?
    /// Songs marked "Keep" (the copy of a duplicate that stays).
    var keepIDs: Set<String> = []

    @State private var sortOrder: [KeyPathComparator<Track>]
    @State private var isTargeted = false

    init(tracks: [Track], selection: Binding<Set<Track.ID>>, showInspector: Binding<Bool>,
         playlist: Playlist? = nil, groupedByDay: Bool = false,
         sections: [TrackSection]? = nil, keepIDs: Set<String> = [],
         initialSort: [KeyPathComparator<Track>]? = nil) {
        self.tracks = tracks
        _selection = selection
        _showInspector = showInspector
        self.playlist = playlist
        self.groupedByDay = groupedByDay
        self.sections = sections
        self.keepIDs = keepIDs
        // nil = artist, album, track order; [] = keep the given order (playlists, albums)
        _sortOrder = State(initialValue: initialSort
            ?? [KeyPathComparator(\.artist), KeyPathComparator(\.album), KeyPathComparator(\.trackNumber)])
    }

    private var rows: [Track] {
        if let shown = shownSections { return shown.flatMap(\.tracks) }
        return sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }

    /// Headers to show, if any: the given sections, or days for Recently Added.
    private var shownSections: [TrackSection]? {
        if let sections { return sections }
        if groupedByDay { return days.map { TrackSection(id: $0.title, title: $0.title, tracks: $0.tracks) } }
        return nil
    }

    /// Songs by the day they were added, newest day first; a column sort applies within each day.
    private var days: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: tracks) { track in
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(track.dateAdded)))
        }
        return byDay.keys.sorted(by: >).map { day in
            let songs = byDay[day] ?? []
            return DayGroup(day: day, tracks: sortOrder.isEmpty
                            ? songs.sorted { $0.dateAdded > $1.dateAdded }
                            : songs.sorted(using: sortOrder))
        }
    }

    struct DayGroup: Identifiable {
        let day: Date
        let tracks: [Track]
        var id: Date { day }

        /// "Today", "Yesterday", "Monday, 3 November" (with the year when it isn't this year).
        var title: String {
            let calendar = Calendar.current
            let name: String
            if calendar.isDateInToday(day) {
                name = "Today"
            } else if calendar.isDateInYesterday(day) {
                name = "Yesterday"
            } else if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
                name = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            } else {
                name = day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            }
            return "\(name) · \(Format.songs(tracks.count))"
        }
    }

    /// Selected ids in on-screen order, so playlists keep the order you see.
    private func ordered(_ ids: Set<Track.ID>) -> [String] {
        rows.map(\.id).filter(ids.contains)
    }

    var body: some View {
        Table(of: Track.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 8) {
                    PlayingTitle(track: track)
                    if keepIDs.contains(track.id) {
                        Text("Keep")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.brand, in: .capsule)
                            .help("This copy stays: it has the best cover art, info, quality and play count")
                    }
                }
            }
            .width(min: 120, ideal: 280)
            TableColumn("Artist", value: \.artist) { Text($0.artist).lineLimit(1) }
                .width(min: 70, ideal: 180)
            TableColumn("Album", value: \.album) { Text($0.album).lineLimit(1) }
                .width(min: 70, ideal: 200)
            TableColumn("Time", value: \.lengthMs) { track in
                Text(Format.duration(ms: track.lengthMs)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(56)
            TableColumn("Genre", value: \.genre) { Text($0.genre).lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 100)
            TableColumn("Year", value: \.year) { track in
                Text(track.year > 0 ? String(track.year) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? String(track.playCount) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)
        } rows: {
            if let shownSections {
                ForEach(shownSections) { group in
                    Section {
                        ForEach(group.tracks) { track in
                            TableRow(track)
                                .draggable(TrackDrag.payload(track.id))
                        }
                    } header: {
                        Text(group.title)
                            .font(.headline)
                    }
                }
            } else {
                ForEach(rows) { track in
                    TableRow(track)
                        .draggable(TrackDrag.payload(track.id))
                }
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
                    .strokeBorder(Color.brand, lineWidth: 3)
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

/// A titled group of rows in a song list.
struct TrackSection: Identifiable {
    let id: String
    let title: String
    let tracks: [Track]
}

/// Cover and title in the Title column. The song that's playing stands out: an animated
/// sound icon over its cover (a still speaker while paused) and its title in the app colour.
private struct PlayingTitle: View {
    let track: Track
    private var player: PlayerController { .shared }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 8) {
            ArtworkView(artworkID: track.artworkId, size: 26, cornerRadius: 4, seed: track.album)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.black.opacity(0.5))
                            .overlay {
                                Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            }
                    }
                }
            Text(track.displayTitle)
                .lineLimit(1)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.brand : .primary)
        }
        .help(isCurrent ? (player.isPlaying ? "Now playing" : "Paused") : "")
    }
}
