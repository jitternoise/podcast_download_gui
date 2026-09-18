import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var search = model.search

        NavigationStack(path: $search.path) {
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
        @Bindable var search = model.search

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search Apple Podcasts…", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search.runSearch() } }
                    .onChange(of: search.query) { _, _ in search.queryChanged() }
                    .accessibilityLabel("Search Apple Podcasts")
                if search.isSearching { ProgressView().controlSize(.small) }
            }
            if let error = search.searchError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                TextField("Or paste an RSS feed, show web page, or Apple Podcasts link…", text: $search.feedText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search.addFeed(library: model.library) } }
                    .accessibilityLabel("Feed or show address")
                Button("Open") { Task { await search.addFeed(library: model.library) } }
                    .disabled(search.feedText.trimmingCharacters(in: .whitespaces).isEmpty || search.isLoadingFeed)
                if search.isLoadingFeed { ProgressView().controlSize(.small) }
            }
            if let error = search.feedError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var resultsList: some View {
        if model.search.results.isEmpty {
            ContentUnavailableView(
                model.search.isSearching ? "Searching…" : "Find a podcast",
                systemImage: "magnifyingglass",
                description: Text("Search by show name, host, or topic — results appear as you type — or paste a feed URL above.")
            )
        } else {
            List(model.search.results) { podcast in
                NavigationLink(value: podcast) {
                    SearchResultRow(podcast: podcast)
                }
            }
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
