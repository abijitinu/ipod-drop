import Foundation

/// One song as Apple's iTunes Search API returns it.
nonisolated private struct ITunesSong: Decodable, Sendable {
    let trackId: Int
    let collectionId: Int?
    let trackName: String
    let artistName: String
    let collectionName: String?
    let collectionArtistName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    let trackTimeMillis: Int?
    let artworkUrl100: String?

    var catalog: CatalogSong {
        CatalogSong(
            id: "itunes:\(trackId)", source: .itunes, trackName: trackName, artistName: artistName,
            collectionName: collectionName, collectionArtistName: collectionArtistName,
            primaryGenreName: primaryGenreName, year: releaseDate.flatMap { Int($0.prefix(4)) },
            trackNumber: trackNumber, trackCount: trackCount, discNumber: discNumber, discCount: discCount,
            trackTimeMillis: trackTimeMillis,
            // Apple serves any size by rewriting the URL; 600×600 suits the iPod and the app.
            artworkURL: artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
            isSingle: collectionName?.hasSuffix("- Single") ?? false,
            isCompilation: collectionArtistName?.caseInsensitiveCompare("Various Artists") == .orderedSame)
    }
}

/// Looks songs up in the iTunes catalogue. Apple allows roughly 20 requests a
/// minute, so requests are spaced out; a 403/429 pauses and retries once.
actor ITunesLookup {
    static let shared = ITunesLookup()

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 3.1
    private let country = (Locale.current.region?.identifier ?? "US").lowercased()

    /// Track lists of albums already matched, by Apple's album id.
    private var albums: [Int: [CatalogSong]] = [:]
    /// Which Apple album each library album turned out to be.
    private var albumForKey: [String: Int] = [:]

    /// Best matches for a track, best first (empty when nothing plausible).
    /// `albumSize` is how many of the songs being looked up share this track's album:
    /// once one of them matches, the album's whole track list is fetched in a single
    /// request and the rest are matched against it without searching.
    func matches(for track: Track, query override: String? = nil, albumSize: Int = 1) async throws -> [CatalogMatch] {
        let key = Self.albumKey(track)
        if override == nil, let id = albumForKey[key], let songs = albums[id] {
            let local = Self.ranked(songs, for: track)
            if local.first?.confidence == .high { return local }
        }
        var seen = Set<Int>()
        var scored: [CatalogMatch] = []
        var albumIDs: [String: Int] = [:]
        for query in override.map({ [$0] }) ?? Self.queries(for: track) {
            try Task.checkCancellation()
            var results = try await search(query, country: country)
            if results.isEmpty, country != "in" {
                // Indian film music is sometimes only in the Indian storefront.
                results = try await search(query, country: "in")
            }
            for result in results where seen.insert(result.trackId).inserted {
                let song = result.catalog
                albumIDs[song.id] = result.collectionId
                scored.append(CatalogMatch(song: song, score: Self.score(song, against: track)))
            }
            if scored.contains(where: { $0.confidence == .high }) { break }
        }
        let ranked = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        if albumSize > 1, !key.isEmpty, albumForKey[key] == nil,
           let best = ranked.first, best.confidence == .high, let id = albumIDs[best.song.id] {
            albumForKey[key] = id
            if albums[id] == nil, let songs = try? await albumTracks(id) { albums[id] = songs }
        }
        return ranked
    }

    /// Library album identity: album name plus album artist (or artist). Empty when unknown.
    static func albumKey(_ track: Track) -> String {
        guard !Track.isMissing(track.album) else { return "" }
        return (clean(track.album) + "|" + track.albumOwner).lowercased()
    }

    private static func ranked(_ songs: [CatalogSong], for track: Track) -> [CatalogMatch] {
        songs.map { CatalogMatch(song: $0, score: score($0, against: track)) }
            .filter { $0.score > 0 }.sorted { $0.score > $1.score }
    }

    /// Every song on one album, in one request.
    private func albumTracks(_ collectionId: Int) async throws -> [CatalogSong] {
        for storefront in [country, "in"] {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "id", value: String(collectionId)),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "country", value: storefront),
            ]
            let data = try await fetch(components.url!)
            // The first result describes the album itself; keep the songs.
            let items = (try? JSONDecoder().decode(LookupResponse.self, from: data).results) ?? []
            let songs = items.compactMap(\.song)
            if !songs.isEmpty { return songs.map(\.catalog) }
        }
        return []
    }

    private func search(_ term: String, country: String) async throws -> [ITunesSong] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        let data = try await fetch(components.url!)
        return (try? JSONDecoder().decode(Response.self, from: data).results) ?? []
    }

    /// One request, spaced to stay under Apple's limit; a 403/429 waits a minute and retries once.
    private func fetch(_ url: URL) async throws -> Data {
        let wait = spacing - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) {
            try await Task.sleep(for: .seconds(60))
            lastRequest = Date()
            return try await URLSession.shared.data(from: url).0
        }
        return data
    }

    /// Lookup results mix the album and its songs; songs decode, the album doesn't.
    private struct LookupResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let song: ITunesSong?
            init(from decoder: Decoder) throws { song = try? ITunesSong(from: decoder) }
        }
    }

    private struct Response: Decodable { let results: [ITunesSong] }

    // MARK: Queries

    /// Words that YouTube uploads add to titles but that aren't part of the song name.
    private static let noise = [
        "official video", "official audio", "official music video", "official lyric video",
        "lyrical video", "lyric video", "lyrics video", "lyrical", "lyrics", "video song", "full song",
        "audio song", "full video", "hd", "4k", "official", "movie song", "film song", "malayalam movie song",
        "tamil movie song", "hindi movie song", "remastered", "with lyrics", "visualizer",
    ]

    /// Cleaned search terms, most specific first.
    static func queries(for track: Track) -> [String] {
        let parts = track.title
            .components(separatedBy: CharacterSet(charactersIn: "|｜•"))
            .map(clean)
            .filter { !$0.isEmpty }
        let name = parts.first ?? clean(track.title)
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        if !artist.isEmpty, artist.lowercased() != "unknown artist" { out.append("\(name) \(artist)") }
        if parts.count > 1 { out.append("\(name) \(parts[1])") }  // song + film/album name
        out.append(name)
        if !track.album.isEmpty, track.album.lowercased() != "unknown album" { out.append("\(name) \(clean(track.album))") }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    static func clean(_ text: String) -> String {
        var s = text
        // Drop bracketed extras like "(Official Video)" or "[HD]", but keep "(From …)".
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\((?![Ff]rom )[^)]*\)"#, with: " ", options: .regularExpression)
        for word in noise.sorted(by: { $0.count > $1.count }) {  // "malayalam movie song" before "movie song"
            s = s.replacingOccurrences(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#,
                                       with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:,.")))
    }

    // MARK: Scoring

    private static let variantWords = ["karaoke", "instrumental", "lofi", "lo-fi", "remix", "cover",
                                       "reprise", "unplugged", "slowed", "reverb", "8d", "acoustic", "live"]

    /// 0…100+: song length agreement matters most, then title, then artist.
    static func score(_ song: CatalogSong, against track: Track) -> Int {
        var score = 0
        if let ms = song.trackTimeMillis, track.lengthMs > 0 {
            let diff = abs(ms - track.lengthMs) / 1000
            score += diff <= 2 ? 50 : diff <= 5 ? 35 : diff <= 10 ? 15 : diff <= 20 ? 0 : -40
        }
        let wanted = tokens(queries(for: track).last ?? track.title)
        let found = tokens(song.trackName.replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression))
        if !wanted.isEmpty, !found.isEmpty {
            let overlap = Double(wanted.intersection(found).count) / Double(wanted.union(found).count)
            score += Int(overlap * 40)
        }
        let artist = tokens(track.artist)
        if !artist.isEmpty, !artist.intersection(tokens(song.artistName)).isEmpty { score += 15 }
        let source = track.title.lowercased()
        let result = (song.trackName + " " + (song.collectionName ?? "") + " " + song.artistName).lowercased()
        if variantWords.contains(where: { result.contains($0) && !source.contains($0) }) { score -= 50 }
        if song.isSingle { score -= 3 }  // prefer the album version of the same recording
        if song.isCompilation, !track.compilation { score -= 5 }  // and the artist's own album over a various-artists one
        return score
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 })
    }
}
