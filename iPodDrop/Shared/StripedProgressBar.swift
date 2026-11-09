import SwiftUI

/// A progress bar in the style of iTunes' sync display: a red gradient fill with
/// diagonal stripes that keep moving, so it's clear work is happening even when the
/// percentage holds still. With no known amount (nil) the whole track animates.
/// Stripes stand still when Reduce Motion is on.
///
/// Everything is drawn in one Canvas of fixed height: progress and animation only
/// repaint and never change layout.
struct StripedProgressBar: View {
    var fraction: Double?
    var height: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in draw(in: &context, size: size, phase: phase) }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, phase: TimeInterval) {
        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
        context.fill(track, with: .color(.secondary.opacity(0.18)))

        let amount = min(max(fraction ?? 1, 0), 1)
        let width = max(size.width * CGFloat(amount), amount > 0 ? size.height : 0)
        guard width > 0 else { return }
        let fill = Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height),
                        cornerRadius: size.height / 2)
        context.clip(to: fill)
        context.opacity = fraction == nil ? 0.55 : 1
        context.fill(fill, with: .linearGradient(Gradient(colors: [.brandLight, .brandDeep]),
                                                 startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        let spacing: CGFloat = 14
        let shift = CGFloat((phase * 18).truncatingRemainder(dividingBy: Double(spacing)))
        var x = -size.height - spacing + shift
        while x < width + size.height {
            var stripe = Path()
            stripe.move(to: CGPoint(x: x, y: size.height))
            stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
            stripe.addLine(to: CGPoint(x: x + size.height + spacing / 2, y: 0))
            stripe.addLine(to: CGPoint(x: x + spacing / 2, y: size.height))
            stripe.closeSubpath()
            context.fill(stripe, with: .color(.white.opacity(0.22)))
            x += spacing
        }
        // A soft highlight along the top, like the glassy iTunes bar.
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: size.height / 2)),
                     with: .color(.white.opacity(0.12)))
    }
}
