import AppKit
import Foundation
import Observation

/// Ties the settings, library and download manager together and exposes the
/// handful of user-level actions the views need.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let library: Library
    let downloads: DownloadManager
    let player: Player
    let windowMode = WindowMode()
    let search = SearchState()

    /// Something the user needs to see that isn't tied to one view (e.g. a
    /// trash or import failure). RootView shows it as an alert.
    var alertMessage: String?

    /// Set by "jump to now playing"; ContentView selects this podcast and clears it.
    var requestedPodcastID: String?

    /// What's actually in the master folder right now (see `rescanDisk`).
    private(set) var onDisk: [PodcastFolder] = []

    /// Why the master folder can't be used right now, if it can't.
    enum FolderProblem: Equatable {
        case missing        // renamed, deleted, or on a volume that isn't mounted
        case noPermission   // macOS Files-and-Folders access was denied
    }
    private(set) var folderProblem: FolderProblem?

    /// Non-nil while the library is being moved to a new master folder.
    private(set) var moveStatus: String?
    var moveError: String?

    /// Non-nil while "Verify Library" runs or its report is showing.
    var verification: LibraryVerification?
    /// The sheet that offers to run it.
    var showVerifyOptions = false
    private var verifyTask: Task<Void, Never>?
    private var verifyGeneration = 0

    /// Episode keys that should open in the default player as soon as they land on disk.
    private var playWhenFinished: Set<String> = []
    /// Downloads requested while the library was being moved; started afterwards.
    private var deferredDownloads: [(Episode, Podcast)] = []

    /// - Parameters: injectable for tests; the defaults are the real app stores.
    init(settings: AppSettings? = nil, library: Library? = nil,
         downloads: DownloadManager? = nil, player: Player? = nil,
         observeSystem: Bool = true) {
        let settings = settings ?? AppSettings()
        let library = library ?? Library()
        let downloads = downloads ?? DownloadManager()
        let player = player ?? Player()
        self.settings = settings
        self.library = library
        self.downloads = downloads
        self.player = player

        downloads.maxConcurrent = settings.maxConcurrentDownloads
        library.migrateDownloadPaths(masterDirectory: settings.masterDirectory)
        downloads.setFinishedHandler { [weak self] episode, result in
            guard let self else { return }
            library.markDownloaded(episode, relativePath: relativePath(of: result.url), size: result.size, sha256: result.sha256)
            rescanDisk()
            if playWhenFinished.remove(episode.key) != nil,
               let podcast = downloads.item(for: episode)?.podcast {
                // The user asked for this one specifically — but if they've
                // started something else in the meantime, don't cut it off.
                if !player.isPlaying || player.episode?.key == episode.key {
                    play(episode, from: podcast)
                }
            }
            if let podcast = downloads.item(for: episode)?.podcast {
                applyKeepLatest(for: podcast)
            }
        }
        downloads.onActiveCountChange = { count in
            NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        player.onPositionUpdate = { [weak self] episode, seconds in
            self?.library.setPlaybackPosition(seconds, for: episode)
        }
        player.onFinished = { [weak self] episode in
            guard let self else { return }
            // Finished episodes start from the beginning next time.
            library.setPlaybackPosition(0, for: episode)
            library.setPlayed(episode, true)
            if settings.deleteAfterPlayed, let podcast = player.podcast, let file = localFile(for: episode, in: podcast) {
                trash(file: file, of: episode)
            }
            if settings.continuousPlay { playNext(after: episode) }
        }
        player.skipInterval = Double(settings.skipInterval)
        player.rate = settings.playbackRate
        player.onRateChange = { [weak self] rate in self?.settings.playbackRate = rate }
        player.artworkProvider = { url in await ImageCache.shared.image(for: url) }
        player.onNextTrack = { [weak self] in
            guard let self, let episode = player.episode else { return }
            playNext(after: episode)
        }
        player.onPreviousTrack = { [weak self] in
            guard let self, let episode = player.episode else { return }
            if player.currentTime > 3 { player.seek(to: 0) } else { playPrevious(before: episode) }
        }
        rescanDisk()
        if observeSystem {
            startPeriodicRefresh()
            observeSleep()
        }
    }

    func applySettings() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
        player.skipInterval = Double(settings.skipInterval)
    }

    private var sleepObserver: NSObjectProtocol?
    private let routeMonitor = AudioRouteMonitor()

    /// Pause when the Mac sleeps so audio doesn't burst out of the speakers on
    /// wake, and when headphones or AirPods disconnect so it doesn't switch to
    /// the built-in speakers mid-episode.
    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.isPlaying else { return }
                self.player.pause()
            }
        }
        routeMonitor.onChange = { [weak self] nowBuiltIn in
            Task { @MainActor in
                guard let self, nowBuiltIn, self.player.isPlaying else { return }
                self.player.pause()
            }
        }
        routeMonitor.start()
    }

    /// True while quitting would interrupt something the user cares about.
    var hasWorkInProgress: Bool {
        !downloads.activeItems.isEmpty || player.isPlaying
    }

    // MARK: Local files

    /// The downloaded file for an episode, if it exists in the master folder.
    /// Checks the recorded location first, then the location it would be saved
    /// to now — unless that file is recorded as belonging to another episode
    /// that happens to produce the same name.
    func localFile(for episode: Episode, in podcast: Podcast) -> URL? {
        let fm = FileManager.default
        if let rel = library.downloadedRelativePath(for: episode) {
            let url = settings.masterDirectory.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let expected = settings.file(for: episode, in: podcast)
        guard fm.fileExists(atPath: expected.path) else { return nil }
        if let owner = library.episodeID(downloadedTo: relativePath(of: expected)), owner != episode.key { return nil }
        return expected
    }

    /// Where a download of `episode` should be written. A re-download replaces
    /// the episode's own file; otherwise the name is made unique so two episodes
    /// that sanitize to the same file name never overwrite each other.
    private func destination(for episode: Episode, in podcast: Podcast) -> URL {
        if let own = localFile(for: episode, in: podcast) { return own }
        let candidate = settings.file(for: episode, in: podcast)
        return FileNaming.uniqueURL(candidate) { url in
            FileManager.default.fileExists(atPath: url.path)
                || downloads.activeItems.contains { $0.id != episode.key && $0.destination.standardizedFileURL == url.standardizedFileURL }
        }
    }

    private func relativePath(of url: URL) -> String {
        let prefix = settings.masterDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private var scanGeneration = 0

    /// Re-reads the master folder on a background thread and updates `onDisk`
    /// and `folderProblem`. A scan that finishes after a newer one started is
    /// discarded, so a stale snapshot can't overwrite a fresh one.
    func rescanDisk() {
        let master = settings.masterDirectory
        scanGeneration += 1
        let generation = scanGeneration
        Task.detached(priority: .utility) {
            let problem = LibraryFolder.check(master)
            let folders = problem == nil ? LibraryFolder.scan(master) : []
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.onDisk = folders
                self.folderProblem = problem
                // The folder exists now (created by a download, or the drive is
                // back): make sure the bookmark points at it.
                if problem == nil { self.settings.refreshBookmark() }
            }
        }
    }

    /// Re-points the app at `url` without moving anything — for when the old
    /// folder is gone and there is nothing to move.
    func adoptMasterDirectory(_ url: URL) {
        settings.masterDirectory = url
        rescanDisk()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Moves a downloaded file to the Trash.
    func trash(_ file: LocalFile) {
        trash(file: file.url, of: episode(matching: file.url)?.episode)
    }

    /// Moves an episode's download to the Trash (the episode stays in the list).
    func deleteDownload(of episode: Episode, in podcast: Podcast) {
        guard let file = localFile(for: episode, in: podcast) else { return }
        if player.episode?.key == episode.key { player.stop() }
        trash(file: file, of: episode)
    }

    private func trash(file: URL, of episode: Episode?) {
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            if let episode { library.forgetDownload(episode) }
        } catch {
            alertMessage = "Couldn't move \"\(file.lastPathComponent)\" to the Trash: \(error.localizedDescription)"
        }
        rescanDisk()
    }

    /// With "keep the latest N" set, trash the oldest downloads beyond N.
    /// Only ever touches files the app downloaded itself.
    func applyKeepLatest(for podcast: Podcast) {
        guard let current = library.podcast(withID: podcast.id), current.autoDownload, current.keepLatest > 0 else { return }
        let downloaded = library.episodes(for: current).filter { localFile(for: $0, in: current) != nil }   // newest first
        for episode in downloaded.dropFirst(current.keepLatest) where player.episode?.key != episode.key {
            if library.downloadedRelativePath(for: episode) != nil { deleteDownload(of: episode, in: current) }
        }
    }

    // MARK: Master folder

    /// Points the app at a new master folder and relocates every existing
    /// download into it. In-flight downloads are restarted against the new folder.
    func changeMasterDirectory(to newURL: URL) async {
        let old = settings.masterDirectory
        guard old.standardizedFileURL != newURL.standardizedFileURL else { return }
        guard moveStatus == nil else { return }

        // Anything still downloading was headed for the old folder; restart it later.
        let inFlight = downloads.activeItems
        for item in inFlight { downloads.cancel(item.id) }

        moveStatus = "Moving your library to \(newURL.lastPathComponent)…"
        moveError = nil

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try LibraryFolder.move(from: old, to: newURL)
            }.value
            // Point at the new folder as soon as anything lives there, so what
            // did move doesn't vanish from the app; leftovers are merged in by
            // choosing the same folder again.
            if result.isComplete || result.moved > 0 {
                settings.masterDirectory = newURL
            }
            var notes: [String] = []
            if !result.failed.isEmpty {
                notes.append("Moved \(result.total - result.failed.count) of \(result.total) podcast folders. Couldn't move: "
                             + result.failed.joined(separator: "; ")
                             + ". Choose the same folder again to move the rest.")
            }
            if result.skipped > 0 {
                notes.append("\(result.skipped) file(s) already existed in the new folder and were left in place at the old location.")
            }
            moveError = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch {
            moveError = "Couldn't move the library: \(error.localizedDescription)"
        }
        moveStatus = nil

        for item in inFlight {
            download(item.episode, from: item.podcast)
        }
        let deferred = deferredDownloads
        deferredDownloads = []
        for (episode, podcast) in deferred { download(episode, from: podcast) }
        rescanDisk()
    }

    // MARK: Downloads

    func download(_ episode: Episode, from podcast: Podcast, automatic: Bool = false) {
        // Mid-move, the master folder is about to change: hold the request so
        // the file isn't written into the folder being abandoned.
        if moveStatus != nil {
            if !deferredDownloads.contains(where: { $0.0.key == episode.key }) { deferredDownloads.append((episode, podcast)) }
            return
        }
        let destination = destination(for: episode, in: podcast)
        // Belt and braces: names are sanitized, but nothing may ever be written
        // outside the master folder.
        let root = settings.masterDirectory.standardizedFileURL.path + "/"
        guard destination.standardizedFileURL.path.hasPrefix(root) else {
            NSLog("Refusing to download outside the master folder: \(destination.path)")
            return
        }
        downloads.enqueue(episode, from: podcast, to: destination, automatic: automatic)
    }

    /// How many of this show's episodes are on disk (for confirmations and the header).
    func downloadedCount(for podcast: Podcast) -> Int {
        library.episodes(for: podcast).filter { localFile(for: $0, in: podcast) != nil }.count
    }

    /// Double-click behaviour: play immediately if the file exists, otherwise
    /// download it and play when the download completes.
    func downloadAndPlay(_ episode: Episode, from podcast: Podcast) {
        if localFile(for: episode, in: podcast) != nil {
            play(episode, from: podcast)
            return
        }
        playWhenFinished.insert(episode.key)
        download(episode, from: podcast)
    }

    // MARK: Playback

    /// Plays a downloaded episode in the built-in player, resuming where it left off.
    func play(_ episode: Episode, from podcast: Podcast) {
        guard let file = localFile(for: episode, in: podcast) else { return }
        let saved = library.playbackPosition(for: episode)
        player.play(episode, from: podcast, file: file, startAt: saved > 5 ? saved : 0)
    }

    /// Plays a file found on disk (Downloads tab). Matches it back to a known
    /// episode when possible so the resume position is shared.
    func play(_ file: LocalFile, in folder: PodcastFolder) {
        if file.isEvicted {
            // In iCloud but not on this Mac: ask for it and tell the user.
            try? FileManager.default.startDownloadingUbiquitousItem(at: file.url)
            alertMessage = "\"\(file.name)\" is in iCloud Drive but not downloaded to this Mac yet. It's being fetched now — try again in a moment."
            return
        }
        let resolved: Episode
        let podcast: Podcast
        if let match = episode(matching: file.url) {
            (resolved, podcast) = (match.episode, match.podcast)
        } else {
            // Not one of ours (or from a show since unsubscribed): key by the
            // master-relative path so the position survives a library move.
            podcast = Podcast(title: folder.name, author: "", feedURL: folder.url, artworkURL: nil)
            resolved = Episode(
                id: relativePath(of: file.url), title: file.name, summary: "", publishedAt: file.modified,
                enclosureURL: file.url, enclosureLength: file.size, mimeType: nil, duration: nil,
                podcastID: "file"
            )
        }
        let saved = library.playbackPosition(for: resolved)
        player.play(resolved, from: podcast, file: file.url, startAt: saved > 5 ? saved : 0)
    }

    /// The subscribed episode that was downloaded to `url`, found through the
    /// recorded download path (so a show that was renamed still matches).
    private func episode(matching url: URL) -> EpisodeRef? {
        let rel = relativePath(of: url)
        guard let key = library.episodeID(downloadedTo: rel) else { return nil }
        for podcast in library.podcasts {
            if let episode = library.episodes(for: podcast).first(where: { $0.key == key }) {
                return EpisodeRef(episode: episode, podcast: podcast)
            }
        }
        return nil
    }

    // MARK: Continuous play

    /// The next newer downloaded episode of the same show, if any.
    func playNext(after episode: Episode) {
        guard let (next, podcast) = neighbour(of: episode, offset: -1) else { return }
        play(next, from: podcast)
    }

    func playPrevious(before episode: Episode) {
        guard let (previous, podcast) = neighbour(of: episode, offset: 1) else { player.seek(to: 0); return }
        play(previous, from: podcast)
    }

    /// Episodes are stored newest first, so offset -1 is the next newer one.
    private func neighbour(of episode: Episode, offset: Int) -> (Episode, Podcast)? {
        guard let podcastID = episode.podcastID, let podcast = library.podcast(withID: podcastID) else { return nil }
        let list = library.episodes(for: podcast)
        guard let idx = list.firstIndex(where: { $0.key == episode.key }) else { return nil }
        var i = idx + offset
        while list.indices.contains(i) {
            if localFile(for: list[i], in: podcast) != nil { return (list[i], podcast) }
            i += offset
        }
        return nil
    }

    /// Asks ContentView to show the podcast of whatever is playing.
    func revealNowPlaying() {
        guard let id = player.episode?.podcastID, library.podcast(withID: id) != nil else { return }
        requestedPodcastID = id
    }

    func isCurrentlyLoaded(_ episode: Episode) -> Bool {
        player.episode?.key == episode.key
    }

    func cancelDownload(_ id: String) {
        playWhenFinished.remove(id)
        downloads.cancel(id)
    }

    func cancelAllDownloads() {
        playWhenFinished.removeAll()
        downloads.cancelAll()
    }

    /// Hands the file to whatever app the user has set for that file type.
    func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func downloadAll(_ podcast: Podcast) {
        for episode in library.episodes(for: podcast)
        where localFile(for: episode, in: podcast) == nil && !downloads.isQueuedOrActive(episode) {
            download(episode, from: podcast)
        }
    }

    // MARK: Verify

    /// Checks every recorded download against what was fetched (see
    /// `LibraryVerification`). Progress and the report land in `verification`.
    func verifyLibrary(checksums: Bool) {
        guard verifyTask == nil else { return }
        let master = settings.masterDirectory
        let records = library.downloaded.sorted { $0.key < $1.key }
        var report = LibraryVerification()
        report.checksums = checksums
        report.total = records.count
        verification = report
        verifyGeneration += 1
        let generation = verifyGeneration

        verifyTask = Task { [weak self] in
            // A hundred at a time: a stat per file is cheap, a hop to a
            // background thread per file is not.
            for batch in stride(from: 0, to: records.count, by: 100).map({ Array(records[$0..<min($0 + 100, records.count)]) }) {
                if Task.isCancelled { break }
                let outcomes = await Task.detached(priority: .utility) {
                    batch.map { ($0.key, $0.value, LibraryVerifier.inspect($0.value, in: master, checksums: checksums)) }
                }.value
                guard let self, !Task.isCancelled else { break }
                for (key, record, outcome) in outcomes {
                    self.verification?.checked += 1
                    switch outcome {
                    case .ok: self.verification?.ok += 1
                    case .inCloud: self.verification?.inCloud += 1
                    case .missing:
                        self.verification?.missing.append(.init(key: key, path: record.path, reason: "not found"))
                    case .damaged(let reason):
                        self.verification?.damaged.append(.init(key: key, path: record.path, reason: reason))
                    case .baselined(let size, let sha256):
                        self.library.setDownloadBaseline(size: size, sha256: sha256, forKey: key)
                        self.verification?.ok += 1
                        self.verification?.baselined += 1
                    }
                }
            }
            // A pass dismissed and restarted meanwhile owns `verification` now.
            guard let self, self.verifyGeneration == generation else { return }
            self.verification?.cancelled = Task.isCancelled
            self.verification?.isRunning = false
            self.verifyTask = nil
        }
    }

    func cancelVerification() {
        verifyTask?.cancel()
    }

    /// Closes the report. A running pass is stopped.
    func dismissVerification() {
        verifyTask?.cancel()
        verifyTask = nil
        verification = nil
        showVerifyOptions = false
    }

    /// Fetches the missing and damaged files again. A damaged file is
    /// replaced in place; a missing one lands where it would today. Episodes
    /// no longer in their feed can't be fetched and are reported back.
    @discardableResult
    func redownloadVerificationProblems() -> Int {
        guard let report = verification else { return 0 }
        var queued = 0
        var unknown = 0
        for problem in report.problems {
            guard let ref = library.episodeRef(forKey: problem.key) else { unknown += 1; continue }
            download(ref.episode, from: ref.podcast)
            queued += 1
        }
        if unknown > 0 {
            alertMessage = "\(unknown) file\(unknown == 1 ? "" : "s") couldn't be queued: the episode is no longer in its feed (or the show is no longer a subscription)."
        }
        return queued
    }

    // MARK: Refresh

    /// Refreshes one feed. Returns false if the feed couldn't be fetched.
    @discardableResult
    func refresh(_ podcast: Podcast) async -> Bool {
        let newEpisodes = await library.refresh(podcast)
        let succeeded = library.refreshErrors[podcast.id] == nil
        // Don't auto-download into a folder that isn't there.
        guard folderProblem == nil,
              let current = library.podcast(withID: podcast.id), current.autoDownload else { return succeeded }
        for episode in newEpisodes where localFile(for: episode, in: current) == nil {
            download(episode, from: current, automatic: true)
        }
        return succeeded
    }

    /// How many feeds "Refresh All" fetches at once. Each open connection
    /// holds sizeable buffers, so 49 at a time is ~70 MB of peak memory for
    /// no real speed gain over a handful.
    static let refreshConcurrency = 6
    private let refreshGate = AsyncSemaphore(limit: AppModel.refreshConcurrency)

    /// Manual "refresh everything" — always runs.
    func refreshAll() async {
        guard !library.podcasts.isEmpty else { return }
        // Fan out on the main actor (each refresh awaits its own network call),
        // a few at a time.
        let tasks = library.podcasts.map { podcast in
            Task { @MainActor in
                await self.refreshGate.wait()
                defer { Task { await self.refreshGate.signal() } }
                return await self.refresh(podcast)
            }
        }
        var anySucceeded = false
        for task in tasks where await task.value { anySucceeded = true }
        // Offline launches must not count as "checked": the next automatic
        // refresh should try again rather than wait out the whole interval.
        if anySucceeded { library.markFullRefresh() }
    }

    private var didRunLaunchRefresh = false

    /// Automatic refresh at launch: runs at most once per app session, and only
    /// if the last full refresh is older than the interval chosen in Settings.
    func refreshOnLaunchIfDue() async {
        guard !didRunLaunchRefresh else { return }
        didRunLaunchRefresh = true
        await refreshIfDue()
    }

    /// Automatic refresh while the app stays open: after the Mac wakes, when
    /// the app comes to the front, and every few minutes — each time only if
    /// the interval chosen in Settings has passed since the last full refresh.
    func refreshIfDue() async {
        guard library.refreshing.isEmpty,
              RefreshPolicy.isDue(lastFullRefresh: library.lastFullRefresh,
                                  minimumMinutes: settings.autoRefreshMinutes) else { return }
        await refreshAll()
    }

    static let periodicRefreshCheck: Duration = .seconds(5 * 60)
    private var refreshObservers: [NSObjectProtocol] = []

    private func startPeriodicRefresh() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: Self.periodicRefreshCheck)
                await self.refreshIfDue()
            }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
        refreshObservers = [wake, active]
    }

    // MARK: Finder helpers

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolder(for podcast: Podcast) {
        let folder = settings.folder(for: podcast)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func openMasterFolder() {
        try? FileManager.default.createDirectory(at: settings.masterDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.masterDirectory)
    }
}
