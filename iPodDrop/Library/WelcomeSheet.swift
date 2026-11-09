import SwiftUI

/// First-run guide: connect the iPod, allow access to it, add music. Shown once
/// (Help › Welcome to iPod Drop shows it again).
struct WelcomeSheet: View {
    static let seenKey = "hasSeenWelcome"

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private let ffmpegInstalled = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }

    private let pages = 3

    var body: some View {
        VStack(spacing: 22) {
            Group {
                switch page {
                case 0: connect
                case 1: allow
                default: addMusic
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            HStack(spacing: 7) {
                ForEach(0..<pages, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.brand : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(pages)")

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation(.smooth) { page -= 1 } }
                } else {
                    Button("Skip") { finish() }
                }
                Spacer()
                Button(page == pages - 1 ? "Get Started" : "Continue") {
                    if page == pages - 1 { finish() } else { withAnimation(.smooth) { page += 1 } }
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 470)
        .tint(.brand)
    }

    // MARK: Pages

    private var connect: some View {
        step(title: "Connect your iPod",
             text: "Plug in your iPod classic, nano, mini or other click-wheel iPod with its USB cable, ideally straight into your Mac rather than a hub.") {
            Image("iPodLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 96)
                .foregroundStyle(.brandGradient)
        } detail: {
            Label("If it only charges, iPod Drop shows how to put it into Disk Mode.", systemImage: "bolt.horizontal")
            Label("Quit iTunes, Music or iOpenPod first: only one app should change the iPod.", systemImage: "info.circle")
        }
    }

    private var allow: some View {
        step(title: "Allow access",
             text: "macOS asks whether iPod Drop may open files on a removable volume. Click Allow, or iPod Drop can see the iPod but not open it.") {
            Image(systemName: "lock.open.display")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.brandGradient)
        } detail: {
            Label("Missed it? System Settings › Privacy & Security › Files & Folders › iPod Drop › Removable Volumes.",
                  systemImage: "gearshape")
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
    }

    private var addMusic: some View {
        step(title: "Add music",
             text: "Drag songs or folders onto the iPod icon in the menu bar or into this window, or press ⌘O. Anything the iPod can't play is converted for you.") {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.brandGradient)
        } detail: {
            if ffmpegInstalled {
                Label("Ready to convert FLAC, Opus, WAV and more.", systemImage: "checkmark.circle")
            } else {
                Label("To convert FLAC, Opus and other formats, install ffmpeg with Homebrew: brew install ffmpeg",
                      systemImage: "exclamationmark.triangle")
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                }
                .buttonStyle(.link)
            }
            Label("Rate a song 1 star on the iPod to mark it for removal; removed songs are kept on this Mac for 30 days.",
                  systemImage: "star.slash")
        }
    }

    private func step(title: String, text: String,
                      @ViewBuilder art: () -> some View,
                      @ViewBuilder detail: () -> some View) -> some View {
        VStack(spacing: 16) {
            art()
            Text(title).font(.title.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) { detail() }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .adaptiveGlass(in: .rect(cornerRadius: 14))
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }
}
