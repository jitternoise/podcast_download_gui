import SwiftUI

/// Persistent playback controls docked at the bottom of the window.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var player: Player { model.player }

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying
                .frame(width: 240, alignment: .leading)

            transport

            scrubber

            speedMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Pieces

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            ArtworkView(url: player.podcast?.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.episode?.title ?? "Nothing playing")
                    .font(.headline)
                    .lineLimit(1)
                Text(player.podcast?.title ?? "Double-click an episode to play it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.\(Int(Player.skipInterval))")
                    .font(.system(size: 20))
            }
            .help("Back \(Int(Player.skipInterval)) seconds")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .help(player.isPlaying ? "Pause" : "Play")

            Button { player.skipForward() } label: {
                Image(systemName: "goforward.\(Int(Player.skipInterval))")
                    .font(.system(size: 20))
            }
            .help("Forward \(Int(Player.skipInterval)) seconds")
        }
        .buttonStyle(.borderless)
        .disabled(!player.hasItem)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(timeString(isScrubbing ? scrubValue : player.currentTime))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.currentTime },
                    set: { scrubValue = $0 }
                ),
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

            Text("-" + timeString(player.duration - (isScrubbing ? scrubValue : player.currentTime)))
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Player.rates, id: \.self) { rate in
                Button {
                    player.rate = rate
                } label: {
                    if rate == player.rate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(rateLabel(player.rate))
                .monospacedDigit()
                .frame(width: 44)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }

    // MARK: Formatting

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}
