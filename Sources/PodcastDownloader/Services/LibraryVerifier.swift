import Foundation

/// "Verify Library": walks every recorded download and checks that the file
/// is still there and still the file that was fetched. Sizes are compared
/// always; checksums when asked (that reads every byte of the library).
/// Downloads from before sizes and checksums were kept get theirs recorded,
/// so the next pass can compare.
struct LibraryVerification: Sendable {
    struct Problem: Identifiable, Hashable, Sendable {
        let key: String          // Episode.key
        let path: String         // relative to the master folder
        let reason: String
        var id: String { key }
    }

    var checksums = false
    var total = 0
    var checked = 0
    var ok = 0
    /// In iCloud Drive but not on this Mac: can't be checked, isn't missing.
    var inCloud = 0
    /// Had no size (or checksum) on record; the current one was recorded.
    var baselined = 0
    var missing: [Problem] = []
    var damaged: [Problem] = []
    var isRunning = true
    var cancelled = false

    var problems: [Problem] { missing + damaged }
}

enum LibraryVerifier {
    enum Outcome: Sendable {
        case ok
        case inCloud
        case missing
        case damaged(String)
        /// Nothing to compare against yet; record what's there.
        case baselined(size: Int64?, sha256: String?)
    }

    /// One file. Runs off the main actor.
    static func inspect(_ record: DownloadRecord, in master: URL, checksums: Bool) -> Outcome {
        let url = master.appendingPathComponent(record.path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // iCloud Drive keeps an evicted file as ".name.icloud".
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            return fm.fileExists(atPath: placeholder.path) ? .inCloud : .missing
        }
        if LibraryFolder.isEvicted(url) { return .inCloud }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let recorded = record.size, recorded != size {
            let got = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let want = ByteCountFormatter.string(fromByteCount: recorded, countStyle: .file)
            return .damaged("\(got) on disk, \(want) when downloaded")
        }
        let newSize: Int64? = record.size == nil ? size : nil
        var newHash: String?
        if checksums {
            let hash: String
            do {
                hash = try FileHash.sha256(of: url)
            } catch {
                return .damaged("couldn't be read: \(error.localizedDescription)")
            }
            if let recorded = record.sha256 {
                if recorded != hash { return .damaged("contents changed since it was downloaded") }
            } else {
                newHash = hash
            }
        }
        if newSize == nil, newHash == nil { return .ok }
        return .baselined(size: newSize, sha256: newHash)
    }
}
