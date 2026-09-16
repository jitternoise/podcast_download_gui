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

    func testSameEpisodeIDInTwoPodcastsStaysDistinct() {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B")
        lib.subscribe(a); lib.subscribe(b)
        lib.cacheEpisodes([episode("shared", daysAgo: 1)], for: a)
        lib.cacheEpisodes([episode("shared", daysAgo: 2)], for: b)
        XCTAssertEqual(lib.latestEpisodes().count, 2)
    }
}
