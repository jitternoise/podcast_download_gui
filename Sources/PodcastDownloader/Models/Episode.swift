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

    /// File extension inferred from the enclosure URL, falling back to the
    /// MIME type and finally to mp3.
    var fileExtension: String {
        let ext = enclosureURL.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        switch mimeType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "video/mp4": return "mp4"
        default: return "mp3"
        }
    }

    /// `2024-03-09 - Episode Title.mp3`
    var fileName: String {
        var name = FileNaming.sanitize(title, fallback: id)
        if let publishedAt {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            name = "\(df.string(from: publishedAt)) - \(name)"
        }
        return "\(name).\(fileExtension)"
    }
}

enum FileNaming {
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)

    /// Strip characters that are illegal or awkward in macOS file names and
    /// clamp the length so very long titles don't hit filesystem limits.
    ///
    /// The fallback is cleaned the same way: it is usually the feed's `<guid>`,
    /// which is attacker-controlled and must never be able to carry a path.
    static func sanitize(_ raw: String, fallback: String) -> String {
        var cleaned = clean(raw)
        if cleaned.isEmpty { cleaned = clean(fallback) }
        if cleaned.isEmpty { cleaned = "Untitled" }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned
    }

    private static func clean(_ raw: String) -> String {
        var cleaned = raw.components(separatedBy: illegal)
            .filter { $0 != "." && $0 != ".." }      // path-only pieces mean nothing as text
            .joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
