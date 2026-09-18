import Foundation
import Observation

/// Queues episode downloads, limits concurrency, reports progress, and moves
/// finished files into `<master>/<podcast>/<episode>.<ext>`.
@MainActor
@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []

    var maxConcurrent: Int = 3 {
        didSet { pump() }
    }

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var onFinished: ((Episode, URL) -> Void)?
    private var transport: DownloadTransport!

    init() {
        transport = DownloadTransport(
            onProgress: { [weak self] id, received, expected in
                Task { @MainActor in self?.progress(id: id, received: received, expected: expected) }
            },
            onComplete: { [weak self] id, result in
                Task { @MainActor in self?.complete(id: id, result: result) }
            }
        )
    }

    /// Called on the main actor whenever a download lands on disk.
    func setFinishedHandler(_ handler: @escaping (Episode, URL) -> Void) {
        onFinished = handler
    }

    var activeItems: [DownloadItem] { items.filter(\.isActive) }
    var finishedItems: [DownloadItem] { items.filter { !$0.isActive } }

    func item(for episode: Episode) -> DownloadItem? {
        items.first { $0.id == episode.id }
    }

    func isQueuedOrActive(_ episode: Episode) -> Bool {
        item(for: episode)?.isActive ?? false
    }

    // MARK: Queue control

    func enqueue(_ episode: Episode, from podcast: Podcast, to destination: URL) {
        if let existing = item(for: episode), existing.isActive { return }
        items.removeAll { $0.id == episode.id }
        items.append(DownloadItem(id: episode.id, episode: episode, podcast: podcast, destination: destination))
        pump()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        transport.forget(id)
        setState(id, .cancelled)
        pump()
    }

    func cancelAll() {
        for id in items.filter(\.isActive).map(\.id) { cancel(id) }
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    func retry(_ id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }), !items[idx].isActive else { return }
        items[idx].state = .queued
        items[idx].bytesReceived = 0
        items[idx].bytesExpected = -1
        pump()
    }

    /// Start queued downloads until the concurrency limit is reached.
    private func pump() {
        let running = items.filter { $0.state == .downloading }.count
        var slots = max(0, maxConcurrent - running)
        guard slots > 0 else { return }

        for idx in items.indices where items[idx].state == .queued && slots > 0 {
            // start() marks the item .failed itself when it can't begin; only a
            // real task occupies a slot.
            if start(items[idx]) {
                items[idx].state = .downloading
                slots -= 1
            }
        }
    }

    /// Kicks off the transfer. Returns false (and marks the item failed) if it can't.
    private func start(_ item: DownloadItem) -> Bool {
        guard item.episode.enclosureURL.isWebURL else {
            setState(item.id, .failed("Unsupported URL: \(item.episode.enclosureURL.absoluteString)"))
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: item.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            setState(item.id, .failed("Could not create folder: \(error.localizedDescription)"))
            return false
        }
        var request = URLRequest(url: item.episode.enclosureURL)
        request.setValue("PodcastDownloader/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let task = transport.download(request, id: item.id, destination: item.destination)
        tasks[item.id] = task
        return true
    }

    // MARK: Callbacks

    private func progress(id: String, received: Int64, expected: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].state == .downloading else { return }
        items[idx].bytesReceived = received
        items[idx].bytesExpected = expected
    }

    private func complete(id: String, result: Result<URL, Error>) {
        tasks[id] = nil
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // A cancelled item already had its state set; don't overwrite it.
        guard items[idx].state == .downloading else { pump(); return }

        switch result {
        case .success(let url):
            items[idx].state = .finished
            items[idx].bytesReceived = items[idx].bytesExpected
            onFinished?(items[idx].episode, url)
        case .failure(let error):
            items[idx].state = .failed(error.localizedDescription)
        }
        pump()
    }

    private func setState(_ id: String, _ state: DownloadItem.State) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = state
    }
}

/// URLSession delegate wrapper. Lives off the main actor; forwards events via closures.
final class DownloadTransport: NSObject, URLSessionDownloadDelegate {
    typealias ProgressHandler = (String, Int64, Int64) -> Void
    typealias CompletionHandler = (String, Result<URL, Error>) -> Void

    private struct Pending {
        let id: String
        let destination: URL
    }

    private let onProgress: ProgressHandler
    private let onComplete: CompletionHandler
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]      // task identifier -> pending
    private var session: URLSession!

    init(onProgress: @escaping ProgressHandler, onComplete: @escaping CompletionHandler) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(_ request: URLRequest, id: String, destination: URL) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: request)
        lock.withLock { pending[task.taskIdentifier] = Pending(id: id, destination: destination) }
        task.resume()
        return task
    }

    func forget(_ id: String) {
        lock.withLock { pending = pending.filter { $0.value.id != id } }
    }

    private func take(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
    }

    private func peek(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending[task.taskIdentifier] }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let p = peek(downloadTask) else { return }
        onProgress(p.id, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted as soon as this method returns, so the move must be synchronous.
        guard let p = take(downloadTask) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onComplete(p.id, .failure(FeedError(message: "Server returned HTTP \(http.statusCode).")))
            return
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: p.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: p.destination.path) {
                try fm.removeItem(at: p.destination)
            }
            try fm.moveItem(at: location, to: p.destination)
            onComplete(p.id, .success(p.destination))
        } catch {
            onComplete(p.id, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is reported from didFinishDownloadingTo; here we only care about failures.
        guard let error, let p = take(task) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onComplete(p.id, .failure(error))
    }
}
