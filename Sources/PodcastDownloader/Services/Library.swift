import Foundation
import Observation

/// An episode together with the podcast it belongs to.
struct EpisodeRef: Identifiable, Hashable {
    let episode: Episode
    let podcast: Podcast
    var id: String { podcast.id + "|" + episode.id }
}

/// Subscriptions, cached episodes, and the record of what has been downloaded.
/// Persisted as a single JSON file in ~/Library/Application Support.
///
/// Download locations are stored *relative to the master folder* so the whole
/// library can be moved by simply pointing the app at a new folder.
@MainActor
@Observable
final class Library {
    private struct Snapshot: Codable {
        /// 1 (or absent): per-episode maps keyed by guid. 2: keyed by `Episode.key`.
        var version: Int?
        var podcasts: [Podcast]
        var episodes: [String: [Episode]]
        var downloaded: [String: String]
        var lastRefreshed: [String: Date]
        var playbackPositions: [String: Double]?
        var lastFullRefresh: Date?
        var played: [String]?
    }
    private static let currentVersion = 2

    private(set) var podcasts: [Podcast] = [] {
        didSet { latestCache = nil }
    }
    private(set) var episodes: [String: [Episode]] = [:] {  // podcast id -> episodes, newest first
        didSet { latestCache = nil }
    }
    private var latestCache: [EpisodeRef]?
    private(set) var downloaded: [String: String] = [:] {   // episode key -> path relative to master folder
        didSet { downloadedOwners = Dictionary(downloaded.map { ($1, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    private var downloadedOwners: [String: String] = [:]     // relative path -> episode key
    private(set) var lastRefreshed: [String: Date] = [:]     // podcast id -> date
    private(set) var playbackPositions: [String: Double] = [:] // episode key -> seconds listened to
    private(set) var lastFullRefresh: Date?                    // when every subscription was last refreshed together
    private(set) var played: Set<String> = []                  // episode keys played to the end (or marked)
    private(set) var refreshing: Set<String> = []
    var refreshErrors: [String: String] = [:]                // podcast id -> last error
    /// Set when library.json existed but couldn't be read; the file was kept aside.
    private(set) var loadError: String?

    /// Fetches a feed. Replaceable so refresh logic can be tested without a network.
    var loadFeed: (URL) async throws -> ParsedFeed = FeedLoader.load

    private let fileURL: URL
    private var didBackUpThisSession = false
    /// Pending write, coalesced so a burst of mutations (Refresh All, a
    /// playback tick) costs one encode on a background thread, not many on
    /// the main actor.
    private var saveTask: Task<Void, Never>?
    /// How long mutations are coalesced before hitting the disk.
    var saveDelay: Duration = .milliseconds(500)

    /// - Parameter fileURL: where to persist; defaults to Application Support. Tests pass a temp file.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PodcastDownloader", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("library.json")
        }
        load()
    }

    // MARK: Queries

    func isSubscribed(_ podcast: Podcast) -> Bool {
        podcasts.contains { $0.id == podcast.id }
    }

    func podcast(withID id: String) -> Podcast? {
        podcasts.first { $0.id == id }
    }

    func episodes(for podcast: Podcast) -> [Episode] {
        episodes[podcast.id] ?? []
    }

    /// The newest episodes across every subscription, newest first.
    /// Episodes without a publish date sort last. Sorted once per change,
    /// not once per view update.
    func latestEpisodes(limit: Int = 100) -> [EpisodeRef] {
        if let latestCache { return Array(latestCache.prefix(limit)) }
        let all = podcasts
            .flatMap { podcast in episodes(for: podcast).map { EpisodeRef(episode: $0, podcast: podcast) } }
            .sorted { a, b in
                switch (a.episode.publishedAt, b.episode.publishedAt) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.episode.title < b.episode.title
                }
            }
        latestCache = all
        return Array(all.prefix(limit))
    }

    /// Every episode across subscriptions; use `latestEpisodes` for the top of the list.
    var totalEpisodeCount: Int { podcasts.reduce(0) { $0 + episodes(for: $1).count } }

    /// Path relative to the master folder where this episode was saved, if known.
    func downloadedRelativePath(for episode: Episode) -> String? {
        downloaded[episode.key]
    }

    /// The episode recorded as having been saved to this master-relative path, if any.
    func episodeID(downloadedTo relativePath: String) -> String? {
        downloadedOwners[relativePath]
    }

    // MARK: Mutations

    func subscribe(_ podcast: Podcast) {
        guard !isSubscribed(podcast) else { return }
        podcasts.append(podcast)
        podcasts.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save()
    }

    func unsubscribe(_ podcast: Podcast) {
        podcasts.removeAll { $0.id == podcast.id }
        // The episode cache stays for the session so the detail view keeps
        // showing the show (and re-subscribing is instant); it is not persisted.
        lastRefreshed[podcast.id] = nil
        refreshErrors[podcast.id] = nil
        save()
    }

    func update(_ podcast: Podcast) {
        guard let idx = podcasts.firstIndex(where: { $0.id == podcast.id }) else { return }
        podcasts[idx] = podcast
        save()
    }

    func markDownloaded(_ episode: Episode, relativePath: String) {
        downloaded[episode.key] = relativePath
        save()
    }

    func markFullRefresh(at date: Date = Date()) {
        lastFullRefresh = date
        save()
    }

    func playbackPosition(for episode: Episode) -> Double {
        playbackPositions[episode.key] ?? 0
    }

    func setPlaybackPosition(_ seconds: Double, for episode: Episode) {
        playbackPositions[episode.key] = seconds > 0 ? seconds : nil
        save()
    }

    func forgetDownload(_ episode: Episode) {
        downloaded[episode.key] = nil
        save()
    }

    func isPlayed(_ episode: Episode) -> Bool { played.contains(episode.key) }

    func setPlayed(_ episode: Episode, _ value: Bool) {
        if value {
            played.insert(episode.key)
            playbackPositions[episode.key] = nil
        } else {
            played.remove(episode.key)
        }
        save()
    }

    /// Converts any absolute paths saved by earlier versions into master-relative ones.
    func migrateDownloadPaths(masterDirectory: URL) {
        let prefix = masterDirectory.standardizedFileURL.path + "/"
        var changed = false
        for (id, path) in downloaded where path.hasPrefix("/") {
            if path.hasPrefix(prefix) {
                downloaded[id] = String(path.dropFirst(prefix.count))
            } else {
                downloaded[id] = nil
            }
            changed = true
        }
        if changed { save() }
    }

    /// Cache episodes for a podcast the user is only previewing (not subscribed).
    func cacheEpisodes(_ list: [Episode], for podcast: Podcast) {
        episodes[podcast.id] = Self.stamp(list, with: podcast.id)
    }

    private static func stamp(_ list: [Episode], with podcastID: String) -> [Episode] {
        list.map { var e = $0; e.podcastID = podcastID; return e }
    }

    // MARK: Refresh

    /// Fetches the feed, updates metadata and the episode list, and returns the
    /// episodes that are new since the previous refresh.
    @discardableResult
    func refresh(_ podcast: Podcast) async -> [Episode] {
        guard !refreshing.contains(podcast.id) else { return [] }
        refreshing.insert(podcast.id)
        defer { refreshing.remove(podcast.id) }

        do {
            let feed = try await loadFeed(podcast.feedURL)
            let sorted = Self.stamp(
                feed.episodes.sorted(by: Episode.newestFirst),
                with: podcast.id
            )
            let previousIDs = Set((episodes[podcast.id] ?? []).map(\.id))
            let hadPrevious = lastRefreshed[podcast.id] != nil
            let newEpisodes = hadPrevious ? sorted.filter { !previousIDs.contains($0.id) } : []

            episodes[podcast.id] = sorted
            refreshErrors[podcast.id] = nil

            // Overlay the feed's metadata onto the *current* record, not the
            // value captured before the await: the user may have toggled
            // auto-download (or anything else) while the feed was loading.
            if let idx = podcasts.firstIndex(where: { $0.id == podcast.id }) {
                var updated = podcasts[idx]
                if !feed.title.isEmpty { updated.title = feed.title }
                if !feed.author.isEmpty { updated.author = feed.author }
                if !feed.summary.isEmpty { updated.summary = feed.summary }
                if updated.artworkURL == nil { updated.artworkURL = feed.artworkURL }
                podcasts[idx] = updated
                lastRefreshed[podcast.id] = Date()
                save()
            }
            return newEpisodes
        } catch is CancellationError {
            return []                       // navigated away; not a feed problem
        } catch let error as URLError where error.code == .cancelled {
            return []
        } catch {
            refreshErrors[podcast.id] = error.localizedDescription
            return []
        }
    }

    // MARK: Persistence

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap: Snapshot
        do {
            snap = try decoder.decode(Snapshot.self, from: try Data(contentsOf: fileURL))
        } catch {
            // Never let the next save() bury a file we couldn't read: keep it
            // aside under a name the user can find, and say so.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
            try? fm.moveItem(at: fileURL, to: aside)
            loadError = "The subscriptions file couldn't be read (\(error.localizedDescription)). It was kept as \(aside.lastPathComponent) and the app started with an empty library."
            NSLog("Failed to load library: \(error)")
            return
        }
        podcasts = snap.podcasts
        episodes = snap.episodes
        downloaded = snap.downloaded
        lastRefreshed = snap.lastRefreshed
        playbackPositions = snap.playbackPositions ?? [:]
        lastFullRefresh = snap.lastFullRefresh
        played = Set(snap.played ?? [])
        if (snap.version ?? 1) < 2 { migrateToCompositeKeys() }
    }

    /// v1 keyed downloads and positions by the feed's guid alone; stamp the
    /// cached episodes with their podcast and re-key under `Episode.key`.
    private func migrateToCompositeKeys() {
        for (podcastID, list) in episodes {
            let stamped = Self.stamp(list, with: podcastID)
            episodes[podcastID] = stamped
            for episode in stamped where episode.key != episode.id {
                if downloaded[episode.key] == nil, let path = downloaded.removeValue(forKey: episode.id) {
                    downloaded[episode.key] = path
                }
                if playbackPositions[episode.key] == nil, let pos = playbackPositions.removeValue(forKey: episode.id) {
                    playbackPositions[episode.key] = pos
                }
            }
        }
        save()
    }

    /// Schedules a write. Encoding and I/O happen off the main actor after a
    /// short delay so bursts collapse into one write; `flush()` forces it.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    /// Writes any pending changes now. Call before the process exits.
    func flush() async {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        await write()
    }

    /// Synchronous variant for app termination, where nothing can await.
    func flushNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        let snap = snapshot()
        let url = fileURL
        backUpOncePerSession()
        Self.write(snap, to: url)
    }

    private func write() async {
        let snap = snapshot()
        let url = fileURL
        backUpOncePerSession()
        await Task.detached(priority: .utility) { Self.write(snap, to: url) }.value
        saveTask = nil
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            version: Self.currentVersion,
            podcasts: podcasts,
            episodes: episodes.filter { key, _ in podcasts.contains { $0.id == key } },
            downloaded: downloaded,
            lastRefreshed: lastRefreshed,
            playbackPositions: playbackPositions,
            lastFullRefresh: lastFullRefresh,
            played: Array(played).sorted()
        )
    }

    private nonisolated static func write(_ snap: Snapshot, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(snap)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Failed to save library: \(error)")
        }
    }

    /// Keeps last session's file as library.json.bak before this session first overwrites it.
    private func backUpOncePerSession() {
        guard !didBackUpThisSession else { return }
        didBackUpThisSession = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let bak = fileURL.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: fileURL, to: bak)
    }
}
