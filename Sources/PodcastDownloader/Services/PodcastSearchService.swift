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

    func search(_ term: String) async throws -> [Podcast] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "term", value: trimmed),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
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
