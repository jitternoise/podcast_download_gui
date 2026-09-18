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
    /// With auto-download on, keep only this many most-recent downloads
    /// (older ones go to the Trash). 0 = keep everything.
    var keepLatest: Int = 0

    var id: String { feedURL.absoluteString }

    init(title: String, author: String, feedURL: URL, artworkURL: URL? = nil, summary: String? = nil,
         autoDownload: Bool = false, keepLatest: Int = 0) {
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.summary = summary
        self.autoDownload = autoDownload
        self.keepLatest = keepLatest
    }

    /// Fields added after 1.0 are optional on read so older library files
    /// keep loading (the synthesized decoder would reject a missing key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        autoDownload = try c.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? false
        keepLatest = try c.decodeIfPresent(Int.self, forKey: .keepLatest) ?? 0
    }

    /// Folder-safe version of the title, used as the sub-directory name.
    var folderName: String { FileNaming.sanitize(title, fallback: "Podcast") }
}
