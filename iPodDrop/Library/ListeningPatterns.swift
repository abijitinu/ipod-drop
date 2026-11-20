import Charts
import SwiftUI

/// How the music on the iPod gets listened to, from the play counts and last-played
/// dates the iPod keeps: headline numbers, genres, decades, time of day, what's on
/// repeat and what's been forgotten.
struct ListeningPatterns: View {
    let tracks: [Track]

    private var played: [Track] { tracks.filter { $0.playCount > 0 } }
    private var listenedMs: Int { tracks.reduce(0) { $0 + $1.playCount * $1.lengthMs } }

    var body: some View {
        Card(title: "Listening Patterns", subtitle: "From the plays your iPod has counted") {
            if played.isEmpty {
                Text("No plays yet. The iPod counts every song you finish; patterns show up here the next time it connects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                tiles
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    chartBox("Genres", note: "Time listened") { genreChart }
                    chartBox("Decades", note: "Time listened, by release year") { decadeChart }
                    chartBox("Time of Day", note: "When each song was last played") { timeOfDayChart }
                    chartBox("Last Played", note: "Played songs, by when you last heard them") { recencyChart }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    songBox("On Repeat", note: "Your most played songs", songs: onRepeat) { "\($0.playCount) plays" }
                    if !forgotten.isEmpty {
                        songBox("Forgotten Favourites", note: "Played a lot, but not in 3 months", songs: forgotten) {
                            "Last played \(Format.date($0.lastPlayed))"
                        }
                    }
                }
            }
        }
    }

    // MARK: Headline numbers

    private var tiles: some View {
        let share = Double(played.count) / Double(max(tracks.count, 1))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("Time Listened", Format.longDuration(ms: listenedMs), detail: "\(totalPlays.formatted()) plays")
            tile("Songs Played", share.formatted(.percent.precision(.fractionLength(0))),
                 detail: "\(played.count) of \(tracks.count) songs")
            tile("Top Genre", genres.first?.name ?? "—",
                 detail: genres.first.map { Format.longDuration(ms: $0.ms) } ?? "")
            tile("Top Decade", decades.max { $0.ms < $1.ms }?.name ?? "—", detail: decadeDetail)
            tile("Never Played", neverPlayed.count.formatted(), detail: "songs waiting") {
                PlayerController.shared.shuffle = true
                PlayerController.shared.play(neverPlayed.shuffled())
            }
        }
    }

    private var totalPlays: Int { tracks.reduce(0) { $0 + $1.playCount } }
    private var neverPlayed: [Track] { tracks.filter { $0.playCount == 0 } }

    private var decadeDetail: String {
        guard let top = decades.max(by: { $0.ms < $1.ms }), listenedMs > 0 else { return "" }
        return "\((Double(top.ms) / Double(listenedMs)).formatted(.percent.precision(.fractionLength(0)))) of listening"
    }

    private func tile(_ label: String, _ value: String, detail: String, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if action != nil {
                    Spacer(minLength: 0)
                    Image(systemName: "shuffle").font(.caption).foregroundStyle(Color.brand)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { action?() }
        .help(action == nil ? "" : "Shuffle the songs you haven't played yet")
    }

    // MARK: Charts

    private struct Bucket: Identifiable {
        var id: String { name }
        let name: String
        let ms: Int
        var count = 0
    }

    private var genres: [Bucket] {
        var byGenre: [String: Int] = [:]
        for track in played {
            let genre = track.genre.trimmingCharacters(in: .whitespaces)
            byGenre[genre.isEmpty ? "No Genre" : genre, default: 0] += track.playCount * track.lengthMs
        }
        return byGenre.map { Bucket(name: $0.key, ms: $0.value) }.sorted { $0.ms > $1.ms }
    }

    private var genreChart: some View {
        Chart(Array(genres.prefix(6))) { bucket in
            BarMark(x: .value("Time", Double(bucket.ms) / 3_600_000), y: .value("Genre", bucket.name))
                .foregroundStyle(Color.brand.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(Format.longDuration(ms: bucket.ms)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { AxisValueLabel().font(.caption) } }
    }

    private var decades: [Bucket] {
        var byDecade: [Int: Int] = [:]
        for track in played where track.year > 1900 {
            byDecade[track.year / 10 * 10, default: 0] += track.playCount * track.lengthMs
        }
        return byDecade.keys.sorted().map { Bucket(name: "\($0)s", ms: byDecade[$0] ?? 0) }
    }

    private var decadeChart: some View {
        Group {
            if decades.isEmpty {
                Text("Add release years (Fix Info can find them) to see this.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(decades) { bucket in
                    BarMark(x: .value("Decade", bucket.name), y: .value("Time", Double(bucket.ms) / 3_600_000))
                        .foregroundStyle(Color.orange.gradient)
                        .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let hours = value.as(Double.self) { Text("\(hours.formatted()) hr") } }
                    }
                }
            }
        }
    }

    private var timesOfDay: [Bucket] {
        let names = ["Morning", "Afternoon", "Evening", "Night"]
        var counts = [0, 0, 0, 0]
        let calendar = Calendar.current
        for track in played where track.lastPlayed > 0 {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(track.lastPlayed)))
            let slot = switch hour {
            case 5..<12: 0
            case 12..<17: 1
            case 17..<22: 2
            default: 3
            }
            counts[slot] += 1
        }
        return names.indices.map { Bucket(name: names[$0], ms: 0, count: counts[$0]) }
    }

    private var timeOfDayChart: some View {
        Chart(timesOfDay) { bucket in
            BarMark(x: .value("Time of day", bucket.name), y: .value("Songs", bucket.count))
                .foregroundStyle(Color.indigo.gradient)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(bucket.count)").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYAxis(.hidden)
    }

    private var recency: [Bucket] {
        let now = Date().timeIntervalSince1970
        let day = 86_400.0
        var counts = [0, 0, 0, 0]
        for track in played {
            guard track.lastPlayed > 0 else { continue }
            let age = now - Double(track.lastPlayed)
            counts[age < 7 * day ? 0 : age < 30 * day ? 1 : age < 182 * day ? 2 : 3] += 1
        }
        let names = ["This Week", "This Month", "6 Months", "Older"]
        return names.indices.map { Bucket(name: names[$0], ms: 0, count: counts[$0]) }
    }

    private var recencyChart: some View {
        Chart(recency) { bucket in
            BarMark(x: .value("Last played", bucket.name), y: .value("Songs", bucket.count))
                .foregroundStyle(Color.teal.gradient)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(bucket.count)").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYAxis(.hidden)
    }

    private func chartBox<Content: View>(_ title: String, note: String, @ViewBuilder _ chart: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            chart().frame(height: 170)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Songs

    private var onRepeat: [Track] {
        Array(played.sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.lastPlayed > $1.lastPlayed }.prefix(5))
    }

    /// Songs played 3 or more times whose last play was over 3 months ago.
    private var forgotten: [Track] {
        let cutoff = Date().timeIntervalSince1970 - 90 * 86_400
        return Array(played
            .filter { $0.playCount >= 3 && $0.lastPlayed > 0 && Double($0.lastPlayed) < cutoff }
            .sorted { $0.playCount > $1.playCount }
            .prefix(5))
    }

    private func songBox(_ title: String, note: String, songs: [Track], detail: @escaping (Track) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play", systemImage: "play.fill") { PlayerController.shared.play(songs) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            ForEach(songs) { track in
                HStack(spacing: 10) {
                    ArtworkView(artworkID: track.artworkId, size: 32, cornerRadius: 4, seed: track.album)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.displayTitle).lineLimit(1)
                        Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(detail(track)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .font(.callout)
                .contentShape(.rect)
                .onTapGesture(count: 2) { PlayerController.shared.play(songs, startingAt: track.id) }
                .contextMenu { TrackActionsMenu(ids: [track.id]) }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
