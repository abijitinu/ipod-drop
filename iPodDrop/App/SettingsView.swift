import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private let store = LibraryStore.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

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
