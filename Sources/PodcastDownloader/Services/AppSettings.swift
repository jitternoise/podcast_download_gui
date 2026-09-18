import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let masterDirectory = "masterDirectory"
        static let masterDirectoryBookmark = "masterDirectoryBookmark"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let autoRefreshMinutes = "autoRefreshMinutes"
    }

    /// ~/Music/Podcasts. Unlike ~/Downloads it isn't protected by a
    /// Files-and-Folders permission prompt, so a freshly installed app can
    /// scan and write there without asking.
    static let defaultMasterDirectory = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Podcasts", isDirectory: true)

    /// Where versions before the Music default put the library.
    static let legacyMasterDirectory = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Podcasts", isDirectory: true)

    /// Root folder under which one sub-folder per podcast is created.
    ///
    /// Persisted as a path *and* a bookmark: the bookmark follows the folder
    /// if it is renamed or moved in Finder; the path is the fallback when the
    /// bookmark can't be resolved (volume unmounted, folder deleted).
    var masterDirectory: URL {
        didSet { persistMasterDirectory() }
    }

    var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads) }
    }

    /// Minimum gap between automatic refresh-all runs (see `RefreshPolicy`).
    var autoRefreshMinutes: Int {
        didSet { defaults.set(autoRefreshMinutes, forKey: Keys.autoRefreshMinutes) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        masterDirectory = Self.resolveMasterDirectory(from: defaults)
        let stored = defaults.integer(forKey: Keys.maxConcurrentDownloads)
        maxConcurrentDownloads = stored == 0 ? 3 : max(1, min(stored, 10))
        autoRefreshMinutes = defaults.object(forKey: Keys.autoRefreshMinutes) as? Int ?? 60
        // Pin what was resolved: a first-run default (so a later change of
        // default never re-points an existing library) or a bookmark that
        // followed a rename (so the path is current too).
        if defaults.string(forKey: Keys.masterDirectory) != masterDirectory.path { persistMasterDirectory() }
    }

    private static func resolveMasterDirectory(from defaults: UserDefaults) -> URL {
        if let data = defaults.data(forKey: Keys.masterDirectoryBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
               !url.pathComponents.contains(".Trash") {   // a trashed folder is gone, not moved
                return URL(fileURLWithPath: url.path, isDirectory: true)
            }
        }
        if let path = defaults.string(forKey: Keys.masterDirectory), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // First run. Keep using ~/Downloads/Podcasts if an earlier version created it.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacyMasterDirectory.path, isDirectory: &isDir), isDir.boolValue {
            return legacyMasterDirectory
        }
        return defaultMasterDirectory
    }

    private func persistMasterDirectory() {
        defaults.set(masterDirectory.path, forKey: Keys.masterDirectory)
        // Bookmarks need the folder to exist; refresh whenever we can.
        if let data = try? masterDirectory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Keys.masterDirectoryBookmark)
        } else {
            defaults.removeObject(forKey: Keys.masterDirectoryBookmark)
        }
    }

    /// Re-saves the bookmark, e.g. once the folder has been created.
    func refreshBookmark() {
        persistMasterDirectory()
    }

    func folder(for podcast: Podcast) -> URL {
        masterDirectory.appendingPathComponent(podcast.folderName, isDirectory: true)
    }

    func file(for episode: Episode, in podcast: Podcast) -> URL {
        folder(for: podcast).appendingPathComponent(episode.fileName)
    }
}
