import AppKit
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
        // The player bar sits *below* the split view rather than as a
        // safe-area inset over it: on macOS the inset doesn't reach into the
        // detail column's List, so the last rows would scroll underneath it.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            if let problem = model.folderProblem {
                FolderProblemBanner(problem: problem)
            }
            PlayerBar()
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

/// Shown above the player bar while the master folder can't be used.
struct FolderProblemBanner: View {
    @Environment(AppModel.self) private var model
    let problem: AppModel.FolderProblem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(model.settings.masterDirectory.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            switch problem {
            case .missing:
                Button("Locate…") { locate() }
                Button("Use Default Folder") { model.adoptMasterDirectory(AppSettings.defaultMasterDirectory) }
            case .noPermission:
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                Button("Choose Another Folder…") { locate() }
            }
            Button("Check Again") { model.rescanDisk() }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
        .overlay(alignment: .top) { Divider() }
    }

    private var title: String {
        switch problem {
        case .missing: "The podcast folder can't be found. Downloads are paused until it's back or you pick another one."
        case .noPermission: "macOS is blocking access to the podcast folder. Downloads will fail until it's allowed."
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that holds your podcast sub-folders."
        if panel.runModal() == .OK, let url = panel.url {
            model.adoptMasterDirectory(url)
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
