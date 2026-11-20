import AppKit
import UniformTypeIdentifiers

/// Custom cover art from an image on the Mac: choose a file, or drop one on the
/// artwork in the Info panel. Applied to every selected song (a whole album at once).
enum CoverArt {
    /// Image types the iPod importer reads directly; anything else is converted to PNG first.
    private static let direct: Set<String> = ["jpg", "jpeg", "png"]

    /// Ask for an image, then put it on the songs.
    @MainActor
    static func choose(for trackIDs: [String]) {
        guard !trackIDs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = trackIDs.count == 1 ? "Choose Cover Art" : "Choose Cover Art for \(trackIDs.count) Songs"
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await apply(url, to: trackIDs) }
    }

    /// Put the image at `url` on the songs, saved to the iPod in one write.
    @MainActor
    @discardableResult
    static func apply(_ url: URL, to trackIDs: [String]) async -> Bool {
        let store = LibraryStore.shared
        guard !trackIDs.isEmpty else { return false }
        guard let path = prepared(url) else {
            store.lastError = "“\(url.lastPathComponent)” isn't an image iPod Drop can read. Try a JPEG or PNG."
            return false
        }
        return await store.editMany(trackIDs.map { ["id": $0, "fields": [String: Any](), "artworkPath": path] })
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image)
            ?? UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// A JPEG or PNG path for the importer: the file itself, or a PNG copy of HEIC,
    /// WebP, TIFF and other formats macOS can open.
    private static func prepared(_ url: URL) -> String? {
        guard isImage(url) else { return nil }
        if direct.contains(url.pathExtension.lowercased()) { return url.path }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iPodDrop-cover-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString + ".png")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? target.path : nil
    }
}
