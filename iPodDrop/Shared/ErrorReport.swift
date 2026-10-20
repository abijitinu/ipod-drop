import AppKit

/// "Send Error Report…": opens a new email to the developer with a short summary of
/// the Mac, the app and the iPod, plus the engine log attached. Nothing is sent until
/// the person presses Send in their mail app.
enum ErrorReport {
    static let recipient = "lonepixel236@gmail.com"

    static func compose(problem: String? = nil) {
        let subject = "iPod Drop \(appVersion) error report"
        let body = summary(problem: problem ?? LibraryStore.shared.recentErrors.last?.message)
        var items: [Any] = [body]
        if let log = logAttachment() { items.append(log) }

        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [recipient]
            mail.subject = subject
            mail.perform(withItems: items)
            return
        }
        // No mail account set up for sharing: fall back to a mailto link (no
        // attachment possible) and show the log so it can be attached by hand.
        var link = URLComponents()
        link.scheme = "mailto"
        link.path = recipient
        link.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body + "\n(Please attach the log file that iPod Drop just showed in Finder.)"),
        ]
        if let url = link.url { NSWorkspace.shared.open(url) }
        if let log = logAttachment() { NSWorkspace.shared.activateFileViewerSelecting([log]) }
    }

    // MARK: Contents

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func summary(problem: String?) -> String {
        let store = LibraryStore.shared
        let device = store.device
        var lines = [
            "What were you doing when it went wrong?",
            "",
            "",
            "— Details (added by iPod Drop) —",
            "iPod Drop: \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(macModel)",
        ]
        if device.connected {
            lines.append("iPod: \(device.model ?? "unknown model"), \(device.songs ?? 0) songs, "
                + "\(device.availableBytes.map { Format.bytes($0) } ?? "?") free")
        } else {
            lines.append("iPod: not connected (\(device.devices.count) detected, \(device.unmounted.count) on USB only)")
            lines += device.unmounted.map { "  · \($0.name): \($0.message)" }
            lines += device.devices.filter { !$0.ready }.map { "  · \($0.model ?? $0.name): \($0.message)" }
        }
        if let problem { lines += ["", "Problem: \(problem)"] }
        let errors = store.recentErrors.suffix(8)
        if !errors.isEmpty {
            lines += ["", "Recent errors:"]
            lines += errors.map { "  \($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" }
        }
        let failed = store.sendLog.filter { $0.state == .failed }.prefix(8)
        if !failed.isEmpty {
            lines += ["", "Files that failed:"]
            lines += failed.map { "  \($0.file): \($0.detail)" }
        }
        return lines.joined(separator: "\n")
    }

    /// The end of this session's engine log and the one before it (a crash or a
    /// relaunch starts a new log), with the home folder shortened to ~ so the
    /// report doesn't carry the account name in every path.
    private static func logAttachment() -> URL? {
        func tail(_ url: URL, lines: Int) -> String? {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
        let parts = [
            tail(EngineClient.previousLogURL, lines: 1500).map { "=== Previous session ===\n" + $0 },
            tail(EngineClient.logURL, lines: 3000).map { "=== This session ===\n" + $0 },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let cleaned = parts.joined(separator: "\n\n").replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let url = FileManager.default.temporaryDirectory.appending(path: "iPod Drop log.txt")
        do {
            try cleaned.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }
}
