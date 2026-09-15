import SwiftUI

struct PodcastDetailView: View {
    @Environment(AppModel.self) private var model
    let podcast: Podcast

    /// The library's copy when subscribed (it carries auto-download and refreshed metadata).
    private var current: Podcast { model.library.podcast(withID: podcast.id) ?? podcast }
    private var isSubscribed: Bool { model.library.isSubscribed(podcast) }
    private var episodes: [Episode] { model.library.episodes(for: podcast) }
    private var isRefreshing: Bool { model.library.refreshing.contains(podcast.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            episodeList
        }
        .navigationTitle(current.title)
        .toolbar { toolbarContent }
        .task(id: podcast.id) {
            if episodes.isEmpty { await model.refresh(podcast) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(url: current.artworkURL, size: 110)

            VStack(alignment: .leading, spacing: 6) {
                Text(current.title).font(.title2.bold())
                if !current.author.isEmpty {
                    Text(current.author).font(.headline).foregroundStyle(.secondary)
                }
                if let summary = current.summary, !summary.isEmpty {
                    Text(HTMLStripper.strip(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 12) {
                    Text("\(episodes.count) episodes")
                    Text("·")
                    Text("\(downloadedCount) downloaded")
                    if let date = model.library.lastRefreshed[podcast.id] {
                        Text("·")
                        Text("Updated \(date, style: .relative) ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

                if isSubscribed {
                    Toggle("Automatically download new episodes", isOn: autoDownloadBinding)
                        .toggleStyle(.checkbox)
                        .padding(.top, 4)
                }

                if let error = model.library.refreshErrors[podcast.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding()
    }

    private var autoDownloadBinding: Binding<Bool> {
        Binding(
            get: { current.autoDownload },
            set: { newValue in
                var p = current
                p.autoDownload = newValue
                model.library.update(p)
            }
        )
    }

    private var downloadedCount: Int {
        episodes.filter { model.localFile(for: $0, in: current) != nil }.count
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodeList: some View {
        if episodes.isEmpty {
            if isRefreshing {
                ContentUnavailableView("Loading episodes…", systemImage: "antenna.radiowaves.left.and.right")
            } else {
                ContentUnavailableView("No episodes", systemImage: "tray",
                                       description: Text("The feed didn't return any downloadable episodes."))
            }
        } else {
            List(episodes) { episode in
                EpisodeRow(episode: episode, podcast: current)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isSubscribed {
                Button {
                    model.library.unsubscribe(podcast)
                } label: {
                    Label("Unsubscribe", systemImage: "minus.circle")
                }
                .help("Remove this podcast from your subscriptions (downloaded files are kept)")
            } else {
                Button {
                    model.library.subscribe(current)
                } label: {
                    Label("Subscribe", systemImage: "plus.circle")
                }
                .help("Add this podcast to your subscriptions")
            }

            Button {
                Task { await model.refresh(podcast) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            .help("Reload the feed")

            Button {
                model.downloadAll(current)
            } label: {
                Label("Download All", systemImage: "arrow.down.to.line")
            }
            .disabled(episodes.isEmpty)
            .help("Download every episode that isn't already on disk")

            Button {
                model.openFolder(for: current)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .help("Show this podcast's folder in Finder")
        }
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: Episode
    let podcast: Podcast

    private var localFile: URL? { model.localFile(for: episode, in: podcast) }
    private var downloadItem: DownloadItem? { model.downloads.item(for: episode) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let date = episode.publishedAt {
                        Text(date, format: .dateTime.year().month(.abbreviated).day())
                    }
                    if let duration = episode.duration {
                        Text("·"); Text(formatDuration(duration))
                    }
                    if let length = episode.enclosureLength, length > 0 {
                        Text("·"); Text(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !episode.summary.isEmpty {
                    Text(episode.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.downloadAndPlay(episode, from: podcast)
        }
        .help(localFile == nil ? "Double-click to download and play" : "Double-click to play")
        .contextMenu {
            if let localFile {
                Button("Play") { model.play(localFile) }
                Button("Show in Finder") { model.revealInFinder(localFile) }
                Divider()
                Button("Download Again") { model.download(episode, from: podcast) }
            } else {
                Button("Download and Play") { model.downloadAndPlay(episode, from: podcast) }
                Button("Download") { model.download(episode, from: podcast) }
                    .disabled(model.downloads.isQueuedOrActive(episode))
            }
            Button("Copy Audio URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(episode.enclosureURL.absoluteString, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let localFile {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button {
                    model.play(localFile)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play")
                Button {
                    model.revealInFinder(localFile)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            .frame(width: 130, alignment: .trailing)
        } else if let item = downloadItem, item.isActive {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let progress = item.progress {
                        ProgressView(value: progress).frame(width: 90)
                        Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(item.state == .queued ? "Queued" : "Starting…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.cancelDownload(item.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
            .frame(width: 130, alignment: .trailing)
        } else if let item = downloadItem, case .failed(let message) = item.state {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(message)
                Button("Retry") { model.download(episode, from: podcast) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(width: 130, alignment: .trailing)
        } else {
            Button {
                model.download(episode, from: podcast)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 130, alignment: .trailing)
        }
    }

    /// iTunes duration is either seconds ("3600") or HH:MM:SS / MM:SS.
    private func formatDuration(_ raw: String) -> String {
        if let seconds = Int(raw) {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return h > 0 ? "\(h)h \(m)m" : "\(m) min"
        }
        return raw
    }
}
