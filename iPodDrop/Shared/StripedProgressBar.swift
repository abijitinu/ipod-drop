import SwiftUI

/// A progress bar in the style of iTunes' sync display: a red gradient fill with
/// diagonal stripes that keep moving, so it's clear work is happening even when the
/// percentage holds still. With no known amount (nil) the whole track animates.
/// Stripes stand still when Reduce Motion is on.
struct StripedProgressBar: View {
    var fraction: Double?
    var height: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let filled = geo.size.width * CGFloat(min(max(fraction ?? 1, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    stripes(phase: phase)
                }
                .frame(width: max(filled, fraction == nil ? geo.size.width : height))
                .clipShape(Capsule())
                .opacity(fraction == nil ? 0.55 : 1)
                .animation(.smooth(duration: 0.35), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func stripes(phase: TimeInterval) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [.brandLight, .brandDeep]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            let spacing: CGFloat = 14
            let shift = CGFloat((phase * 18).truncatingRemainder(dividingBy: Double(spacing)))
            var x = -size.height - spacing + shift
            while x < size.width + size.height {
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
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)),
                         with: .color(.white.opacity(0.12)))
        }
    }
}
