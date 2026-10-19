import SwiftUI

/// Cover art loaded from the iPod, with a tinted placeholder while it loads or when absent.
struct ArtworkView: View {
    private let store = LibraryStore.shared
    @Environment(\.displayScale) private var scale

    let artworkID: Int
    var size: CGFloat
    var cornerRadius: CGFloat = 6
    /// Seeds the placeholder colour so albums without art still look distinct.
    var seed: String = ""

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: artworkID) {
            image = nil
            image = await store.artwork(artworkID, pixels: Int(size * scale))
        }
    }

    private var placeholder: some View {
        // String.hashValue changes every launch; use a stable sum so colours don't shuffle.
        let hue = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.35, brightness: 0.75),
                     Color(hue: hue, saturation: 0.45, brightness: 0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
