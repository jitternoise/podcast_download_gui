import XCTest
@testable import PodcastDownloader

/// Live network tests against real services. They download a real episode,
/// so they only run when explicitly asked for:
///     PODCAST_NETWORK_TESTS=1 swift test --filter NetworkTests
final class NetworkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PODCAST_NETWORK_TESTS"] != nil,
                          "set PODCAST_NETWORK_TESTS=1 to run the live network tests")
    }

    func testSearchReturnsFeeds() async throws {
        let results: [Podcast]
        do {
            results = try await PodcastSearchService().search("planet money")
        } catch {
            throw XCTSkip("network unavailable: \(error)")
        }
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.feedURL.scheme?.hasPrefix("http") == true })
        XCTAssertTrue(results.contains { $0.title.localizedCaseInsensitiveContains("planet money") })
    }

    func testLoadRealFeedAndDownloadEpisode() async throws {
        let results: [Podcast]
        do {
            results = try await PodcastSearchService().search("planet money")
        } catch {
            throw XCTSkip("network unavailable: \(error)")
        }
        guard let podcast = results.first(where: { $0.title.localizedCaseInsensitiveContains("planet money") }) else {
            throw XCTSkip("show not found")
        }

        let feed = try await FeedLoader.load(podcast.feedURL)
        XCTAssertFalse(feed.title.isEmpty)
        XCTAssertFalse(feed.episodes.isEmpty)
        let episode = try XCTUnwrap(feed.episodes.first)
        XCTAssertNotNil(episode.publishedAt)

        // Download the newest episode into a temp master folder via the real manager.
        let master = FileManager.default.temporaryDirectory.appendingPathComponent("pdtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: master) }
        let destination = master
            .appendingPathComponent(podcast.folderName, isDirectory: true)
            .appendingPathComponent(episode.fileName)

        let finished = expectation(description: "download finished")
        var finishedURL: URL?
        let manager = await DownloadManager()
        await manager.setFinishedHandler { _, url in
            finishedURL = url
            finished.fulfill()
        }
        await manager.enqueue(episode, from: podcast, to: destination)

        await fulfillment(of: [finished], timeout: 180)
        XCTAssertEqual(finishedURL, destination)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
        XCTAssertGreaterThan(size, 1_000_000, "downloaded file should be a real audio file")
        let item = await manager.item(for: episode)
        XCTAssertEqual(item?.state, .finished)
        print("Downloaded \(size) bytes to \(destination.path)")
    }
}
