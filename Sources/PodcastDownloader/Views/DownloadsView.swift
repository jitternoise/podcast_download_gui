import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.downloads.items.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Episodes you download will show up here."))
            } else {
                List {
                    let active = model.downloads.activeItems
                    let finished = model.downloads.finishedItems.sorted { $0.createdAt > $1.createdAt }
                    if !active.isEmpty {
                        Section("In Progress (\(active.count))") {
                            ForEach(active) { DownloadRow(item: $0) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Finished") {
                            ForEach(finished) { DownloadRow(item: $0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Master Folder", systemImage: "folder") { model.openMasterFolder() }
                Button("Cancel All", systemImage: "xmark.circle") { model.downloads.cancelAll() }
                    .disabled(model.downloads.activeItems.isEmpty)
                Button("Clear Finished", systemImage: "trash") { model.downloads.clearFinished() }
                    .disabled(model.downloads.finishedItems.isEmpty)
            }
        }
    }
}

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
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
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
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .queued, .downloading:
            Button("Cancel", systemImage: "xmark.circle") { model.downloads.cancel(item.id) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .finished:
            Button("Show in Finder", systemImage: "magnifyingglass.circle") { model.revealInFinder(item.destination) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .failed, .cancelled:
            Button("Retry") { model.downloads.retry(item.id) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file)
    }
}
