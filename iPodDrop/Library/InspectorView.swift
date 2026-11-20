import SwiftUI

/// Song info for the selection. With several songs selected, fields that differ show
/// "Mixed" and are only changed if you type into them.
struct InspectorView: View {
    private let store = LibraryStore.shared
    let trackIDs: Set<Track.ID>

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var saving = false
    @State private var artDropTargeted = false
    /// The field being typed in, for its list of names already on the iPod.
    @FocusState private var focusedField: FieldSuggestions.Field?
    @State private var highlighted: Int?
    /// Hides the list after a name is picked, until the text changes again.
    @State private var pickedText: String?

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
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tracks.count == 1 ? tracks[0].displayTitle : "\(tracks.count) songs")
                            .font(.headline).lineLimit(2)
                        Text(tracks.count == 1 ? tracks[0].displayArtist : Format.longDuration(ms: tracks.reduce(0) { $0 + $1.lengthMs }))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Button("Choose Cover Art…") {
                            CoverArt.choose(for: tracks.map(\.id))
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .lineLimit(1)
                        .disabled(store.editBlocker != nil)
                        .help("Use an image from your Mac, or drop one on the artwork")
                        .padding(.top, 2)
                    }
                }
            }
            Section("Details") {
                textRow("Title", \.title)
                textRow("Artist", \.artist, suggest: .artist)
                textRow("Album", \.album, suggest: .album)
                textRow("Album Artist", \.albumArtist, suggest: .albumArtist)
                textRow("Genre", \.genre, suggest: .genre)
                textRow("Composer", \.composer, suggest: .composer)
                row("Year") {
                    numberField(\.year, width: 56)
                    Spacer(minLength: 0)
                }
                row("Track") {
                    numberField(\.trackNumber)
                    Text("of").foregroundStyle(.secondary)
                    numberField(\.totalTracks)
                    Spacer(minLength: 0)
                }
                row("Disc") {
                    numberField(\.discNumber)
                    Text("of").foregroundStyle(.secondary)
                    numberField(\.totalDiscs)
                    Spacer(minLength: 0)
                }
                row("Rating") {
                    RatingControl(stars: $draft.stars, mixed: draft.stars == nil)
                    Spacer(minLength: 0)
                }
                row("Comment") {
                    TextField("Comment", text: binding(\.comment), prompt: prompt(\.comment, "Add a comment"),
                              axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                }
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
            .background(.bar)  // fields scroll underneath; keep the buttons readable
        }
    }

    /// The cover; drop an image file from Finder on it to use it for the selected songs.
    private var artwork: some View {
        ArtworkView(artworkID: tracks.first { $0.artworkId > 0 }?.artworkId ?? 0, size: 72,
                    cornerRadius: 8, seed: tracks[0].album)
            .overlay {
                if artDropTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.brand, lineWidth: 3)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard store.editBlocker == nil, let url = urls.first(where: CoverArt.isImage) else { return false }
                let ids = tracks.map(\.id)
                Task { await CoverArt.apply(url, to: ids) }
                return true
            } isTargeted: { artDropTargeted = $0 }
            .help("Drop an image here to use it as the cover art")
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

    /// Labels sit in one fixed column, smaller and grey; the values line up after them.
    private static let labelWidth: CGFloat = 96

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private func textRow(_ label: String, _ key: WritableKeyPath<Draft, String?>) -> some View {
        row(label) {
            TextField(label, text: binding(key), prompt: prompt(key, "Add \(label.lowercased())"))
                .labelsHidden()
                .textFieldStyle(.plain)
        }
    }

    /// A text row that lists names already on the iPod under it while you type.
    /// Click a name, or use the arrow keys and Return, to fill it in.
    private func textRow(_ label: String, _ key: WritableKeyPath<Draft, String?>,
                         suggest: FieldSuggestions.Field) -> some View {
        let text = draft[keyPath: key] ?? ""
        let names = focusedField == suggest && draft[keyPath: key] != original[keyPath: key] && text != pickedText
            ? store.suggestions.matches(suggest, for: text, limit: 5) : []
        let pick = { (name: String) in
            draft[keyPath: key] = name
            pickedText = name
            highlighted = nil
        }
        return row(label) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(label, text: binding(key), prompt: prompt(key, "Add \(label.lowercased())"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: suggest)
                    .onChange(of: text) { highlighted = nil }
                    .onKeyPress(.downArrow) {
                        guard !names.isEmpty else { return .ignored }
                        highlighted = min((highlighted ?? -1) + 1, names.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !names.isEmpty, let index = highlighted else { return .ignored }
                        highlighted = index > 0 ? index - 1 : nil
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !names.isEmpty else { return .ignored }
                        pickedText = text
                        return .handled
                    }
                    .onSubmit {
                        if let index = highlighted, names.indices.contains(index) { pick(names[index]) }
                    }
                if !names.isEmpty {
                    SuggestionList(names: names, icon: suggest.icon, highlighted: $highlighted, pick: pick)
                }
            }
        }
    }

    private func numberField(_ key: WritableKeyPath<Draft, Int?>, width: CGFloat = 44) -> some View {
        TextField("", text: Binding(
            get: { draft[keyPath: key].map { $0 > 0 ? String($0) : "" } ?? "" },
            set: { draft[keyPath: key] = Int($0.filter(\.isNumber)) ?? 0 }
        ), prompt: Text(draft[keyPath: key] == nil ? "Mixed" : "–"))
        .labelsHidden()
        .textFieldStyle(.plain)
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
    }

    private func binding(_ key: WritableKeyPath<Draft, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 })
    }

    /// "Mixed" when the selected songs differ, otherwise a hint for an empty field.
    private func prompt(_ key: WritableKeyPath<Draft, String?>, _ empty: String) -> Text {
        Text(draft[keyPath: key] == nil ? "Mixed" : empty)
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
                        .foregroundStyle(value <= (stars ?? 0) ? Color.brand : Color.secondary.opacity(mixed ? 0.3 : 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
            }
        }
    }
}

/// Names already on the iPod, shown as a small menu under the field being typed in.
private struct SuggestionList: View {
    let names: [String]
    let icon: String
    @Binding var highlighted: Int?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("On your iPod")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let on = index == highlighted
                Button { pick(name) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.caption)
                            .frame(width: 14)
                            .foregroundStyle(on ? .white : .secondary)
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(on ? .white : .primary)
                        Spacer(minLength: 0)
                        if on {
                            Image(systemName: "return")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(on ? Color.brand : .clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(5)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

extension FieldSuggestions.Field {
    var icon: String {
        switch self {
        case .artist, .albumArtist: "music.mic"
        case .album: "square.stack"
        case .genre: "guitars"
        case .composer: "music.quarternote.3"
        }
    }
}
