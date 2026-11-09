import AppKit
import SwiftUI

/// Sheet sizes that fit the window they're attached to. A sheet taller than its
/// window hangs off the bottom of the screen (and in full screen its buttons can't
/// be reached), so large sheets shrink to the room available.
enum SheetSize {
    /// Room inside the library window, leaving a small margin around the sheet.
    static var available: CGSize {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let room = window?.contentLayoutRect.size ?? CGSize(width: 1000, height: 700)
        return CGSize(width: room.width - 40, height: room.height - 24)
    }

    /// `preferred`, or smaller when the window is smaller; never below `minimum`.
    static func fitting(_ preferred: CGSize, minimum: CGSize = CGSize(width: 480, height: 320)) -> CGSize {
        let room = available
        return CGSize(width: max(minimum.width, min(preferred.width, room.width)),
                      height: max(minimum.height, min(preferred.height, room.height)))
    }
}

/// Two panes side by side with a divider you drag to resize (double-click resets).
/// Pure SwiftUI on purpose: AppKit's HSplitView kept its widths when the window
/// got narrower (opening Info), pushing panels past the window edge. Here the
/// leading pane gives way first, so the trailing pane always keeps `minTrailing`.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @AppStorage private var width: Double
    private let defaultWidth: Double
    private let minLeading: CGFloat, maxLeading: CGFloat, minTrailing: CGFloat
    private let leading: Leading, trailing: Trailing
    @State private var dragStart: Double?

    init(id: String, defaultWidth: CGFloat, minLeading: CGFloat, maxLeading: CGFloat, minTrailing: CGFloat,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        _width = AppStorage(wrappedValue: Double(defaultWidth), "split." + id)
        self.defaultWidth = Double(defaultWidth)
        self.minLeading = minLeading
        self.maxLeading = maxLeading
        self.minTrailing = minTrailing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { geo in
            let upper = max(minLeading, min(maxLeading, geo.size.width - minTrailing))
            let current = min(max(CGFloat(width), minLeading), upper)
            HStack(spacing: 0) {
                leading.frame(width: current)
                divider(current: current, upper: upper)
                trailing.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(current: CGFloat, upper: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)  // a wider grab area than the visible line
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? Double(current)
                        dragStart = start
                        width = Double(min(max(CGFloat(start) + drag.translation.width, minLeading), upper))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { width = defaultWidth }
            .accessibilityLabel("Resize")
    }
}
