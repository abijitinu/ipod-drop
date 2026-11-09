import SwiftUI

nonisolated struct Album: Identifiable, Hashable {
    var id: String { "\(owner)\u{1F}\(title)" }
    let title: String
    let owner: String
    let year: Int
    let artworkID: Int
    let trackIDs: [String]
}

extension Array where Element == Track {
    func albums() -> [Album] {
        Dictionary(grouping: self) { "\($0.albumOwner)\u{1F}\($0.displayAlbum)" }
            .map { _, tracks in
                let sorted = tracks.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
                let first = sorted[0]
                return Album(
                    title: first.displayAlbum,
                    owner: first.albumOwner,
                    year: tracks.map(\.year).max() ?? 0,
                    artworkID: tracks.first { $0.artworkId > 0 }?.artworkId ?? 0,
                    trackIDs: sorted.map(\.id)
                )
            }
            .sorted { ($0.owner.lowercased(), $0.title.lowercased()) < ($1.owner.lowercased(), $1.title.lowercased()) }
    }
}

/// Album covers in a grid; opening one shows its songs.
struct AlbumsView: View {
    private let store = LibraryStore.shared
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool
    @State private var path: [Album] = []

    var body: some View {
        NavigationStack(path: $path) {
            let albums = tracks.albums()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) { AlbumTile(album: album) }
                            .buttonStyle(.plain)
                            .contextMenu { TrackActionsMenu(ids: album.trackIDs) }
                            .draggable(TrackDrag.payload(album.trackIDs)) {
                                ArtworkView(artworkID: album.artworkID, size: 64, cornerRadius: 8, seed: album.title)
                            }
                    }
                }
                .padding(24)
            }
            .overlay { if albums.isEmpty { ContentUnavailableView.search } }
            .navigationDestination(for: Album.self) { album in
                AlbumDetail(album: album, selection: $selection, showInspector: $showInspector)
            }
        }
    }
}

private struct AlbumTile: View {
    let album: Album
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ArtworkView(artworkID: album.artworkID, size: proxy.size.width, cornerRadius: 10, seed: album.title)
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.02 : 1)
            Text(album.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(album.owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }
}

private struct AlbumDetail: View {
    private let store = LibraryStore.shared
    let album: Album
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool

    var body: some View {
        let tracks = album.trackIDs.compactMap { store.tracksByID[$0] }
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                ArtworkView(artworkID: album.artworkID, size: 160, cornerRadius: 12, seed: album.title)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title).font(.largeTitle.weight(.bold)).lineLimit(2)
                    Text(album.owner).font(.title3).foregroundStyle(Color.brand)
                    Text([album.year > 0 ? String(album.year) : nil,
                          Format.songs(tracks.count),
                          Format.longDuration(ms: tracks.reduce(0) { $0 + $1.lengthMs })]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            SongsTable(tracks: tracks, selection: $selection, showInspector: $showInspector, initialSort: [])
        }
        .navigationTitle(album.title)
    }
}

/// Artists or genres on the left, their songs on the right.
struct GroupedView: View {
    enum Kind { case artist, genre }

    let kind: Kind
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool
    @State private var chosen: String?

    var body: some View {
        let groups = Dictionary(grouping: tracks, by: key)
        let names = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ResizableSplit(id: kind == .artist ? "artists" : "genres", defaultWidth: 240,
                       minLeading: 150, maxLeading: 420, minTrailing: 300) {
            List(names, id: \.self, selection: $chosen) { name in
                let ids = (groups[name] ?? []).map(\.id)
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text("\(ids.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .contextMenu { TrackActionsMenu(ids: ids) }
                .draggable(TrackDrag.payload(ids))
            }
        } trailing: {
            if let chosen, let songs = groups[chosen] {
                SongsTable(tracks: songs, selection: $selection, showInspector: $showInspector)
            } else {
                ContentUnavailableView(kind == .artist ? "Choose an Artist" : "Choose a Genre",
                                       systemImage: kind == .artist ? "music.microphone" : "guitars")
            }
        }
        .onAppear { if chosen == nil { chosen = names.first } }
    }

    private func key(_ track: Track) -> String {
        switch kind {
        case .artist: track.albumOwner
        case .genre: track.genre.isEmpty ? "Unknown Genre" : track.genre
        }
    }
}
