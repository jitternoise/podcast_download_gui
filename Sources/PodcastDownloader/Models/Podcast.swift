import Foundation

/// A podcast feed. Identified by its feed URL so the same show found via
/// search and via a pasted URL collapses into one subscription.
struct Podcast: Identifiable, Codable, Hashable {
    var title: String
    var author: String
    var feedURL: URL
    var artworkURL: URL?
    var summary: String?
    var autoDownload: Bool = false

    var id: String { feedURL.absoluteString }

    /// Folder-safe version of the title, used as the sub-directory name.
    var folderName: String { FileNaming.sanitize(title, fallback: "Podcast") }
}
