import SwiftUI

/// Persistent playback controls docked at the bottom of the full window.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            NowPlayingLabel(artworkSize: 44)
                .frame(width: 240, alignment: .leading)

            TransportButtons(playSize: 36, skipSize: 20)

            Scrubber()

            SpeedMenu()

            Button {
                model.windowMode.collapse()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help("Switch to Mini Player (⇧⌘M)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Compact layout used when the window is collapsed to just the player.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var windowMode = model.windowMode

        HStack(alignment: .top, spacing: 12) {
            ArtworkView(url: model.player.podcast?.artworkURL, size: 96)

            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.player.episode?.title ?? "Nothing playing")
                            .font(.headline)
                            .lineLimit(1)
                        Text(model.player.podcast?.title ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle(isOn: $windowMode.keepOnTop) {
                        Image(systemName: windowMode.keepOnTop ? "pin.fill" : "pin")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(windowMode.keepOnTop ? "Stop keeping on top" : "Keep on top of other windows")
                    Button {
                        model.windowMode.expand()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to full window (⇧⌘M)")
                }

                Scrubber()

                HStack(spacing: 12) {
                    Spacer()
                    TransportButtons(playSize: 30, skipSize: 18)
                    Spacer()
                    SpeedMenu()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Shared pieces

struct NowPlayingLabel: View {
    @Environment(AppModel.self) private var model
    var artworkSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: model.player.podcast?.artworkURL, size: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.player.episode?.title ?? "Nothing playing")
                    .font(.headline)
                    .lineLimit(1)
                Text(model.player.podcast?.title ?? "Double-click an episode to play it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct TransportButtons: View {
    @Environment(AppModel.self) private var model
    var playSize: CGFloat
    var skipSize: CGFloat

    private var player: Player { model.player }

    var body: some View {
        HStack(spacing: 18) {
            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.\(Int(Player.skipInterval))")
                    .font(.system(size: skipSize))
            }
            .help("Back \(Int(Player.skipInterval)) seconds")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playSize))
            }
            .help(player.isPlaying ? "Pause" : "Play")

            Button { player.skipForward() } label: {
                Image(systemName: "goforward.\(Int(Player.skipInterval))")
                    .font(.system(size: skipSize))
            }
            .help("Forward \(Int(Player.skipInterval)) seconds")
        }
        .buttonStyle(.borderless)
        .disabled(!player.hasItem)
    }
}

struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var player: Player { model.player }
    private var shown: Double { isScrubbing ? scrubValue : player.currentTime }

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeText.format(shown))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

            Slider(
                value: Binding(get: { shown }, set: { scrubValue = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if editing {
                    scrubValue = player.currentTime
                    isScrubbing = true
                } else {
                    player.seek(to: scrubValue)
                    isScrubbing = false
                }
            }
            .disabled(!player.hasItem || player.duration == 0)

            Text("-" + TimeText.format(player.duration - shown))
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}

struct SpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(Player.rates, id: \.self) { rate in
                Button {
                    model.player.rate = rate
                } label: {
                    if rate == model.player.rate {
                        Label(TimeText.rate(rate), systemImage: "checkmark")
                    } else {
                        Text(TimeText.rate(rate))
                    }
                }
            }
        } label: {
            Text(TimeText.rate(model.player.rate))
                .monospacedDigit()
                .frame(width: 44)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }
}

enum TimeText {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func rate(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}
