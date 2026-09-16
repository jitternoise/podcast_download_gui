import SwiftUI

/// The newest episodes across all subscriptions, newest first.
struct LatestEpisodesView: View {
    @Environment(AppModel.self) private var model

    static let limit = 100

    private var items: [EpisodeRef] { model.library.latestEpisodes(limit: Self.limit) }

    var body: some View {
        Group {
            if model.library.podcasts.isEmpty {
                ContentUnavailableView("No subscriptions", systemImage: "clock",
                                       description: Text("Subscribe to some podcasts and their newest episodes will appear here."))
            } else if items.isEmpty {
                ContentUnavailableView("No episodes yet", systemImage: "clock",
                                       description: Text("Refresh your subscriptions to load episodes."))
            } else {
                List(items) { ref in
                    EpisodeRow(episode: ref.episode, podcast: ref.podcast, showPodcast: true)
                }
            }
        }
        .navigationTitle("Latest Episodes")
        .navigationSubtitle("\(items.count) newest across \(model.library.podcasts.count) subscriptions")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh All", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                    .disabled(!model.library.refreshing.isEmpty)
            }
        }
    }
}
