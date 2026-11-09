import SwiftUI

/// Product photo of an iPod (from iOpenPod's model catalog), or a symbol when unknown.
struct DeviceImage: View {
    let path: String?
    var size: CGFloat = 44
    var dimmed = false

    var body: some View {
        Group {
            if let path, let image = DeviceImageCache.image(path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
            } else {
                Image(systemName: "ipod")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

private enum DeviceImageCache {
    nonisolated(unsafe) static var images: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        let image = NSImage(contentsOfFile: path)
        images[path] = image
        return image
    }
}

/// The open iPod's name as a menu for switching between connected iPods.
struct DevicePicker: View {
    private let store = LibraryStore.shared
    var font: Font = .headline

    var body: some View {
        Menu {
            ForEach(store.device.devices) { device in
                Button {
                    store.selectDevice(device)
                } label: {
                    if device.active {
                        Label(device.displayName, systemImage: "checkmark")
                    } else {
                        Text(device.ready ? device.displayName : "\(device.displayName) (unavailable)")
                    }
                }
                .disabled(!device.ready || store.isBusy)
            }
        } label: {
            Text(store.device.name ?? "Choose an iPod").font(font)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch to another connected iPod")
    }
}

/// iPods that are plugged in but not usable, each with its photo and what to do.
struct DeviceProblemsView: View {
    private let store = LibraryStore.shared
    var compact = false

    var body: some View {
        let problems = store.device.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(problems) { problem in
                    HStack(alignment: .top, spacing: 12) {
                        DeviceImage(path: problem.image, size: compact ? 36 : 52, dimmed: true)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .font(compact ? .caption : .body)
                                    .offset(x: 4, y: 4)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(problem.needsPermission ? "iPod Drop needs permission to open \(problem.name)"
                                                         : "\(problem.name) isn't available")
                                .font(.callout.weight(.semibold))
                            Text(problem.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(compact ? 5 : nil)
                                .textSelection(.enabled)
                            if problem.needsPermission {
                                Button("Open Privacy Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .controlSize(.small)
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: compact ? .infinity : 520, alignment: .leading)
            .adaptiveGlass(in: .rect(cornerRadius: 16), tint: .orange.opacity(0.10))
        }
    }
}

/// Several iPods are connected and none is open yet: one card per iPod.
struct DeviceChooser: View {
    private let store = LibraryStore.shared

    var body: some View {
        let ready = store.device.devices.filter(\.ready)
        HStack(spacing: 16) {
            ForEach(ready) { device in
                Button {
                    store.selectDevice(device)
                } label: {
                    VStack(spacing: 10) {
                        DeviceImage(path: device.image, size: 96)
                        Text(device.name).font(.headline).lineLimit(1)
                        if !device.model.isEmpty {
                            Text(device.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(Format.bytes(device.availableBytes)) free")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 160)
                    .padding(.vertical, 16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .adaptiveGlass(in: .rect(cornerRadius: 18), interactive: true)
            }
        }
    }
}

/// What the library window shows when no iPod is open: starting, nothing
/// connected, an iPod with a problem, or a choice between several iPods.
struct DeviceStateView: View {
    private let store = LibraryStore.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 24) {
                content
            }
            .padding(40)
            .frame(maxWidth: 640)
        }
    }

    @ViewBuilder
    private var content: some View {
        let device = store.device
        let ready = device.devices.filter(\.ready)
        if case .failed(let message) = store.engine.state {
            ContentUnavailableView {
                Label("iPod Drop Couldn't Start", systemImage: "exclamationmark.octagon")
            } description: {
                Text(message)
            } actions: {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([EngineClient.logURL]) }
            }
        } else if store.engine.state == .starting {
            ProgressView("Starting…").controlSize(.large)
        } else if let recovery = device.recovery {
            RecoveryView(state: recovery, image: ready.first?.image)
        } else if ready.count > 1 {
            VStack(spacing: 6) {
                Text("Choose an iPod").font(.title2.weight(.semibold))
                Text("\(ready.count) iPods are connected. Pick the one to open; you can switch from the sidebar later.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            DeviceChooser()
            DeviceProblemsView()
        } else if ready.count == 1 {
            // Opening the only usable iPod; the engine selects it automatically.
            DeviceImage(path: ready[0].image, size: 120)
            ProgressView("Opening \(ready[0].name)…")
        } else if !device.problems.isEmpty {
            VStack(spacing: 6) {
                Text(device.problems.count == 1 ? "Your iPod Isn't Available" : "Your iPods Aren't Available")
                    .font(.title2.weight(.semibold))
                Text("iPod Drop can see it, but can't open it yet.")
                    .foregroundStyle(.secondary)
            }
            DeviceProblemsView()
            Text("iPod Drop keeps checking. It opens automatically once the iPod is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            NoDeviceView()
        }
    }
}

/// An earlier save to the iPod was interrupted (unplugged, crashed, or failed while
/// writing). iOpenPod keeps the iPod closed until someone decides what to do.
private struct RecoveryView: View {
    private let store = LibraryStore.shared
    let state: RecoveryState
    let image: String?

    var body: some View {
        VStack(spacing: 18) {
            DeviceImage(path: image, size: 110)
            VStack(spacing: 8) {
                Text("An Earlier Change Didn't Finish").font(.title2.weight(.semibold))
                Text("Saving to this iPod was interrupted, so it can't open until you choose what to do. Restoring puts back the library exactly as it was before that change; songs already on the iPod stay.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if state.busy {
                ProgressView("Recovering… don't unplug the iPod")
            } else {
                HStack(spacing: 12) {
                    Button("Keep Current Contents") { store.recover(.keep) }
                        .glassButtonStyle()
                        .help("Leave the iPod as it is now. Its recovery copies stay on the iPod.")
                    Button("Restore Previous Library") { store.recover(.restore) }
                        .glassProminentButtonStyle()
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            if let error = state.error ?? store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Send Error Report…") { ErrorReport.compose(problem: error) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// Empty state: nothing connected.
private struct NoDeviceView: View {
    private let store = LibraryStore.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: store.device.searching)
            VStack(spacing: 6) {
                Text("Connect an iPod").font(.title2.weight(.semibold))
                Text("Plug in an iPod classic, nano, mini or other click-wheel iPod with a USB cable. Your library appears here as soon as it's ready.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Use a port directly on your Mac if the iPod only charges", systemImage: "bolt.horizontal")
                Label("iPod touch and iPod shuffle aren't supported", systemImage: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .adaptiveGlass(in: .rect(cornerRadius: 14))
        }
    }
}
