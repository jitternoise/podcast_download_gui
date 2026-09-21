import AppKit
import SwiftUI

struct PodcastDetailView: View {
    @Environment(AppModel.self) private var model
    let podcast: Podcast

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", downloaded = "Downloaded", unplayed = "Unplayed"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest First", oldest = "Oldest First"
        var id: String { rawValue }
    }

    @State private var selectedID: Episode.ID?
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .newest
    @State private var downloadedCount = 0
    @State private var confirmDownloadAll = false
    @State private var confirmUnsubscribe = false
    @State private var notesFor: Episode?

    /// The library's copy when subscribed (it carries auto-download and refreshed metadata).
    private var current: Podcast { model.library.podcast(withID: podcast.id) ?? podcast }
    private var isSubscribed: Bool { model.library.isSubscribed(podcast) }
    private var episodes: [Episode] { model.library.episodes(for: podcast) }
    private var isRefreshing: Bool { model.library.refreshing.contains(podcast.id) }

    private var visibleEpisodes: [Episode] {
        var list = episodes
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.summary.localizedCaseInsensitiveContains(needle) }
        }
        switch filter {
        case .all: break
        case .downloaded: list = list.filter { model.localFile(for: $0, in: current) != nil }
        case .unplayed: list = list.filter { !model.library.isPlayed($0) }
        }
        if sort == .oldest { list.reverse() }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            episodeList
        }
        .navigationTitle(current.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search episodes")
        .toolbar { toolbarContent }
        .task(id: podcast.id) {
            // Detached from this view's lifetime: navigating away must not
            // cancel the fetch (and record "cancelled" as a feed error).
            if episodes.isEmpty { Task { await model.refresh(current) } }
        }
        .onAppear { recount() }
        .onChange(of: model.onDisk) { _, _ in recount() }
        .onChange(of: model.library.downloaded.count) { _, _ in recount() }
        .onChange(of: episodes.count) { _, _ in recount() }
        .confirmationDialog(downloadAllTitle, isPresented: $confirmDownloadAll, titleVisibility: .visible) {
            Button("Download \(missingEpisodes.count) Episodes") { model.downloadAll(current) }
        } message: {
            Text(downloadAllMessage)
        }
        .confirmationDialog("Unsubscribe from “\(current.title)”?", isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { model.library.unsubscribe(podcast) }
        } message: {
            Text("Downloaded files are kept. The show stops refreshing and disappears from the sidebar.")
        }
        .sheet(item: $notesFor) { episode in
            EpisodeNotesView(episode: episode, podcast: current)
        }
    }

    /// `downloadedCount` stats every episode; do it when something changed,
    /// not on every body evaluation.
    private func recount() {
        downloadedCount = model.downloadedCount(for: current)
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
                    HStack(spacing: 16) {
                        Toggle("Automatically download new episodes", isOn: autoDownloadBinding)
                            .toggleStyle(.checkbox)
                        if current.autoDownload {
                            Stepper(value: keepLatestBinding, in: 0...100) {
                                Text(current.keepLatest == 0 ? "Keep all" : "Keep latest \(current.keepLatest)")
                                    .font(.callout)
                            }
                            .help("Older auto-downloads are moved to the Trash once this many are on disk. 0 keeps everything.")
                        }
                    }
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

    private var keepLatestBinding: Binding<Int> {
        Binding(
            get: { current.keepLatest },
            set: { newValue in
                var p = current
                p.keepLatest = newValue
                model.library.update(p)
                model.applyKeepLatest(for: p)
            }
        )
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodeList: some View {
        if episodes.isEmpty {
            if isRefreshing {
                ContentUnavailableView("Loading episodes…", systemImage: "antenna.radiowaves.left.and.right")
            } else if let error = model.library.refreshErrors[podcast.id] {
                ContentUnavailableView("Couldn't load episodes", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ContentUnavailableView("No episodes", systemImage: "tray",
                                       description: Text("The feed didn't return any downloadable episodes."))
            }
        } else if visibleEpisodes.isEmpty {
            ContentUnavailableView.search(text: searchText.isEmpty ? filter.rawValue : searchText)
        } else {
            List(visibleEpisodes, selection: $selectedID) { episode in
                EpisodeRow(episode: episode, podcast: current, onShowNotes: { notesFor = episode })
                    .tag(episode.id)
            }
            .onKeyPress(.return) { playSelected(); return .handled }
            .onKeyPress(.delete) { deleteSelected(); return .handled }
            .onKeyPress(.space) { model.player.togglePlayPause(); return .handled }
        }
    }

    private var selectedEpisode: Episode? {
        selectedID.flatMap { id in episodes.first { $0.id == id } }
    }

    private func playSelected() {
        guard let episode = selectedEpisode else { return }
        model.downloadAndPlay(episode, from: current)
    }

    private func deleteSelected() {
        guard let episode = selectedEpisode else { return }
        model.deleteDownload(of: episode, in: current)
    }

    // MARK: Toolbar

    private var missingEpisodes: [Episode] {
        episodes.filter { model.localFile(for: $0, in: current) == nil && !model.downloads.isQueuedOrActive($0) }
    }

    private var downloadAllTitle: String {
        "Download all \(missingEpisodes.count) episodes of “\(current.title)”?"
    }

    private var downloadAllMessage: String {
        let bytes = missingEpisodes.compactMap(\.enclosureLength).reduce(0, +)
        let unknown = missingEpisodes.filter { ($0.enclosureLength ?? 0) <= 0 }.count
        var text = bytes > 0 ? "About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "Size unknown"
        if bytes > 0, unknown > 0 { text += " (plus \(unknown) of unknown size)" }
        return text + ". Files go to \(model.settings.folder(for: current).path)."
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Filter", systemImage: filter == .all && sort == .newest ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter and sort episodes")

            if isSubscribed {
                Button {
                    confirmUnsubscribe = true
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
                Task { await model.refresh(current) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            .help("Reload the feed")

            Button {
                confirmDownloadAll = true
            } label: {
                Label("Download All", systemImage: "arrow.down.to.line")
            }
            .disabled(missingEpisodes.isEmpty)
            .help(missingEpisodes.isEmpty ? "Every episode is already on disk" : "Download every episode that isn't already on disk")

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
    /// Show the podcast's artwork and name — used in cross-podcast lists.
    var showPodcast = false
    var onShowNotes: (() -> Void)?

    private var localFile: URL? { model.localFile(for: episode, in: podcast) }
    private var downloadItem: DownloadItem? { model.downloads.item(for: episode) }
    private var isPlayed: Bool { model.library.isPlayed(episode) }
    private var position: Double { model.library.playbackPosition(for: episode) }
    private var isLoaded: Bool { model.isCurrentlyLoaded(episode) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showPodcast {
                ArtworkView(url: podcast.artworkURL, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !isPlayed, localFile != nil, position == 0 {
                        Circle().fill(.tint).frame(width: 7, height: 7)
                            .accessibilityLabel("Unplayed")
                    }
                    Text(episode.title).font(.headline).lineLimit(2)
                        .foregroundStyle(isPlayed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                metaLine
                if !episode.summary.isEmpty {
                    Text(episode.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                progressLine
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
        .contextMenu { contextMenu }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if showPodcast {
                Text(podcast.title).lineLimit(1)
                Text("·")
            }
            if let date = episode.publishedAt {
                Text(date, format: .dateTime.year().month(.abbreviated).day())
            }
            if let seconds = episode.durationSeconds {
                Text("·"); Text(TimeText.duration(seconds))
            }
            if let length = episode.enclosureLength, length > 0 {
                Text("·"); Text(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
            }
            if isPlayed {
                Text("·"); Label("Played", systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var progressLine: some View {
        let total = episode.durationSeconds.map(Double.init) ?? (isLoaded ? model.player.duration : 0)
        if position > 0, total > 0 {
            HStack(spacing: 8) {
                ProgressView(value: min(position, total), total: total)
                    .frame(width: 120)
                    .controlSize(.small)
                Text("\(TimeText.duration(Int(total - position))) left")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(TimeText.duration(Int(total - position))) remaining")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let localFile {
            Button("Play") { model.play(episode, from: podcast) }
            Button("Open in External App") { model.openExternally(localFile) }
            Button("Show in Finder") { model.revealInFinder(localFile) }
            Divider()
            Button("Download Again") { model.download(episode, from: podcast) }
            Button("Delete Download", role: .destructive) { model.deleteDownload(of: episode, in: podcast) }
        } else {
            Button("Download and Play") { model.downloadAndPlay(episode, from: podcast) }
            Button("Download") { model.download(episode, from: podcast) }
                .disabled(model.downloads.isQueuedOrActive(episode))
        }
        Divider()
        Button(isPlayed ? "Mark as Unplayed" : "Mark as Played") { model.library.setPlayed(episode, !isPlayed) }
        if let onShowNotes {
            Button("Show Notes…") { onShowNotes() }
        }
        if let link = episode.link {
            Button("Open Episode Page") { model.openExternally(link) }
        }
        Button("Copy Audio URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(episode.enclosureURL.absoluteString, forType: .string)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let localFile {
            HStack(spacing: 6) {
                if isLoaded {
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                        .help("Now playing")
                        .accessibilityLabel("Now playing")
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Downloaded")
                }
                Button("Play", systemImage: "play.circle") { model.play(episode, from: podcast) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Play")
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder(localFile) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Show in Finder")
                Button("Delete Download", systemImage: "trash") { model.deleteDownload(of: episode, in: podcast) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Move the downloaded file to the Trash")
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
                Button("Cancel", systemImage: "xmark.circle") { model.cancelDownload(item.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Cancel")
            }
            .frame(width: 130, alignment: .trailing)
        } else if let item = downloadItem, case .failed(let message) = item.state {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(message)
                    .accessibilityLabel("Failed: \(message)")
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
}

/// Full show notes for one episode, as the feed published them (links and
/// all) when that's more than the plain text in the list.
struct EpisodeNotesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let episode: Episode
    let podcast: Podcast
    @State private var rendered: AttributedString?

    private var notes: AttributedString {
        rendered ?? AttributedString(episode.summary.isEmpty ? "This episode has no show notes." : episode.summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(url: podcast.artworkURL, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).font(.title3.bold())
                    Text(podcast.title).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let date = episode.publishedAt {
                            Text(date, format: .dateTime.year().month(.abbreviated).day())
                        }
                        if let seconds = episode.durationSeconds { Text("·"); Text(TimeText.duration(seconds)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy Audio URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(episode.enclosureURL.absoluteString, forType: .string)
                }
                if let link = episode.link {
                    Button("Open Episode Page") { model.openExternally(link) }
                }
                Spacer()
                Button(model.localFile(for: episode, in: podcast) == nil ? "Download and Play" : "Play") {
                    model.downloadAndPlay(episode, from: podcast)
                    dismiss()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: episode.key) {
            guard let html = await model.library.notesHTML(for: episode) else { return }
            rendered = NotesRenderer.hasMarkup(html) ? NotesRenderer.render(html) : AttributedString(html)
        }
    }
}
