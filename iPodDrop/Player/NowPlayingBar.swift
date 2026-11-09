import SwiftUI

/// Glass player bar along the bottom of the library window.
struct NowPlayingBar: View {
    /// Room the bar takes at the bottom of the window, for things that float above it.
    static let reservedHeight: CGFloat = 80

    private let player = PlayerController.shared
    @State private var scrub: Double = 0
    @State private var showQueue = false

    var body: some View {
        HStack(spacing: 18) {
            nowPlaying
                .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                transport
                scrubber
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 0)
            trailing
                .frame(minWidth: 180, maxWidth: 300, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .adaptiveGlass(in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = player.current {
            HStack(spacing: 10) {
                ArtworkView(artworkID: track.artworkId, size: 44, cornerRadius: 6, seed: track.album)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(track.artist.isEmpty ? track.displayAlbum : "\(track.displayArtist) — \(track.displayAlbum)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contextMenu { TrackActionsMenu(ids: [track.id]) }
        } else {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 44, height: 44)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                Text("Double-click a song to play it")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffle ? Color.brand : .secondary)
            }
            .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
            Button(action: player.previous) { Image(systemName: "backward.fill") }
                .help("Previous")
                .disabled(player.current == nil)
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(player.isPlaying ? "Pause" : "Play")
            .disabled(LibraryStore.shared.tracks.isEmpty)
            Button(action: player.next) { Image(systemName: "forward.fill") }
                .help("Next")
                .disabled(player.current == nil)
            Button {
                player.repeatMode = switch player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.brand)
            }
            .help(repeatHelp)
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold))
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: "Repeat is off"
        case .all: "Repeating all"
        case .one: "Repeating this song"
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(Format.duration(ms: Int((player.isScrubbing ? scrub : player.currentTime) * 1000)))
                .frame(width: 44, alignment: .trailing)
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
            .controlSize(.mini)
            .disabled(player.current == nil)
            Text("-" + Format.duration(ms: Int(max(0, player.duration - (player.isScrubbing ? scrub : player.currentTime)) * 1000)))
                .frame(width: 48, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var trailing: some View {
        @Bindable var player = player
        return HStack(spacing: 10) {
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.plain)
                .foregroundStyle(showQueue ? Color.brand : .secondary)
                .help("Up Next")
                .popover(isPresented: $showQueue, arrowEdge: .top) { UpNextView() }
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 100)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The queue: what's playing and what plays next.
private struct UpNextView: View {
    private let player = PlayerController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next").font(.headline)
            if player.upNext.isEmpty {
                Text("Nothing queued. Right-click songs and choose Play Next.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(player.upNext.prefix(100).enumerated()), id: \.offset) { offset, track in
                            Button {
                                player.jump(to: (player.queue.firstIndex { $0.id == player.current?.id } ?? 0) + offset + 1)
                            } label: {
                                HStack(spacing: 8) {
                                    ArtworkView(artworkID: track.artworkId, size: 28, cornerRadius: 4, seed: track.album)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.displayTitle).lineLimit(1)
                                        Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(Format.duration(ms: track.lengthMs)).font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
