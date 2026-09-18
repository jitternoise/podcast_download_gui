import XCTest
@testable import PodcastDownloader

@MainActor
final class LibraryTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func podcast(_ name: String) -> Podcast {
        Podcast(title: name, author: "", feedURL: URL(string: "https://example.com/\(name)")!)
    }

    private func episode(_ id: String, daysAgo: Int?) -> Episode {
        Episode(id: id, title: id, summary: "",
                publishedAt: daysAgo.map { Date().addingTimeInterval(-Double($0) * 86_400) },
                enclosureURL: URL(string: "https://example.com/\(id).mp3")!,
                enclosureLength: nil, mimeType: nil, duration: nil)
    }

    func testLatestEpisodesMergesSubscriptionsNewestFirst() {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B"), unsubscribed = podcast("C")
        lib.subscribe(a)
        lib.subscribe(b)
        lib.cacheEpisodes([episode("a-old", daysAgo: 10), episode("a-new", daysAgo: 1), episode("a-undated", daysAgo: nil)], for: a)
        lib.cacheEpisodes([episode("b-mid", daysAgo: 5), episode("b-newest", daysAgo: 0)], for: b)
        lib.cacheEpisodes([episode("c-newest", daysAgo: 0)], for: unsubscribed)   // not subscribed: excluded

        let latest = lib.latestEpisodes()
        XCTAssertEqual(latest.map(\.episode.id), ["b-newest", "a-new", "b-mid", "a-old", "a-undated"])
        XCTAssertEqual(latest.first?.podcast.id, b.id)
        XCTAssertEqual(latest.map(\.id).count, Set(latest.map(\.id)).count, "ids are unique across podcasts")
    }

    func testLatestEpisodesHonoursLimit() {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)
        lib.cacheEpisodes((0..<150).map { (i: Int) -> Episode in episode("e\(String(i))", daysAgo: i) }, for: a)

        let latest = lib.latestEpisodes(limit: 100)
        XCTAssertEqual(latest.count, 100)
        XCTAssertEqual(latest.first?.episode.id, "e0")
        XCTAssertEqual(latest.last?.episode.id, "e99")
    }

    func testDownloadsAndPositionsAreKeyedPerPodcast() {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B")
        lib.subscribe(a); lib.subscribe(b)
        lib.cacheEpisodes([episode("shared", daysAgo: 1)], for: a)
        lib.cacheEpisodes([episode("shared", daysAgo: 2)], for: b)
        let epA = lib.episodes(for: a)[0], epB = lib.episodes(for: b)[0]
        XCTAssertNotEqual(epA.key, epB.key)

        lib.markDownloaded(epA, relativePath: "A/shared.mp3")
        lib.setPlaybackPosition(42, for: epA)

        XCTAssertEqual(lib.downloadedRelativePath(for: epA), "A/shared.mp3")
        XCTAssertNil(lib.downloadedRelativePath(for: epB), "B's episode is a different episode")
        XCTAssertEqual(lib.playbackPosition(for: epB), 0)
        XCTAssertEqual(lib.episodeID(downloadedTo: "A/shared.mp3"), epA.key)
    }

    func testMigratesV1GuidKeysToCompositeKeys() throws {
        let v1 = """
        {"podcasts":[{"title":"A","author":"","feedURL":"https://example.com/A","autoDownload":false}],
         "episodes":{"https://example.com/A":[{"id":"ep1","title":"One","summary":"","enclosureURL":"https://example.com/1.mp3"}]},
         "downloaded":{"ep1":"A/One.mp3"},
         "lastRefreshed":{},
         "playbackPositions":{"ep1":30}}
        """
        try Data(v1.utf8).write(to: file)
        let lib = Library(fileURL: file)
        XCTAssertNil(lib.loadError)
        let ep = lib.episodes(for: podcast("A"))[0]
        XCTAssertEqual(ep.podcastID, "https://example.com/A")
        XCTAssertEqual(lib.downloadedRelativePath(for: ep), "A/One.mp3")
        XCTAssertEqual(lib.playbackPosition(for: ep), 30)
        XCTAssertNil(lib.downloaded["ep1"], "old key is gone")
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("\"version\" : 2"))
    }

    func testUnreadableFileIsKeptAsideNotOverwritten() throws {
        try Data("{ this is not json".utf8).write(to: file)
        let lib = Library(fileURL: file)
        XCTAssertNotNil(lib.loadError)
        XCTAssertTrue(lib.podcasts.isEmpty)

        lib.subscribe(podcast("A"))   // first mutation writes a fresh file

        let dir = file.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(file.lastPathComponent + ".corrupt-") }
        XCTAssertEqual(kept.count, 1, "the unreadable file was preserved under a new name")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8), "{ this is not json")
        for name in kept { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("example.com"), "a fresh library was written")
    }

    func testRefreshKeepsEditsMadeWhileTheFeedWasLoading() async {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)

        let gate = AsyncStream<Void>.makeStream()
        lib.loadFeed = { _ in
            for await _ in gate.stream { break }          // wait until the test lets the fetch finish
            var feed = ParsedFeed()
            feed.title = "A (renamed by feed)"
            feed.episodes = [Episode(id: "e1", title: "E1", summary: "", publishedAt: nil,
                                     enclosureURL: URL(string: "https://example.com/e1.mp3")!,
                                     enclosureLength: nil, mimeType: nil, duration: nil)]
            return feed
        }

        let refresh = Task { await lib.refresh(a) }        // captures the *old* podcast value
        await Task.yield()
        var edited = a
        edited.autoDownload = true
        lib.update(edited)                                 // user ticks the box mid-fetch
        gate.continuation.yield(())
        gate.continuation.finish()
        _ = await refresh.value

        let current = lib.podcast(withID: a.id)
        XCTAssertEqual(current?.autoDownload, true, "the edit survives the refresh")
        XCTAssertEqual(current?.title, "A (renamed by feed)", "feed metadata still applied")
        XCTAssertEqual(lib.episodes(for: a).first?.podcastID, a.id)
    }

    func testSameEpisodeIDInTwoPodcastsStaysDistinct() {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B")
        lib.subscribe(a); lib.subscribe(b)
        lib.cacheEpisodes([episode("shared", daysAgo: 1)], for: a)
        lib.cacheEpisodes([episode("shared", daysAgo: 2)], for: b)
        XCTAssertEqual(lib.latestEpisodes().count, 2)
    }
}
