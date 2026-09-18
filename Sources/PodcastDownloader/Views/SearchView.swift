import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [Podcast] = []
    @State private var isSearching = false
    @State private var searchError: String?

    @State private var feedText = ""
    @State private var isLoadingFeed = false
    @State private var feedError: String?

    @State private var path = NavigationPath()

    private let service = PodcastSearchService()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                Divider()
                resultsList
            }
            .navigationTitle("Search")
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search Apple Podcasts…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runSearch() } }
                Button("Search") { Task { await runSearch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching { ProgressView().controlSize(.small) }
            }
            if let searchError {
                Text(searchError).font(.callout).foregroundStyle(.red)
            }

            HStack {
                TextField("Or paste an RSS feed URL…", text: $feedText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addFeed() } }
                Button("Open Feed") { Task { await addFeed() } }
                    .disabled(feedText.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingFeed)
                if isLoadingFeed { ProgressView().controlSize(.small) }
            }
            if let feedError {
                Text(feedError).font(.callout).foregroundStyle(.red)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            ContentUnavailableView(
                isSearching ? "Searching…" : "Find a podcast",
                systemImage: "magnifyingglass",
                description: Text("Search by show name, host, or topic, or paste a feed URL above.")
            )
        } else {
            List(results) { podcast in
                NavigationLink(value: podcast) {
                    SearchResultRow(podcast: podcast)
                }
            }
        }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await service.search(term)
            if results.isEmpty { searchError = "No podcasts found for “\(term)”." }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func addFeed() async {
        var text = feedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            feedError = "That doesn't look like a valid URL."
            return
        }
        isLoadingFeed = true
        feedError = nil
        defer { isLoadingFeed = false }

        // If already subscribed, jump straight to it.
        if let existing = model.library.podcast(withID: url.absoluteString) {
            path.append(existing)
            return
        }

        do {
            let feed = try await FeedLoader.load(url)
            // A pasted web page may have led us to its feed; subscribe to that.
            let feedURL = feed.sourceURL ?? url
            if let existing = model.library.podcast(withID: feedURL.absoluteString) {
                feedText = ""
                path.append(existing)
                return
            }
            let podcast = Podcast(
                title: feed.title.isEmpty ? feedURL.host ?? "Podcast" : feed.title,
                author: feed.author,
                feedURL: feedURL,
                artworkURL: feed.artworkURL,
                summary: feed.summary
            )
            let sorted = feed.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            model.library.cacheEpisodes(sorted, for: podcast)
            feedText = ""
            path.append(podcast)
        } catch {
            feedError = error.localizedDescription
        }
    }
}

struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: podcast.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.headline).lineLimit(1)
                Text(podcast.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.library.isSubscribed(podcast) {
                Label("Subscribed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Subscribe") { model.library.subscribe(podcast) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
