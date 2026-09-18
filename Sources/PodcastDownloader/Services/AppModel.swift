import AppKit
import Foundation
import Observation

/// Ties the settings, library and download manager together and exposes the
/// handful of user-level actions the views need.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let library = Library()
    let downloads = DownloadManager()
    let player = Player()
    let windowMode = WindowMode()

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

    /// Episode keys that should open in the default player as soon as they land on disk.
    private var playWhenFinished: Set<String> = []
    /// Downloads requested while the library was being moved; started afterwards.
    private var deferredDownloads: [(Episode, Podcast)] = []

    init() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
        library.migrateDownloadPaths(masterDirectory: settings.masterDirectory)
        downloads.setFinishedHandler { [weak self] episode, url in
            guard let self else { return }
            library.markDownloaded(episode, relativePath: relativePath(of: url))
            rescanDisk()
            if playWhenFinished.remove(episode.key) != nil,
               let podcast = downloads.item(for: episode)?.podcast {
                play(episode, from: podcast)
            }
        }
        player.onPositionUpdate = { [weak self] episode, seconds in
            self?.library.setPlaybackPosition(seconds, for: episode)
        }
        player.onFinished = { [weak self] episode in
            // Finished episodes start from the beginning next time.
            self?.library.setPlaybackPosition(0, for: episode)
        }
        rescanDisk()
        startPeriodicRefresh()
    }

    func applySettings() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
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

    /// Re-reads the master folder on a background thread and updates `onDisk`
    /// and `folderProblem`.
    func rescanDisk() {
        let master = settings.masterDirectory
        Task.detached(priority: .utility) {
            let problem = LibraryFolder.check(master)
            let folders = problem == nil ? LibraryFolder.scan(master) : []
            await MainActor.run {
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
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch {
            moveError = error.localizedDescription
        }
        rescanDisk()
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

    func download(_ episode: Episode, from podcast: Podcast) {
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
        downloads.enqueue(episode, from: podcast, to: destination)
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
        let podcast = library.podcasts.first { $0.folderName == folder.name }
            ?? Podcast(title: folder.name, author: "", feedURL: folder.url, artworkURL: nil)
        let episode = podcast.id == folder.url.absoluteString ? nil
            : library.episodes(for: podcast).first { localFile(for: $0, in: podcast) == file.url }
        let resolved = episode ?? Episode(
            id: file.url.path, title: file.name, summary: "", publishedAt: file.modified,
            enclosureURL: file.url, enclosureLength: file.size, mimeType: nil, duration: nil,
            podcastID: podcast.id
        )
        let saved = library.playbackPosition(for: resolved)
        player.play(resolved, from: podcast, file: file.url, startAt: saved > 5 ? saved : 0)
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
            download(episode, from: current)
        }
        return succeeded
    }

    /// Manual "refresh everything" — always runs.
    func refreshAll() async {
        guard !library.podcasts.isEmpty else { return }
        let anySucceeded = await withTaskGroup(of: Bool.self) { group in
            for podcast in library.podcasts {
                group.addTask { await self.refresh(podcast) }
            }
            return await group.contains(true)
        }
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
