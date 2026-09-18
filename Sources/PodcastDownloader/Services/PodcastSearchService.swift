import Foundation

/// Searches the Apple Podcasts directory via the public iTunes Search API.
/// No API key required.
struct PodcastSearchService {
    struct SearchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
    }

    /// The user's App Store country, so results match the store they'd see in Apple Podcasts.
    static var storefront: String { Locale.current.region?.identifier.lowercased() ?? "us" }

    func search(_ term: String) async throws -> [Podcast] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: Self.storefront),
            URLQueryItem(name: "term", value: trimmed),
        ]
        return try await fetch(components.url!)
    }

    /// The Apple Podcasts collection id in a `podcasts.apple.com/…/id12345` link, if it is one.
    static func applePodcastsID(in url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "podcasts.apple.com" || host == "itunes.apple.com" else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "/id([0-9]+)"),
              let m = regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
              let r = Range(m.range(at: 1), in: url.path) else { return nil }
        return String(url.path[r])
    }

    /// Resolves an Apple Podcasts link to the show's feed via the lookup API.
    func lookup(id: String) async throws -> Podcast {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: Self.storefront),
        ]
        guard let podcast = try await fetch(components.url!).first else {
            throw SearchError(message: "Apple Podcasts has no feed for that show.")
        }
        return podcast
    }

    private func fetch(_ url: URL) async throws -> [Podcast] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SearchError(message: "Search failed (HTTP \(http.statusCode)).")
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.results.compactMap { r in
            guard let feed = r.feedUrl, let feedURL = URL(string: feed) else { return nil }
            return Podcast(
                title: r.collectionName ?? "Untitled",
                author: r.artistName ?? "",
                feedURL: feedURL,
                artworkURL: (r.artworkUrl600 ?? r.artworkUrl100).flatMap(URL.init(string:))
            )
        }
    }
}
