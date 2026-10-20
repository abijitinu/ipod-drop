import SwiftUI

// Liquid Glass on macOS 26 and later; the closest system look (materials and
// bordered buttons) on macOS 14 Sonoma and macOS 15 Sequoia.

extension View {
    /// A glass surface behind the view, optionally tinted.
    @ViewBuilder
    func adaptiveGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
            glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint) }
                    shape.stroke(.separator, lineWidth: 0.5)
                }
            }
        }
    }

    /// `.buttonStyle(.glass)`, or a bordered button before macOS 26.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// `.buttonStyle(.glassProminent)`, or a prominent bordered button before macOS 26.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// `GlassEffectContainer` on macOS 26 and later; a plain container before.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
