import Foundation

/// A podcast sub-folder inside the master folder, as found on disk.
struct PodcastFolder: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let files: [LocalFile]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// One downloaded file on disk.
struct LocalFile: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let size: Int64
    let modified: Date
    /// In iCloud Drive but not on this Mac right now ("evicted"); it must be
    /// fetched before it can play.
    var isEvicted = false
}

/// Disk-level operations on the master folder: scanning and relocating.
/// Everything here is synchronous and safe to run off the main actor.
enum LibraryFolder {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "m4b"]

    static func isMediaFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Finder bookkeeping that shouldn't stop a folder from counting as empty.
    private static let ignorableEntries: Set<String> = [".DS_Store", ".localized"]

    /// Whether the master folder can be used. A folder that doesn't exist yet
    /// is fine when its parent is reachable (the first download creates it).
    static func check(_ master: URL) -> AppModel.FolderProblem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: master.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return .missing }
            do {
                _ = try fm.contentsOfDirectory(atPath: master.path)
                return nil
            } catch {
                return isPermissionError(error) ? .noPermission : .missing
            }
        }
        // Not there. Distinguish "not created yet" from "the drive is unplugged"
        // or "the parent folder is off limits".
        let parent = master.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        do {
            _ = try fm.contentsOfDirectory(atPath: parent.path)
            return nil
        } catch {
            return isPermissionError(error) ? .noPermission : .missing
        }
    }

    /// Whether a file is in iCloud Drive but not currently downloaded to this Mac.
    static func isEvicted(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
        return isEvicted(values)
    }

    private static func isEvicted(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status == .notDownloaded
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError)
    }

    /// Lists every podcast sub-folder and the media files inside it.
    static func scan(_ master: URL) -> [PodcastFolder] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: master, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [PodcastFolder] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
                                             .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []

            let localFiles: [LocalFile] = files.compactMap { file in
                guard isMediaFile(file),
                      let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return LocalFile(
                    name: file.deletingPathExtension().lastPathComponent,
                    url: file,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate ?? .distantPast,
                    isEvicted: isEvicted(values)
                )
            }
            .sorted { $0.modified > $1.modified }

            folders.append(PodcastFolder(name: dir.lastPathComponent, url: dir, files: localFiles))
        }
        return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct MoveResult {
        var moved = 0
        var skipped = 0      // already existed at destination; source left in place
        var replaced = 0     // destination had a partial copy from an interrupted move
        var failed: [String] = []   // "<name>: <reason>", one per item that couldn't be moved
        var total = 0        // podcast folders found in the old location

        var isComplete: Bool { failed.isEmpty }
    }

    /// Moves the podcast sub-folders from `old` into `new`, merging folders that
    /// already exist there. Files that already exist at the destination are
    /// skipped rather than overwritten. Works across volumes (copy + delete).
    ///
    /// Only sub-folders that contain media files are touched, so pointing the
    /// app at a folder that holds other things (or at ~/Downloads itself) never
    /// relocates them. Anything else in `old` is left exactly where it is, and
    /// `old` is only removed once nothing but Finder bookkeeping remains.
    static func move(from old: URL, to new: URL) throws -> MoveResult {
        let fm = FileManager.default
        var result = MoveResult()
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        guard oldPath != newPath else { return result }
        guard !newPath.hasPrefix(oldPath + "/") else {
            throw FeedError(message: "The new folder can't be inside the current one.")
        }

        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: oldPath) else { return result }

        // One failing item (disk full, permissions) must not abandon the rest:
        // whatever moved stays moved, and the caller reports what didn't.
        let folders = try podcastFolders(in: old)
        result.total = folders.count
        for source in folders {
            let target = new.appendingPathComponent(source.lastPathComponent)
            do {
                if !fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: source, to: target)
                    result.moved += 1
                    continue
                }
                try merge(source, into: target, result: &result)
            } catch {
                result.failed.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if result.isComplete { removeIfEmpty(old) }
        return result
    }

    /// Moves media files from `source` into the existing folder `target`.
    private static func merge(_ source: URL, into target: URL, result: inout MoveResult) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for file in files where isMediaFile(file) {
            let fileTarget = target.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: fileTarget.path) {
                // A cross-volume move copies to the final name, so a quit or
                // error mid-copy leaves a truncated file behind. The source is
                // still intact, so a size mismatch means: replace it.
                if size(of: fileTarget) == size(of: file) {
                    result.skipped += 1
                    continue
                }
                try fm.removeItem(at: fileTarget)
                result.replaced += 1
            }
            try fm.moveItem(at: file, to: fileTarget)
            result.moved += 1
        }
        removeIfEmpty(source)
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Immediate sub-folders of `master` that hold at least one media file.
    private static func podcastFolders(in master: URL) throws -> [URL] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: master, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries.filter { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return false }
            return files.contains(where: isMediaFile)
        }
    }

    /// Deletes `dir` only if it holds nothing but Finder bookkeeping. Hidden
    /// files the user put there (dotfiles, .git, …) keep the folder alive.
    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let remaining = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        if remaining.allSatisfy({ ignorableEntries.contains($0) }) {
            try? fm.removeItem(at: dir)
        }
    }
}
