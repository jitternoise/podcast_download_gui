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
    /// Strip characters that are illegal or awkward in macOS file names and
    /// clamp the length so very long titles don't hit filesystem limits.
    static func sanitize(_ raw: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Finder treats a leading dot as hidden.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = fallback }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned
    }
}
