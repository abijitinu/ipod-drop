import SwiftUI

/// The menu bar popover: where dropped music goes, progress, and recent transfers.
struct SendView: View {
    private let store = LibraryStore.shared
    var openLibrary: () -> Void
    var chooseFiles: () -> Void

    @State private var isTargeted = false
    @State private var namingPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                DeviceHeader()
                if store.device.connected {
                    targetPicker
                    dropZone
                    if let activity = store.activity {
                        ActivityRow(activity: activity)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !store.sendLog.isEmpty { recent }
                } else {
                    disconnected
                }
                if let error = store.lastError { ErrorBanner(message: error) }
                footer
            }
            .padding(16)
        }
        .frame(width: 360)
        .animation(.smooth(duration: 0.25), value: store.activity)
        .animation(.smooth(duration: 0.25), value: store.device.connected)
        .tint(.brand)
        .alert("New Playlist", isPresented: $namingPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Use Playlist") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.sendTarget = .newPlaylist(name: name) }
            }
        } message: {
            Text("It's created on your iPod with the first songs you drop.")
        }
    }

    // MARK: Pieces

    private var targetPicker: some View {
        @Bindable var store = store
        return HStack {
            Text("Add to")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Add to", selection: $store.sendTarget) {
                    Label("Library only", systemImage: "music.note.house").tag(SendTarget.library)
                    if case .newPlaylist(let name) = store.sendTarget {
                        Label("\(name) (new)", systemImage: "music.note.list").tag(store.sendTarget)
                    }
                    if !store.regularPlaylists.isEmpty {
                        Divider()
                        ForEach(store.regularPlaylists) { playlist in
                            Label(playlist.name, systemImage: "music.note.list")
                                .tag(SendTarget.playlist(id: playlist.id, name: playlist.name))
                        }
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("New Playlist…", systemImage: "plus") {
                    newPlaylistName = ""
                    namingPlaylist = true
                }
            } label: {
                Label(store.sendTarget.name ?? "Library only",
                      systemImage: store.sendTarget == .library ? "music.note.house" : "music.note.list")
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .fixedSize()
        }
    }

    private var dropZone: some View {
        Button(action: chooseFiles) {
            VStack(spacing: 8) {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isTargeted ? Color.brand : .secondary)
                    .symbolEffect(.bounce, value: isTargeted)
                Text(isTargeted ? "Release to add" : "Drop music here")
                    .font(.headline)
                Text(store.sendTarget.name.map { "Into “\($0)”" } ?? "MP3, AAC, ALAC, FLAC, WAV, Opus or folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 132)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isTargeted ? Color.brand.opacity(0.12) : .clear)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isTargeted ? Color.brand : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.send(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .help("Drop files or folders, or click to choose")
        .disabled(store.editBlocker != nil)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.sendLog.prefix(5)) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.file).lineLimit(1).truncationMode(.middle)
                        Text(item.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var disconnected: some View {
        if store.device.recovery != nil {
            Label("An earlier change to your iPod didn't finish. Open the library to restore it.",
                  systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
                .padding(12)
                .adaptiveGlass(in: .rect(cornerRadius: 14), tint: .orange.opacity(0.12))
        } else if store.device.devices.filter(\.ready).count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose an iPod").font(.headline)
                ForEach(store.device.devices.filter(\.ready)) { device in
                    Button {
                        store.selectDevice(device)
                    } label: {
                        HStack {
                            DeviceImage(path: device.image, size: 28)
                            Text(device.displayName).lineLimit(1)
                            Spacer()
                        }
                    }
                    .glassButtonStyle()
                }
            }
        } else if !store.device.problems.isEmpty {
            DeviceProblemsView(compact: true)
        } else {
            VStack(spacing: 8) {
                if store.device.searching || store.engine.state == .starting {
                    ProgressView().controlSize(.small)
                }
                Text(store.engine.state == .starting ? "Starting…" : "Connect an iPod")
                    .font(.headline)
                Text("Plug it in with a USB cable. It shows up here as soon as it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Library", systemImage: "music.note.list", action: openLibrary)
                .glassButtonStyle()
            Spacer()
            Menu {
                if store.device.connected {
                    Button("Eject iPod", systemImage: "eject") { store.eject() }
                        .disabled(store.isBusy)
                }
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
                Button("Check for Updates…", systemImage: "arrow.down.circle") { AppDelegate.shared?.checkForUpdates() }
                Button("Send Error Report…", systemImage: "envelope") { ErrorReport.compose() }
                Divider()
                Button("Quit iPod Drop") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .glassButtonStyle()
            .fixedSize()
        }
    }
}

/// iPod name, song count and capacity, shared by the popover and the library sidebar.
struct DeviceHeader: View {
    private let store = LibraryStore.shared
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            // The exact model and colour, so you can tell which iPod is open.
            DeviceImage(path: store.device.connected ? store.device.image : nil,
                        size: compact ? 40 : 52, dimmed: !store.device.connected)
            VStack(alignment: .leading, spacing: 4) {
                if store.device.devices.filter(\.ready).count > 1 {
                    DevicePicker(font: compact ? .headline : .title3.weight(.semibold))
                } else {
                    Text(store.device.name ?? "iPod")
                        .font(compact ? .headline : .title3.weight(.semibold))
                }
                if store.device.connected, let model = store.device.model, !model.isEmpty, model != store.device.name {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
                if store.device.connected, let total = store.device.totalBytes, let free = store.device.availableBytes {
                    ProgressView(value: store.device.usedFraction)
                        .progressViewStyle(.linear)
                        .tint(.brand)
                        .frame(maxWidth: 220)
                    Text("\(Format.songs(store.device.songs ?? 0)) · \(Format.bytes(free)) free of \(Format.bytes(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(store.device.searching ? "Looking for your iPod…" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Progress or result of the current transfer, like iTunes' sync display: what's
/// happening, the song being worked on, how many files are done, the percentage,
/// and a moving striped bar so it's clear work continues.
struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                icon
                Text(activity.title)
                    .font(.callout.weight(activity.isWorking ? .semibold : .regular))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if activity.isWorking, let percent = activity.percentText {
                    Text(percent)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.brand)
                }
            }
            if activity.isWorking {
                if let item = activity.item, !item.isEmpty {
                    Text(item)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: item)
                }
                StripedProgressBar(fraction: activity.fraction)
                if let count = activity.countText {
                    Text(count)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .adaptiveGlass(in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch activity.phase {
        case .importing, .saving:
            Image("iPodLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 18)
                .foregroundStyle(.brandGradient)
                .symbolEffect(.pulse, options: .repeating)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct ErrorBanner: View {
    private let store = LibraryStore.shared
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            // A long engine message must never push the window taller than the screen.
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 0)
            Button("Report…") { ErrorReport.compose(problem: message) }
                .buttonStyle(.borderless)
                .font(.callout)
                .help("Email this problem and the app's log to the developer")
            Button("Dismiss", systemImage: "xmark") { store.lastError = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .adaptiveGlass(in: .rect(cornerRadius: 14), tint: .orange.opacity(0.15))
    }
}
