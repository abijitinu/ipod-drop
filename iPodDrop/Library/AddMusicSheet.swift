import SwiftUI
import UniformTypeIdentifiers

/// Add Music: drop files or folders (or choose them), review, pick a playlist, send.
struct AddMusicSheet: View {
    private let store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    let initialTarget: SendTarget
    @State private var target: SendTarget = .library
    @State private var items: [URL] = []
    @State private var isTargeted = false
    @State private var namingPlaylist = false
    @State private var newPlaylistName = ""
    /// Room for the list of staged files, so the sheet always fits the window.
    @State private var listHeight = min(150, max(56, SheetSize.available.height - 440))

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            dropZone
            if !items.isEmpty { staged }
            if let blocker = store.editBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            footer
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { target = initialTarget }
        .tint(.brand)
        .animation(.smooth(duration: 0.2), value: items)
        .alert("New Playlist", isPresented: $namingPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Use Playlist") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { target = .newPlaylist(name: name) }
            }
        } message: {
            Text("It's created on your iPod with these songs.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            DeviceImage(path: store.device.image, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Music to \(store.device.name ?? "iPod")").font(.title3.weight(.semibold))
                Text("Anything the iPod can't play is converted automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isTargeted ? Color.brand : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text(isTargeted ? "Release to add" : "Drag songs or folders here")
                .font(.headline)
            Text("MP3, AAC, Apple Lossless, FLAC, WAV, AIFF, Opus and more")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose Files or Folders…", systemImage: "folder", action: choose)
                .glassButtonStyle()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: items.isEmpty ? 190 : 120)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isTargeted ? Color.brand.opacity(0.10) : Color.secondary.opacity(0.04))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isTargeted ? Color.brand : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var staged: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(items.count) item\(items.count == 1 ? "" : "s") to add")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Clear") { items.removeAll() }
                    .buttonStyle(.borderless)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: url.hasDirectoryPath ? "folder.fill" : "music.note")
                                .foregroundStyle(url.hasDirectoryPath ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 18)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove", systemImage: "xmark.circle.fill") {
                                items.removeAll { $0 == url }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxHeight: listHeight)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack {
            Text("Add to").foregroundStyle(.secondary)
            Menu {
                Picker("Add to", selection: $target) {
                    Label("Library only", systemImage: "music.note.house").tag(SendTarget.library)
                    if case .newPlaylist(let name) = target {
                        Label("\(name) (new)", systemImage: "music.note.list").tag(target)
                    }
                    if !store.regularPlaylists.isEmpty {
                        Divider()
                        ForEach(store.regularPlaylists) { playlist in
                            Label(playlist.name, systemImage: "music.note.list")
                                .tag(SendTarget.playlist(id: playlist.id, name: playlist.name))
                        }
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("New Playlist…", systemImage: "plus") {
                    newPlaylistName = ""
                    namingPlaylist = true
                }
            } label: {
                Text(target.name ?? "Library only")
            }
            .fixedSize()
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(items.isEmpty ? "Add to iPod" : "Add \(items.count) to iPod") {
                store.send(items, to: target)
                dismiss()
            }
            .glassProminentButtonStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(items.isEmpty || store.editBlocker != nil)
        }
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) {
            items.append(url)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.message = "Choose songs or folders of music to add to your iPod."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .folder]
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { add(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            add(panel.urls)
        }
    }
}
