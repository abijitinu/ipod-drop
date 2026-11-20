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
        // The header sits above the table at a fixed height, with single-line text.
        // Text that wraps makes its height depend on the column width, and a split-view
        // column whose size keeps changing sends AppKit into a layout loop (2.4 crash).
        VStack(spacing: 0) {
            if !groups.isEmpty {
                header
                    .frame(height: Self.headerHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                Divider()
            }
            SongsTable(
                tracks: groups.flatMap(\.all), selection: $selection, showInspector: $showInspector,
                sections: groups.map { group in
                    TrackSection(id: group.id,
                                 title: "\(group.keep.displayTitle) – \(group.keep.displayArtist) · \(group.all.count) copies",
                                 tracks: group.all)
                },
                keepIDs: Set(groups.map(\.keep.id)),
                initialSort: [])
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                       description: Text("Every song is on your iPod once."))
            }
        }
    }

    static let headerHeight: CGFloat = 58

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square").font(.title2).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.songs(groups.count)) on your iPod more than once")
                    .font(.headline)
                    .lineLimit(1)
                Text("The copy marked Keep stays and takes the others' place in playlists.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(-1)  // the text truncates before the button shrinks
            .help("The copy marked Keep has the best cover art, info, quality and play count. Removing the others puts it in their playlists.")
            Spacer(minLength: 8)
            Button(extras == 1 ? "Remove Extra Copy…" : "Remove \(extras) Extra Copies…") {
                store.duplicateRemovalRequest = groups
            }
            .glassProminentButtonStyle()
            .fixedSize()
            .disabled(store.editBlocker != nil)
        }
        .padding(.horizontal, 16)
        .background(.bar)
    }
}
