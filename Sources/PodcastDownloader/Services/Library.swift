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
        var podcasts: [Podcast]
        var episodes: [String: [Episode]]
        var downloaded: [String: String]
        var lastRefreshed: [String: Date]
        var playbackPositions: [String: Double]?
        var lastFullRefresh: Date?
    }

    private(set) var podcasts: [Podcast] = []
    private(set) var episodes: [String: [Episode]] = [:]     // podcast id -> episodes, newest first
    private(set) var downloaded: [String: String] = [:]      // episode id -> path relative to master folder
    private(set) var lastRefreshed: [String: Date] = [:]     // podcast id -> date
    private(set) var playbackPositions: [String: Double] = [:] // episode id -> seconds listened to
    private(set) var lastFullRefresh: Date?                    // when every subscription was last refreshed together
    private(set) var refreshing: Set<String> = []
    var refreshErrors: [String: String] = [:]                // podcast id -> last error

    private let fileURL: URL

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
        downloaded[episode.id]
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
        downloaded[episode.id] = relativePath
        save()
    }

    func markFullRefresh(at date: Date = Date()) {
        lastFullRefresh = date
        save()
    }

    func playbackPosition(for episode: Episode) -> Double {
        playbackPositions[episode.id] ?? 0
    }

    func setPlaybackPosition(_ seconds: Double, for episode: Episode) {
        playbackPositions[episode.id] = seconds > 0 ? seconds : nil
        save()
    }

    func forgetDownload(_ episode: Episode) {
        downloaded[episode.id] = nil
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
        episodes[podcast.id] = list
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
            let feed = try await FeedLoader.load(podcast.feedURL)
            let sorted = feed.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            let previousIDs = Set((episodes[podcast.id] ?? []).map(\.id))
            let hadPrevious = lastRefreshed[podcast.id] != nil
            let newEpisodes = hadPrevious ? sorted.filter { !previousIDs.contains($0.id) } : []

            episodes[podcast.id] = sorted
            refreshErrors[podcast.id] = nil

            if isSubscribed(podcast) {
                var updated = podcast
                if !feed.title.isEmpty { updated.title = feed.title }
                if !feed.author.isEmpty { updated.author = feed.author }
                if !feed.summary.isEmpty { updated.summary = feed.summary }
                if updated.artworkURL == nil { updated.artworkURL = feed.artworkURL }
                if let idx = podcasts.firstIndex(where: { $0.id == podcast.id }) { podcasts[idx] = updated }
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return }
        podcasts = snap.podcasts
        episodes = snap.episodes
        downloaded = snap.downloaded
        lastRefreshed = snap.lastRefreshed
        playbackPositions = snap.playbackPositions ?? [:]
        lastFullRefresh = snap.lastFullRefresh
    }

    private func save() {
        let snap = Snapshot(
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
            let data = try encoder.encode(snap)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Failed to save library: \(error)")
        }
    }
}
