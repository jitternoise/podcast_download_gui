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
            if playWhenFinished.remove(episode.id) != nil {
                play(url)
            }
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
        if let file = localFile(for: episode, in: podcast) {
            play(file)
            return
        }
        playWhenFinished.insert(episode.id)
        download(episode, from: podcast)
    }

    func cancelDownload(_ id: String) {
        playWhenFinished.remove(id)
        downloads.cancel(id)
    }

    func cancelAllDownloads() {
        playWhenFinished.removeAll()
        downloads.cancelAll()
    }

    func play(_ url: URL) {
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

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for podcast in library.podcasts {
                group.addTask { await self.refresh(podcast) }
            }
        }
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
