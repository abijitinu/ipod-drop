import SwiftUI

/// Songs that are on the iPod more than once, one header per song. The copy marked
/// "Keep" stays; Remove Extra Copies removes the others and puts the kept copy in
/// their playlists.
struct DuplicatesView: View {
    private let store = LibraryStore.shared
    let groups: [DuplicateGroup]
    @Binding var selection: Set<Track.ID>
    @Binding var showInspector: Bool

    private var extras: Int { groups.reduce(0) { $0 + $1.extras.count } }

    var body: some View {
        SongsTable(
            tracks: groups.flatMap(\.all), selection: $selection, showInspector: $showInspector,
            sections: groups.map { group in
                TrackSection(id: group.id,
                             title: "\(group.keep.displayTitle) – \(group.keep.displayArtist) · \(group.all.count) copies",
                             tracks: group.all)
            },
            keepIDs: Set(groups.map(\.keep.id)),
            initialSort: [])
        .safeAreaInset(edge: .top, spacing: 0) {
            if !groups.isEmpty { header }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                       description: Text("Every song is on your iPod once."))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square").font(.title2).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.songs(groups.count)) on your iPod more than once")
                    .font(.headline)
                Text("The copy marked Keep has the best cover art, info, quality and play count. Removing the others puts it in their playlists.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(extras == 1 ? "Remove Extra Copy…" : "Remove \(extras) Extra Copies…") {
                store.duplicateRemovalRequest = groups
            }
            .glassProminentButtonStyle()
            .disabled(store.editBlocker != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
