import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private let store = LibraryStore.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(LibraryStore.markedPlaylistKey) private var markedPlaylist = true
    @AppStorage(LibraryStore.autoRemoveMarkedKey) private var autoRemoveMarked = false
    @AppStorage(LibraryStore.keepRemovedCopiesKey) private var keepRemovedCopies = true
    @AppStorage(LibraryStore.neverPlayedKey) private var neverPlayed = false
    @AppStorage(LibraryStore.onRepeatKey) private var onRepeat = false
    @AppStorage(LibraryStore.recentlyAddedKey) private var recentlyAdded = true
    @State private var autoUpdate = AppDelegate.shared?.updater.updater.automaticallyChecksForUpdates ?? true

    var body: some View {
        Form {
            Section {
                Toggle("Open iPod Drop at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("iPod Drop starts in the menu bar so you can drop music without opening the library.")
            }
            Section {
                Toggle("Keep a “Marked for Removal” playlist on the iPod", isOn: $markedPlaylist)
                Toggle("Remove marked songs automatically when the iPod connects", isOn: $autoRemoveMarked)
                Toggle("Keep a copy of removed songs on this Mac for 30 days", isOn: $keepRemovedCopies)
            } header: {
                Text("Songs rated 1 star")
            } footer: {
                Text("Rate a song 1 star on your iPod to mark it. It appears in the playlist right away so you can listen again and change your mind. When the iPod connects, iPod Drop offers to remove marked songs (songs on your Mac are never touched).")
            }
            Section {
                Toggle("“Recently Added”: your 50 newest songs", isOn: $recentlyAdded)
                Toggle("“Never Played”: songs you haven’t listened to yet", isOn: $neverPlayed)
                Toggle("“On Repeat”: the 50 songs you play most", isOn: $onRepeat)
            } header: {
                Text("Playlists from your listening")
            } footer: {
                Text("Live playlists on the iPod that change by themselves as you listen. iPod Drop adds them when the iPod connects, and removes them if you turn them off.")
            }
            .onChange(of: neverPlayed) { Task { await store.syncAutoPlaylists() } }
            .onChange(of: onRepeat) { Task { await store.syncAutoPlaylists() } }
            .onChange(of: recentlyAdded) { Task { await store.syncAutoPlaylists() } }
            Section {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in
                        AppDelegate.shared?.updater.updater.automaticallyChecksForUpdates = on
                    }
                LabeledContent("Version \(ErrorReport.appVersion)") {
                    Button("Check Now") { AppDelegate.shared?.checkForUpdates() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("iPod Drop checks once a day and asks before installing a new version.")
            }
            Section {
                LabeledContent("Something not working?") {
                    Button("Send Error Report…") { ErrorReport.compose() }
                }
            } footer: {
                Text("Opens an email to the developer with details about your Mac, the iPod and the app's log. You can read it before sending.")
            }
            Section("Engine") {
                LabeledContent("Status", value: engineStatus)
                LabeledContent("Log") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([EngineClient.logURL])
                    }
                }
            }
            Section {
                Text("iPod Drop manages your iPod with iOpenPod's library engine (GPL-3.0). Quit iOpenPod while using iPod Drop: only one app should write to the iPod at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var engineStatus: String {
        switch store.engine.state {
        case .starting: "Starting…"
        case .running: store.device.connected ? "Connected to \(store.device.name ?? "iPod")" : "Waiting for iPod"
        case .failed(let message): message
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
