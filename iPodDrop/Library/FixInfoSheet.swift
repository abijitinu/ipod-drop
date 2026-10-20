import SwiftUI

/// Look songs up in Apple's iTunes catalogue and apply the info you approve:
/// title, artist, album, genre, year, track and disc numbers, and cover art.
/// Works for a few songs or the whole library; big runs start with a short setup.
struct FixInfoSheet: View {
    private let store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [String]

    @State private var rows: [Row] = []
    @State private var lookup: Task<Void, Never>?
    @State private var started = false
    @State private var stopped = false
    @State private var startedAt = Date()
    @State private var applying = false
    @State private var applyStatus = ""
    /// Cover art downloads done, as 0...1 (the first part of applying).
    @State private var downloadFraction = 0.0
    @State private var fields = Fields()
    /// Leave out songs that already have every detail (setup step).
    @State private var skipComplete = true
    /// Fixed when the sheet opens, from the room in the library window.
    @State private var size = SheetSize.fitting(CGSize(width: 900, height: 640),
                                                minimum: CGSize(width: 700, height: 380))

    /// From this many songs on, the sheet asks how to run before it starts searching.
    static let setupThreshold = 10

    private var tracks: [Track] { trackIDs.compactMap { store.tracksByID[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if started {
                fieldToggles
                List {
                    ForEach($rows) { $row in
                        FixInfoRow(row: $row)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
                footer
            } else {
                setup
            }
        }
        .padding(20)
        .frame(width: size.width, height: size.height)
        .onAppear {
            let all = tracks
            fields.onlyEmpty = all.count >= Self.setupThreshold  // whole-library runs fill gaps by default
            if all.count < Self.setupThreshold { begin() }
        }
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
            if started, searching {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                            .frame(width: 160)
                        Text("\(done) of \(rows.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { stop() }
                            .controlSize(.small)
                            .help("Stop searching. Songs found so far can still be applied.")
                    }
                    if let remaining = timeRemaining {
                        Text(remaining).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Before a big run: which songs, what to change, and roughly how long it takes.
    private var setup: some View {
        let all = tracks
        let incomplete = all.filter { !$0.hasCompleteInfo }
        let count = skipComplete ? incomplete.count : all.count
        return VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Songs", selection: $skipComplete) {
                        Text("Only songs missing details (\(incomplete.count))").tag(true)
                        Text("All \(all.count) songs").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    Divider()
                    Picker("Update", selection: $fields.onlyEmpty) {
                        Text("Only fill in missing details").tag(true)
                        Text("Replace details with Apple's").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    Text(fields.onlyEmpty
                         ? "Titles, artists and other details you already have stay as they are; empty ones are filled in."
                         : "Every ticked detail is replaced with Apple's version when a match is found.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    fieldToggles
                }
                .padding(8)
            }
            Label(Self.estimate(songs: count), systemImage: "clock")
                .font(.callout).foregroundStyle(.secondary)
            Text("Apple limits how fast songs can be looked up. Songs from the same album are matched together, so albums go faster. You can stop at any time and apply what's been found.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Look Up \(count) Song\(count == 1 ? "" : "s")") { begin() }
                    .glassProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
    }

    private var fieldToggles: some View {
        HStack(spacing: 14) {
            Text(fields.onlyEmpty ? "Fill in:" : "Change:").foregroundStyle(.secondary)
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
            if applying {
                ProgressView(value: applyFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("\(applyStatus) \(Int((applyFraction * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Text("\(counts.high) good · \(counts.other) to check · \(counts.none) not found"
                     + (stopped && waiting > 0 ? " · \(waiting) not searched" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(applying ? "Applying…" : "Apply to \(chosen.count) Song\(chosen.count == 1 ? "" : "s")", action: apply)
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || applying || store.editBlocker != nil)
        }
    }

    // MARK: State

    private var searching: Bool { !stopped && rows.contains { $0.state == .waiting || $0.state == .searching } }
    private var done: Int { rows.filter { $0.state != .waiting && $0.state != .searching }.count }
    private var waiting: Int { rows.filter { $0.state == .waiting }.count }
    private var chosen: [Row] { rows.filter { $0.include && $0.selected != nil } }

    /// Downloading cover art is the first 40%, writing to the iPod the rest.
    private var applyFraction: Double {
        guard let activity = store.activity, activity.phase == .saving else { return downloadFraction * 0.4 }
        return 0.4 + 0.6 * (activity.fraction ?? 0)
    }

    /// "About 12 min left", from the pace so far (needs a few songs to be meaningful).
    private var timeRemaining: String? {
        let finished = done
        guard finished >= 3, rows.count > finished else { return nil }
        let perSong = Date().timeIntervalSince(startedAt) / Double(finished)
        return "About " + Self.duration(perSong * Double(rows.count - finished)) + " left"
    }

    /// Up-front guess: one or two searches per song, fewer when albums match together.
    static func estimate(songs: Int) -> String {
        songs == 0 ? "Every song already has its details." : "Takes up to " + duration(Double(songs) * 4.5)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "about a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        return "about \(minutes / 60) h \(minutes % 60) min"
    }

    private func begin() {
        let chosenTracks = tracks.count >= Self.setupThreshold && skipComplete
            ? tracks.filter { !$0.hasCompleteInfo } : tracks
        rows = chosenTracks.map { Row(track: $0) }
        started = true
        stopped = false
        startedAt = Date()
        // How many of these songs share each album, so the lookup knows when
        // fetching a whole album's track list saves searches.
        var albumSizes: [String: Int] = [:]
        for track in chosenTracks { albumSizes[ITunesLookup.albumKey(track), default: 0] += 1 }
        lookup = Task { await runLookups(albumSizes: albumSizes) }
    }

    private func stop() {
        stopped = true
        lookup?.cancel()
        for index in rows.indices where rows[index].state == .searching { rows[index].state = .waiting }
    }

    private func runLookups(albumSizes: [String: Int]) async {
        for index in rows.indices {
            if Task.isCancelled { return }
            await search(index, albumSize: albumSizes[ITunesLookup.albumKey(rows[index].track)] ?? 1)
        }
    }

    fileprivate func search(_ index: Int, query: String? = nil, albumSize: Int = 1) async {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .searching
        do {
            let matches = try await ITunesLookup.shared.matches(for: rows[index].track, query: query, albumSize: albumSize)
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
        stop()
        applying = true
        downloadFraction = 0
        applyStatus = fields.artwork ? "Getting cover art…" : "Preparing…"
        let rowsToApply = chosen
        let fields = fields
        Task {
            var items: [[String: Any]] = []
            let artworkDir = FileManager.default.temporaryDirectory
                .appending(path: "iPodDrop-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            var covers: [URL: String] = [:]  // songs on one album share one download
            for (n, row) in rowsToApply.enumerated() {
                guard let song = row.selected?.song else { continue }
                var item: [String: Any] = ["id": row.track.id, "fields": fields.changes(from: song, to: row.track)]
                if fields.wantsArtwork(for: row.track), let url = song.artworkURL {
                    if covers[url] == nil, let (data, _) = try? await URLSession.shared.data(from: url) {
                        let file = artworkDir.appending(path: "\(song.trackId).jpg")
                        if (try? data.write(to: file)) != nil { covers[url] = file.path }
                    }
                    item["artworkPath"] = covers[url]
                }
                if (item["fields"] as? [String: Any])?.isEmpty == false || item["artworkPath"] != nil {
                    items.append(item)
                }
                downloadFraction = Double(n + 1) / Double(rowsToApply.count)
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
        /// Only fill details that are empty now; never overwrite what's there.
        var onlyEmpty = false

        func wantsArtwork(for track: Track) -> Bool {
            artwork && (!onlyEmpty || track.artworkId == 0)
        }

        /// Engine field values from the match that differ from the song now.
        func changes(from song: ITunesSong, to track: Track) -> [String: Any] {
            var out: [String: Any] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                guard let new, !new.isEmpty, new != old else { return }
                if onlyEmpty, !Track.isMissing(old) { return }
                out[key] = new
            }
            func put(_ key: String, _ new: Int?, _ old: Int) {
                guard let new, new > 0, new != old else { return }
                if onlyEmpty, old > 0 { return }
                out[key] = new
            }
            if title { put("title", song.trackName, track.title) }
            if artist { put("artist", song.artistName, track.artist) }
            if album {
                put("album", song.collectionName, track.album)
                put("albumArtist", song.collectionArtistName ?? song.artistName, track.albumArtist)
                if song.isCompilation, !track.compilation, !onlyEmpty || track.albumArtist.isEmpty {
                    out["compilation"] = true
                }
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
