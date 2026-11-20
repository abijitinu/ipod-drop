import AppKit
import Foundation

/// One song suggested by a music catalogue (iTunes, Deezer or MusicBrainz).
nonisolated struct CatalogSong: Hashable, Identifiable, Sendable {
    enum Source: String, Sendable, CaseIterable {
        case itunes = "iTunes", deezer = "Deezer", musicBrainz = "MusicBrainz"
    }

    let id: String
    let source: Source
    var trackName: String
    var artistName: String
    var collectionName: String?
    var collectionArtistName: String?
    var primaryGenreName: String?
    var year: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var trackTimeMillis: Int?
    var artworkURL: URL?
    var isSingle = false
    var isCompilation = false
    /// Deezer and MusicBrainz searches leave out some details (track number, genre);
    /// they're fetched for the songs you actually pick.
    var needsDetails = false
    /// Source-specific ids used to fetch those details.
    var detailIDs: [String] = []
}

/// A scored suggestion for one song in the library.
nonisolated struct CatalogMatch: Hashable, Sendable {
    enum Confidence: Int, Comparable, Sendable {
        case low, medium, high
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var song: CatalogSong
    let score: Int

    var confidence: Confidence {
        score >= 70 ? .high : score >= 45 ? .medium : .low
    }
}

/// Fix Info's lookup: iTunes first, then Deezer when iTunes has no good match, then
/// MusicBrainz when neither does. Every suggestion says which catalogue it came from.
nonisolated enum SongLookup {
    static func matches(for track: Track, query: String? = nil, albumSize: Int = 1) async throws -> [CatalogMatch] {
        var found: [CatalogMatch] = []
        var failures: [Error] = []
        var good: Bool { found.contains { $0.confidence == .high } }

        func attempt(_ search: () async throws -> [CatalogMatch]) async throws {
            do {
                found += try await search()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                failures.append(error)
            }
        }

        try await attempt { try await ITunesLookup.shared.matches(for: track, query: query, albumSize: albumSize) }
        if !good { try await attempt { try await DeezerLookup.shared.matches(for: track, query: query) } }
        if !good { try await attempt { try await MusicBrainzLookup.shared.matches(for: track, query: query) } }

        if found.isEmpty, failures.count == CatalogSong.Source.allCases.count, let error = failures.first {
            throw error
        }
        var ranked = found.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return order(a.song.source) < order(b.song.source)  // same score: iTunes, then Deezer
        }
        // Fill in the best suggestion's details so the list shows its album, year and cover.
        if let first = ranked.first, first.song.needsDetails {
            ranked[0].song = await details(for: first.song)
        }
        return ranked
    }

    /// The song with every detail its catalogue has (track number, genre, year).
    static func details(for song: CatalogSong) async -> CatalogSong {
        guard song.needsDetails else { return song }
        switch song.source {
        case .itunes: return song
        case .deezer: return await DeezerLookup.shared.details(for: song)
        case .musicBrainz: return await MusicBrainzLookup.shared.details(for: song)
        }
    }

    private static func order(_ source: CatalogSong.Source) -> Int {
        CatalogSong.Source.allCases.firstIndex(of: source) ?? 0
    }

    /// Search phrases for a song: cleaned title and artist (same cleaning as iTunes).
    static func titleAndArtist(_ track: Track) -> (title: String, artist: String?) {
        let parts = track.title.components(separatedBy: CharacterSet(charactersIn: "|｜•"))
            .map(ITunesLookup.clean).filter { !$0.isEmpty }
        let title = parts.first ?? ITunesLookup.clean(track.title)
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        return (title, Track.isMissing(artist) ? nil : artist)
    }

    static func rank(_ songs: [CatalogSong], for track: Track) -> [CatalogMatch] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
            .map { CatalogMatch(song: $0, score: ITunesLookup.score($0, against: track)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }
}

// MARK: - Deezer

/// Deezer's public API: no key needed, strong on current mainstream music, covers up
/// to 1000×1000. Search results lack track numbers and genres; those come from the
/// track and album pages, fetched only for chosen songs.
actor DeezerLookup {
    static let shared = DeezerLookup()

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 0.2  // Deezer allows 50 requests per 5 seconds

    func matches(for track: Track, query override: String? = nil) async throws -> [CatalogMatch] {
        let (title, artist) = SongLookup.titleAndArtist(track)
        var queries: [String] = []
        if let override {
            queries = [override]
        } else {
            if let artist { queries.append("artist:\"\(artist)\" track:\"\(title)\"") }
            queries.append(artist.map { "\(title) \($0)" } ?? title)
        }
        var songs: [CatalogSong] = []
        for query in queries {
            try Task.checkCancellation()
            songs += try await search(query)
            if SongLookup.rank(songs, for: track).first?.confidence == .high { break }
        }
        return SongLookup.rank(songs, for: track)
    }

    func details(for song: CatalogSong) async -> CatalogSong {
        guard song.detailIDs.count == 2,
              let trackData = try? await get("https://api.deezer.com/track/\(song.detailIDs[0])"),
              let info = try? JSONDecoder().decode(TrackInfo.self, from: trackData) else { return song }
        var out = song
        out.trackNumber = info.track_position
        out.discNumber = info.disk_number
        if let year = info.release_date.flatMap({ Int($0.prefix(4)) }), year > 0 { out.year = year }
        if let albumData = try? await get("https://api.deezer.com/album/\(song.detailIDs[1])"),
           let album = try? JSONDecoder().decode(AlbumInfo.self, from: albumData) {
            out.primaryGenreName = album.genres?.data.first?.name
            out.trackCount = album.nb_tracks
            out.collectionArtistName = album.artist?.name
            if let year = album.release_date.flatMap({ Int($0.prefix(4)) }), year > 0 { out.year = year }
            out.isSingle = album.record_type == "single"
            out.isCompilation = album.artist?.name.caseInsensitiveCompare("Various Artists") == .orderedSame
        }
        out.needsDetails = false
        return out
    }

    private func search(_ query: String) async throws -> [CatalogSong] {
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "15")]
        let data = try await get(components.url!.absoluteString)
        let results = (try? JSONDecoder().decode(SearchResponse.self, from: data).data) ?? []
        return results.map { item in
            CatalogSong(
                id: "deezer:\(item.id)", source: .deezer, trackName: item.title, artistName: item.artist.name,
                collectionName: item.album.title, trackTimeMillis: item.duration.map { $0 * 1000 },
                artworkURL: (item.album.cover_xl ?? item.album.cover_big).flatMap(URL.init(string:)),
                needsDetails: true, detailIDs: [String(item.id), String(item.album.id)])
        }
    }

    private func get(_ url: String) async throws -> Data {
        let wait = spacing - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        return try await URLSession.shared.data(from: url).0
    }

    private struct SearchResponse: Decodable { let data: [Item] }
    private struct Item: Decodable {
        let id: Int
        let title: String
        let duration: Int?
        let artist: Named
        let album: Album
    }
    private struct Named: Decodable { let name: String }
    private struct Album: Decodable {
        let id: Int
        let title: String
        let cover_big: String?
        let cover_xl: String?
    }
    private struct TrackInfo: Decodable {
        let track_position: Int?
        let disk_number: Int?
        let release_date: String?
    }
    private struct AlbumInfo: Decodable {
        let nb_tracks: Int?
        let release_date: String?
        let record_type: String?
        let artist: Named?
        let genres: Genres?
        struct Genres: Decodable { let data: [Named] }
    }
}

// MARK: - MusicBrainz

/// MusicBrainz: open music data, no key, the most exact album, track-number and
/// release details, and wide coverage of older, rare and regional music. Allows one
/// request a second and asks every app to identify itself. Covers come from the
/// Cover Art Archive.
actor MusicBrainzLookup {
    static let shared = MusicBrainzLookup()

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 1.1
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2"
        return "iPodDrop/\(version) ( https://github.com/abijitinu/ipod-drop )"
    }()

    func matches(for track: Track, query override: String? = nil) async throws -> [CatalogMatch] {
        let (title, artist) = SongLookup.titleAndArtist(track)
        var queries: [String] = []
        if let override {
            queries = [override]
        } else {
            var base = "recording:\"\(Self.escape(title))\""
            if let artist { base += " AND artist:\"\(Self.escape(artist))\"" }
            // Studio albums first: the plain search tends to rank compilations and live albums.
            queries.append(base + " AND status:official AND primarytype:album NOT secondarytype:compilation NOT secondarytype:live")
            queries.append(base)
        }
        var songs: [CatalogSong] = []
        for query in queries {
            try Task.checkCancellation()
            songs += try await search(query)
            if SongLookup.rank(songs, for: track).first?.confidence == .high { break }
        }
        return SongLookup.rank(songs, for: track)
    }

    /// Adds the genre (from the album's release group).
    func details(for song: CatalogSong) async -> CatalogSong {
        var out = song
        out.needsDetails = false
        guard let group = song.detailIDs.first,
              let data = try? await get("https://musicbrainz.org/ws/2/release-group/\(group)?inc=genres&fmt=json"),
              let info = try? JSONDecoder().decode(GroupInfo.self, from: data) else { return out }
        if let genre = info.genres?.max(by: { $0.count < $1.count }) {
            out.primaryGenreName = genre.name.capitalized
        }
        return out
    }

    private func search(_ query: String) async throws -> [CatalogSong] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "fmt", value: "json"),
                                 URLQueryItem(name: "limit", value: "15")]
        let data = try await get(components.url!.absoluteString)
        let recordings = (try? JSONDecoder().decode(SearchResponse.self, from: data).recordings) ?? []
        return recordings.compactMap(Self.song)
    }

    /// A recording on its best release: official, a plain album, the earliest.
    private static func song(_ recording: Recording) -> CatalogSong? {
        let releases = (recording.releases ?? []).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.date ?? "9999") < (b.date ?? "9999")
        }
        let release = releases.first
        let medium = release?.media?.first
        let group = release?.releaseGroup
        let secondary = group?.secondaryTypes ?? []
        let albumArtist = release?.artistCredit.map(credit)
        var song = CatalogSong(
            id: "mb:\(recording.id)", source: .musicBrainz,
            trackName: recording.title, artistName: credit(recording.artistCredit ?? []),
            collectionName: release?.title, collectionArtistName: albumArtist,
            // The song's original year, not a reissue's.
            year: (recording.firstReleaseDate ?? release?.date).flatMap { Int($0.prefix(4)) },
            trackNumber: medium?.track?.first.flatMap { Int($0.number ?? "") },
            trackCount: medium?.trackCount, discNumber: medium?.position,
            discCount: (release?.media?.count ?? 0) > 1 ? release?.media?.count : nil,
            trackTimeMillis: recording.length ?? medium?.track?.first?.length,
            artworkURL: group.flatMap { URL(string: "https://coverartarchive.org/release-group/\($0.id)/front-500") },
            isSingle: group?.primaryType == "Single",
            isCompilation: secondary.contains("Compilation")
                && albumArtist?.caseInsensitiveCompare("Various Artists") == .orderedSame)
        song.needsDetails = group != nil
        song.detailIDs = group.map { [$0.id] } ?? []
        return song
    }

    private static func rank(_ release: Release) -> Int {
        var rank = release.status == "Official" ? 0 : 10
        let group = release.releaseGroup
        if !(group?.secondaryTypes ?? []).isEmpty { rank += 4 }
        switch group?.primaryType {
        case "Album": break
        case "EP": rank += 1
        case "Single": rank += 2
        default: rank += 3
        }
        return rank
    }

    private static func credit(_ parts: [Credit]) -> String {
        parts.map { $0.name + ($0.joinphrase ?? "") }.joined().trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// One request a second; "busy" replies (503) wait and retry a few times.
    private func get(_ url: String) async throws -> Data {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<4 {
            let wait = spacing - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastRequest = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 503 || status == 429, attempt < 3 {
                try await Task.sleep(for: .seconds(2 * Double(attempt + 1)))
                continue
            }
            return data
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private struct SearchResponse: Decodable { let recordings: [Recording] }
    private struct Recording: Decodable {
        let id: String
        let title: String
        let length: Int?
        let artistCredit: [Credit]?
        let firstReleaseDate: String?
        let releases: [Release]?
        enum CodingKeys: String, CodingKey {
            case id, title, length, releases
            case artistCredit = "artist-credit", firstReleaseDate = "first-release-date"
        }
    }
    private struct Credit: Decodable {
        let name: String
        let joinphrase: String?
    }
    private struct Release: Decodable {
        let title: String
        let status: String?
        let date: String?
        let artistCredit: [Credit]?
        let releaseGroup: Group?
        let media: [Medium]?
        enum CodingKeys: String, CodingKey {
            case title, status, date, media
            case artistCredit = "artist-credit", releaseGroup = "release-group"
        }
    }
    private struct Group: Decodable {
        let id: String
        let primaryType: String?
        let secondaryTypes: [String]?
        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type", secondaryTypes = "secondary-types"
        }
    }
    private struct Medium: Decodable {
        let position: Int?
        let trackCount: Int?
        let track: [TrackEntry]?
        enum CodingKeys: String, CodingKey {
            case position, track
            case trackCount = "track-count"
        }
    }
    private struct TrackEntry: Decodable {
        let number: String?
        let length: Int?
    }
    private struct GroupInfo: Decodable {
        let genres: [Genre]?
        struct Genre: Decodable {
            let name: String
            let count: Int
        }
    }
}
