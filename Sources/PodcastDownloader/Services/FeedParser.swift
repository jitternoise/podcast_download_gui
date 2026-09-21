import Foundation

struct ParsedFeed {
    var title: String = ""
    var author: String = ""
    var summary: String = ""
    var artworkURL: URL?
    var episodes: [Episode] = []
    /// Show notes as published, by episode id — only for episodes whose notes
    /// carry more than the plain text in `Episode.summary` (markup, links, or
    /// a longer version). Stored on disk and read on demand, never held for
    /// the whole library.
    var notesHTML: [String: String] = [:]
    /// The URL the feed was actually fetched from — differs from what the user
    /// pasted when a web page pointed us at its RSS feed.
    var sourceURL: URL?
}

struct FeedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Fetches and parses an RSS 2.0 podcast feed (with the common iTunes extensions).
enum FeedLoader {
    /// Real feeds top out around a few MB even with thousands of episodes.
    static let maxFeedBytes: Int64 = 32 << 20

    static func load(_ url: URL) async throws -> ParsedFeed {
        try await load(url, followingDiscovery: true)
    }

    private static func load(_ url: URL, followingDiscovery: Bool) async throws -> ParsedFeed {
        guard url.isWebURL else { throw FeedError(message: "Only http and https feed addresses are supported.") }
        var request = URLRequest(url: url)
        request.setValue("PodcastDownloader/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        // A refresh must ask the server; a feed served with Cache-Control: max-age
        // would otherwise be answered from URLCache for the whole window.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError(message: "Feed returned HTTP \(http.statusCode).")
        }
        // Feeds are parsed in memory; a runaway or hostile response must not
        // be allowed to grow without bound (Refresh All fetches many at once).
        if response.expectedContentLength > maxFeedBytes {
            throw FeedError(message: "The feed is too large to load (over \(maxFeedBytes >> 20) MB).")
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, maxFeedBytes))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxFeedBytes {
                throw FeedError(message: "The feed is too large to load (over \(maxFeedBytes >> 20) MB).")
            }
        }

        // The most common mistake is pasting the show's web page. If that page
        // advertises its feed, use it; otherwise say what went wrong.
        let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased() ?? ""
        if mime.contains("html") || HTMLSniffer.looksLikeHTML(data) {
            if followingDiscovery, let feed = HTMLSniffer.discoverFeed(in: data, relativeTo: url) {
                return try await load(feed, followingDiscovery: false)
            }
            throw FeedError(message: "That address is a web page, not an RSS feed.")
        }
        var feed = try FeedParser().parse(data)
        feed.sourceURL = url
        return feed
    }
}

enum HTMLSniffer {
    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    /// The first `<link rel="alternate" type="application/rss+xml" href="…">` on the page.
    static func discoverFeed(in data: Data, relativeTo base: URL) -> URL? {
        let html = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            guard tag.range(of: "application/rss+xml", options: .caseInsensitive) != nil,
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, url.isWebURL
            else { continue }
            return url
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var rootElement: String?
    private var seenIDs: Set<String> = []

    // Parsing state
    private var inItem = false
    private var inImageElement = false     // classic <image><url>…</url></image>
    private var text = ""

    private var itemTitle = ""
    private var itemGUID = ""
    private var itemSummary = ""
    private var itemDescription = ""
    private var itemContent = ""           // <content:encoded>, the usual home of full HTML notes
    private var itemLink = ""
    private var itemPubDate = ""
    private var itemDuration = ""
    private var itemEnclosureURL: String?
    private var itemEnclosureLength: Int64?
    private var itemEnclosureType: String?

    func parse(_ data: Data) throws -> ParsedFeed {
        if let error = run(data) {
            // Many real feeds contain HTML entities like &nbsp; outside CDATA,
            // which XMLParser rejects outright. Retry once with them escaped.
            guard let lenient = HTMLEntities.escapeNonXMLEntities(in: data) else { throw error }
            reset()
            if let stillFailing = run(lenient) { throw stillFailing }
        }
        switch rootElement {
        case "rss", "rdf:RDF": break
        case "feed": throw FeedError(message: "This is an Atom feed; only RSS podcast feeds are supported.")
        case "html": throw FeedError(message: "That address is a web page, not an RSS feed.")
        default: throw FeedError(message: "This URL does not look like a podcast RSS feed.")
        }
        if feed.title.isEmpty, feed.episodes.isEmpty {
            throw FeedError(message: "This URL does not look like a podcast RSS feed.")
        }
        feed.title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.author = feed.author.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.summary = feed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return feed
    }

    /// One parse pass; nil on success.
    private func run(_ data: Data) -> FeedError? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        if parser.parse() { return nil }
        // XMLParser's own codes are not meaningful to users (nearly everything
        // is reported as 111); the line number is.
        let line = parser.lineNumber
        return FeedError(message: line > 0 ? "The feed isn't valid XML (line \(line))." : "The feed isn't valid XML.")
    }

    private func reset() {
        feed = ParsedFeed()
        rootElement = nil
        seenIDs = []
        inItem = false
        inImageElement = false
        text = ""
        resetItem()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if rootElement == nil { rootElement = elementName }
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
            case "content:encoded": itemContent = value
            case "link": itemLink = value
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
        itemTitle = ""; itemGUID = ""; itemSummary = ""; itemDescription = ""; itemContent = ""; itemLink = ""
        itemPubDate = ""; itemDuration = ""
        itemEnclosureURL = nil; itemEnclosureLength = nil; itemEnclosureType = nil
    }

    private func finishItem() {
        // Episodes without an audio/video enclosure can't be downloaded; skip them.
        // Only web URLs are accepted: a feed must not be able to point the
        // downloader at file:// or other local schemes.
        guard let enclosure = itemEnclosureURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: enclosure), url.isWebURL else { return }
        // Feeds do reuse guids. Keep ids unique so lists, the download queue and
        // the downloaded/position maps can't conflate two episodes.
        var id = itemGUID.isEmpty ? enclosure : itemGUID
        if seenIDs.contains(id) { id += "|" + enclosure }
        if seenIDs.contains(id) { id += "#" + String(feed.episodes.count + 1) }
        seenIDs.insert(id)
        let summary = HTMLStripper.strip(itemSummary.isEmpty ? itemDescription : itemSummary)
        // The fullest version of the notes is kept as published. Feeds put
        // it in any of three places; the longest is the one with the links.
        let notes = [itemContent, itemDescription, itemSummary].max { $0.count < $1.count } ?? ""
        if HTMLStripper.strip(notes) != summary || notes.count > summary.count {
            feed.notesHTML[id] = notes
        }
        feed.episodes.append(Episode(
            id: id,
            title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
            summary: summary,
            publishedAt: RSSDate.parse(itemPubDate),
            enclosureURL: url,
            enclosureLength: itemEnclosureLength,
            mimeType: itemEnclosureType,
            duration: itemDuration.isEmpty ? nil : itemDuration,
            link: URL(string: itemLink).flatMap { $0.isWebURL ? $0 : nil }
        ))
    }
}

extension URL {
    /// True for http(s) URLs with a host — the only kind the app will fetch.
    var isWebURL: Bool {
        guard let scheme = scheme?.lowercased(), let host, !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum RSSDate {
    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm:ss",       // no zone: assume UTC
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm:ss zzz",
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
            if let d = df.date(from: s) { return plausible(d) }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    /// A "yyyy" pattern happily reads "26" as the year 26; feeds that write
    /// two-digit years mean this century.
    private static func plausible(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = cal.component(.year, from: date)
        guard year < 100 else { return date }
        return cal.date(byAdding: .year, value: 2000, to: date) ?? date
    }
}

enum HTMLEntities {
    /// Named HTML entities feeds commonly leak into XML, mapped to code points.
    static let named: [String: Int] = [
        "nbsp": 0xA0, "copy": 0xA9, "reg": 0xAE, "trade": 0x2122, "deg": 0xB0, "middot": 0xB7,
        "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A,
        "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E, "hellip": 0x2026, "bull": 0x2022,
        "laquo": 0xAB, "raquo": 0xBB, "euro": 0x20AC, "pound": 0xA3, "yen": 0xA5, "cent": 0xA2,
        "sect": 0xA7, "para": 0xB6, "times": 0xD7, "divide": 0xF7, "frac12": 0xBD, "frac14": 0xBC,
        "eacute": 0xE9, "egrave": 0xE8, "ecirc": 0xEA, "agrave": 0xE0, "aacute": 0xE1, "acirc": 0xE2,
        "auml": 0xE4, "ouml": 0xF6, "uuml": 0xFC, "Auml": 0xC4, "Ouml": 0xD6, "Uuml": 0xDC, "szlig": 0xDF,
        "ccedil": 0xE7, "ntilde": 0xF1, "iacute": 0xED, "oacute": 0xF3, "uacute": 0xFA, "Eacute": 0xC9,
        "aring": 0xE5, "oslash": 0xF8, "aelig": 0xE6, "iexcl": 0xA1, "iquest": 0xBF, "shy": 0xAD,
    ]
    private static let xmlBuiltins: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// Replaces `&name;` references XML doesn't know with numeric ones (or
    /// escapes the ampersand when the name is unknown). Returns nil when the
    /// data isn't UTF-8 or nothing needed changing.
    static func escapeNonXMLEntities(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);") else { return nil }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var changed = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard !xmlBuiltins.contains(name) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += named[name].map { "&#\($0);" } ?? "&amp;\(name);"
            cursor = match.range.location + match.range.length
            changed = true
        }
        guard changed else { return nil }
        out += ns.substring(from: cursor)
        return Data(out.utf8)
    }
}

enum HTMLStripper {
    /// Cheap tag stripper for episode descriptions — good enough for a list preview.
    static func strip(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes `&amp;`-style, `&#8217;` and `&#x2019;` references, plus the
    /// named entities in `HTMLEntities.named`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let ref = ns.substring(with: match.range(at: 1))
            let replacement: String?
            if ref.hasPrefix("#x") || ref.hasPrefix("#X") {
                replacement = UInt32(ref.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if ref.hasPrefix("#") {
                replacement = UInt32(ref.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                switch ref {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                case "nbsp": replacement = " "
                default: replacement = HTMLEntities.named[ref].flatMap { Unicode.Scalar(UInt32($0)) }.map { String(Character($0)) }
                }
            }
            guard let replacement else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += replacement
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
