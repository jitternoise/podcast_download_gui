import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Built-in audio player backed by AVPlayer. One instance lives on AppModel.
@MainActor
@Observable
final class Player {
    /// How far the skip buttons (and media keys) jump, in seconds.
    static let skipInterval: Double = 10
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    private(set) var episode: Episode?
    private(set) var podcast: Podcast?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Why the current episode can't be played, if AVFoundation rejected the file.
    private(set) var error: String?
    var rate: Float = 1.0 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    var hasItem: Bool { episode != nil }
    var remaining: Double { max(0, duration - currentTime) }

    /// Called ~every 30s and on pause/stop so the resume position can be saved.
    var onPositionUpdate: ((Episode, Double) -> Void)?
    /// Called when an episode plays to the end.
    var onFinished: ((Episode) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var lastPersistedAt = Date.distantPast
    /// Set when the current item played to the end; cleared by any seek or new load.
    private var didFinish = false
    /// Bumped by every play()/stop() so the async load of a superseded item
    /// can't write its duration or seek into the item that replaced it.
    private var loadGeneration = 0

    init() {
        player.defaultRate = rate
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        configureRemoteCommands()
    }

    // MARK: Loading

    /// Starts playing a local file, resuming from `startAt` if given.
    func play(_ episode: Episode, from podcast: Podcast, file: URL, startAt: Double = 0) {
        if self.episode?.key == episode.key, error == nil {
            resume()
            return
        }
        persistPosition(force: true)

        let item = AVPlayerItem(url: file)
        self.episode = episode
        self.podcast = podcast
        duration = 0
        currentTime = startAt
        didFinish = false
        error = nil
        loadGeneration += 1
        let generation = loadGeneration

        observe(item)
        player.replaceCurrentItem(with: item)
        Task {
            do {
                let seconds = try await item.asset.load(.duration).seconds
                guard generation == loadGeneration else { return }   // superseded meanwhile
                if seconds.isFinite { duration = seconds }
            } catch {
                guard generation == loadGeneration else { return }
                fail("Can't play this file: \(error.localizedDescription)")
                return
            }
            if startAt > 0 {
                await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                guard generation == loadGeneration else { return }
            }
            resume()
        }
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        if let endObserver { center.removeObserver(endObserver) }
        if let failObserver { center.removeObserver(failObserver) }
        endObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didReachEnd() }
        }
        failObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in self?.fail("Playback stopped: \(reason ?? "unknown error")") }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "unknown error"
            Task { @MainActor in self?.fail("Can't play this file: \(reason)") }
        }
    }

    /// The current item is unplayable: keep it loaded so the message has
    /// context, but stop pretending to play.
    private func fail(_ message: String) {
        guard episode != nil, error == nil else { return }
        player.pause()
        isPlaying = false
        error = message
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard episode != nil, error == nil else { return }
        // AVPlayer sits at the end after finishing; play() alone does nothing.
        if didFinish { seek(to: 0) }
        player.play()          // honours defaultRate
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition(force: true)
        updateNowPlaying()
    }

    func skipForward() { seek(to: currentTime + Self.skipInterval) }
    func skipBackward() { seek(to: currentTime - Self.skipInterval) }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        didFinish = false
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func stop() {
        pause()
        loadGeneration += 1
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        episode = nil
        podcast = nil
        currentTime = 0
        duration = 0
        didFinish = false
        error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: Internals

    private func tick(_ time: CMTime) {
        guard episode != nil, time.seconds.isFinite else { return }
        currentTime = time.seconds
        if isPlaying, Date().timeIntervalSince(lastPersistedAt) > 30 {
            persistPosition(force: false)
        }
    }

    private func didReachEnd() {
        isPlaying = false
        currentTime = duration
        didFinish = true
        if let episode {
            onFinished?(episode)
        }
        updateNowPlaying()
    }

    /// Writes the resume point now. Called on quit; otherwise every ~30 s and on pause.
    func flushPosition() {
        persistPosition(force: true)
    }

    private func persistPosition(force: Bool) {
        guard let episode else { return }
        lastPersistedAt = Date()
        // A finished episode starts over next time, whatever currentTime says.
        onPositionUpdate?(episode, didFinish ? 0 : currentTime)
    }

    // MARK: Now Playing / media keys

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }; return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let episode else {
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: podcast?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }
}
