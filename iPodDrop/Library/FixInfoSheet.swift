import SwiftUI

/// Look songs up in iTunes, Deezer and MusicBrainz and apply the info you approve:
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
        .tint(.brand)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fix Info").font(.title2.weight(.semibold))
                Text("Matched by title and song length in iTunes, then Deezer and MusicBrainz when iTunes has no good match. Review before applying.")
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
                        Text("Replace details with the match's").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    Text(fields.onlyEmpty
                         ? "Titles, artists and other details you already have stay as they are; empty ones are filled in."
                         : "Every ticked detail is replaced with the match's version when one is found.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    fieldToggles
                }
                .padding(8)
            }
            Label(Self.estimate(songs: count), systemImage: "clock")
                .font(.callout).foregroundStyle(.secondary)
            Text("Catalogues limit how fast songs can be looked up. Songs from the same album are matched together, so albums go faster. You can stop at any time and apply what's been found.")
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

    /// Songs from one album are looked up one after another, so the first match can
    /// fetch the album's track list for the rest. Different albums run side by side,
    /// so one song's wait for a catalogue overlaps another's.
    private func runLookups(albumSizes: [String: Int]) async {
        var groups: [[Int]] = []
        var groupForKey: [String: Int] = [:]
        for index in rows.indices {
            let key = ITunesLookup.albumKey(rows[index].track)
            if !key.isEmpty, let group = groupForKey[key] {
                groups[group].append(index)
            } else {
                if !key.isEmpty { groupForKey[key] = groups.count }
                groups.append([index])
            }
        }
        let queue = AlbumQueue(groups)
        let workers = (0..<Self.parallelAlbums).map { _ in
            Task { @MainActor in
                while let indices = queue.next() {
                    for index in indices {
                        if Task.isCancelled { return }
                        await search(index, albumSize: albumSizes[ITunesLookup.albumKey(rows[index].track)] ?? 1)
                    }
                }
            }
        }
        await withTaskCancellationHandler {
            for worker in workers { await worker.value }
        } onCancel: {
            for worker in workers { worker.cancel() }
        }
    }

    /// Albums waiting to be looked up, handed out one at a time.
    @MainActor
    private final class AlbumQueue {
        private var groups: [[Int]]
        init(_ groups: [[Int]]) { self.groups = groups.reversed() }
        func next() -> [Int]? { groups.popLast() }
    }

    /// How many albums are looked up at once.
    private static let parallelAlbums = 3

    fileprivate func search(_ index: Int, query: String? = nil, albumSize: Int = 1) async {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .searching
        do {
            let matches = try await SongLookup.matches(for: rows[index].track, query: query, albumSize: albumSize)
            guard rows.indices.contains(index) else { return }
            rows[index].matches = Array(matches.prefix(8))
            ThumbnailCache.shared.prefetch(rows[index].matches)
            rows[index].selection = matches.first.map(\.song.id)
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

            // Full details for the picked songs (Deezer/MusicBrainz track numbers and
            // genre), several at a time; each catalogue keeps to its own pace.
            var songs: [String: CatalogSong] = [:]
            let picked = rowsToApply.compactMap { row in row.selected.map { (row.track.id, $0.song) } }
            let urls = Set(rowsToApply.compactMap { row in
                fields.wantsArtwork(for: row.track) ? row.selected?.song.artworkURL : nil
            })
            let steps = Double(max(picked.count + urls.count, 1))
            var finished = 0.0
            await withTaskGroup(of: (String, CatalogSong).self) { group in
                for (id, song) in picked { group.addTask { (id, await SongLookup.details(for: song)) } }
                for await (id, song) in group {
                    songs[id] = song
                    finished += 1
                    downloadFraction = finished / steps
                }
            }

            // Each cover once (songs on one album share it), six downloads at a time.
            var covers: [URL: String] = [:]
            let wanted = Set(rowsToApply.compactMap { row in
                fields.wantsArtwork(for: row.track) ? songs[row.track.id]?.artworkURL : nil
            })
            await withTaskGroup(of: (URL, String?).self) { group in
                var running = 0
                func collect(_ result: (URL, String?)?) {
                    guard let (url, path) = result else { return }
                    covers[url] = path
                    finished += 1
                    downloadFraction = min(1, finished / steps)
                }
                for (n, url) in wanted.enumerated() {
                    if running >= 6 {
                        collect(await group.next() ?? nil)
                        running -= 1
                    }
                    let file = artworkDir.appending(path: "cover-\(n).jpg")
                    group.addTask {
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, NSImage(data: data) != nil,
                              (try? data.write(to: file)) != nil else { return (url, nil) }
                        return (url, file.path)
                    }
                    running += 1
                }
                for await result in group { collect(result) }
            }

            for row in rowsToApply {
                guard let song = songs[row.track.id] else { continue }
                var item: [String: Any] = ["id": row.track.id, "fields": fields.changes(from: song, to: row.track)]
                if fields.wantsArtwork(for: row.track), let url = song.artworkURL { item["artworkPath"] = covers[url] }
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
        /// Only fill details that are empty now; never overwrite what's there.
        var onlyEmpty = false

        func wantsArtwork(for track: Track) -> Bool {
            artwork && (!onlyEmpty || track.artworkId == 0)
        }

        /// Engine field values from the match that differ from the song now.
        func changes(from song: CatalogSong, to track: Track) -> [String: Any] {
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
        var matches: [CatalogMatch] = []
        var selection: String?
        var include = false

        var selected: CatalogMatch? { matches.first { $0.song.id == selection } }
    }
}

/// One song: what it says now → the suggested match. Click the match (or the
/// button beside it) to see every match with its cover and pick another.
private struct FixInfoRow: View {
    @Binding var row: FixInfoSheet.Row
    @State private var picking = false

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
                .contentShape(.rect)
                .onTapGesture { if canPick { picking = true } }
            Spacer(minLength: 0)
            badge
            Button {
                picking = true
            } label: {
                Label(row.matches.count > 1 ? "\(row.matches.count) Matches" : "Choose",
                      systemImage: "square.grid.2x2")
                    .font(.callout)
            }
            .controlSize(.small)
            .disabled(!canPick)
            .help("See every match with its cover art, or search differently")
            .popover(isPresented: $picking, arrowEdge: .trailing) {
                MatchPicker(row: $row) { picking = false }
            }
        }
        .padding(.vertical, 3)
    }

    private var canPick: Bool {
        switch row.state {
        case .done, .failed: true
        default: false
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
                    RemoteThumbnail(url: song.thumbnailURL, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.trackName).lineLimit(1)
                        Text([song.artistName, song.collectionName, song.year.map(String.init),
                              song.trackTimeMillis.map { Format.duration(ms: $0) }, song.source.rawValue]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help("Click to see other matches")
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
}

/// Every match for one song as a card with its cover, so the right album (and its
/// art) is easy to spot. Also searches with your own words.
private struct MatchPicker: View {
    @Binding var row: FixInfoSheet.Row
    let close: () -> Void
    @State private var query = ""
    @State private var searching = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a Match").font(.headline)
                Text("For “\(row.track.displayTitle)” · \(Format.duration(ms: row.track.lengthMs))")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if searching {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if row.matches.isEmpty {
                Text("No matches. Try searching with the song's name and the artist or film.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(row.matches, id: \.song.id) { match in
                            card(match)
                        }
                    }
                    .padding(2)
                }
                .frame(height: min(470, CGFloat((row.matches.count + 2) / 3) * 240))
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Search iTunes, Deezer and MusicBrainz", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                Spacer(minLength: 12)
                Button("Don't Change") {
                    row.include = false
                    close()
                }
                .help("Leave this song as it is")
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { query = ITunesLookup.queries(for: row.track).last ?? row.track.title }
    }

    private func card(_ match: CatalogMatch) -> some View {
        let song = match.song
        let isSelected = row.selection == song.id
        return Button {
            row.selection = song.id
            row.include = true
            close()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteThumbnail(url: song.thumbnailURL, size: 150)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.brand)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.trackName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text([song.collectionName, song.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        lengthLabel(song)
                        Text(song.source.rawValue)
                        Spacer(minLength: 0)
                        Circle().fill(color(match.confidence)).frame(width: 7, height: 7)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(isSelected ? Color.brand.opacity(0.14) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(song.trackName) — \(song.artistName)\n\(song.collectionName ?? "")")
    }

    /// The match's length, green when it's within 2 seconds of your song.
    private func lengthLabel(_ song: CatalogSong) -> some View {
        let ms = song.trackTimeMillis
        let close = ms.map { abs($0 - row.track.lengthMs) <= 2000 } ?? false
        return Text(ms.map { Format.duration(ms: $0) } ?? "?:??")
            .monospacedDigit()
            .foregroundStyle(close ? Color.green : .secondary)
    }

    private func color(_ confidence: CatalogMatch.Confidence) -> Color {
        switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        let track = row.track
        Task {
            do {
                let matches = try await SongLookup.matches(for: track, query: text)
                row.matches = Array(matches.prefix(8))
                ThumbnailCache.shared.prefetch(row.matches)
                row.selection = matches.first?.song.id
                row.include = matches.first != nil
                row.state = .done
            } catch {
                row.state = .failed(error.localizedDescription)
            }
            searching = false
        }
    }
}

/// Catalogue cover thumbnails, cached for the session so pickers open instantly.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
            return NSImage(data: data)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Start loading the covers of these matches in the background.
    func prefetch(_ matches: [CatalogMatch]) {
        for url in Set(matches.compactMap(\.song.thumbnailURL)) {
            Task { _ = await image(for: url) }
        }
    }
}

/// A catalogue cover, loaded through `ThumbnailCache`.
struct RemoteThumbnail: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").foregroundStyle(.tertiary).font(.system(size: size * 0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: max(5, size * 0.05), style: .continuous))
        .task(id: url) {
            image = nil
            if let url { image = await ThumbnailCache.shared.image(for: url) }
        }
    }
}
