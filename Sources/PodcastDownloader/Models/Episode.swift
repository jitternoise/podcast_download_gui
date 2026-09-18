import Foundation

struct Episode: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var summary: String
    var publishedAt: Date?
    var enclosureURL: URL
    var enclosureLength: Int64?
    var mimeType: String?
    var duration: String?
    /// The feed this episode came from (`Podcast.id`). Set by the library when
    /// episodes are cached, so `key` is unique across podcasts even when two
    /// feeds reuse the same guid.
    var podcastID: String?

    /// Key for per-episode state (downloads, positions, the queue, the player).
    /// `id` alone is only unique within one feed.
    var key: String { podcastID.map { $0 + "|" + id } ?? id }

    /// Newest first; undated episodes sink to the bottom.
    static func newestFirst(_ a: Episode, _ b: Episode) -> Bool {
        (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
    }

    /// File extension inferred from the enclosure URL when it is a media
    /// extension, else from the MIME type, else mp3. A URL ending in .php or
    /// .aspx is a script that serves audio, not the audio's type.
    var fileExtension: String {
        let ext = enclosureURL.pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) { return ext }
        switch mimeType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/flac": return "flac"
        case "video/mp4": return "mp4"
        default: return "mp3"
        }
    }

    /// Extensions treated as podcast media, by URL, by MIME type and by content sniffing alike.
    static let mediaExtensions: Set<String> = ["mp3", "mp2", "mp1", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "m4b"]

    /// `2024-03-09 - Episode Title.mp3`. The date is the UTC publish date so
    /// the same episode gets the same name on every Mac.
    var fileName: String {
        var name = FileNaming.sanitize(title, fallback: id)
        if let publishedAt {
            name = "\(Self.dayFormatter.string(from: publishedAt)) - \(name)"
        }
        return "\(name).\(fileExtension)"
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    /// `<itunes:duration>` in seconds: it is either plain seconds ("3600") or
    /// HH:MM:SS / MM:SS. Nil when absent or unparseable.
    var durationSeconds: Int? {
        guard let raw = duration?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Int(raw) { return seconds }
        if let seconds = Double(raw) { return Int(seconds) }
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == raw.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

enum FileNaming {
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)

    /// Strip characters that are illegal or awkward in macOS file names and
    /// clamp the length so very long titles don't hit filesystem limits.
    ///
    /// The fallback is cleaned the same way: it is usually the feed's `<guid>`,
    /// which is attacker-controlled and must never be able to carry a path.
    /// APFS/HFS+ limit file names to 255 UTF-16 code units, not characters;
    /// leave room for the date prefix, a " (n)" suffix and the extension.
    static let maxUTF16Length = 200

    static func sanitize(_ raw: String, fallback: String) -> String {
        var cleaned = clean(raw)
        if cleaned.isEmpty { cleaned = clean(fallback) }
        if cleaned.isEmpty { cleaned = "Untitled" }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        while cleaned.utf16.count > maxUTF16Length { cleaned.removeLast() }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private static let whitespaceRuns = try! NSRegularExpression(pattern: "\\s+")

    private static func clean(_ raw: String) -> String {
        var cleaned = raw.components(separatedBy: illegal)
            .filter { $0 != "." && $0 != ".." }      // path-only pieces mean nothing as text
            .joined(separator: " ")
        cleaned = whitespaceRuns.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: " ")
        // Finder treats a leading dot as hidden.
        while let first = cleaned.first, first == "." || first.isWhitespace { cleaned.removeFirst() }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// `candidate` with " (2)", " (3)", … inserted before the extension until
    /// `isTaken` says no. Used so two episodes that sanitize to the same name
    /// never overwrite each other.
    static func uniqueURL(_ candidate: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(candidate) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        let dir = candidate.deletingLastPathComponent()
        for n in 2... {
            let url = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
            if !isTaken(url) { return url }
        }
        fatalError("unreachable")
    }
}
