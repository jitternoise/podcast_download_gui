import Foundation

/// Minimal OPML 2.0 reader/writer — the interchange format every podcast app
/// speaks, so subscriptions can move between Macs and apps.
enum OPML {
    struct Entry: Equatable {
        let title: String
        let feedURL: URL
    }

    static func export(_ podcasts: [Podcast]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head>\n    <title>Podcast Downloader subscriptions</title>\n  </head>\n  <body>\n"
        for p in podcasts {
            xml += "    <outline type=\"rss\" text=\"\(escape(p.title))\" title=\"\(escape(p.title))\" xmlUrl=\"\(escape(p.feedURL.absoluteString))\"/>\n"
        }
        xml += "  </body>\n</opml>\n"
        return Data(xml.utf8)
    }

    static func parse(_ data: Data) throws -> [Entry] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw FeedError(message: "That file isn't valid OPML.")
        }
        guard reader.sawOPML else { throw FeedError(message: "That file isn't an OPML subscription list.") }
        return reader.entries
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var sawOPML = false
        private var seen: Set<String> = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if elementName.lowercased() == "opml" { sawOPML = true }
            guard elementName.lowercased() == "outline",
                  let raw = attributes["xmlUrl"] ?? attributes["xmlurl"] ?? attributes["url"],
                  let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.isWebURL,
                  !seen.contains(url.absoluteString) else { return }
            seen.insert(url.absoluteString)
            let title = attributes["title"] ?? attributes["text"] ?? url.host ?? "Podcast"
            entries.append(Entry(title: title, feedURL: url))
        }
    }
}
