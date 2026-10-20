import SwiftUI

/// Song info for the selection. With several songs selected, fields that differ show
/// "Mixed" and are only changed if you type into them.
struct InspectorView: View {
    private let store = LibraryStore.shared
    let trackIDs: Set<Track.ID>

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var saving = false

    private var tracks: [Track] { trackIDs.compactMap { store.tracksByID[$0] } }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "music.note",
                                       description: Text("Select songs to see and edit their info."))
            } else {
                form
            }
        }
        .onChange(of: trackIDs, initial: true) { load() }
        .onChange(of: store.tracks) { if !saving { load() } }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ArtworkView(artworkID: tracks.first { $0.artworkId > 0 }?.artworkId ?? 0, size: 72,
                                cornerRadius: 8, seed: tracks[0].album)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tracks.count == 1 ? tracks[0].displayTitle : "\(tracks.count) songs")
                            .font(.headline).lineLimit(2)
                        Text(tracks.count == 1 ? tracks[0].displayArtist : Format.longDuration(ms: tracks.reduce(0) { $0 + $1.lengthMs }))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Section("Details") {
                field("Title", \.title)
                field("Artist", \.artist)
                field("Album", \.album)
                field("Album Artist", \.albumArtist)
                field("Genre", \.genre)
                field("Composer", \.composer)
                HStack {
                    field("Year", \.year)
                    field("Track", \.trackNumber)
                    field("of", \.totalTracks)
                }
                HStack {
                    field("Disc", \.discNumber)
                    field("of", \.totalDiscs)
                }
                LabeledContent("Rating") { RatingControl(stars: $draft.stars, mixed: draft.stars == nil) }
                TextField("Comment", text: binding(\.comment), prompt: prompt(\.comment), axis: .vertical)
                    .lineLimit(2...4)
            }
            if tracks.count == 1 { fileSection(tracks[0]) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Revert") { draft = original }
                    .disabled(draft == original)
                Button("Fix Info…", systemImage: "wand.and.sparkles") { store.fixInfoRequest = tracks.map(\.id) }
                    .disabled(store.editBlocker != nil)
                    .help("Look these songs up in the iTunes catalogue")
                Spacer()
                Button(saving ? "Saving…" : "Save to iPod", action: save)
                    .glassProminentButtonStyle()
                    .keyboardShortcut("s")
                    .disabled(draft == original || saving || store.editBlocker != nil)
            }
            .padding(14)
        }
    }

    private func fileSection(_ track: Track) -> some View {
        Section("File") {
            LabeledContent("Kind", value: track.fileFormat)
            LabeledContent("Duration", value: Format.duration(ms: track.lengthMs))
            LabeledContent("Size", value: Format.bytes(Int64(track.sizeBytes)))
            if track.bitrateKbps > 0 { LabeledContent("Bit Rate", value: "\(track.bitrateKbps) kbps") }
            if track.sampleRateHz > 0 {
                LabeledContent("Sample Rate", value: "\((Double(track.sampleRateHz) / 1000).formatted()) kHz")
            }
            LabeledContent("Plays", value: "\(track.playCount)")
            if track.dateAdded > 0 { LabeledContent("Added", value: Format.date(track.dateAdded)) }
            if track.lastPlayed > 0 { LabeledContent("Last Played", value: Format.date(track.lastPlayed)) }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Fields

    private func field(_ label: String, _ key: WritableKeyPath<Draft, String?>) -> some View {
        TextField(label, text: binding(key), prompt: prompt(key))
    }

    private func field(_ label: String, _ key: WritableKeyPath<Draft, Int?>) -> some View {
        TextField(label, text: Binding(
            get: { draft[keyPath: key].map { $0 > 0 ? String($0) : "" } ?? "" },
            set: { draft[keyPath: key] = Int($0.filter(\.isNumber)) ?? 0 }
        ), prompt: Text(draft[keyPath: key] == nil ? "Mixed" : ""))
        .monospacedDigit()
    }

    private func binding(_ key: WritableKeyPath<Draft, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 })
    }

    private func prompt(_ key: WritableKeyPath<Draft, String?>) -> Text? {
        draft[keyPath: key] == nil ? Text("Mixed") : nil
    }

    // MARK: Load and save

    private func load() {
        let value = Draft(tracks)
        draft = value
        original = value
    }

    private func save() {
        let fields = draft.changes(from: original)
        let ids = tracks.map(\.id)
        saving = true
        Task {
            if await store.edit(ids, fields: fields) { original = draft }
            saving = false
        }
    }

    /// Editable fields; nil means the selected songs disagree.
    struct Draft: Equatable {
        var title, artist, album, albumArtist, genre, composer, comment: String?
        var year, trackNumber, totalTracks, discNumber, totalDiscs: Int?
        var stars: Int?

        init() {}

        init(_ tracks: [Track]) {
            func common<T: Equatable>(_ value: (Track) -> T) -> T? {
                guard let first = tracks.first.map(value) else { return nil }
                return tracks.allSatisfy { value($0) == first } ? first : nil
            }
            title = common(\.title); artist = common(\.artist); album = common(\.album)
            albumArtist = common(\.albumArtist); genre = common(\.genre)
            composer = common(\.composer); comment = common(\.comment)
            year = common(\.year); trackNumber = common(\.trackNumber); totalTracks = common(\.totalTracks)
            discNumber = common(\.discNumber); totalDiscs = common(\.totalDiscs)
            stars = common(\.stars)
        }

        /// Engine field names and values for everything the user changed.
        func changes(from old: Draft) -> [String: Any] {
            var out: [String: Any] = [:]
            func put<T: Equatable>(_ name: String, _ key: KeyPath<Draft, T?>) {
                if let value = self[keyPath: key], value != old[keyPath: key] { out[name] = value }
            }
            put("title", \.title); put("artist", \.artist); put("album", \.album)
            put("albumArtist", \.albumArtist); put("genre", \.genre)
            put("composer", \.composer); put("comment", \.comment)
            put("year", \.year); put("trackNumber", \.trackNumber); put("totalTracks", \.totalTracks)
            put("discNumber", \.discNumber); put("totalDiscs", \.totalDiscs)
            if let stars, stars != old.stars { out["rating"] = stars * 20 }
            return out
        }
    }
}

private struct RatingControl: View {
    @Binding var stars: Int?
    var mixed: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    stars = (stars == value) ? 0 : value
                } label: {
                    Image(systemName: value <= (stars ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= (stars ?? 0) ? Color.accentColor : Color.secondary.opacity(mixed ? 0.3 : 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
            }
        }
    }
}
