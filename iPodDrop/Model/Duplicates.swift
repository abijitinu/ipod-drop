import Foundation

/// One song that is on the iPod more than once: the copy worth keeping, and the rest.
nonisolated struct DuplicateGroup: Identifiable, Hashable {
    let keep: Track
    let extras: [Track]
    var id: String { keep.id }
    var all: [Track] { [keep] + extras }
}

/// Finds songs that are on the iPod more than once.
///
/// Two songs are copies when their title and artist match (ignoring case, accents,
/// spaces and punctuation) and their lengths are within 3 seconds. The album isn't
/// compared, so the same recording on an album and on a compilation counts; a live
/// or remixed version is longer or shorter, or titled differently, so it doesn't.
nonisolated enum Duplicates {
    static let lengthToleranceMs = 3000

    static func groups(_ tracks: [Track]) -> [DuplicateGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks where track.isAudio {
            guard let key = key(track) else { continue }
            buckets[key, default: []].append(track)
        }
        var groups: [DuplicateGroup] = []
        for bucket in buckets.values where bucket.count > 1 {
            // Copies of one song are close in length; versions of different lengths aren't copies.
            var cluster: [Track] = []
            for track in bucket.sorted(by: { $0.lengthMs < $1.lengthMs }) {
                if let first = cluster.first, track.lengthMs - first.lengthMs > lengthToleranceMs {
                    if let group = group(cluster) { groups.append(group) }
                    cluster = []
                }
                cluster.append(track)
            }
            if let group = group(cluster) { groups.append(group) }
        }
        return groups.sorted { a, b in
            let artist = a.keep.displayArtist.localizedStandardCompare(b.keep.displayArtist)
            if artist != .orderedSame { return artist == .orderedAscending }
            return a.keep.displayTitle.localizedStandardCompare(b.keep.displayTitle) == .orderedAscending
        }
    }

    private static func group(_ copies: [Track]) -> DuplicateGroup? {
        guard copies.count > 1 else { return nil }
        let ranked = copies.sorted(by: isBetter)
        return DuplicateGroup(keep: ranked[0], extras: Array(ranked.dropFirst()))
    }

    /// Title and artist reduced to letters and digits; nil when the title is a placeholder.
    static func key(_ track: Track) -> String? {
        guard !Track.isMissing(track.title) else { return nil }
        return normalize(track.title) + "\u{1F}" + normalize(Track.isMissing(track.artist) ? "" : track.artist)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// The copy to keep: has cover art, more complete info, better quality, played
    /// more, then added first.
    static func isBetter(_ a: Track, _ b: Track) -> Bool {
        if (a.artworkId > 0) != (b.artworkId > 0) { return a.artworkId > 0 }
        if completeness(a) != completeness(b) { return completeness(a) > completeness(b) }
        if a.bitrateKbps != b.bitrateKbps { return a.bitrateKbps > b.bitrateKbps }
        if a.playCount != b.playCount { return a.playCount > b.playCount }
        if a.dateAdded != b.dateAdded { return a.dateAdded < b.dateAdded }
        return a.id < b.id
    }

    private static func completeness(_ track: Track) -> Int {
        [!Track.isMissing(track.album), !Track.isMissing(track.genre), track.year > 0, track.trackNumber > 0]
            .filter { $0 }.count
    }
}
