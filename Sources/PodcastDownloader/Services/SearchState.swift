import Foundation
import Observation
import SwiftUI

/// State of the Search screen. Lives on AppModel rather than in the view so
/// the query, results and pushed detail survive switching sidebar items.
@MainActor
@Observable
final class SearchState {
    var query = ""
    var results: [Podcast] = []
    var isSearching = false
    var searchError: String?

    var feedText = ""
    var isLoadingFeed = false
    var feedError: String?

    var path = NavigationPath()

    private let service = PodcastSearchService()
    private var searchTask: Task<Void, Never>?

    /// Search as you type, debounced so each keystroke doesn't hit the API.
    func queryChanged() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            if term.isEmpty { results = []; searchError = nil }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let found = try await service.search(term)
            guard !Task.isCancelled else { return }
            results = found
            if found.isEmpty { searchError = "No podcasts found for “\(term)”." }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Opens whatever is in the feed field: an RSS URL, a show's web page, or
    /// an Apple Podcasts link. On success the show is pushed onto `path`.
    func addFeed(library: Library) async {
        var text = feedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            feedError = "That doesn't look like a valid URL."
            return
        }
        await open(url, library: library)
    }

    /// Same as `addFeed`, for URLs arriving from outside (feed:// links, drag & drop).
    func open(_ url: URL, library: Library) async {
        isLoadingFeed = true
        feedError = nil
        defer { isLoadingFeed = false }

        // If already subscribed, jump straight to it.
        if let existing = library.podcast(withID: url.absoluteString) {
            feedText = ""
            path.append(existing)
            return
        }

        do {
            let feed: ParsedFeed
            let fallback: Podcast
            if let id = PodcastSearchService.applePodcastsID(in: url) {
                // Apple Podcasts links carry no feed; look the show up.
                let found = try await service.lookup(id: id)
                if let existing = library.podcast(withID: found.id) {
                    feedText = ""
                    path.append(existing)
                    return
                }
                feed = try await FeedLoader.load(found.feedURL)
                fallback = found
            } else {
                feed = try await FeedLoader.load(url)
                // A pasted web page may have led us to its feed; subscribe to that.
                let feedURL = feed.sourceURL ?? url
                if let existing = library.podcast(withID: feedURL.absoluteString) {
                    feedText = ""
                    path.append(existing)
                    return
                }
                fallback = Podcast(title: feedURL.host ?? "Podcast", author: "", feedURL: feedURL)
            }
            let podcast = Self.podcast(from: feed, fallback: fallback)
            let sorted = feed.episodes.sorted(by: Episode.newestFirst)
            library.cacheEpisodes(sorted, for: podcast)
            feedText = ""
            path.append(podcast)
        } catch {
            feedError = error.localizedDescription
        }
    }

    private static func podcast(from feed: ParsedFeed, fallback: Podcast) -> Podcast {
        var podcast = fallback
        if !feed.title.isEmpty { podcast.title = feed.title }
        if !feed.author.isEmpty { podcast.author = feed.author }
        if let source = feed.sourceURL { podcast.feedURL = source }
        if podcast.artworkURL == nil { podcast.artworkURL = feed.artworkURL }
        if !feed.summary.isEmpty { podcast.summary = feed.summary }
        return podcast
    }
}
