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
