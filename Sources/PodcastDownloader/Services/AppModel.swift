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

    /// Episode ids that should open in the default player as soon as they land on disk.
    private var playWhenFinished: Set<String> = []

    init() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
        downloads.setFinishedHandler { [weak self] episode, url in
            guard let self else { return }
            library.markDownloaded(episode, at: url)
            if playWhenFinished.remove(episode.id) != nil {
                play(url)
            }
        }
    }

    func applySettings() {
        downloads.maxConcurrent = settings.maxConcurrentDownloads
    }

    // MARK: Downloads

    func download(_ episode: Episode, from podcast: Podcast) {
        let destination = settings.file(for: episode, in: podcast)
        downloads.enqueue(episode, from: podcast, to: destination)
    }

    /// Double-click behaviour: play immediately if the file exists, otherwise
    /// download it and play when the download completes.
    func downloadAndPlay(_ episode: Episode, from podcast: Podcast) {
        if let file = library.localFile(for: episode) {
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
        where library.localFile(for: episode) == nil && !downloads.isQueuedOrActive(episode) {
            download(episode, from: podcast)
        }
    }

    // MARK: Refresh

    func refresh(_ podcast: Podcast) async {
        let newEpisodes = await library.refresh(podcast)
        guard let current = library.podcast(withID: podcast.id), current.autoDownload else { return }
        for episode in newEpisodes where library.localFile(for: episode) == nil {
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
