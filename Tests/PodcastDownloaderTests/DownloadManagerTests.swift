import XCTest
@testable import PodcastDownloader

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func episode(_ id: String, url: String) -> Episode {
        Episode(id: id, title: id, summary: "", publishedAt: nil, enclosureURL: URL(string: url)!,
                enclosureLength: nil, mimeType: nil, duration: nil)
    }
    private let podcast = Podcast(title: "Show", author: "", feedURL: URL(string: "https://example.com/feed")!)

    func testNonWebEnclosureFailsImmediatelyWithoutOccupyingASlot() {
        let manager = DownloadManager()
        manager.maxConcurrent = 1
        let local = episode("local", url: "file:///etc/passwd")

        manager.enqueue(local, from: podcast, to: root.appendingPathComponent("Show/local.mp3"))

        guard case .failed(let message)? = manager.item(for: local)?.state else {
            return XCTFail("expected .failed, got \(String(describing: manager.item(for: local)?.state))")
        }
        XCTAssertTrue(message.contains("Unsupported URL"))
        XCTAssertTrue(manager.activeItems.isEmpty, "a failed start must not linger as 'downloading'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Show/local.mp3").path))
    }

    func testWebPageBodiesAreRejected() throws {
        let html = root.appendingPathComponent("page.tmp")
        try Data("<!DOCTYPE html><html><body>Sign in to the network</body></html>".utf8).write(to: html)
        let audio = root.appendingPathComponent("audio.tmp")
        try Data([0x49, 0x44, 0x33, 0x04, 0x00] + [UInt8](repeating: 0, count: 2000)).write(to: audio)   // "ID3" tag
        let url = URL(string: "https://example.com/x.mp3")!
        let expected = DownloadTransport.Expectation(mimeType: "audio/mpeg", length: 5_000_000)

        XCTAssertNotNil(DownloadTransport.rejectionReason(for: html, response: nil, expected: expected))
        XCTAssertNotNil(DownloadTransport.rejectionReason(
            for: audio, response: HTTPURLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil), expected: expected))
        XCTAssertNil(DownloadTransport.rejectionReason(
            for: audio, response: HTTPURLResponse(url: url, mimeType: "audio/mpeg", expectedContentLength: 0, textEncodingName: nil), expected: expected))
        XCTAssertNil(DownloadTransport.rejectionReason(for: audio, response: nil, expected: expected))
    }

    func testTransientNetworkErrorsAreRecognised() {
        func failure(_ code: Int) -> DownloadTransport.Failure {
            .init(error: NSError(domain: NSURLErrorDomain, code: code), resumeData: nil)
        }
        XCTAssertTrue(failure(NSURLErrorNetworkConnectionLost).isTransient)
        XCTAssertTrue(failure(NSURLErrorTimedOut).isTransient)
        XCTAssertTrue(failure(NSURLErrorNotConnectedToInternet).isTransient)
        XCTAssertFalse(failure(NSURLErrorBadServerResponse).isTransient)
        XCTAssertFalse(DownloadTransport.Failure(error: FeedError(message: "HTTP 404"), resumeData: nil).isTransient)
    }

    func testFailedStartDoesNotBlockTheQueue() {
        let manager = DownloadManager()
        manager.maxConcurrent = 1
        let bad = episode("bad", url: "file:///etc/passwd")
        // A destination whose parent can't be created: a regular file where a folder should be.
        try? Data().write(to: root.appendingPathComponent("blocker"))
        let unwritable = episode("unwritable", url: "https://example.com/x.mp3")

        manager.enqueue(bad, from: podcast, to: root.appendingPathComponent("Show/bad.mp3"))
        manager.enqueue(unwritable, from: podcast, to: root.appendingPathComponent("blocker/inner/x.mp3"))

        XCTAssertEqual(manager.activeItems.count, 0)
        for id in ["bad", "unwritable"] {
            guard case .failed? = manager.items.first(where: { $0.id == id })?.state else {
                return XCTFail("\(id) should be .failed")
            }
        }
    }
}
