import AppKit
import Observation
import SwiftUI

/// The menu bar iPod icon: accepts dropped files and opens the Send popover on click.
/// SwiftUI's MenuBarExtra can't receive drops, so this is an AppKit status item.
final class StatusItemController: NSObject {
    private let store: LibraryStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(store: LibraryStore, openLibrary: @escaping () -> Void, chooseFiles: @escaping () -> Void) {
        self.store = store
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "ipod", accessibilityDescription: "iPod Drop")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "iPod Drop: drop music here, click for options"
            let overlay = DropOverlay(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onDrop = { [weak self] urls in
                self?.store.send(urls)
                self?.showPopover()
            }
            overlay.onClick = { [weak self] in self?.togglePopover() }
            overlay.onHover = { button.highlight($0) }
            button.addSubview(overlay)
        }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(
            rootView: SendView(
                openLibrary: { [weak self] in self?.popover.performClose(nil); openLibrary() },
                chooseFiles: { [weak self] in self?.popover.performClose(nil); chooseFiles() }
            )
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        observeBadge()
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    /// Mirror progress next to the icon ("3/12", "Saving", "✓").
    private func observeBadge() {
        withObservationTracking {
            let text = store.activity?.badge ?? ""
            item.button?.title = text.isEmpty ? "" : " \(text)"
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
    }
}

/// Transparent view over the status item button that takes file drops and clicks.
private final class DropOverlay: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover?(false)
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
