import SwiftUI

/// Copies of songs removed from the iPod, kept on the Mac for 30 days
/// (~/Music/iPod Drop/Recently Removed). Add them back to undo a removal.
struct RecentlyRemovedSheet: View {
    private let store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var batches: [Batch] = []
    @State private var selection = Set<URL>()
    @State private var size = SheetSize.fitting(CGSize(width: 640, height: 520), minimum: CGSize(width: 520, height: 360))

    struct Batch: Identifiable {
        let id: URL
        let removed: Date
        let songs: [URL]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recently Removed").font(.title2.weight(.semibold))
                Text("Copies of songs removed from your iPod, kept on this Mac for 30 days. Add them back to undo a removal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if batches.isEmpty {
                ContentUnavailableView("Nothing Removed Recently", systemImage: "trash.slash",
                                       description: Text("Songs you remove from the iPod show up here for 30 days."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(batches) { batch in
                        Section(batch.removed.formatted(date: .abbreviated, time: .shortened)) {
                            ForEach(batch.songs, id: \.self) { url in
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "music.note")
                                    .lineLimit(1)
                                    .tag(url)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        selection.isEmpty ? [LibraryStore.recentlyRemovedFolder] : Array(selection))
                }
                .disabled(batches.isEmpty)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection.isEmpty ? "Add All Back to iPod" : "Add \(selection.count) Back to iPod") {
                    let urls = selection.isEmpty ? batches.flatMap(\.songs) : Array(selection)
                    store.send(urls, to: .library)
                    dismiss()
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(batches.isEmpty || store.editBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: size.width, height: size.height)
        .tint(.brand)
        .onAppear(perform: load)
    }

    private func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: LibraryStore.recentlyRemovedFolder,
                                                    includingPropertiesForKeys: [.creationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        batches = folders.compactMap { folder in
            let songs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !songs.isEmpty else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Batch(id: folder, removed: date, songs: songs)
        }
        .sorted { $0.removed > $1.removed }
    }
}
