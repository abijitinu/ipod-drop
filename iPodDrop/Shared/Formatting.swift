import Foundation

enum Format {
    static func duration(ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func longDuration(ms: Int) -> String {
        let minutes = ms / 60_000
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f hr", hours) : "\(Int(hours.rounded())) hr"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func songs(_ count: Int) -> String {
        "\(count.formatted()) song\(count == 1 ? "" : "s")"
    }

    static func date(_ unix: Int) -> String {
        guard unix > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .omitted)
    }
}

/// Drag payload for songs moved between views inside the app.
enum TrackDrag {
    static let prefix = "ipoddrop-track:"

    static func payload(_ id: String) -> String { prefix + id }

    static func ids(from strings: [String]) -> [String] {
        strings.flatMap { $0.components(separatedBy: .newlines) }
            .compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }
}
