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

    /// Non-nil while the library is being moved to a new master folder.
    private(set) var moveStatus: String?
    var moveError: String?

    /// Episode ids that should open in the default player as soon as they land on disk.
    private var playWhenFinished: Set<String> = []

    init() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
        library.migrateDownloadPaths(masterDirectory: settings.masterDirectory)
        downloads.setFinishedHandler { [weak self] episode, url in
            guard let self else { return }
            library.markDownloaded(episode, relativePath: relativePath(of: url))
            rescanDisk()
            if playWhenFinished.remove(episode.id) != nil,
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
    }

    func applySettings() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
    }

    // MARK: Local files

    /// The downloaded file for an episode, if it exists in the master folder.
    /// Checks the recorded location first, then the location it would be saved to now.
    func localFile(for episode: Episode, in podcast: Podcast) -> URL? {
        let fm = FileManager.default
        if let rel = library.downloadedRelativePath(for: episode) {
            let url = settings.masterDirectory.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let expected = settings.file(for: episode, in: podcast)
        return fm.fileExists(atPath: expected.path) ? expected : nil
    }

    private func relativePath(of url: URL) -> String {
        let prefix = settings.masterDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Re-reads the master folder on a background thread and updates `onDisk`.
    func rescanDisk() {
        let master = settings.masterDirectory
        Task.detached(priority: .utility) {
            let folders = LibraryFolder.scan(master)
            await MainActor.run { self.onDisk = folders }
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
        defer { moveStatus = nil }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try LibraryFolder.move(from: old, to: newURL)
            }.value
            settings.masterDirectory = newURL
            if result.skipped > 0 {
                moveError = "\(result.skipped) file(s) already existed in the new folder and were left in place at the old location."
            }
        } catch {
            moveError = "Couldn't move the library: \(error.localizedDescription)"
        }

        for item in inFlight {
            download(item.episode, from: item.podcast)
        }
        rescanDisk()
    }

    // MARK: Downloads

    func download(_ episode: Episode, from podcast: Podcast) {
        let destination = settings.file(for: episode, in: podcast)
        downloads.enqueue(episode, from: podcast, to: destination)
    }

    /// Double-click behaviour: play immediately if the file exists, otherwise
    /// download it and play when the download completes.
    func downloadAndPlay(_ episode: Episode, from podcast: Podcast) {
        if localFile(for: episode, in: podcast) != nil {
            play(episode, from: podcast)
            return
        }
        playWhenFinished.insert(episode.id)
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
            enclosureURL: file.url, enclosureLength: file.size, mimeType: nil, duration: nil
        )
        let saved = library.playbackPosition(for: resolved)
        player.play(resolved, from: podcast, file: file.url, startAt: saved > 5 ? saved : 0)
    }

    func isCurrentlyLoaded(_ episode: Episode) -> Bool {
        player.episode?.id == episode.id
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

    func refresh(_ podcast: Podcast) async {
        let newEpisodes = await library.refresh(podcast)
        guard let current = library.podcast(withID: podcast.id), current.autoDownload else { return }
        for episode in newEpisodes where localFile(for: episode, in: current) == nil {
            download(episode, from: current)
        }
    }

    /// Manual "refresh everything" — always runs.
    func refreshAll() async {
        guard !library.podcasts.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for podcast in library.podcasts {
                group.addTask { await self.refresh(podcast) }
            }
        }
        library.markFullRefresh()
    }

    /// Automatic refresh (launch): only runs if the last full refresh is older
    /// than the interval chosen in Settings.
    func refreshAllIfDue() async {
        guard RefreshPolicy.isDue(lastFullRefresh: library.lastFullRefresh,
                                  minimumMinutes: settings.autoRefreshMinutes) else { return }
        await refreshAll()
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
