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

    /// Transient failures (sleep, Wi-Fi hand-off, timeouts) are retried this many times by themselves.
    static let maxAutoRetries = 2

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var onFinished: ((Episode, URL) -> Void)?
    private var transport: DownloadTransport!
    /// Held while anything is downloading: keeps the Mac from idle-sleeping and
    /// App Nap from throttling us when the window is hidden.
    private var activity: NSObjectProtocol?

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
        items.first { $0.id == episode.key }
    }

    func isQueuedOrActive(_ episode: Episode) -> Bool {
        item(for: episode)?.isActive ?? false
    }

    // MARK: Queue control

    func enqueue(_ episode: Episode, from podcast: Podcast, to destination: URL) {
        if let existing = item(for: episode), existing.isActive { return }
        // A previous attempt at the same destination may have left resume data.
        let previous = item(for: episode)
        items.removeAll { $0.id == episode.key }
        var item = DownloadItem(id: episode.key, episode: episode, podcast: podcast, destination: destination)
        if previous?.destination == destination { item.resumeData = previous?.resumeData }
        items.append(item)
        pump()
    }

    func cancel(_ id: String) {
        if let task = tasks[id] {
            // Keep what was transferred so a later retry can continue.
            task.cancel { [weak self] data in
                Task { @MainActor in self?.storeResumeData(data, for: id) }
            }
        }
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
        defer { updateActivity() }
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

    private func updateActivity() {
        let busy = items.contains { $0.state == .downloading }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Downloading podcast episodes"
            )
        } else if !busy, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func storeResumeData(_ data: Data?, for id: String) {
        guard let data, let idx = items.firstIndex(where: { $0.id == id }), !items[idx].isActive else { return }
        items[idx].resumeData = data
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
            let ns = error as NSError
            let denied = ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError
            setState(item.id, .failed(denied
                ? "macOS denied access to the podcast folder. Allow it in System Settings › Privacy & Security › Files and Folders, or choose another folder in Settings."
                : "Could not create folder: \(error.localizedDescription)"))
            return false
        }
        let task: URLSessionDownloadTask
        if let resumeData = item.resumeData {
            task = transport.resume(resumeData, id: item.id, destination: item.destination, expected: expected(for: item))
        } else {
            var request = URLRequest(url: item.episode.enclosureURL)
            request.setValue("PodcastDownloader/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            task = transport.download(request, id: item.id, destination: item.destination, expected: expected(for: item))
        }
        tasks[item.id] = task
        return true
    }

    private func expected(for item: DownloadItem) -> DownloadTransport.Expectation {
        .init(mimeType: item.episode.mimeType, length: item.episode.enclosureLength)
    }

    // MARK: Callbacks

    private func progress(id: String, received: Int64, expected: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].state == .downloading else { return }
        items[idx].bytesReceived = received
        items[idx].bytesExpected = expected
    }

    private func complete(id: String, result: Result<URL, DownloadTransport.Failure>) {
        tasks[id] = nil
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // A cancelled item already had its state set; don't overwrite it.
        guard items[idx].state == .downloading else { pump(); return }

        switch result {
        case .success(let url):
            items[idx].state = .finished
            items[idx].bytesReceived = items[idx].bytesExpected
            items[idx].resumeData = nil
            onFinished?(items[idx].episode, url)
        case .failure(let failure):
            items[idx].resumeData = failure.resumeData
            if failure.isTransient, items[idx].autoRetries < Self.maxAutoRetries {
                // Sleep, a Wi-Fi hand-off or a stalled CDN: pick up where it stopped.
                items[idx].autoRetries += 1
                items[idx].state = .queued
            } else {
                items[idx].state = .failed(failure.error.localizedDescription)
            }
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
    typealias CompletionHandler = (String, Result<URL, Failure>) -> Void

    /// What the feed said about the enclosure, used to spot bodies that aren't audio.
    struct Expectation {
        var mimeType: String?
        var length: Int64?
    }

    struct Failure: Error {
        let error: Error
        /// Present when URLSession can continue the transfer later.
        let resumeData: Data?

        /// Errors that go away by themselves: lost connection, timeout, offline.
        var isTransient: Bool {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return false }
            return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(ns.code)
        }
    }

    private struct Pending {
        let id: String
        let destination: URL
        let expected: Expectation
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
        // After sleep or a network change, wait for connectivity instead of
        // failing the whole queue with "offline".
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(_ request: URLRequest, id: String, destination: URL, expected: Expectation) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: request)
        lock.withLock { pending[task.taskIdentifier] = Pending(id: id, destination: destination, expected: expected) }
        task.resume()
        return task
    }

    func resume(_ resumeData: Data, id: String, destination: URL, expected: Expectation) -> URLSessionDownloadTask {
        let task = session.downloadTask(withResumeData: resumeData)
        lock.withLock { pending[task.taskIdentifier] = Pending(id: id, destination: destination, expected: expected) }
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
            onComplete(p.id, .failure(Failure(error: FeedError(message: "Server returned HTTP \(http.statusCode)."), resumeData: nil)))
            return
        }
        if let reason = Self.rejectionReason(for: location, response: downloadTask.response, expected: p.expected) {
            onComplete(p.id, .failure(Failure(error: FeedError(message: reason), resumeData: nil)))
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
            onComplete(p.id, .failure(Failure(error: error, resumeData: nil)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is reported from didFinishDownloadingTo; here we only care about failures.
        guard let error, let p = take(task) else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        onComplete(p.id, .failure(Failure(error: error, resumeData: resumeData)))
    }

    /// A 200 with a web page in it (captive portal, hot-link block page) must
    /// not be saved as the episode. Nil means the body looks like media.
    static func rejectionReason(for file: URL, response: URLResponse?, expected: Expectation) -> String? {
        let mime = response?.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("xml") || mime.contains("json") {
            return "Server returned a web page instead of audio (\(mime))."
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        if HTMLSniffer.looksLikeHTML(head) {
            return "Server returned a web page instead of audio."
        }
        return nil
    }
}
