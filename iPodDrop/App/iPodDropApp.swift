import Sparkle
import SwiftUI

@main
struct iPodDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { app.checkForUpdates() }
            }
            CommandMenu("Controls") {
                // Space also toggles while the song list has focus (not in text fields).
                Button("Play/Pause") { PlayerController.shared.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Next") { PlayerController.shared.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { PlayerController.shared.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Shuffle") { PlayerController.shared.shuffle.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Repeat") {
                    let player = PlayerController.shared
                    player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Volume Up") { PlayerController.shared.volume = min(1, PlayerController.shared.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume Down") { PlayerController.shared.volume = max(0, PlayerController.shared.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Send Error Report…") { ErrorReport.compose() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Music to iPod…") { app.chooseFiles() }
                    .keyboardShortcut("o")
                Button("Show Library") { app.showLibrary() }
                    .keyboardShortcut("l")
                Divider()
                Button("Fix Info for All Songs…") { app.fixAllInfo() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

/// Owns the app's long-lived pieces: the engine-backed store, the menu bar icon and
/// the library window. The app lives in the menu bar and gains a Dock icon while the
/// library window is open.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = LibraryStore.shared
    /// In-app updates: checks the appcast on the website daily and on request.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var statusItem: StatusItemController?
    private var libraryWindow: NSWindow?

    /// For views outside the SwiftUI scene (menu bar popover, Settings) that need the updater.
    private(set) static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Plugging in, removing or rearranging displays can leave the window hanging off one.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryWindow?.fitToScreen() }
        }
        statusItem = StatusItemController(
            store: store,
            openLibrary: { [weak self] in self?.showLibrary() },
            chooseFiles: { [weak self] in self?.chooseFiles() }
        )
        if !ProcessInfo.processInfo.arguments.contains("--menu-bar-only") {
            showLibrary()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showLibrary()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A transfer to your iPod is in progress."
        alert.informativeText = "Quitting now can leave the iPod's library incomplete. Wait for it to finish."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.engine.stop()
    }

    func showLibrary() {
        if libraryWindow == nil {
            let host = NSHostingController(rootView: LibraryView())
            host.sceneBridgingOptions = [.toolbars, .title]
            // The window's size is the person's choice. By default the hosting
            // controller resizes the window to the content's ideal size whenever the
            // content changes, and a song table's ideal height is every row: after a
            // delete or an edit the window grew taller than the screen, pushing the
            // bottom bar and centred dialogs off screen. Only `minSize` below applies.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.tabbingMode = .disallowed  // one library window; no tab bar menu items
            window.title = "iPod Drop"
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.minSize = NSSize(width: 860, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("LibraryWindow")
            // Start just after the close/minimise/zoom buttons.
            let buttonsEnd = window.standardWindowButton(.zoomButton).map { $0.frame.maxX } ?? 66
            window.addTitlebarAccessoryViewController(Self.wordmarkAccessory(leading: buttonsEnd + 14))
            libraryWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        libraryWindow?.makeKeyAndOrderFront(nil)
        libraryWindow?.fitToScreen()  // after showing: before that the window has no screen
        NSApp.activate()
    }

    /// The "iPod Drop" name beside the window buttons. An AppKit accessory with a
    /// fixed size, so it stays out of SwiftUI's split-view sizing (a toolbar item in
    /// the sidebar column fed into a layout loop that crashed 2.4).
    private static func wordmarkAccessory(leading: CGFloat) -> NSTitlebarAccessoryViewController {
        let host = NSHostingView(rootView: Wordmark().padding(.leading, leading))
        host.sizingOptions = []
        let size = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: ceil(size.width) + 4, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        accessory.layoutAttribute = .leading
        return accessory
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === libraryWindow else { return }
        // Back to a menu bar-only app; the engine keeps running for drops.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func checkForUpdates() {
        NSApp.activate()  // a menu bar app's update window would otherwise open behind others
        updater.checkForUpdates(nil)
    }

    /// Look up details and cover art for the whole library (the sheet asks how first).
    func fixAllInfo() {
        showLibrary()
        guard store.editBlocker == nil, !store.tracks.isEmpty else { return }
        store.fixInfoRequest = store.tracks.map(\.id)
    }

    func chooseFiles() {
        showLibrary()
        store.showAddMusic = true
    }
}

extension NSWindow {
    /// Keep the whole window on its screen. A frame saved on a bigger display, or
    /// grown by an older version, would otherwise hide the bottom of the window.
    func fitToScreen() {
        guard !styleMask.contains(.fullScreen) else { return }
        // The display holding most of the window (a saved frame can straddle displays
        // or hang off one, e.g. after the displays were rearranged).
        func overlap(_ s: NSScreen) -> CGFloat {
            let i = s.frame.intersection(self.frame)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let target = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) ?? screen ?? NSScreen.main
        else { return }
        let visible = target.visibleFrame
        var frame = self.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != self.frame { setFrame(frame, display: true) }
    }
}
