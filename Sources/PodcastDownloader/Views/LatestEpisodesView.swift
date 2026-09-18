import SwiftUI

/// The newest episodes across all subscriptions, newest first.
struct LatestEpisodesView: View {
    @Environment(AppModel.self) private var model

    static let page = 100
    @State private var limit = LatestEpisodesView.page
    @State private var notesFor: EpisodeRef?

    private var items: [EpisodeRef] { model.library.latestEpisodes(limit: limit) }
    private var total: Int { model.library.totalEpisodeCount }

    var body: some View {
        Group {
            if model.library.podcasts.isEmpty {
                ContentUnavailableView("No subscriptions", systemImage: "clock",
                                       description: Text("Subscribe to some podcasts and their newest episodes will appear here."))
            } else if items.isEmpty {
                ContentUnavailableView("No episodes yet", systemImage: "clock",
                                       description: Text("Refresh your subscriptions to load episodes."))
            } else {
                List {
                    ForEach(items) { ref in
                        EpisodeRow(episode: ref.episode, podcast: ref.podcast, showPodcast: true, onShowNotes: { notesFor = ref })
                    }
                    if total > items.count {
                        HStack {
                            Spacer()
                            Button("Show \(min(Self.page, total - items.count)) More (\(total - items.count) older)") {
                                limit += Self.page
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .navigationTitle("Latest Episodes")
        .navigationSubtitle("\(items.count) of \(total) episodes across \(model.library.podcasts.count) subscriptions")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh All", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                    .disabled(!model.library.refreshing.isEmpty)
                    .help("Check every subscription for new episodes (⌘R)")
            }
        }
        .sheet(item: $notesFor) { ref in
            EpisodeNotesView(episode: ref.episode, podcast: ref.podcast)
        }
    }
}
