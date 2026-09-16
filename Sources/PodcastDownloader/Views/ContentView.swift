import SwiftUI

enum SidebarItem: Hashable {
    case search
    case downloads
    case latest
    case podcast(String)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .search

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            await model.refreshAllIfDue()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Downloads", systemImage: "arrow.down.circle")
                    .badge(model.downloads.activeItems.count)
                    .tag(SidebarItem.downloads)
                Label("Latest Episodes", systemImage: "clock")
                    .tag(SidebarItem.latest)
            }

            Section("Subscriptions") {
                if model.library.podcasts.isEmpty {
                    Text("No subscriptions yet.\nSearch for a show to get started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.library.podcasts) { podcast in
                    PodcastSidebarRow(podcast: podcast)
                        .tag(SidebarItem.podcast(podcast.id))
                        .contextMenu {
                            Button("Refresh") { Task { await model.refresh(podcast) } }
                            Button("Open Folder in Finder") { model.openFolder(for: podcast) }
                            Divider()
                            Button("Unsubscribe", role: .destructive) {
                                if selection == .podcast(podcast.id) { selection = .search }
                                model.library.unsubscribe(podcast)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(model.library.podcasts.isEmpty || !model.library.refreshing.isEmpty)
                Spacer()
                if !model.library.refreshing.isEmpty {
                    ProgressView().controlSize(.small)
                } else if let last = model.library.lastFullRefresh {
                    Text("Updated \(last, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Automatic refresh: \(RefreshPolicy.label(forMinutes: model.settings.autoRefreshMinutes).lowercased())")
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .search, .none:
            SearchView()
        case .downloads:
            DownloadsView()
        case .latest:
            LatestEpisodesView()
        case .podcast(let id):
            if let podcast = model.library.podcast(withID: id) {
                NavigationStack {
                    PodcastDetailView(podcast: podcast)
                }
            } else {
                ContentUnavailableView("Podcast not found", systemImage: "questionmark.circle")
            }
        }
    }
}

struct PodcastSidebarRow: View {
    @Environment(AppModel.self) private var model
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(url: podcast.artworkURL, size: 24)
            Text(podcast.title)
                .lineLimit(1)
            Spacer()
            if model.library.refreshing.contains(podcast.id) {
                ProgressView().controlSize(.mini)
            } else if model.library.refreshErrors[podcast.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(model.library.refreshErrors[podcast.id] ?? "")
            }
        }
    }
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                        .font(.system(size: size * 0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}
