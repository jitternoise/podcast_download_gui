import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let masterDirectory = "masterDirectory"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let autoRefreshMinutes = "autoRefreshMinutes"
    }

    static let defaultMasterDirectory = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Podcasts", isDirectory: true)

    /// Root folder under which one sub-folder per podcast is created.
    var masterDirectory: URL {
        didSet { UserDefaults.standard.set(masterDirectory.path, forKey: Keys.masterDirectory) }
    }

    var maxConcurrentDownloads: Int {
        didSet { UserDefaults.standard.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads) }
    }

    /// Minimum gap between automatic refresh-all runs (see `RefreshPolicy`).
    var autoRefreshMinutes: Int {
        didSet { UserDefaults.standard.set(autoRefreshMinutes, forKey: Keys.autoRefreshMinutes) }
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Keys.masterDirectory), !path.isEmpty {
            masterDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            masterDirectory = Self.defaultMasterDirectory
        }
        let stored = defaults.integer(forKey: Keys.maxConcurrentDownloads)
        maxConcurrentDownloads = stored == 0 ? 3 : max(1, min(stored, 10))
        autoRefreshMinutes = defaults.object(forKey: Keys.autoRefreshMinutes) as? Int ?? 60
    }

    func folder(for podcast: Podcast) -> URL {
        masterDirectory.appendingPathComponent(podcast.folderName, isDirectory: true)
    }

    func file(for episode: Episode, in podcast: Podcast) -> URL {
        folder(for: podcast).appendingPathComponent(episode.fileName)
    }
}
