import SwiftUI

enum SidebarItem: Hashable {
    case songs, albums, artists, genres, recentlyAdded
    case playlist(String)
}

/// The Manage window: sidebar of library sections and playlists, content, and inspector.
struct LibraryView: View {
    private let store = LibraryStore.shared
    @State private var section: SidebarItem? = .songs
    @State private var selection = Set<Track.ID>()
    @State private var search = ""
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $section)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.device.connected { NowPlayingBar() }
                }
                // Floats above the player instead of sitting in the safe area: progress
                // changes many times a second and must never resize the column (a column
                // whose minimum size keeps changing sends AppKit into a layout loop).
                .overlay(alignment: .bottom) {
                    statusOverlay
                        .padding(.bottom, store.device.connected ? NowPlayingBar.reservedHeight : 0)
                }
                .inspector(isPresented: $showInspector) {
                    InspectorView(trackIDs: selection)
                        .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
                }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search songs, artists, albums")
        .toolbar { toolbar }
        .overlay { if !store.device.connected { DeviceStateView() } }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .onChange(of: section) { selection.removeAll() }
        // Forget selected songs that were removed, so the table never points at rows that are gone.
        .onChange(of: store.tracks) {
            let kept = selection.filter { store.tracksByID[$0] != nil }
            if kept.count != selection.count { selection = kept }
        }
        .sheet(isPresented: Binding(get: { store.showAddMusic }, set: { store.showAddMusic = $0 })) {
            AddMusicSheet(initialTarget: currentTarget)
        }
        .modifier(LibraryDialogs(section: $section))
        .tint(.brand)
        .onChange(of: store.infoRequest) { _, ids in
            guard let ids else { return }
            selection = ids
            showInspector = true
            store.infoRequest = nil
        }
    }

    // MARK: Content

    @ViewBuilder
    private var detail: some View {
        switch section ?? .songs {
        case .songs:
            SongsTable(tracks: filtered(store.tracks), selection: $selection, showInspector: $showInspector)
        case .recentlyAdded:
            SongsTable(tracks: filtered(store.tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(200).map { $0 }),
                       selection: $selection, showInspector: $showInspector, initialSort: [])
        case .albums:
            AlbumsView(tracks: filtered(store.tracks), selection: $selection, showInspector: $showInspector)
        case .artists:
            GroupedView(kind: .artist, tracks: filtered(store.tracks), selection: $selection, showInspector: $showInspector)
        case .genres:
            GroupedView(kind: .genre, tracks: filtered(store.tracks), selection: $selection, showInspector: $showInspector)
        case .playlist(let id):
            if let playlist = store.playlist(id: id) {
                SongsTable(tracks: filtered(store.tracks(in: playlist)), selection: $selection,
                           showInspector: $showInspector, playlist: playlist, initialSort: [])
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
            }
        }
    }

    private func filtered(_ tracks: [Track]) -> [Track] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query) || $0.genre.localizedStandardContains(query)
                || $0.albumArtist.localizedStandardContains(query)
        }
    }

    /// Where "Add Music" sends files by default: the playlist on screen, else the library.
    private var currentTarget: SendTarget {
        if case .playlist(let id) = section, let playlist = store.playlist(id: id) {
            return .playlist(id: playlist.id, name: playlist.name)
        }
        return .library
    }

    private var title: String {
        switch section ?? .songs {
        case .songs: "Songs"
        case .recentlyAdded: "Recently Added"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .playlist(let id): store.playlist(id: id)?.name ?? "Playlist"
        }
    }

    private var subtitle: String {
        guard store.device.connected else { return "" }
        let tracks: [Track] = switch section ?? .songs {
        case .playlist(let id): store.playlist(id: id).map { store.tracks(in: $0) } ?? []
        default: store.tracks
        }
        let total = tracks.reduce(0) { $0 + $1.lengthMs }
        return "\(Format.songs(tracks.count)), \(Format.longDuration(ms: total))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Music", systemImage: "plus") { store.showAddMusic = true }
                .help("Add music to the iPod")
                .disabled(store.editBlocker != nil)
            Button("Eject", systemImage: "eject") { store.eject() }
                .help("Eject the iPod")
                .disabled(!store.device.connected || store.isBusy)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Fix Info", systemImage: "wand.and.sparkles") { fixInfo() }
                .help(selection.isEmpty ? "Look up song info and cover art for every song here"
                                        : "Look up song info and cover art for the selected songs")
                .disabled(store.editBlocker != nil || store.tracks.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Info", systemImage: "info.circle") { showInspector.toggle() }
                .help("Show song info")
        }
    }

    /// The selected songs, or everything in the current view (filtered by search).
    private func fixInfo() {
        if !selection.isEmpty {
            store.fixInfoRequest = Array(selection)
            return
        }
        let shown: [Track] = switch section ?? .songs {
        case .playlist(let id): store.playlist(id: id).map { store.tracks(in: $0) } ?? []
        case .recentlyAdded: Array(store.tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(200))
        default: store.tracks
        }
        store.fixInfoRequest = filtered(shown).map(\.id)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 8) {
            if let error = store.lastError {
                ErrorBanner(message: error).frame(maxWidth: 460)
            }
            if store.device.otherWriter {
                Label("iOpenPod is open. Quit it to make changes here.", systemImage: "exclamationmark.triangle")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .adaptiveGlass(in: .capsule, tint: .orange.opacity(0.15))
            }
            if let activity = store.activity {
                ActivityRow(activity: activity).frame(maxWidth: 420)
            }
        }
        .padding(16)
        .animation(.smooth, value: store.activity)
        .animation(.smooth, value: store.lastError)
    }
}

private struct Sidebar: View {
    private let store = LibraryStore.shared
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                DeviceHeader(compact: true)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }
            Section("Library") {
                libraryRow("Recently Added", "clock", .recentlyAdded, tracks: store.tracks)
                libraryRow("Songs", "music.note", .songs, tracks: store.tracks)
                libraryRow("Albums", "square.stack", .albums, tracks: store.tracks)
                libraryRow("Artists", "music.microphone", .artists, tracks: store.tracks)
                libraryRow("Genres", "guitars", .genres, tracks: store.tracks)
            }
            Section("Playlists") {
                ForEach(store.regularPlaylists) { playlist in
                    PlaylistRow(playlist: playlist)
                        .tag(SidebarItem.playlist(playlist.id))
                        .contextMenu { playlistMenu(playlist) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A solid bar so the playlist list scrolls under it instead of overlapping it.
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button("New Playlist", systemImage: "plus") { store.newPlaylistRequest = [] }
                        .buttonStyle(.borderless)
                        .disabled(store.editBlocker != nil)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    private func libraryRow(_ title: String, _ symbol: String, _ item: SidebarItem, tracks: [Track],
                            badge: Int = 0) -> some View {
        Label(title, systemImage: symbol)
            .badge(badge)
            .tag(item)
            .contextMenu {
                Button("Open", systemImage: "arrow.right.circle") { selection = item }
                Button("Add Music…", systemImage: "plus") { store.showAddMusic = true }
                .disabled(store.editBlocker != nil)
                Button("Fix Info for \(title)…", systemImage: "wand.and.sparkles") {
                    store.fixInfoRequest = tracks.map(\.id)
                }
                .disabled(store.editBlocker != nil || tracks.isEmpty)
                Button("New Playlist from \(title)…", systemImage: "text.badge.plus") {
                    store.newPlaylistRequest = tracks.map(\.id)
                }
                .disabled(store.editBlocker != nil || tracks.isEmpty)
            }
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        let blocked = store.editBlocker != nil
        Button("Open", systemImage: "arrow.right.circle") { selection = .playlist(playlist.id) }
        Button("Play Playlist", systemImage: "play.fill") {
            PlayerController.shared.shuffle = false
            PlayerController.shared.play(store.tracks(in: playlist))
        }
        .disabled(playlist.trackIds.isEmpty)
        Button("Shuffle Playlist", systemImage: "shuffle") {
            PlayerController.shared.shuffle = true
            PlayerController.shared.play(store.tracks(in: playlist).shuffled())
        }
        .disabled(playlist.trackIds.isEmpty)
        Divider()
        Button("Add Music to Playlist…", systemImage: "plus") {
            selection = .playlist(playlist.id)
            store.showAddMusic = true
        }
        .disabled(blocked)
        Button("Duplicate", systemImage: "plus.square.on.square") {
            Task { _ = await store.createPlaylist(named: "\(playlist.name) copy", with: playlist.trackIds) }
        }
        .disabled(blocked)
        Divider()
        Button("Rename…", systemImage: "pencil") { store.renameRequest = playlist }
            .disabled(blocked)
        Button("Delete Playlist…", systemImage: "trash", role: .destructive) { store.deleteRequest = playlist }
            .disabled(blocked)
    }
}

/// "iPod Drop" wordmark with the iPod logo, in Apple Music red. Shown beside the
/// window buttons by an AppKit title bar accessory (see `AppDelegate.showLibrary`),
/// outside the split view so it never takes part in the columns' size calculations.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("iPodLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 24)
                .foregroundStyle(.brandGradient)
            HStack(spacing: 0) {
                Text("iPod")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(" Drop")
                    .font(.system(size: 18, weight: .light, design: .rounded))
                    .foregroundStyle(Color.brand)
            }
            .kerning(-0.3)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iPod Drop")
    }
}

/// The library window's dialogs, opened by any right-click menu through the store.
private struct LibraryDialogs: ViewModifier {
    private let store = LibraryStore.shared
    @Binding var section: SidebarItem?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { store.fixInfoRequest != nil },
                                        set: { if !$0 { store.fixInfoRequest = nil } })) {
                FixInfoSheet(trackIDs: store.fixInfoRequest ?? [])
            }
            .sheet(item: Binding(get: { store.renameRequest }, set: { store.renameRequest = $0 })) { playlist in
                NameSheet(title: "Rename Playlist", initial: playlist.name, action: "Rename") { name in
                    Task { await store.renamePlaylist(playlist, to: name) }
                }
            }
            .sheet(isPresented: Binding(get: { store.newPlaylistRequest != nil },
                                        set: { if !$0 { store.newPlaylistRequest = nil } })) {
                let ids = store.newPlaylistRequest ?? []
                NameSheet(title: ids.isEmpty ? "New Playlist" : "New Playlist with \(Format.songs(ids.count))",
                          initial: "", action: "Create") { name in
                    Task {
                        if await store.createPlaylist(named: name, with: ids),
                           let created = store.regularPlaylists.first(where: { $0.name == name }) {
                            section = .playlist(created.id)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete “\(store.deleteRequest?.name ?? "")”?",
                isPresented: Binding(get: { store.deleteRequest != nil }, set: { if !$0 { store.deleteRequest = nil } }),
                presenting: store.deleteRequest
            ) { playlist in
                Button("Delete Playlist", role: .destructive) {
                    if section == .playlist(playlist.id) { section = .songs }
                    Task { await store.deletePlaylist(playlist) }
                }
            } message: { _ in
                Text("The songs stay on your iPod.")
            }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { store.removalRequest != nil }, set: { if !$0 { store.removalRequest = nil } }),
                presenting: store.removalRequest
            ) { ids in
                Button("Remove from iPod", role: .destructive) {
                    Task { await store.removeFromIPod(Set(ids)) }
                }
            } message: { _ in
                Text("They're deleted from the iPod and from every playlist. Files on your Mac aren't affected.")
            }
    }

    private var removalTitle: String {
        let count = store.removalRequest?.count ?? 0
        if count == 1, let id = store.removalRequest?.first, let track = store.tracksByID[id] {
            return "Remove “\(track.displayTitle)” from your iPod?"
        }
        return "Remove \(count) songs from your iPod?"
    }
}

/// A playlist in the sidebar; accepts songs dragged from the table and files from Finder.
private struct PlaylistRow: View {
    private let store = LibraryStore.shared
    let playlist: Playlist
    @State private var isTargeted = false

    var body: some View {
        Label(playlist.name, systemImage: "music.note.list")
            .badge(playlist.trackIds.count)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.brand, lineWidth: isTargeted ? 2 : 0)
                    .padding(-3)
            )
            .onDrop(of: [.fileURL, .plainText], isTargeted: $isTargeted) { providers in
                accept(providers)
                return true
            }
    }

    private func accept(_ providers: [NSItemProvider]) {
        let target = playlist
        Task {
            var urls: [URL] = []
            var strings: [String] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url"),
                   let url = try? await provider.loadFileURL() {
                    urls.append(url)
                } else if let text = try? await provider.loadString() {
                    strings.append(text)
                }
            }
            let ids = TrackDrag.ids(from: strings)
            if !ids.isEmpty { await store.add(ids, to: target) }
            if !urls.isEmpty { store.send(urls, to: .playlist(id: target.id, name: target.name)) }
        }
    }
}

private extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }

    func loadString() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: text) }
            }
        }
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    let action: String
    let commit: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: save)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = initial }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        commit(trimmed)
        dismiss()
    }
}
