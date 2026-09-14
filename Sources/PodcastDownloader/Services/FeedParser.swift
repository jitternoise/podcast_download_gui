import Foundation

struct ParsedFeed {
    var title: String = ""
    var author: String = ""
    var summary: String = ""
    var artworkURL: URL?
    var episodes: [Episode] = []
}

struct FeedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Fetches and parses an RSS 2.0 podcast feed (with the common iTunes extensions).
enum FeedLoader {
    static func load(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.setValue("PodcastDownloader/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError(message: "Feed returned HTTP \(http.statusCode).")
        }
        return try FeedParser().parse(data)
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var parseError: Error?

    // Parsing state
    private var inItem = false
    private var inImageElement = false     // classic <image><url>…</url></image>
    private var text = ""

    private var itemTitle = ""
    private var itemGUID = ""
    private var itemSummary = ""
    private var itemDescription = ""
    private var itemPubDate = ""
    private var itemDuration = ""
    private var itemEnclosureURL: String?
    private var itemEnclosureLength: Int64?
    private var itemEnclosureType: String?

    func parse(_ data: Data) throws -> ParsedFeed {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "unknown error"
            throw FeedError(message: "Could not parse feed: \(detail)")
        }
        if feed.title.isEmpty, feed.episodes.isEmpty {
            throw FeedError(message: "This URL does not look like a podcast RSS feed.")
        }
        feed.title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.author = feed.author.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.summary = feed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return feed
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch elementName {
        case "item":
            inItem = true
            resetItem()
        case "enclosure" where inItem:
            itemEnclosureURL = attributes["url"]
            itemEnclosureLength = attributes["length"].flatMap { Int64($0) }
            itemEnclosureType = attributes["type"]
        case "itunes:image" where !inItem:
            if feed.artworkURL == nil, let href = attributes["href"], let url = URL(string: href) {
                feed.artworkURL = url
            }
        case "image" where !inItem:
            inImageElement = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch elementName {
            case "item":
                inItem = false
                finishItem()
            case "title": itemTitle = value
            case "guid": itemGUID = value
            case "pubDate": itemPubDate = value
            case "description": itemDescription = value
            case "itunes:summary": itemSummary = value
            case "itunes:duration": itemDuration = value
            default: break
            }
            return
        }

        switch elementName {
        case "title" where !inImageElement:
            if feed.title.isEmpty { feed.title = value }
        case "itunes:author":
            if feed.author.isEmpty { feed.author = value }
        case "description", "itunes:summary":
            if feed.summary.isEmpty { feed.summary = value }
        case "url" where inImageElement:
            if feed.artworkURL == nil, let url = URL(string: value) { feed.artworkURL = url }
        case "image":
            inImageElement = false
        default:
            break
        }
    }

    // MARK: Helpers

    private func resetItem() {
        itemTitle = ""; itemGUID = ""; itemSummary = ""; itemDescription = ""
        itemPubDate = ""; itemDuration = ""
        itemEnclosureURL = nil; itemEnclosureLength = nil; itemEnclosureType = nil
    }

    private func finishItem() {
        // Episodes without an audio/video enclosure can't be downloaded; skip them.
        guard let enclosure = itemEnclosureURL, let url = URL(string: enclosure) else { return }
        let id = itemGUID.isEmpty ? enclosure : itemGUID
        let summary = itemSummary.isEmpty ? itemDescription : itemSummary
        feed.episodes.append(Episode(
            id: id,
            title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
            summary: HTMLStripper.strip(summary),
            publishedAt: RSSDate.parse(itemPubDate),
            enclosureURL: url,
            enclosureLength: itemEnclosureLength,
            mimeType: itemEnclosureType,
            duration: itemDuration.isEmpty ? nil : itemDuration
        ))
    }
}

enum RSSDate {
    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
        ]
        return formats.map { format in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = format
            return df
        }
    }()

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for df in formatters {
            if let d = df.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

enum HTMLStripper {
    /// Cheap tag stripper for episode descriptions — good enough for a list preview.
    static func strip(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
