import AVKit
import SwiftUI

/// Persistent playback controls docked at the bottom of the full window.
/// Two layouts: the full one, and a tighter one for narrow windows.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                NowPlayingLabel(artworkSize: 44)
                    .frame(width: 240, alignment: .leading)
                TransportButtons(playSize: 36, skipSize: 20)
                Scrubber()
                ChapterMenu()
                SpeedMenu()
                VolumeControl(showsSlider: true)
                MiniToggleButton()
            }
            HStack(spacing: 12) {
                NowPlayingLabel(artworkSize: 36)
                    .frame(width: 170, alignment: .leading)
                TransportButtons(playSize: 32, skipSize: 18)
                Scrubber()
                ChapterMenu()
                SpeedMenu()
                VolumeControl(showsSlider: false)
                MiniToggleButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct MiniToggleButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Switch to Mini Player", systemImage: "arrow.down.right.and.arrow.up.left") {
            model.windowMode.collapse()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Switch to Mini Player (⇧⌘M)")
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
                        Text(model.player.error ?? model.player.currentChapter?.title ?? model.player.podcast?.title ?? "")
                            .font(.caption)
                            .foregroundStyle(model.player.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle(isOn: $windowMode.keepOnTop) {
                        Label("Keep on Top", systemImage: windowMode.keepOnTop ? "pin.fill" : "pin")
                            .labelStyle(.iconOnly)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(windowMode.keepOnTop ? "Stop keeping on top" : "Keep on top of other windows and Spaces")
                    Button("Back to Full Window", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.windowMode.expand()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Back to full window (⇧⌘M)")
                }

                Scrubber()

                HStack(spacing: 12) {
                    SleepTimerBadge()
                    Spacer()
                    TransportButtons(playSize: 30, skipSize: 18)
                    Spacer()
                    SpeedMenu()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: WindowMode.miniContentSize.width, height: WindowMode.miniContentSize.height)
        .background(.bar)
    }
}

// MARK: - Shared pieces

struct NowPlayingLabel: View {
    @Environment(AppModel.self) private var model
    var artworkSize: CGFloat

    private var canReveal: Bool {
        model.player.episode?.podcastID.flatMap { model.library.podcast(withID: $0) } != nil
    }

    var body: some View {
        Button {
            model.revealNowPlaying()
        } label: {
            HStack(spacing: 10) {
                ArtworkView(url: model.player.podcast?.artworkURL, size: artworkSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.player.episode?.title ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(model.player.error ?? model.player.currentChapter?.title ?? model.player.podcast?.title ?? "Double-click an episode to play it")
                        .font(.caption)
                        .foregroundStyle(model.player.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(1)
                        .help(model.player.error ?? "")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReveal)
        .help(canReveal ? "Show this episode in its podcast (⌘L)" : "")
        .accessibilityLabel(model.player.episode.map { "Now playing: \($0.title)" } ?? "Nothing playing")
    }
}

struct TransportButtons: View {
    @Environment(AppModel.self) private var model
    var playSize: CGFloat
    var skipSize: CGFloat

    private var player: Player { model.player }
    private var skip: Int { Int(player.skipInterval) }

    var body: some View {
        HStack(spacing: 18) {
            Button("Back \(skip) Seconds", systemImage: "gobackward.\(skip)") { player.skipBackward() }
                .font(.system(size: skipSize))
                .help("Back \(skip) seconds (⌥⌘←)")

            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                player.togglePlayPause()
            }
            .font(.system(size: playSize))
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")

            Button("Forward \(skip) Seconds", systemImage: "goforward.\(skip)") { player.skipForward() }
                .font(.system(size: skipSize))
                .help("Forward \(skip) seconds (⌥⌘→)")
        }
        .labelStyle(.iconOnly)
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
    private var knowsDuration: Bool { player.duration > 0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeText.format(shown))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .accessibilityLabel("Elapsed \(TimeText.spoken(shown))")

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
            .disabled(!player.hasItem || !knowsDuration)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeText.spoken(shown))

            Text(knowsDuration ? "-" + TimeText.format(player.duration - shown) : "--:--")
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
                .accessibilityLabel(knowsDuration ? "Remaining \(TimeText.spoken(player.duration - shown))" : "Duration unknown")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}

struct ChapterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.player.chapters.isEmpty {
            Menu {
                ForEach(model.player.chapters) { chapter in
                    Button {
                        model.player.seek(to: chapter.start)
                    } label: {
                        if chapter == model.player.currentChapter {
                            Label("\(TimeText.format(chapter.start))  \(chapter.title)", systemImage: "checkmark")
                        } else {
                            Text("\(TimeText.format(chapter.start))  \(chapter.title)")
                        }
                    }
                }
            } label: {
                Label("Chapters", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chapters")
        }
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
                .frame(width: 48)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Playback speed, \(TimeText.rate(model.player.rate))")
    }
}

/// App volume plus the system AirPlay / output-device picker.
struct VolumeControl: View {
    @Environment(AppModel.self) private var model
    var showsSlider: Bool

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 6) {
            if showsSlider {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 80)
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
                    .help("Volume")
            }
            RoutePicker()
                .frame(width: 24, height: 24)
                .help("AirPlay and audio output")
        }
    }
}

/// `AVRoutePickerView`: the same output/AirPlay picker Music.app uses.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setAccessibilityLabel("AirPlay and audio output")
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct SleepTimerBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.player.sleepTimer {
        case .off:
            EmptyView()
        case .endOfEpisode:
            Label("Sleep: end of episode", systemImage: "moon.zzz.fill")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
                .help("Sleep timer: pauses at the end of this episode")
        case .minutes:
            if let ends = model.player.sleepTimerEnds {
                Label {
                    Text(ends, style: .timer).monospacedDigit()
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                }
                .font(.caption).foregroundStyle(.secondary)
                .help("Sleep timer")
            }
        }
    }
}

enum TimeText {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1 hour, 2 minutes" — for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0 seconds" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .full
        return f.string(from: seconds) ?? "0 seconds"
    }

    /// "1×", "1.25×", "0.75×" — never "1.2×".
    static func rate(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.4g×", rate)
    }

    /// Episode length for lists: "1h 2m", "45 min".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600 + 30) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1)) min"
    }
}
