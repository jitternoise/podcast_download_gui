import XCTest
@testable import PodcastDownloader

@MainActor
final class LibraryTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        // A folder per test: the library keeps shows/ and notes/ next to its file.
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func showFile(_ podcast: Podcast) -> URL {
        dir.appendingPathComponent("shows").appendingPathComponent(Library.fileName(for: podcast.id))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
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

    func testMigratesV1GuidKeysToCompositeKeys() async throws {
        let v1 = """
        {"podcasts":[{"title":"A","author":"","feedURL":"https://example.com/A","autoDownload":true}],
         "episodes":{"https://example.com/A":[{"id":"ep1","title":"One","summary":"","enclosureURL":"https://example.com/1.mp3"}]},
         "downloaded":{"ep1":"A/One.mp3"},
         "lastRefreshed":{},
         "playbackPositions":{"ep1":30}}
        """
        try Data(v1.utf8).write(to: file)
        let lib = Library(fileURL: file)
        XCTAssertNil(lib.loadError)
        XCTAssertEqual(lib.podcasts.first?.autoDownload, true)
        XCTAssertEqual(lib.podcasts.first?.keepLatest, 0, "field added later defaults instead of failing the load")
        let ep = lib.episodes(for: podcast("A"))[0]
        XCTAssertEqual(ep.podcastID, "https://example.com/A")
        XCTAssertEqual(lib.downloadedRelativePath(for: ep), "A/One.mp3")
        XCTAssertEqual(lib.playbackPosition(for: ep), 30)
        XCTAssertNil(lib.downloaded["ep1"], "old key is gone")
        await lib.flush()
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("\"version\":3"))
    }

    func testV2SingleFileIsSplitIntoIndexAndShowFiles() async throws {
        let v2 = """
        {"version":2,
         "podcasts":[{"title":"A","author":"","feedURL":"https://example.com/A"},{"title":"B","author":"","feedURL":"https://example.com/B"}],
         "episodes":{"https://example.com/A":[{"id":"a1","title":"A1","summary":"","enclosureURL":"https://example.com/a1.mp3"}],
                     "https://example.com/B":[{"id":"b1","title":"B1","summary":"","enclosureURL":"https://example.com/b1.mp3"}]},
         "downloaded":{"https://example.com/A|a1":"A/A1.mp3","file|Loose/x.mp3":"Loose/x.mp3"},
         "lastRefreshed":{"https://example.com/A":"2026-09-01T00:00:00Z"},
         "playbackPositions":{"https://example.com/B|b1":12,"file|Loose/x.mp3":99},
         "played":["https://example.com/A|a1"],
         "lastFullRefresh":"2026-09-02T00:00:00Z"}
        """
        try Data(v2.utf8).write(to: file)
        let a = podcast("A"), b = podcast("B")
        let lib = Library(fileURL: file)
        XCTAssertNil(lib.loadError)
        XCTAssertEqual(lib.episodes(for: a).map(\.id), ["a1"])
        XCTAssertEqual(lib.downloadedRelativePath(for: lib.episodes(for: a)[0]), "A/A1.mp3")
        await lib.flush()

        // The index no longer carries episodes; each show has its own file.
        let index = try json(file)
        XCTAssertEqual(index["version"] as? Int, 3)
        XCTAssertNil(index["episodes"])
        XCTAssertEqual((index["downloaded"] as? [String: Any])?.keys.sorted(), ["file|Loose/x.mp3"], "only state outside any subscription stays in the index")
        XCTAssertEqual((index["playbackPositions"] as? [String: Double])?["file|Loose/x.mp3"], 99)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path), "the single-file version is kept")

        let showA = try json(showFile(a)), showB = try json(showFile(b))
        XCTAssertEqual((showA["episodes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(((showA["downloaded"] as? [String: Any])?["https://example.com/A|a1"] as? [String: Any])?["path"] as? String, "A/A1.mp3")
        XCTAssertEqual(showA["played"] as? [String], ["https://example.com/A|a1"])
        XCTAssertEqual(showA["lastRefreshed"] as? String, "2026-09-01T00:00:00Z")
        XCTAssertEqual((showB["playbackPositions"] as? [String: Double])?["https://example.com/B|b1"], 12)

        // And it all comes back.
        let reloaded = Library(fileURL: file)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.podcasts.map(\.title), ["A", "B"])
        XCTAssertEqual(reloaded.episodes(for: b).map(\.id), ["b1"])
        XCTAssertEqual(reloaded.playbackPosition(for: reloaded.episodes(for: b)[0]), 12)
        XCTAssertTrue(reloaded.isPlayed(reloaded.episodes(for: a)[0]))
        XCTAssertEqual(reloaded.lastRefreshed[a.id], ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        XCTAssertNotNil(reloaded.lastFullRefresh)
        XCTAssertEqual(reloaded.episodeID(downloadedTo: "Loose/x.mp3"), "file|Loose/x.mp3")
    }

    func testAPositionTickRewritesOneShowNotTheLibrary() async throws {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B")
        lib.subscribe(a); lib.subscribe(b)
        lib.cacheEpisodes([episode("a1", daysAgo: 1)], for: a)
        lib.cacheEpisodes([episode("b1", daysAgo: 1)], for: b)
        await lib.flush()
        let before = try (file: Data(contentsOf: file), a: Data(contentsOf: showFile(a)), b: Data(contentsOf: showFile(b)))

        lib.setPlaybackPosition(30, for: lib.episodes(for: b)[0])
        await lib.flush()

        XCTAssertEqual(try Data(contentsOf: file), before.file, "index untouched")
        XCTAssertEqual(try Data(contentsOf: showFile(a)), before.a, "other show untouched")
        XCTAssertNotEqual(try Data(contentsOf: showFile(b)), before.b)
        XCTAssertEqual(Library(fileURL: file).playbackPosition(for: lib.episodes(for: b)[0]), 30)
    }

    func testUnsubscribeRemovesTheShowFileButKeepsItsState() async throws {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)
        lib.cacheEpisodes([episode("a1", daysAgo: 1)], for: a)
        let a1 = lib.episodes(for: a)[0]
        lib.markDownloaded(a1, relativePath: "A/a1.m4a", size: 10, sha256: "abc")
        await lib.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: showFile(a).path))

        lib.unsubscribe(a)
        await lib.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: showFile(a).path))
        let index = try json(file)
        XCTAssertNotNil((index["downloaded"] as? [String: Any])?[a1.key], "the download record moved into the index")

        // Re-subscribing (and refreshing) puts it back into the show's file.
        let again = Library(fileURL: file)
        XCTAssertEqual(again.downloadedRelativePath(for: a1), "A/a1.m4a")
        again.subscribe(a)
        again.cacheEpisodes([episode("a1", daysAgo: 1)], for: a)
        await again.flush()
        XCTAssertNil((try json(file)["downloaded"] as? [String: Any])?[a1.key])
        XCTAssertEqual(Library(fileURL: file).downloaded[a1.key]?.sha256, "abc")
    }

    func testNotesAreKeptOnDiskAndReadOnDemand() async throws {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)
        lib.loadFeed = { _ in
            var feed = ParsedFeed()
            feed.title = "A"
            feed.episodes = [self.episode("a1", daysAgo: 1), self.episode("a2", daysAgo: 2)]
            feed.notesHTML = ["a1": "<p>Hello <a href=\"https://example.com\">there</a></p>"]
            return feed
        }
        await lib.refresh(a)
        let a1 = lib.episodes(for: a)[0], a2 = lib.episodes(for: a)[1]
        let early = await lib.notesHTML(for: a1)
        XCTAssertEqual(early, "<p>Hello <a href=\"https://example.com\">there</a></p>", "available before the write lands")
        let none = await lib.notesHTML(for: a2)
        XCTAssertNil(none)
        await lib.flush()

        let notesFile = dir.appendingPathComponent("notes").appendingPathComponent(Library.fileName(for: a.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesFile.path))
        let showFile = try String(contentsOf: showFile(a), encoding: .utf8)
        XCTAssertFalse(showFile.contains("href"), "notes don't bloat the show file that's loaded at launch")

        let reloaded = Library(fileURL: file)
        let fromDisk = await reloaded.notesHTML(for: a1)
        XCTAssertEqual(fromDisk, "<p>Hello <a href=\"https://example.com\">there</a></p>")
        let stillNone = await reloaded.notesHTML(for: a2)
        XCTAssertNil(stillNone)

        reloaded.unsubscribe(a)
        await reloaded.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesFile.path), "gone with the subscription")
    }

    func testPreviewedShowsNotesStayInMemoryUntilSubscribed() async throws {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.cacheEpisodes([episode("a1", daysAgo: 1)], for: a, notes: ["a1": "<b>hi</b>"])
        let a1 = lib.episodes(for: a)[0]
        let preview = await lib.notesHTML(for: a1)
        XCTAssertEqual(preview, "<b>hi</b>")
        lib.subscribe(a)
        await lib.flush()
        let persisted = await Library(fileURL: file).notesHTML(for: a1)
        XCTAssertEqual(persisted, "<b>hi</b>")
    }

    func testUnreadableShowFileIsSetAsideAndReported() async throws {
        let lib = Library(fileURL: file)
        let a = podcast("A"), b = podcast("B")
        lib.subscribe(a); lib.subscribe(b)
        lib.cacheEpisodes([episode("a1", daysAgo: 1)], for: a)
        lib.cacheEpisodes([episode("b1", daysAgo: 1)], for: b)
        await lib.flush()
        try Data("{ nope".utf8).write(to: showFile(a))

        let reloaded = Library(fileURL: file)
        XCTAssertNotNil(reloaded.loadError)
        XCTAssertTrue(reloaded.loadError?.contains("“A”") == true, reloaded.loadError ?? "")
        XCTAssertEqual(reloaded.podcasts.count, 2, "the subscription itself is fine")
        XCTAssertTrue(reloaded.episodes(for: a).isEmpty)
        XCTAssertEqual(reloaded.episodes(for: b).map(\.id), ["b1"], "the other show loaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: showFile(a).path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("shows").path)
            .filter { $0.hasPrefix(Library.fileName(for: a.id) + ".corrupt-") }
        XCTAssertEqual(kept.count, 1)
    }

    func testDownloadRecordReadsOldPlainPaths() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode([String: DownloadRecord].self, from: Data(#"{"k":"A/x.mp3"}"#.utf8))
        XCTAssertEqual(old["k"], DownloadRecord(path: "A/x.mp3"))
        let new = try decoder.decode([String: DownloadRecord].self, from: Data(#"{"k":{"path":"A/x.mp3","size":5,"sha256":"ab"}}"#.utf8))
        XCTAssertEqual(new["k"], DownloadRecord(path: "A/x.mp3", size: 5, sha256: "ab"))
    }

    func testUnreadableFileIsKeptAsideNotOverwritten() async throws {
        try Data("{ this is not json".utf8).write(to: file)
        let lib = Library(fileURL: file)
        XCTAssertNotNil(lib.loadError)
        XCTAssertTrue(lib.podcasts.isEmpty)

        lib.subscribe(podcast("A"))   // first mutation writes a fresh file
        await lib.flush()

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

    func testSavesAreCoalescedAndFlushable() async throws {
        let lib = Library(fileURL: file)
        lib.saveDelay = .seconds(10)
        lib.subscribe(podcast("A"))
        lib.subscribe(podcast("B"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing written yet")
        lib.flushNow()
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("example.com") && written.contains("\"version\":3"))

        lib.subscribe(podcast("C"))
        await lib.flush()
        XCTAssertEqual(Library(fileURL: file).podcasts.count, 3)
    }

    func testPlayedStateRoundTrips() async {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)
        lib.cacheEpisodes([episode("e1", daysAgo: 1)], for: a)
        let ep = lib.episodes(for: a)[0]
        lib.setPlaybackPosition(120, for: ep)
        lib.setPlayed(ep, true)
        XCTAssertEqual(lib.playbackPosition(for: ep), 0, "marking played clears the resume point")
        await lib.flush()
        let reloaded = Library(fileURL: file)
        XCTAssertTrue(reloaded.isPlayed(reloaded.episodes(for: a)[0]))
    }

    func testUnsubscribeKeepsEpisodesForTheSession() {
        let lib = Library(fileURL: file)
        let a = podcast("A")
        lib.subscribe(a)
        lib.cacheEpisodes([episode("e1", daysAgo: 1)], for: a)
        lib.unsubscribe(a)
        XCTAssertEqual(lib.episodes(for: a).count, 1, "the detail view can still show the show")
        XCTAssertTrue(lib.latestEpisodes().isEmpty, "…but it's no longer part of Latest")
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
