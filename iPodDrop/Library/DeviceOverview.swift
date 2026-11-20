import SwiftUI

/// The iPod page, opened by clicking the iPod at the top of the sidebar: what the iPod
/// is, how its storage is used, and which artists you spend your listening time on.
struct DeviceOverview: View {
    private let store = LibraryStore.shared
    @State private var metric: Metric?

    enum Metric: String, CaseIterable, Identifiable {
        case listened, library
        var id: String { rawValue }
        var name: String {
            switch self {
            case .listened: "Time Listened"
            case .library: "Music on iPod"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                storageCard
                ListeningPatterns(tracks: store.tracks.filter(\.isAudio))
                artistsCard
            }
            .padding(24)
            .padding(.bottom, NowPlayingBar.reservedHeight)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        let device = store.device
        let audio = store.tracks.filter(\.isAudio)
        return HStack(alignment: .top, spacing: 24) {
            DeviceImage(path: device.image, size: 132)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name ?? "iPod")
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    if let model = device.model, !model.isEmpty {
                        Text(model).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        fact("Capacity", device.totalBytes.map(Format.bytes) ?? "—")
                        fact("Available", device.availableBytes.map(Format.bytes) ?? "—")
                        fact("Songs", audio.count.formatted())
                    }
                    GridRow {
                        fact("Playing Time", Format.longDuration(ms: audio.reduce(0) { $0 + $1.lengthMs }))
                        fact("Artists", Set(audio.map(Self.artistName)).count.formatted())
                        fact("Albums", Set(audio.map { "\($0.albumOwner)\u{1F}\($0.album)" }).count.formatted())
                    }
                    GridRow {
                        fact("Playlists", store.regularPlaylists.count.formatted())
                        fact("Total Plays", audio.reduce(0) { $0 + $1.playCount }.formatted())
                        if let path = device.mountPath {
                            fact("Disk", URL(fileURLWithPath: path).lastPathComponent)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit().lineLimit(1)
        }
    }

    // MARK: Storage

    private var storageCard: some View {
        let total = store.device.totalBytes ?? 0
        let free = store.device.availableBytes ?? 0
        let music = store.tracks.filter(\.isAudio).reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
        let video = store.tracks.filter { !$0.isAudio }.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
        let other = max(0, total - free - music - video)
        var segments = [Segment(name: "Music", value: Double(music), color: .brand, detail: Format.bytes(music))]
        if video > 0 { segments.append(Segment(name: "Video", value: Double(video), color: .purple, detail: Format.bytes(video))) }
        // Everything else on the disk: files that aren't songs in the library, such as
        // leftovers from other apps, notes, games or files you copied to it.
        segments.append(Segment(name: "Other Files", value: Double(other), color: .gray, detail: Format.bytes(other)))
        segments.append(Segment(name: "Free", value: Double(free), color: Color.secondary.opacity(0.18), detail: Format.bytes(free)))
        return Card(title: "Storage",
                    subtitle: total > 0 ? "\(Format.bytes(total - free)) used of \(Format.bytes(total))" : nil) {
            SegmentBar(segments: segments, total: Double(max(total, 1)))
            Legend(segments: segments)
        }
    }

    // MARK: Artists

    private var artistsCard: some View {
        let stats = Self.artistStats(store.tracks)
        let anyPlays = stats.contains { $0.listenedMs > 0 }
        let metric = self.metric ?? (anyPlays ? .listened : .library)
        let value: (ArtistStat) -> Int = metric == .listened ? \.listenedMs : \.libraryMs
        let ranked = stats.filter { value($0) > 0 }.sorted { value($0) > value($1) }
        let total = ranked.reduce(0) { $0 + value($1) }
        return Card(title: "Top Artists",
                    subtitle: total > 0 ? "\(Format.longDuration(ms: total)) \(metric == .listened ? "listened" : "of music")" : nil,
                    accessory: {
                        Picker("Show", selection: Binding(get: { metric }, set: { self.metric = $0 })) {
                            ForEach(Metric.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }) {
            if ranked.isEmpty {
                Text(metric == .listened
                     ? "No plays yet. The iPod counts every song you finish; plays show up here the next time it connects."
                     : "No music on this iPod yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ArtistList(stats: Array(ranked.prefix(10)), value: value, best: value(ranked[0]))
            }
        }
    }

    struct ArtistStat {
        let name: String
        var songs: [String] = []
        var plays = 0
        /// Plays × song length: how long you've spent listening.
        var listenedMs = 0
        /// Length of all their songs on the iPod.
        var libraryMs = 0
    }

    /// One entry per artist name (ignoring case), audio only.
    static func artistStats(_ tracks: [Track]) -> [ArtistStat] {
        var byKey: [String: ArtistStat] = [:]
        for track in tracks where track.isAudio {
            let name = artistName(track)
            let key = name.lowercased()
            var stat = byKey[key] ?? ArtistStat(name: name)
            stat.songs.append(track.id)
            stat.plays += track.playCount
            stat.listenedMs += track.playCount * track.lengthMs
            stat.libraryMs += track.lengthMs
            byKey[key] = stat
        }
        return Array(byKey.values)
    }

    static func artistName(_ track: Track) -> String {
        let name = track.artist.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unknown Artist" : name
    }

}

// MARK: Pieces

private struct Segment: Identifiable {
    var id: String { name }
    let name: String
    let value: Double
    let color: Color
    let detail: String
}

/// A rounded bar split into coloured parts, like a disk's capacity bar.
private struct SegmentBar: View {
    let segments: [Segment]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    let width = geo.size.width * segment.value / max(total, 1)
                    if width >= 1 {
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: width)
                            .help("\(segment.name): \(segment.detail)")
                    }
                }
            }
        }
        .frame(height: 24)
        .background(Color.secondary.opacity(0.12))
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct Legend: View {
    let segments: [Segment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                HStack(spacing: 7) {
                    Circle().fill(segment.color).frame(width: 9, height: 9)
                    Text(segment.name).lineLimit(1)
                    Text(segment.detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .font(.callout)
            }
        }
    }
}

/// Every artist, longest first: a bar for their share, the time, plays and songs.
private struct ArtistList: View {
    let stats: [DeviceOverview.ArtistStat]
    let value: (DeviceOverview.ArtistStat) -> Int
    let best: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(stats.enumerated()), id: \.element.name) { index, stat in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(stat.name)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.brand.opacity(index < 3 ? 1 : 0.55))
                            .frame(width: max(4, geo.size.width * Double(value(stat)) / Double(max(best, 1))))
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 8)
                    Text(Format.longDuration(ms: value(stat)))
                        .monospacedDigit()
                        .frame(width: 96, alignment: .trailing)
                    Text(stat.plays == 1 ? "1 play" : "\(stat.plays.formatted()) plays")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                    Text(Format.songs(stat.songs.count))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                }
                .font(.callout)
                .padding(.vertical, 5)
                .contentShape(.rect)
                .contextMenu { TrackActionsMenu(ids: stat.songs) }
                .onTapGesture(count: 2) {
                    PlayerController.shared.play(stat.songs.compactMap { LibraryStore.shared.tracksByID[$0] })
                }
                .help("Double-click to play \(stat.name)")
            }
        }
    }
}

struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String, subtitle: String?, @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}
