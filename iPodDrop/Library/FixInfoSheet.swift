import SwiftUI

/// Look songs up in Apple's iTunes catalogue and apply the info you approve:
/// title, artist, album, genre, year, track number and cover art.
struct FixInfoSheet: View {
    private let store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [String]

    @State private var rows: [Row] = []
    @State private var lookup: Task<Void, Never>?
    @State private var applying = false
    @State private var applyStatus = ""
    @State private var fields = Fields()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fieldToggles
            List {
                ForEach($rows) { $row in
                    FixInfoRow(row: $row)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 320)
            footer
        }
        .padding(20)
        .frame(width: 860, height: 640)
        .onAppear(perform: start)
        .onDisappear { lookup?.cancel() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fix Info").font(.title2.weight(.semibold))
                Text("Matched against Apple's iTunes catalogue by title and song length. Review before applying.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if searching {
                ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                    .frame(width: 140)
                Text("\(done) of \(rows.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var fieldToggles: some View {
        HStack(spacing: 14) {
            Text("Change:").foregroundStyle(.secondary)
            Toggle("Title", isOn: $fields.title)
            Toggle("Artist", isOn: $fields.artist)
            Toggle("Album", isOn: $fields.album)
            Toggle("Genre", isOn: $fields.genre)
            Toggle("Year", isOn: $fields.year)
            Toggle("Track #", isOn: $fields.trackNumber)
            Toggle("Cover Art", isOn: $fields.artwork)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            let counts = rows.reduce(into: (high: 0, other: 0, none: 0)) { c, row in
                switch row.selected?.confidence {
                case .high: c.high += 1
                case .some: c.other += 1
                case nil: if row.state == .done { c.none += 1 }
                }
            }
            Text("\(counts.high) good · \(counts.other) to check · \(counts.none) not found")
                .font(.caption).foregroundStyle(.secondary)
            if !applyStatus.isEmpty {
                Text(applyStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(applying ? "Applying…" : "Apply to \(chosen.count) Song\(chosen.count == 1 ? "" : "s")", action: apply)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || applying || store.editBlocker != nil)
        }
    }

    // MARK: State

    private var searching: Bool { rows.contains { $0.state == .waiting || $0.state == .searching } }
    private var done: Int { rows.filter { $0.state != .waiting && $0.state != .searching }.count }
    private var chosen: [Row] { rows.filter { $0.include && $0.selected != nil } }

    private func start() {
        rows = trackIDs.compactMap { store.tracksByID[$0] }.map { Row(track: $0) }
        lookup = Task { await runLookups() }
    }

    private func runLookups() async {
        for index in rows.indices {
            if Task.isCancelled { return }
            await search(index)
        }
    }

    fileprivate func search(_ index: Int, query: String? = nil) async {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .searching
        do {
            let matches = try await ITunesLookup.shared.matches(for: rows[index].track, query: query)
            guard rows.indices.contains(index) else { return }
            rows[index].matches = Array(matches.prefix(6))
            rows[index].selection = matches.first.map(\.song.trackId)
            // Only pre-tick confident matches; you decide on the rest.
            rows[index].include = matches.first?.confidence == .high
            rows[index].state = .done
        } catch is CancellationError {
            return
        } catch {
            guard rows.indices.contains(index) else { return }
            rows[index].state = .failed(error.localizedDescription)
        }
    }

    // MARK: Apply

    private func apply() {
        lookup?.cancel()
        applying = true
        let rowsToApply = chosen
        let fields = fields
        Task {
            var items: [[String: Any]] = []
            let artworkDir = FileManager.default.temporaryDirectory
                .appending(path: "iPodDrop-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            for (n, row) in rowsToApply.enumerated() {
                guard let song = row.selected?.song else { continue }
                var item: [String: Any] = ["id": row.track.id, "fields": fields.changes(from: song, to: row.track)]
                if fields.artwork, let url = song.artworkURL {
                    applyStatus = "Downloading cover art \(n + 1) of \(rowsToApply.count)…"
                    if let (data, _) = try? await URLSession.shared.data(from: url) {
                        let file = artworkDir.appending(path: "\(song.trackId).jpg")
                        if (try? data.write(to: file)) != nil { item["artworkPath"] = file.path }
                    }
                }
                if (item["fields"] as? [String: Any])?.isEmpty == false || item["artworkPath"] != nil {
                    items.append(item)
                }
            }
            applyStatus = "Saving to the iPod…"
            let ok = items.isEmpty ? true : await store.editMany(items)
            try? FileManager.default.removeItem(at: artworkDir)
            applying = false
            applyStatus = ""
            if ok { dismiss() }
        }
    }

    struct Fields {
        var title = true, artist = true, album = true, genre = true, year = true, trackNumber = true, artwork = true

        /// Engine field values from the match that differ from the song now.
        func changes(from song: ITunesSong, to track: Track) -> [String: Any] {
            var out: [String: Any] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                if let new, !new.isEmpty, new != old { out[key] = new }
            }
            func put(_ key: String, _ new: Int?, _ old: Int) {
                if let new, new > 0, new != old { out[key] = new }
            }
            if title { put("title", song.trackName, track.title) }
            if artist { put("artist", song.artistName, track.artist) }
            if album {
                put("album", song.collectionName, track.album)
                put("albumArtist", song.collectionArtistName ?? song.artistName, track.albumArtist)
            }
            if genre { put("genre", song.primaryGenreName, track.genre) }
            if year { put("year", song.year, track.year) }
            if trackNumber {
                put("trackNumber", song.trackNumber, track.trackNumber)
                put("totalTracks", song.trackCount, track.totalTracks)
                put("discNumber", song.discNumber, track.discNumber)
                put("totalDiscs", song.discCount, track.totalDiscs)
            }
            return out
        }
    }

    struct Row: Identifiable {
        enum State: Equatable { case waiting, searching, done, failed(String) }

        var id: String { track.id }
        let track: Track
        var state: State = .waiting
        var matches: [ITunesMatch] = []
        var selection: Int?
        var include = false

        var selected: ITunesMatch? { matches.first { $0.song.trackId == selection } }
    }
}

/// One song: what it says now → what Apple suggests, with alternatives.
private struct FixInfoRow: View {
    @Binding var row: FixInfoSheet.Row
    @State private var searchingCustom = false
    @State private var customQuery = ""

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $row.include)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(row.selected == nil)
            HStack(spacing: 8) {
                ArtworkView(artworkID: row.track.artworkId, size: 40, cornerRadius: 5, seed: row.track.album)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.track.displayTitle).lineLimit(1)
                    Text("\(row.track.displayArtist) · \(Format.duration(ms: row.track.lengthMs))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 300, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            suggestion
            Spacer(minLength: 0)
            badge
            menu
        }
        .padding(.vertical, 3)
        .popover(isPresented: $searchingCustom) {
            HStack {
                TextField("Search iTunes", text: $customQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(runCustom)
                Button("Search", action: runCustom).disabled(customQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var suggestion: some View {
        switch row.state {
        case .waiting:
            Text("Waiting…").font(.callout).foregroundStyle(.tertiary)
        case .searching:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.orange).lineLimit(2)
        case .done:
            if let match = row.selected {
                let song = match.song
                HStack(spacing: 8) {
                    AsyncImage(url: song.artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.trackName).lineLimit(1)
                        Text([song.artistName, song.collectionName, song.year.map(String.init),
                              song.trackTimeMillis.map { Format.duration(ms: $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text("No match found. Try your own search.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let match = row.selected {
            switch match.confidence {
            case .high: Label("Good match", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .medium: Label("Check", systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
            case .low: Label("Unlikely", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var menu: some View {
        Menu {
            if !row.matches.isEmpty {
                Section("Matches") {
                    ForEach(row.matches, id: \.song.trackId) { match in
                        let song = match.song
                        Button {
                            row.selection = song.trackId
                            row.include = true
                        } label: {
                            Text("\(song.trackName) — \(song.artistName) (\(song.trackTimeMillis.map { Format.duration(ms: $0) } ?? "?"))")
                            if row.selection == song.trackId { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Button("Search Differently…") {
                customQuery = ITunesLookup.queries(for: row.track).last ?? row.track.title
                searchingCustom = true
            }
            Button("Don't Change This Song") { row.include = false }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.callout)
    }

    private func runCustom() {
        let query = customQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searchingCustom = false
        row.state = .searching
        let track = row.track
        Task {
            do {
                let matches = try await ITunesLookup.shared.matches(for: track, query: query)
                row.matches = Array(matches.prefix(6))
                row.selection = matches.first?.song.trackId
                row.include = matches.first != nil
                row.state = .done
            } catch {
                row.state = .failed(error.localizedDescription)
            }
        }
    }
}
