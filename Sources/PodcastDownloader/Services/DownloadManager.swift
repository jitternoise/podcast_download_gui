import Foundation
import Observation

/// Queues episode downloads, limits concurrency, reports progress, and moves
/// finished files into `<master>/<podcast>/<episode>.<ext>`.
@MainActor
@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = [] {
        didSet {
            let count = items.filter(\.isActive).count
            if count != lastActiveCount {
                lastActiveCount = count
                onActiveCountChange?(count)
            }
        }
    }
    private var lastActiveCount = 0
    /// Called whenever the number of queued+running downloads changes (Dock badge).
    var onActiveCountChange: ((Int) -> Void)?

    var maxConcurrent: Int = 3 {
        didSet { pump() }
    }

    /// Transient failures (sleep, Wi-Fi hand-off, timeouts) are retried this many times by themselves.
    static let maxAutoRetries = 2

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var onFinished: ((Episode, DownloadTransport.Completed) -> Void)?
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
    func setFinishedHandler(_ handler: @escaping (Episode, DownloadTransport.Completed) -> Void) {
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

    func enqueue(_ episode: Episode, from podcast: Podcast, to destination: URL, automatic: Bool = false) {
        if let existing = item(for: episode), existing.isActive { return }
        // A previous attempt at the same destination may have left resume data.
        let previous = item(for: episode)
        items.removeAll { $0.id == episode.key }
        var item = DownloadItem(id: episode.key, episode: episode, podcast: podcast, destination: destination)
        item.isAutomatic = automatic
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
            if item.isAutomatic {
                // Nobody asked for this right now: stay off hotspots and Low Data Mode.
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
            }
            task = transport.download(request, id: item.id, destination: item.destination, expected: expected(for: item))
        }
        tasks[item.id] = task
        return true
    }

    private func expected(for item: DownloadItem) -> DownloadTransport.Expectation {
        .init(mimeType: item.episode.mimeType, length: item.episode.enclosureLength)
    }

    // MARK: Callbacks

    private var lastProgressUpdate: [String: Date] = [:]

    /// Progress arrives per network chunk; publishing every one re-renders
    /// every row. A few updates per second is plenty for a progress bar.
    private func progress(id: String, received: Int64, expected: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].state == .downloading else { return }
        let now = Date()
        if let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.25, received < expected { return }
        lastProgressUpdate[id] = now
        items[idx].bytesReceived = received
        items[idx].bytesExpected = expected
    }

    private func complete(id: String, result: Result<DownloadTransport.Completed, DownloadTransport.Failure>) {
        tasks[id] = nil
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // A cancelled item already had its state set; don't overwrite it.
        guard items[idx].state == .downloading else { pump(); return }

        switch result {
        case .success(let completed):
            items[idx].state = .finished
            items[idx].bytesReceived = items[idx].bytesExpected
            items[idx].resumeData = nil
            onFinished?(items[idx].episode, completed)
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

/// URLSession delegate wrapper. Lives off the main actor; forwards events via
/// closures. Its only mutable state is `pending`, guarded by `lock`.
final class DownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (String, Int64, Int64) -> Void
    typealias CompletionHandler = @Sendable (String, Result<Completed, Failure>) -> Void

    /// What the feed said about the enclosure, used to spot bodies that aren't audio.
    struct Expectation {
        var mimeType: String?
        var length: Int64?
    }

    /// A download that passed every check and is in its final place, with
    /// what was measured on the way: the record "Verify Library" checks against.
    struct Completed: Sendable {
        let url: URL
        let size: Int64
        let sha256: String
    }

    struct Failure: Error, @unchecked Sendable {
        let error: Error
        /// Present when URLSession can continue the transfer later.
        let resumeData: Data?

        /// Errors that go away by themselves: lost connection, timeout, offline,
        /// or a transfer that ended before the announced length.
        var isTransient: Bool {
            if error is TruncatedDownload { return true }
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
        config.httpMaximumConnectionsPerHost = 10      // matches the top of the concurrency setting
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
        let verdict: Verdict
        do {
            verdict = try Self.check(file: location, response: downloadTask.response, expected: p.expected)
        } catch {
            onComplete(p.id, .failure(Failure(error: error, resumeData: nil)))
            return
        }

        let fm = FileManager.default
        do {
            // Name the file for what it actually contains.
            var final = p.destination
            if let ext = verdict.sniffedExtension, ext != final.pathExtension.lowercased() {
                final = final.deletingPathExtension().appendingPathExtension(ext)
            }
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The temp file is on the boot volume; moving it to an external
            // drive is a copy, and a crash mid-copy must not leave a
            // truncated file under the real name. Copy as ".part", then rename
            // (same volume: atomic).
            let partial = final.appendingPathExtension("part")
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: location, to: partial)
            for stale in [p.destination, final] where fm.fileExists(atPath: stale.path) {
                try fm.removeItem(at: stale)        // "Download Again": replace the old copy
            }
            try fm.moveItem(at: partial, to: final)
            onComplete(p.id, .success(Completed(url: final, size: verdict.size, sha256: verdict.sha256)))
        } catch {
            onComplete(p.id, .failure(Failure(error: error, resumeData: nil)))
        }
    }

    /// The body ended before the server's announced Content-Length.
    struct TruncatedDownload: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Verdict {
        /// The format the bytes turned out to be, when recognised.
        var sniffedExtension: String?
        var size: Int64
        var sha256: String
    }

    /// Validates a completed transfer: the server's promised length must
    /// match, and the body must be media, not a web page. Throws a
    /// user-readable reason otherwise. The file's checksum is taken here,
    /// while it is still in the page cache from being written.
    static func check(file: URL, response: URLResponse?, expected: Expectation) throws -> Verdict {
        if let reason = rejectionReason(for: file, response: response, expected: expected) {
            throw FeedError(message: reason)
        }
        // A connection that drops before the announced length can surface as
        // a clean finish; a short file must never be recorded as the episode.
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let promised = response?.expectedContentLength ?? -1
        let encoded = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased()
        let got = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if promised > 0, encoded == "identity", size != promised {
            let want = ByteCountFormatter.string(fromByteCount: promised, countStyle: .file)
            throw TruncatedDownload(message: "Download was cut short (\(got) of \(want)). Retry to fetch it again.")
        }
        // No length from the server: the feed's <enclosure length> is the
        // only clue, and feeds get it wrong by a little all the time (ads
        // stitched in, re-encodes). Only a body under half of it is treated
        // as cut short.
        if promised <= 0, let announced = expected.length, announced > 0, size * 2 < announced {
            let want = ByteCountFormatter.string(fromByteCount: announced, countStyle: .file)
            throw TruncatedDownload(message: "Download was cut short (\(got) of about \(want), the size the feed announces). Retry to fetch it again.")
        }
        return Verdict(sniffedExtension: MediaSniffer.fileExtension(of: file), size: size, sha256: try FileHash.sha256(of: file))
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
