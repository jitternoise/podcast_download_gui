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
}

/// Disk-level operations on the master folder: scanning and relocating.
/// Everything here is synchronous and safe to run off the main actor.
enum LibraryFolder {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "m4b"]

    /// Lists every podcast sub-folder and the media files inside it.
    static func scan(_ master: URL) -> [PodcastFolder] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: master, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [PodcastFolder] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let localFiles: [LocalFile] = files.compactMap { file in
                guard audioExtensions.contains(file.pathExtension.lowercased()),
                      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { return nil }
                return LocalFile(
                    name: file.deletingPathExtension().lastPathComponent,
                    url: file,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate ?? .distantPast
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
    }

    /// Moves every podcast sub-folder from `old` into `new`, merging folders that
    /// already exist there. Files that already exist at the destination are
    /// skipped rather than overwritten. Works across volumes (copy + delete).
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

        let entries = try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for source in entries {
            let target = new.appendingPathComponent(source.lastPathComponent)
            let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

            if !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: source, to: target)
                result.moved += 1
            } else if isDir {
                // Merge file-by-file into the existing folder.
                let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                for file in files {
                    let fileTarget = target.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: fileTarget.path) {
                        result.skipped += 1
                    } else {
                        try fm.moveItem(at: file, to: fileTarget)
                        result.moved += 1
                    }
                }
                removeIfEmpty(source)
            } else {
                result.skipped += 1
            }
        }
        removeIfEmpty(old)
        return result
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        let remaining = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
        if remaining.isEmpty { try? fm.removeItem(at: dir) }
    }
}
