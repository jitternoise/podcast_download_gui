import AppKit
import Foundation

/// Turns show notes as the feed published them into text SwiftUI can show:
/// paragraphs, links that open, bold and italic — in the app's own font and
/// colours, not the feed's.
enum NotesRenderer {
    /// Whether the notes contain any markup worth rendering (otherwise the
    /// plain text is shown as is, newlines and all).
    static func hasMarkup(_ html: String) -> Bool {
        html.range(of: "<\\s*[A-Za-z!/]", options: .regularExpression) != nil
    }

    /// Elements that would fetch something or embed a player. Notes are text.
    private static let dropped = try! NSRegularExpression(
        pattern: "<\\s*(script|style|iframe|object|embed|video|audio|img|link|meta)\\b[^>]*>(.*?<\\s*/\\s*\\1\\s*>)?",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Must run on the main thread: AppKit's HTML importer requires it.
    @MainActor
    static func render(_ html: String) -> AttributedString {
        let cleaned = dropped.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        guard let source = try? NSAttributedString(
            data: Data(cleaned.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else {
            return AttributedString(HTMLStripper.strip(html))
        }
        // Keep only what carries meaning: the text, links, bold and italic.
        var runs: [(text: String, link: URL?, bold: Bool, italic: Bool)] = []
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            let link = (attrs[.link] as? URL ?? (attrs[.link] as? String).flatMap(URL.init(string:))).flatMap { $0.isWebURL ? $0 : nil }
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            runs.append((source.attributedSubstring(from: range).string, link, traits.contains(.bold), traits.contains(.italic)))
        }
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece[AttributeScopes.FoundationAttributes.LinkAttribute.self] = run.link
            if run.bold { piece[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized }
            if run.italic { piece[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .emphasized }
            out += piece
        }
        // The importer ends every paragraph with a newline; drop the trailing run of them.
        while out.characters.last?.isNewline == true { out.characters.removeLast() }
        return out
    }
}
