import SwiftUI

/// Shows what's in the master folder, plus anything currently in flight.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    private var active: [DownloadItem] { model.downloads.activeItems }
    private var failed: [DownloadItem] {
        model.downloads.finishedItems
            .filter { if case .failed = $0.state { true } else { false } }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var cancelled: [DownloadItem] {
        model.downloads.finishedItems.filter { $0.state == .cancelled }.sorted { $0.createdAt > $1.createdAt }
    }
    private var totalFiles: Int { model.onDisk.reduce(0) { $0 + $1.files.count } }
    private var totalSize: Int64 { model.onDisk.reduce(0) { $0 + $1.totalSize } }

    var body: some View {
        Group {
            if active.isEmpty, failed.isEmpty, cancelled.isEmpty, model.onDisk.isEmpty {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Episodes you download are saved to\n\(model.settings.masterDirectory.path)"))
            } else {
                List {
                    if !active.isEmpty {
                        Section("In Progress (\(active.count))") {
                            ForEach(active) { DownloadRow(item: $0) }
                        }
                    }
                    if !failed.isEmpty {
                        Section("Failed") {
                            ForEach(failed) { DownloadRow(item: $0) }
                        }
                    }
                    if !cancelled.isEmpty {
                        Section("Cancelled") {
                            ForEach(cancelled) { DownloadRow(item: $0) }
                        }
                    }
                    ForEach(model.onDisk) { folder in
                        Section {
                            ForEach(folder.files) { LocalFileRow(file: $0, folder: folder) }
                        } header: {
                            HStack {
                                Text(folder.name)
                                Spacer()
                                Text("\(folder.files.count) episodes · \(bytes(folder.totalSize))")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationSubtitle("\(totalFiles) files · \(bytes(totalSize)) in \(model.settings.masterDirectory.path)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescanDisk() }
                    .help("Re-read the master folder")
                Button("Open Master Folder", systemImage: "folder") { model.openMasterFolder() }
                Button("Cancel All", systemImage: "xmark.circle") { model.cancelAllDownloads() }
                    .disabled(active.isEmpty)
                Button("Clear Finished", systemImage: "xmark.bin") { model.downloads.clearFinished() }
                    .disabled(failed.isEmpty && cancelled.isEmpty)
                    .help("Remove failed and cancelled entries from this list (files on disk are untouched)")
            }
        }
        .onAppear { model.rescanDisk() }
    }

}

/// A file that exists in the master folder.
struct LocalFileRow: View {
    @Environment(AppModel.self) private var model
    let file: LocalFile
    let folder: PodcastFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isEvicted ? "icloud.and.arrow.down" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(file.isEvicted ? "In iCloud Drive, not downloaded to this Mac" : "")
                .accessibilityLabel(file.isEvicted ? "In iCloud, not on this Mac" : "Audio file")
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.headline).lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.modified, format: .dateTime.year().month(.abbreviated).day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play", systemImage: "play.circle") { model.play(file, in: folder) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Play")
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(file.url) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(file, in: folder) }
        .contextMenu {
            Button("Play") { model.play(file, in: folder) }
            Button("Open in External App") { model.openExternally(file.url) }
            Button("Show in Finder") { model.revealInFinder(file.url) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(file) }
        }
    }
}

/// An in-flight, failed or cancelled queue item.
struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.podcast.artworkURL, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.episode.title).font(.headline).lineLimit(1)
                Text(item.podcast.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                statusLine
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .queued:
            Text(item.autoRetries > 0 ? "Retrying…" : "Waiting…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 8) {
                if let progress = item.progress {
                    ProgressView(value: progress).frame(maxWidth: 240)
                    Text("\(bytes(item.bytesReceived)) of \(bytes(item.bytesExpected))")
                } else {
                    ProgressView().controlSize(.small)
                    Text(bytes(item.bytesReceived))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case .finished:
            Text(item.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text(item.resumeData != nil ? "Cancelled — Retry continues where it stopped" : "Cancelled")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .queued, .downloading:
            Button("Cancel", systemImage: "xmark.circle") { model.cancelDownload(item.id) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .finished:
            Button("Play", systemImage: "play.circle") { model.play(item.episode, from: item.podcast) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .failed, .cancelled:
            Button("Retry") { model.download(item.episode, from: item.podcast) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

}

private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file)
}
