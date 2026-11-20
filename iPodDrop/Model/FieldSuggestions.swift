import Foundation

/// Names already on the iPod for the text fields of the Info panel, so typing "Ar"
/// in Artist offers "A.R. Rahman" and "Arctic Monkeys" instead of a new spelling.
struct FieldSuggestions {
    enum Field: CaseIterable { case artist, album, albumArtist, genre, composer }

    /// Each field's distinct values, most used first.
    private var values: [Field: [Entry]] = [:]

    private struct Entry {
        let name: String
        let folded: String
        /// Letters and digits only, so "ar" finds "A.R. Rahman".
        let compact: String
        /// Folded words, so "rahman" also finds "A.R. Rahman".
        let words: [Substring]
    }

    init() {}

    init(_ tracks: [Track]) {
        for field in Field.allCases {
            var counts: [String: Int] = [:]
            for track in tracks where track.isAudio {
                let name = Self.value(field, of: track).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { counts[name, default: 0] += 1 }
            }
            values[field] = counts
                .sorted { $0.value != $1.value ? $0.value > $1.value
                    : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, _ in
                    let folded = Self.fold(name)
                    return Entry(name: name, folded: folded, compact: Self.compact(folded),
                                 words: folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
                }
        }
        // Album artists are usually artists too; offer both lists in both fields.
        let artists = values[.artist] ?? [], albumArtists = values[.albumArtist] ?? []
        let artistNames = Set(artists.map(\.name)), albumArtistNames = Set(albumArtists.map(\.name))
        values[.albumArtist] = albumArtists + artists.filter { !albumArtistNames.contains($0.name) }
        values[.artist] = artists + albumArtists.filter { !artistNames.contains($0.name) }
    }

    /// Up to `limit` names that start with what was typed, or have a word that does.
    /// Nothing when the field is empty or already holds exactly one of the names.
    func matches(_ field: Field, for text: String, limit: Int = 8) -> [String] {
        let typed = Self.fold(text.trimmingCharacters(in: .whitespaces))
        let typedCompact = Self.compact(typed)
        guard !typed.isEmpty, let all = values[field] else { return [] }
        var starts: [String] = [], inside: [String] = []
        for entry in all {
            if entry.folded == typed { continue }
            if entry.folded.hasPrefix(typed) || (!typedCompact.isEmpty && entry.compact.hasPrefix(typedCompact)) {
                starts.append(entry.name)
                if starts.count == limit { break }
            } else if inside.count < limit, entry.words.contains(where: { $0.hasPrefix(typed) }) {
                inside.append(entry.name)
            }
        }
        return Array((starts + inside).prefix(limit))
    }

    private static func value(_ field: Field, of track: Track) -> String {
        switch field {
        case .artist: track.artist
        case .album: track.album
        case .albumArtist: track.albumArtist
        case .genre: track.genre
        case .composer: track.composer
        }
    }

    private static func compact(_ folded: String) -> String {
        String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
