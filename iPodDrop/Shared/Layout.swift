import AppKit

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
