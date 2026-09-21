import CryptoKit
import Foundation
import Observation

/// An episode together with the podcast it belongs to.
struct EpisodeRef: Identifiable, Hashable {
    let episode: Episode
    let podcast: Podcast
    var id: String { podcast.id + "|" + episode.id }
}

/// Where one downloaded episode was stored, as recorded when the transfer
/// completed. The size and checksum let "Verify Library" tell a file that
/// changed or was cut short from one that is exactly what was fetched.
struct DownloadRecord: Codable, Hashable {
    /// Relative to the master folder.
    var path: String
    var size: Int64?
    var sha256: String?

    init(path: String, size: Int64? = nil, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    /// Library versions before 3 stored just the path.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let path = try? single.decode(String.self) {
            self.path = path
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    }
}

/// Subscriptions, cached episodes, and the record of what has been downloaded.
///
/// Persisted in ~/Library/Application Support as `library.json` (the
/// subscriptions) plus one `shows/<id>.json` per subscription holding its
/// episodes and per-episode state. A playback tick or a refresh rewrites one
/// show's file, not the whole library, so the size of the library doesn't set
/// the cost of a save. Show notes as the feed published them (HTML) live in
/// `notes/<id>.json` and are only read when an episode's notes are opened.
///
/// Download locations are stored *relative to the master folder* so the whole
/// library can be moved by simply pointing the app at a new folder.
@MainActor
@Observable
final class Library {
    /// `library.json`. Per-episode state here belongs to no current
    /// subscription: files played from the Downloads tab, shows since
    /// unsubscribed. Versions 1 and 2 held every show's episodes as well.
    private struct Index: Codable {
        /// 1 (or absent): per-episode maps keyed by guid. 2: keyed by
        /// `Episode.key`. 3: episodes and per-show state in `shows/`.
        var version: Int?
        var podcasts: [Podcast]
        var lastFullRefresh: Date?
        var downloaded: [String: DownloadRecord]?
        var playbackPositions: [String: Double]?
        var played: [String]?
        // Versions 1 and 2 only.
        var episodes: [String: [Episode]]?
        var lastRefreshed: [String: Date]?
    }

    /// `shows/<id>.json`: everything about one subscription.
    private struct ShowFile: Codable {
        var podcastID: String
        var episodes: [Episode]
        var downloaded: [String: DownloadRecord]
        var playbackPositions: [String: Double]
        var played: [String]
        var lastRefreshed: Date?
    }
    nonisolated private static let currentVersion = 3

    private(set) var podcasts: [Podcast] = [] {
        didSet { latestCache = nil }
    }
    private(set) var episodes: [String: [Episode]] = [:] {  // podcast id -> episodes, newest first
        didSet { latestCache = nil }
    }
    private var latestCache: (limit: Int, items: [EpisodeRef])?
    private(set) var downloaded: [String: DownloadRecord] = [:] {   // episode key -> where it was saved
        didSet { downloadedOwners = Dictionary(downloaded.map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    private var downloadedOwners: [String: String] = [:]     // relative path -> episode key
    private(set) var lastRefreshed: [String: Date] = [:]     // podcast id -> date
    private(set) var playbackPositions: [String: Double] = [:] // episode key -> seconds listened to
    private(set) var lastFullRefresh: Date?                    // when every subscription was last refreshed together
    private(set) var played: Set<String> = []                  // episode keys played to the end (or marked)
    private(set) var refreshing: Set<String> = []
    var refreshErrors: [String: String] = [:]                // podcast id -> last error
    /// Set when a library file existed but couldn't be read; the file was kept aside.
    private(set) var loadError: String?

    /// Fetches a feed. Replaceable so refresh logic can be tested without a network.
    var loadFeed: (URL) async throws -> ParsedFeed = FeedLoader.load

    private let fileURL: URL
    private var didBackUpThisSession = false

    // What must be written: the index, and which shows. Decided per mutation
    // so a position tick touches one file.
    private var dirtyIndex = false
    private var dirtyShows: Set<String> = []
    private var removedShows: Set<String> = []
    /// HTML show notes from the latest refresh of a subscribed show, until
    /// they have been written to `notes/`.
    private var pendingNotes: [String: [String: String]] = [:]
    /// Notes read from disk (or fetched for a show that isn't subscribed),
    /// a few shows at a time so opening notes doesn't grow the app.
    private var notesCache: [String: [String: String]] = [:]
    private var notesCacheOrder: [String] = []
    private static let notesCacheLimit = 3

    /// Pending write, coalesced so a burst of mutations (Refresh All, a
    /// playback tick) costs one encode on a background thread, not many on
    /// the main actor.
    private var saveTask: Task<Void, Never>?
    /// How long mutations are coalesced before hitting the disk.
    var saveDelay: Duration = .milliseconds(500)
    /// All writes go through one serial queue: they land in the order they
    /// were taken, and a synchronous flush waits for whatever is in flight.
    private static let writeQueue = DispatchQueue(label: "PodcastDownloader.library-write", qos: .utility)

    /// - Parameter fileURL: where to persist; defaults to Application Support.
    ///   Tests pass a file in a temp folder of their own — `shows/` and
    ///   `notes/` are created next to it.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let sandbox = Sandbox.dataDirectory {
            self.fileURL = sandbox.appendingPathComponent("library.json")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PodcastDownloader", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("library.json")
        }
        load()
    }

    private var directory: URL { fileURL.deletingLastPathComponent() }
    private var showsDirectory: URL { directory.appendingPathComponent("shows", isDirectory: true) }
    private var notesDirectory: URL { directory.appendingPathComponent("notes", isDirectory: true) }

    /// `shows/` and `notes/` file name for a podcast: a hash of the feed URL,
    /// which is stable, unique, and safe on every file system.
    nonisolated static func fileName(for podcastID: String) -> String {
        SHA256.hash(data: Data(podcastID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// The podcast an episode key belongs to (`Episode.key` is `podcastID|id`).
    nonisolated private static func owner(of key: String) -> Substring {
        key.prefix { $0 != "|" }
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

    /// The cached episode behind a per-episode key, with its podcast.
    func episodeRef(forKey key: String) -> EpisodeRef? {
        guard let podcast = podcast(withID: String(Self.owner(of: key))),
              let episode = episodes(for: podcast).first(where: { $0.key == key }) else { return nil }
        return EpisodeRef(episode: episode, podcast: podcast)
    }

    /// The newest episodes across every subscription, newest first.
    /// Episodes without a publish date sort last. Sorted once per change,
    /// not once per view update — and only as much as needed: each show's
    /// list is already newest first, so the newest `limit` overall are among
    /// the newest `limit` of each show.
    func latestEpisodes(limit: Int = 100) -> [EpisodeRef] {
        if let latestCache, latestCache.limit >= limit { return Array(latestCache.items.prefix(limit)) }
        let top = podcasts
            .flatMap { podcast in episodes(for: podcast).prefix(limit).map { EpisodeRef(episode: $0, podcast: podcast) } }
            .sorted { a, b in
                switch (a.episode.publishedAt, b.episode.publishedAt) {
                case let (x?, y?): return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.episode.title < b.episode.title
                }
            }
            .prefix(limit)
        latestCache = (limit, Array(top))
        return Array(top)
    }

    /// Every episode across subscriptions; use `latestEpisodes` for the top of the list.
    var totalEpisodeCount: Int { podcasts.reduce(0) { $0 + episodes(for: $1).count } }

    /// Path relative to the master folder where this episode was saved, if known.
    func downloadedRelativePath(for episode: Episode) -> String? {
        downloaded[episode.key]?.path
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
        // Its state (if it was subscribed before) moves out of the index
        // into its own file; notes fetched while previewing get written.
        removedShows.remove(podcast.id)
        if let notes = notesCache.removeValue(forKey: podcast.id) {
            notesCacheOrder.removeAll { $0 == podcast.id }
            pendingNotes[podcast.id] = notes
        }
        dirtyIndex = true
        save(show: podcast.id)
    }

    func unsubscribe(_ podcast: Podcast) {
        podcasts.removeAll { $0.id == podcast.id }
        // The episode cache stays for the session so the detail view keeps
        // showing the show (and re-subscribing is instant); it is not persisted.
        // Downloads, positions and played marks are kept in the index.
        lastRefreshed[podcast.id] = nil
        refreshErrors[podcast.id] = nil
        dirtyShows.remove(podcast.id)
        removedShows.insert(podcast.id)
        pendingNotes[podcast.id] = nil
        saveIndex()
    }

    func update(_ podcast: Podcast) {
        guard let idx = podcasts.firstIndex(where: { $0.id == podcast.id }) else { return }
        podcasts[idx] = podcast
        saveIndex()
    }

    func markDownloaded(_ episode: Episode, relativePath: String, size: Int64? = nil, sha256: String? = nil) {
        downloaded[episode.key] = DownloadRecord(path: relativePath, size: size, sha256: sha256)
        save(for: episode)
    }

    /// Records the size/checksum "Verify Library" measured for a download that
    /// had none on record (from before checksums were kept).
    func setDownloadBaseline(size: Int64?, sha256: String?, forKey key: String) {
        guard var record = downloaded[key] else { return }
        if let size { record.size = size }
        if let sha256 { record.sha256 = sha256 }
        downloaded[key] = record
        save(show: String(Self.owner(of: key)))
    }

    func markFullRefresh(at date: Date = Date()) {
        lastFullRefresh = date
        saveIndex()
    }

    func playbackPosition(for episode: Episode) -> Double {
        playbackPositions[episode.key] ?? 0
    }

    func setPlaybackPosition(_ seconds: Double, for episode: Episode) {
        playbackPositions[episode.key] = seconds > 0 ? seconds : nil
        save(for: episode)
    }

    func forgetDownload(_ episode: Episode) {
        downloaded[episode.key] = nil
        save(for: episode)
    }

    func isPlayed(_ episode: Episode) -> Bool { played.contains(episode.key) }

    func setPlayed(_ episode: Episode, _ value: Bool) {
        if value {
            played.insert(episode.key)
            playbackPositions[episode.key] = nil
        } else {
            played.remove(episode.key)
        }
        save(for: episode)
    }

    /// Converts any absolute paths saved by earlier versions into master-relative ones.
    func migrateDownloadPaths(masterDirectory: URL) {
        let prefix = masterDirectory.standardizedFileURL.path + "/"
        for (key, record) in downloaded where record.path.hasPrefix("/") {
            if record.path.hasPrefix(prefix) {
                var updated = record
                updated.path = String(record.path.dropFirst(prefix.count))
                downloaded[key] = updated
            } else {
                downloaded[key] = nil
            }
            save(show: String(Self.owner(of: key)))
        }
    }

    /// Cache episodes for a podcast the user is only previewing (not subscribed).
    /// Lists are always kept newest first (`latestEpisodes` relies on it).
    func cacheEpisodes(_ list: [Episode], for podcast: Podcast, notes: [String: String] = [:]) {
        episodes[podcast.id] = Self.stamp(list.sorted(by: Episode.newestFirst), with: podcast.id)
        storeNotes(notes, for: podcast.id)
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
            storeNotes(feed.notesHTML, for: podcast.id)
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
                dirtyIndex = true
                save(show: podcast.id)
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

    // MARK: Show notes

    /// The episode's show notes as the feed published them (HTML), when they
    /// carry more than the plain-text `summary`. Read from disk on demand.
    func notesHTML(for episode: Episode) async -> String? {
        guard let podcastID = episode.podcastID else { return nil }
        if let notes = pendingNotes[podcastID] ?? notesCache[podcastID] { return notes[episode.id] }
        guard podcast(withID: podcastID) != nil else { return nil }
        let url = notesDirectory.appendingPathComponent(Self.fileName(for: podcastID))
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        }.value
        // A refresh may have landed meanwhile; its notes take precedence.
        if let fresh = pendingNotes[podcastID] { return fresh[episode.id] }
        cacheNotes(loaded, for: podcastID)
        return loaded[episode.id]
    }

    /// New notes for a show: queued for the show's next write when subscribed,
    /// otherwise kept in memory for the session (a previewed show).
    private func storeNotes(_ notes: [String: String], for podcastID: String) {
        notesCache[podcastID] = nil
        notesCacheOrder.removeAll { $0 == podcastID }
        if podcast(withID: podcastID) != nil {
            pendingNotes[podcastID] = notes
        } else if !notes.isEmpty {
            cacheNotes(notes, for: podcastID)
        }
    }

    private func cacheNotes(_ notes: [String: String], for podcastID: String) {
        notesCache[podcastID] = notes
        notesCacheOrder.removeAll { $0 == podcastID }
        notesCacheOrder.append(podcastID)
        while notesCacheOrder.count > Self.notesCacheLimit {
            notesCache[notesCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: Persistence

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let index: Index
        do {
            index = try Self.decoder().decode(Index.self, from: try Data(contentsOf: fileURL))
        } catch {
            // Never let the next save() bury a file we couldn't read: keep it
            // aside under a name the user can find, and say so.
            let aside = Self.setAside(fileURL)
            loadError = "The subscriptions file couldn't be read (\(error.localizedDescription)). It was kept as \(aside) and the app started with an empty library."
            NSLog("Failed to load library: \(error)")
            return
        }
        podcasts = index.podcasts
        lastFullRefresh = index.lastFullRefresh
        downloaded = index.downloaded ?? [:]
        playbackPositions = index.playbackPositions ?? [:]
        played = Set(index.played ?? [])

        let version = index.version ?? 1
        if version < Self.currentVersion {
            // One file held everything: take the episodes from it and write
            // the split layout. library.json.bak keeps the old file.
            episodes = (index.episodes ?? [:]).reduce(into: [:]) { $0[$1.key] = Self.stamp($1.value, with: $1.key) }
            lastRefreshed = index.lastRefreshed ?? [:]
            if version < 2 { migrateToCompositeKeys() }
            dirtyIndex = true
            dirtyShows = Set(podcasts.map(\.id))
            scheduleWrite()
        } else {
            loadShows()
        }
    }

    /// Reads every subscription's `shows/` file, in parallel: decoding is the
    /// cost of launch, and it splits evenly across cores.
    private func loadShows() {
        let entries = podcasts.map { ($0, showsDirectory.appendingPathComponent(Self.fileName(for: $0.id))) }
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var shows: [ShowFile] = []
            var problems: [String] = []
        }
        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            let (podcast, url) = entries[i]
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let show = try Self.decoder().decode(ShowFile.self, from: try Data(contentsOf: url))
                collector.lock.withLock { collector.shows.append(show) }
            } catch {
                let aside = Self.setAside(url)
                NSLog("Failed to load episodes for \(podcast.title): \(error)")
                collector.lock.withLock {
                    collector.problems.append("“\(podcast.title)” (kept as shows/\(aside); it will be rebuilt by the next refresh)")
                }
            }
        }
        // Build the maps once and assign once: `downloaded`'s observer
        // re-indexes the whole map on every assignment.
        var allEpisodes = episodes, allDownloaded = downloaded, allPositions = playbackPositions
        var allPlayed = played, allRefreshed = lastRefreshed
        for show in collector.shows {
            allEpisodes[show.podcastID] = Self.stamp(show.episodes, with: show.podcastID)
            allDownloaded.merge(show.downloaded) { _, new in new }
            allPositions.merge(show.playbackPositions) { _, new in new }
            allPlayed.formUnion(show.played)
            allRefreshed[show.podcastID] = show.lastRefreshed
        }
        episodes = allEpisodes
        downloaded = allDownloaded
        playbackPositions = allPositions
        played = allPlayed
        lastRefreshed = allRefreshed
        if !collector.problems.isEmpty {
            loadError = "The episode list couldn't be read for " + collector.problems.sorted().joined(separator: ", ") + "."
        }
    }

    /// Moves an unreadable file out of the way; returns the new name.
    nonisolated private static func setAside(_ url: URL) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: aside)
        return aside.lastPathComponent
    }

    /// v1 keyed downloads and positions by the feed's guid alone; stamp the
    /// cached episodes with their podcast and re-key under `Episode.key`.
    private func migrateToCompositeKeys() {
        for (podcastID, list) in episodes {
            let stamped = Self.stamp(list, with: podcastID)
            episodes[podcastID] = stamped
            for episode in stamped where episode.key != episode.id {
                if downloaded[episode.key] == nil, let record = downloaded.removeValue(forKey: episode.id) {
                    downloaded[episode.key] = record
                }
                if playbackPositions[episode.key] == nil, let pos = playbackPositions.removeValue(forKey: episode.id) {
                    playbackPositions[episode.key] = pos
                }
            }
        }
    }

    /// State keyed by an episode belongs to its show's file when the show is
    /// subscribed, otherwise to the index.
    private func save(for episode: Episode) {
        save(show: episode.podcastID)
    }

    private func save(show id: String?) {
        if let id, podcast(withID: id) != nil {
            dirtyShows.insert(id)
        } else {
            dirtyIndex = true
        }
        scheduleWrite()
    }

    private func saveIndex() {
        dirtyIndex = true
        scheduleWrite()
    }

    /// Schedules a write. Encoding and I/O happen off the main actor after a
    /// short delay so bursts collapse into one write; `flush()` forces it.
    private func scheduleWrite() {
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
    /// Waits for any write already in flight, then lands this one.
    func flushNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        let plan = takePlan()
        Self.writeQueue.sync { Self.write(plan) }
        didWrite(plan)
    }

    private func write() async {
        let plan = takePlan()
        await withCheckedContinuation { continuation in
            Self.writeQueue.async {
                Self.write(plan)
                continuation.resume()
            }
        }
        didWrite(plan)
        if dirtyShows.isEmpty, !dirtyIndex, removedShows.isEmpty { saveTask = nil }
    }

    /// Everything the writer needs, taken on the main actor: copies of the
    /// maps (copy-on-write, so cheap) and which files are due. Splitting the
    /// maps per show happens on the writer's thread.
    private struct WritePlan: Sendable {
        var index: URL?
        var indexData: (podcasts: [Podcast], lastFullRefresh: Date?)
        var shows: [String: URL]            // podcast id -> file, for shows due a write
        var notes: [String: (URL, [String: String])]
        var remove: [URL]
        var subscribed: Set<String>
        var episodes: [String: [Episode]]
        var downloaded: [String: DownloadRecord]
        var playbackPositions: [String: Double]
        var played: Set<String>
        var lastRefreshed: [String: Date]
    }

    private func takePlan() -> WritePlan {
        backUpOncePerSession()
        var plan = WritePlan(
            index: dirtyIndex ? fileURL : nil,
            indexData: (podcasts, lastFullRefresh),
            shows: [:], notes: [:], remove: [],
            subscribed: Set(podcasts.map(\.id)),
            episodes: episodes, downloaded: downloaded, playbackPositions: playbackPositions,
            played: played, lastRefreshed: lastRefreshed
        )
        for id in dirtyShows where plan.subscribed.contains(id) {
            plan.shows[id] = showsDirectory.appendingPathComponent(Self.fileName(for: id))
            if let notes = pendingNotes[id] {
                plan.notes[id] = (notesDirectory.appendingPathComponent(Self.fileName(for: id)), notes)
            }
        }
        for id in removedShows {
            plan.remove.append(showsDirectory.appendingPathComponent(Self.fileName(for: id)))
            plan.remove.append(notesDirectory.appendingPathComponent(Self.fileName(for: id)))
        }
        dirtyIndex = false
        dirtyShows = []
        removedShows = []
        return plan
    }

    private func didWrite(_ plan: WritePlan) {
        // Notes that were written are no longer pending — unless a newer
        // refresh replaced them meanwhile.
        for (id, entry) in plan.notes where pendingNotes[id] == entry.1 {
            pendingNotes[id] = nil
            notesCache[id] = nil
            notesCacheOrder.removeAll { $0 == id }
        }
    }

    nonisolated private static func write(_ plan: WritePlan) {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        // One pass over the per-episode maps sorts them into the shows being
        // written and the leftovers that belong in the index.
        var downloaded: [String: [String: DownloadRecord]] = [:]
        var positions: [String: [String: Double]] = [:]
        var played: [String: [String]] = [:]
        let loose = "" // key for state outside any subscription
        func bucket(_ key: String) -> String? {
            let show = String(owner(of: key))
            if plan.shows[show] != nil { return show }
            return plan.subscribed.contains(show) ? nil : loose
        }
        for (key, record) in plan.downloaded { if let b = bucket(key) { downloaded[b, default: [:]][key] = record } }
        for (key, pos) in plan.playbackPositions { if let b = bucket(key) { positions[b, default: [:]][key] = pos } }
        for key in plan.played { if let b = bucket(key) { played[b, default: []].append(key) } }

        func put<T: Encodable>(_ value: T, at url: URL) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(value).write(to: url, options: .atomic)
            } catch {
                NSLog("Failed to save \(url.lastPathComponent): \(error)")
            }
        }
        for (id, url) in plan.shows {
            put(ShowFile(
                podcastID: id,
                episodes: plan.episodes[id] ?? [],
                downloaded: downloaded[id] ?? [:],
                playbackPositions: positions[id] ?? [:],
                played: (played[id] ?? []).sorted(),
                lastRefreshed: plan.lastRefreshed[id]
            ), at: url)
        }
        for entry in plan.notes.values {
            put(entry.1, at: entry.0)
        }
        if let url = plan.index {
            put(Index(
                version: currentVersion,
                podcasts: plan.indexData.podcasts,
                lastFullRefresh: plan.indexData.lastFullRefresh,
                downloaded: downloaded[loose] ?? [:],
                playbackPositions: positions[loose] ?? [:],
                played: (played[loose] ?? []).sorted()
            ), at: url)
        }
        for url in plan.remove {
            try? fm.removeItem(at: url)
        }
    }

    nonisolated private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Keeps last session's index as library.json.bak before this session first overwrites it.
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
