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
    }
    private static let currentVersion = 2

    private(set) var podcasts: [Podcast] = []
    private(set) var episodes: [String: [Episode]] = [:]     // podcast id -> episodes, newest first
    private(set) var downloaded: [String: String] = [:] {   // episode key -> path relative to master folder
        didSet { downloadedOwners = Dictionary(downloaded.map { ($1, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    private var downloadedOwners: [String: String] = [:]     // relative path -> episode key
    private(set) var lastRefreshed: [String: Date] = [:]     // podcast id -> date
    private(set) var playbackPositions: [String: Double] = [:] // episode key -> seconds listened to
    private(set) var lastFullRefresh: Date?                    // when every subscription was last refreshed together
    private(set) var refreshing: Set<String> = []
    var refreshErrors: [String: String] = [:]                // podcast id -> last error
    /// Set when library.json existed but couldn't be read; the file was kept aside.
    private(set) var loadError: String?

    /// Fetches a feed. Replaceable so refresh logic can be tested without a network.
    var loadFeed: (URL) async throws -> ParsedFeed = FeedLoader.load

    private let fileURL: URL
    private var didBackUpThisSession = false

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
    /// Episodes without a publish date sort last.
    func latestEpisodes(limit: Int = 100) -> [EpisodeRef] {
        podcasts
            .flatMap { podcast in episodes(for: podcast).map { EpisodeRef(episode: $0, podcast: podcast) } }
            .sorted { a, b in
                switch (a.episode.publishedAt, b.episode.publishedAt) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.episode.title < b.episode.title
                }
            }
            .prefix(limit)
            .map { $0 }
    }

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
        episodes[podcast.id] = nil
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
                feed.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) },
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

    private func save() {
        let snap = Snapshot(
            version: Self.currentVersion,
            podcasts: podcasts,
            episodes: episodes.filter { key, _ in podcasts.contains { $0.id == key } },
            downloaded: downloaded,
            lastRefreshed: lastRefreshed,
            playbackPositions: playbackPositions,
            lastFullRefresh: lastFullRefresh
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            backUpOncePerSession()
            let data = try encoder.encode(snap)
            try data.write(to: fileURL, options: .atomic)
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
