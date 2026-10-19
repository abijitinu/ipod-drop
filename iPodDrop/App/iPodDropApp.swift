import SwiftUI

@main
struct iPodDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
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
            CommandGroup(replacing: .newItem) {
                Button("Add Music to iPod…") { app.chooseFiles() }
                    .keyboardShortcut("o")
                Button("Show Library") { app.showLibrary() }
                    .keyboardShortcut("l")
            }
        }
    }
}

/// Owns the app's long-lived pieces: the engine-backed store, the menu bar icon and
/// the library window. The app lives in the menu bar and gains a Dock icon while the
/// library window is open.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = LibraryStore.shared
    private var statusItem: StatusItemController?
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.title = "iPod Drop"
            window.setContentSize(NSSize(width: 1180, height: 740))
            window.minSize = NSSize(width: 860, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("LibraryWindow")
            libraryWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === libraryWindow else { return }
        // Back to a menu bar-only app; the engine keeps running for drops.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func chooseFiles() {
        showLibrary()
        store.showAddMusic = true
    }
}
