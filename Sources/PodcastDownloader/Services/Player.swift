import AppKit
import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// A chapter marker read from the file's metadata (ID3 CHAP / MP4 chapter track).
struct Chapter: Identifiable, Hashable {
    var id: Double { start }
    let title: String
    let start: Double
}

/// Built-in audio player backed by AVPlayer. One instance lives on AppModel.
@MainActor
@Observable
final class Player {
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// How far the skip buttons (and media keys) jump, in seconds. Set from Settings.
    var skipInterval: Double = 10 {
        didSet {
            let center = MPRemoteCommandCenter.shared()
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        }
    }

    private(set) var episode: Episode?
    private(set) var podcast: Podcast?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var chapters: [Chapter] = []
    /// Why the current episode can't be played, if AVFoundation rejected the file.
    private(set) var error: String?

    var rate: Float = 1.0 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
            if rate != oldValue { onRateChange?(rate) }
        }
    }

    /// 0…1. AVPlayer's own volume, independent of the system volume.
    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

    var hasItem: Bool { episode != nil }
    var currentChapter: Chapter? { chapters.last { $0.start <= currentTime + 0.5 } }

    /// Called ~every 30s and on pause/stop so the resume position can be saved.
    var onPositionUpdate: ((Episode, Double) -> Void)?
    /// Called when an episode plays to the end.
    var onFinished: ((Episode) -> Void)?
    /// Called when the user picks a different speed (persisted by the owner).
    var onRateChange: ((Float) -> Void)?
    /// Next/previous-track media keys (AirPods double/triple tap, keyboards).
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    /// Loads artwork for Now Playing; nil means none is shown.
    var artworkProvider: ((URL) async -> NSImage?)?

    // MARK: Sleep timer

    enum SleepTimer: Hashable {
        case off
        case minutes(Int)
        case endOfEpisode
    }
    private(set) var sleepTimer: SleepTimer = .off
    /// When a minutes-based timer fires, if one is running.
    private(set) var sleepTimerEnds: Date?
    private var sleepTask: Task<Void, Never>?

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnds = nil
        sleepTimer = timer
        guard case .minutes(let minutes) = timer else { return }
        let ends = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnds = ends
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            pause()
            setSleepTimer(.off)
        }
    }

    // MARK: Internals

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var lastPersistedAt = Date.distantPast
    /// Set when the current item played to the end; cleared by any seek or new load.
    private var didFinish = false
    /// Bumped by every play()/stop() so the async load of a superseded item
    /// can't write its duration or seek into the item that replaced it.
    private var loadGeneration = 0
    private let controlsNowPlaying: Bool

    /// - Parameter controlsNowPlaying: false in tests, so they don't take over
    ///   the Mac's Now Playing / media keys.
    init(controlsNowPlaying: Bool = true) {
        self.controlsNowPlaying = controlsNowPlaying
        player.defaultRate = rate
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        if controlsNowPlaying {
            configureRemoteCommands()
            // Elapsed time in Control Center is only pushed on state changes;
            // after sleep it would show the pre-sleep position.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
        }
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
        // Spoken word at 1.5–2× sounds far better with the time-domain algorithm.
        item.audioTimePitchAlgorithm = .timeDomain
        self.episode = episode
        self.podcast = podcast
        duration = 0
        currentTime = startAt
        chapters = []
        didFinish = false
        error = nil
        artwork = nil
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
            if case .endOfEpisode = sleepTimer { } else if case .minutes = sleepTimer { } else { sleepTimer = .off }
            await loadChapters(from: item.asset, generation: generation)
            await loadArtwork(for: podcast, generation: generation)
        }
    }

    private func loadChapters(from asset: AVAsset, generation: Int) async {
        guard let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty,
              let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages),
              generation == loadGeneration else { return }
        var found: [Chapter] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            guard start.isFinite else { continue }
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = (try? await titleItem?.load(.stringValue)) ?? nil
            found.append(Chapter(title: title ?? "Chapter \(found.count + 1)", start: start))
        }
        guard generation == loadGeneration else { return }
        chapters = found.sorted { $0.start < $1.start }
    }

    private var artwork: NSImage?

    private func loadArtwork(for podcast: Podcast, generation: Int) async {
        guard controlsNowPlaying, let url = podcast.artworkURL, let provider = artworkProvider else { return }
        let image = await provider(url)
        guard generation == loadGeneration, let image else { return }
        artwork = image
        updateNowPlaying()
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
        if controlsNowPlaying { MPNowPlayingInfoCenter.default().playbackState = .stopped }
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

    func skipForward() { seek(to: currentTime + skipInterval) }
    func skipBackward() { seek(to: currentTime - skipInterval) }

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
        chapters = []
        didFinish = false
        error = nil
        artwork = nil
        if controlsNowPlaying {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    // MARK: Internals

    private func tick(_ time: CMTime) {
        guard episode != nil, time.seconds.isFinite else { return }
        currentTime = time.seconds
        if isPlaying, Date().timeIntervalSince(lastPersistedAt) > 30 {
            persistPosition(force: false)
            updateNowPlaying()      // keep Control Center's elapsed time honest
        }
    }

    private func didReachEnd() {
        isPlaying = false
        currentTime = duration
        didFinish = true
        let finished = episode
        if case .endOfEpisode = sleepTimer {
            setSleepTimer(.off)
            updateNowPlaying()
            if let finished { onFinished?(finished) }
            return
        }
        updateNowPlaying()
        if let finished {
            onFinished?(finished)
        }
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
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNextTrack?() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPreviousTrack?() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }; return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.rate = e.playbackRate }; return .success
        }
    }

    private func updateNowPlaying() {
        guard controlsNowPlaying else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let episode else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: podcast?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        if let chapter = currentChapter {
            info[MPMediaItemPropertyAlbumTitle] = chapter.title
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
