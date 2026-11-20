import AppKit
import SwiftUI

/// The full-window player: big cover art over a blurred copy of it, the song's details,
/// large controls and, in wide windows, Up Next beside it. Opened by clicking the song
/// in the player bar; closed with the chevron or Esc.
///
/// It floats over the whole window as an overlay, so nothing in it can change the size
/// of the split view's columns.
struct NowPlayingPage: View {
    private let player = PlayerController.shared
    private let store = LibraryStore.shared
    @State private var scrub: Double = 0
    /// Controls fade away after a few still seconds while music plays; moving the mouse
    /// brings them back.
    @State private var idle = false
    @State private var idleTimer: Task<Void, Never>?

    /// Below this width the cover sits above the details instead of beside them.
    private static let sideBySideWidth: CGFloat = 760
    /// Below this width Up Next and Info open as popovers instead of a side panel.
    private static let panelWidth: CGFloat = 1060

    var body: some View {
        if let track = player.current {
            GeometryReader { geo in
                let roomForQueue = geo.size.width >= Self.panelWidth
                let sidePanel = roomForQueue ? player.nowPlayingPanel : nil
                let mainWidth = geo.size.width - (sidePanel != nil ? 380 : 0)
                HStack(spacing: 0) {
                    content(track, size: CGSize(width: mainWidth, height: geo.size.height),
                            roomForQueue: roomForQueue)
                        .frame(width: mainWidth, height: geo.size.height)
                    if let sidePanel {
                        panel(sidePanel, track: track, height: geo.size.height - 120)
                            .adaptiveGlass(in: .rect(cornerRadius: 18, style: .continuous))
                            .clipShape(.rect(cornerRadius: 18, style: .continuous))
                            .padding(.trailing, 28)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background { backdrop(track) }
            .overlay(alignment: .topLeading) {
                closeButton
                    .opacity(idle ? 0 : 1)
                    .allowsHitTesting(!idle)
            }
            .environment(\.colorScheme, .dark)
            .animation(.smooth(duration: 0.3), value: player.nowPlayingPanel)
            .onContinuousHover { _ in wake() }
            .onChange(of: player.nowPlayingPanel) { wake() }
            .onChange(of: player.isPlaying) { wake() }
            .onAppear {
                AppDelegate.shared?.setNowPlayingMode(true)
                wake()
            }
            .onDisappear {
                idleTimer?.cancel()
                player.nowPlayingPanel = nil
                AppDelegate.shared?.setNowPlayingMode(false)
            }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ track: Track, size: CGSize, roomForQueue: Bool) -> some View {
        if size.width >= Self.sideBySideWidth {
            let side = max(120, min(size.height - 140, size.width * 0.44, 560))
            HStack(spacing: 56) {
                cover(track, side: side)
                details(track, alignment: .leading, roomForQueue: roomForQueue)
                    .frame(maxWidth: 420)
            }
            .padding(.horizontal, 56)
        } else {
            let side = max(100, min(size.width - 96, size.height - 380, 460))
            VStack(spacing: 28) {
                cover(track, side: side)
                details(track, alignment: .center, roomForQueue: roomForQueue)
                    .frame(maxWidth: min(460, size.width - 64))
            }
            .padding(.vertical, 40)
        }
    }

    /// The cover eases back a little while paused, and forward again when playing.
    private func cover(_ track: Track, side: CGFloat) -> some View {
        ArtworkView(artworkID: track.artworkId, size: side, cornerRadius: max(8, side * 0.025), seed: track.album)
            .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: player.isPlaying ? 30 : 14, y: 12)
            .scaleEffect(player.isPlaying ? 1 : 0.86)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
            .contextMenu { TrackActionsMenu(ids: [track.id]) }
            .id(track.id)
            .transition(.opacity)
    }

    private func details(_ track: Track, alignment: HorizontalAlignment, roomForQueue: Bool) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 22) {
            VStack(alignment: alignment, spacing: 6) {
                Text(track.displayTitle)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                Text(track.displayArtist)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(albumLine(track))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .textSelection(.enabled)

            VStack(alignment: alignment, spacing: 22) {
                scrubber
                transport
                volume
                bottomButtons(track, roomForQueue: roomForQueue)
            }
            .opacity(idle ? 0 : 1)
            .allowsHitTesting(!idle)
        }
    }

    private func albumLine(_ track: Track) -> String {
        track.year > 0 ? "\(track.displayAlbum) · \(track.year)" : track.displayAlbum
    }

    // MARK: Controls

    /// Shows the controls, then hides them (and the pointer) after 3 still seconds,
    /// unless paused, scrubbing or a panel is open.
    private func wake() {
        if idle { withAnimation(.easeOut(duration: 0.25)) { idle = false } }
        idleTimer?.cancel()
        idleTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying, !player.isScrubbing, player.nowPlayingPanel == nil else { return }
            withAnimation(.easeInOut(duration: 0.8)) { idle = true }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var scrubber: some View {
        let time = player.isScrubbing ? scrub : player.currentTime
        return VStack(spacing: 4) {
            Slider(value: Binding(
                get: { player.isScrubbing ? scrub : player.currentTime },
                set: { scrub = $0 }
            ), in: 0...max(player.duration, 1)) { editing in
                if editing {
                    scrub = player.currentTime
                    player.isScrubbing = true
                } else {
                    player.seek(to: scrub)
                    player.isScrubbing = false
                }
            }
            .controlSize(.small)
            .tint(.white)
            HStack {
                Text(Format.duration(ms: Int(time * 1000)))
                Spacer()
                Text("-" + Format.duration(ms: Int(max(0, player.duration - time) * 1000)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Color.brand : .secondary)
            }
            .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
            Spacer(minLength: 12)
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.system(size: 26))
            }
            .help("Previous")
            Spacer(minLength: 12)
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 52, height: 48)
                    .contentTransition(.symbolEffect(.replace))
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Play")
            Spacer(minLength: 12)
            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.system(size: 26))
            }
            .help("Next")
            Spacer(minLength: 12)
            Button {
                player.repeatMode = switch player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.brand)
            }
            .help(player.repeatMode == .off ? "Repeat is off" : player.repeatMode == .all ? "Repeating all" : "Repeating this song")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var volume: some View {
        @Bindable var player = player
        return HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.mini)
                .tint(.white)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func bottomButtons(_ track: Track, roomForQueue: Bool) -> some View {
        HStack(spacing: 26) {
            panelButton(.info, symbol: "info.circle", help: "Get Info", track: track, roomForQueue: roomForQueue)
            panelButton(.queue, symbol: "list.bullet", help: "Up Next", track: track, roomForQueue: roomForQueue)
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
    }

    /// Opens its panel beside the player, or as a popover when the window is narrow.
    private func panelButton(_ kind: PlayerController.NowPlayingPanel, symbol: String, help: String,
                             track: Track, roomForQueue: Bool) -> some View {
        let isOpen = player.nowPlayingPanel == kind
        return Button {
            player.nowPlayingPanel = isOpen ? nil : kind
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(isOpen ? Color.brand : .secondary)
                .frame(width: 30, height: 30)
                .background(isOpen ? Color.white.opacity(0.12) : .clear, in: .circle)
        }
        .help(help)
        .popover(isPresented: Binding(get: { isOpen && !roomForQueue },
                                      set: { if !$0, player.nowPlayingPanel == kind { player.nowPlayingPanel = nil } }),
                 arrowEdge: .top) {
            panel(kind, track: track, height: 520)
        }
    }

    @ViewBuilder
    private func panel(_ kind: PlayerController.NowPlayingPanel, track: Track, height: CGFloat) -> some View {
        Group {
            switch kind {
            case .queue:
                UpNextView(width: 340, maxHeight: height - 40)
            case .info:
                InspectorView(trackIDs: [track.id])
                    .frame(width: 340, height: max(300, height))
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button { withAnimation(.smooth(duration: 0.35)) { player.showsNowPlaying = false } } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .adaptiveGlass(in: .circle, interactive: true)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close Now Playing (Esc)")
        .padding(18)
    }

    /// The cover again, blown up and blurred, darkened so white text stays readable.
    private func backdrop(_ track: Track) -> some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.3
            ArtworkView(artworkID: track.artworkId, size: side, cornerRadius: 0, seed: track.album)
                .blur(radius: 90)
                .saturation(1.3)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(Color.black.opacity(0.42))
                .animation(.easeInOut(duration: 0.6), value: track.artworkId)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}  // clicks on the backdrop don't reach the library underneath
    }
}
