import XCTest
@testable import PodcastDownloader

/// AppModel wired to temp storage: no real defaults, library, network or Now Playing.
@MainActor
final class AppModelTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("master"), withIntermediateDirectories: true)
        suite = "appmodel-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.masterDirectory = root.appendingPathComponent("master", isDirectory: true)
        let library = Library(fileURL: root.appendingPathComponent("library.json"))
        let player = Player(controlsNowPlaying: false)
        player.volume = 0
        model = AppModel(settings: settings, library: library, downloads: DownloadManager(), player: player, observeSystem: false)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private let show = Podcast(title: "Show", author: "", feedURL: URL(string: "https://example.com/feed")!)

    private func episode(_ id: String, title: String, day: String = "2026-09-01") -> Episode {
        Episode(id: id, title: title, summary: "", publishedAt: ISO8601DateFormatter().date(from: "\(day)T12:00:00Z"),
                enclosureURL: URL(string: "https://example.com/\(id).mp3")!, enclosureLength: nil, mimeType: nil, duration: nil)
    }

    private func writeFile(_ relative: String, bytes: Int = 16) throws -> URL {
        let url = model.settings.masterDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testRecordedDownloadWinsOverExpectedPathAndOtherEpisodesFileIsNotClaimed() throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("a", title: "Same Name"), episode("b", title: "Same Name")], for: show)
        let a = model.library.episodes(for: show)[0], b = model.library.episodes(for: show)[1]

        let file = try writeFile("Show/2026-09-01 - Same Name.mp3")
        model.library.markDownloaded(a, relativePath: "Show/2026-09-01 - Same Name.mp3")

        XCTAssertEqual(model.localFile(for: a, in: show), file)
        XCTAssertNil(model.localFile(for: b, in: show), "b sanitizes to the same name but that file is a's")
    }

    func testPlayingAFileFromTheDownloadsTabMatchesItsEpisodeByRecordedPath() throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("a", title: "One")], for: show)
        let a = model.library.episodes(for: show)[0]
        let url = try writeFile("Renamed Show Folder/whatever.mp3")
        model.library.markDownloaded(a, relativePath: "Renamed Show Folder/whatever.mp3")
        model.library.setPlaybackPosition(200, for: a)

        let folder = PodcastFolder(name: "Renamed Show Folder", url: url.deletingLastPathComponent(),
                                   files: [LocalFile(name: "whatever", url: url, size: 16, modified: Date())])
        model.play(folder.files[0], in: folder)

        XCTAssertEqual(model.player.episode?.key, a.key, "resume position is shared with the episode row")
        model.player.stop()
    }

    func testDeleteDownloadTrashesAndForgets() throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("a", title: "One")], for: show)
        let a = model.library.episodes(for: show)[0]
        let url = try writeFile("Show/2026-09-01 - One.mp3")
        model.library.markDownloaded(a, relativePath: "Show/2026-09-01 - One.mp3")

        model.deleteDownload(of: a, in: show)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(model.library.downloadedRelativePath(for: a))
        XCTAssertNil(model.localFile(for: a, in: show))
    }

    func testKeepLatestTrimsOldestAutoDownloads() throws {
        var subscribed = show
        subscribed.autoDownload = true
        subscribed.keepLatest = 2
        model.library.subscribe(subscribed)
        model.library.cacheEpisodes([
            episode("new", title: "New", day: "2026-09-03"),
            episode("mid", title: "Mid", day: "2026-09-02"),
            episode("old", title: "Old", day: "2026-09-01"),
        ], for: show)
        for ep in model.library.episodes(for: show) {
            _ = try writeFile("Show/\(ep.fileName)")
            model.library.markDownloaded(ep, relativePath: "Show/\(ep.fileName)")
        }

        model.applyKeepLatest(for: show)

        let remaining = model.library.episodes(for: show).filter { model.localFile(for: $0, in: show) != nil }.map(\.id)
        XCTAssertEqual(remaining, ["new", "mid"])
    }

    func testDownloadsDuringAMoveAreDeferredAndTheMoveIsScoped() async throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("a", title: "One")], for: show)
        let a = model.library.episodes(for: show)[0]
        _ = try writeFile("Show/2026-09-01 - One.mp3")
        _ = try writeFile("notes.txt")
        let newMaster = root.appendingPathComponent("elsewhere", isDirectory: true)

        await model.changeMasterDirectory(to: newMaster)

        XCTAssertEqual(model.settings.masterDirectory.standardizedFileURL.path, newMaster.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newMaster.appendingPathComponent("Show/2026-09-01 - One.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("master/notes.txt").path), "unrelated file untouched")
        XCTAssertNotNil(model.localFile(for: a, in: show), "recorded relative path resolves under the new master")
    }

    func testVerifyLibraryFindsMissingAndChangedFilesAndQueuesThemAgain() async throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("ok", title: "OK"), episode("gone", title: "Gone"),
                                     episode("short", title: "Short"), episode("old", title: "Old")], for: show)
        let eps = Dictionary(uniqueKeysWithValues: model.library.episodes(for: show).map { ($0.id, $0) })
        let okHash = try FileHash.sha256(of: try writeFile("Show/ok.mp3", bytes: 100))
        model.library.markDownloaded(eps["ok"]!, relativePath: "Show/ok.mp3", size: 100, sha256: okHash)
        model.library.markDownloaded(eps["gone"]!, relativePath: "Show/gone.mp3", size: 100, sha256: okHash)
        _ = try writeFile("Show/short.mp3", bytes: 40)
        model.library.markDownloaded(eps["short"]!, relativePath: "Show/short.mp3", size: 100, sha256: okHash)
        _ = try writeFile("Show/old.mp3", bytes: 64)
        model.library.markDownloaded(eps["old"]!, relativePath: "Show/old.mp3")     // from before sizes were kept

        model.verifyLibrary(checksums: false)
        while model.verification?.isRunning == true { try await Task.sleep(for: .milliseconds(20)) }
        let report = try XCTUnwrap(model.verification)

        XCTAssertEqual(report.checked, 4)
        XCTAssertEqual(report.missing.map(\.path), ["Show/gone.mp3"])
        XCTAssertEqual(report.damaged.map(\.path), ["Show/short.mp3"])
        XCTAssertEqual(report.baselined, 1)
        XCTAssertEqual(model.library.downloaded[eps["old"]!.key]?.size, 64, "the size on disk is now the baseline")
        XCTAssertNil(model.library.downloaded[eps["old"]!.key]?.sha256, "no checksum was asked for")

        XCTAssertEqual(model.redownloadVerificationProblems(), 2)
        XCTAssertEqual(Set(model.downloads.activeItems.map(\.episode.id)), ["gone", "short"])
        XCTAssertEqual(model.downloads.item(for: eps["short"]!)?.destination.lastPathComponent, "short.mp3", "a damaged file is replaced in place")
        model.cancelAllDownloads()
        model.dismissVerification()
        XCTAssertNil(model.verification)
    }

    func testVerifyLibraryWithChecksumsCatchesSameSizeChanges() async throws {
        model.library.subscribe(show)
        model.library.cacheEpisodes([episode("a", title: "A"), episode("b", title: "B")], for: show)
        let a = model.library.episodes(for: show)[0], b = model.library.episodes(for: show)[1]
        let fileA = try writeFile("Show/a.mp3", bytes: 50)
        model.library.markDownloaded(a, relativePath: "Show/a.mp3", size: 50, sha256: try FileHash.sha256(of: fileA))
        try Data(repeating: 2, count: 50).write(to: fileA)                    // same size, different bytes
        let fileB = try writeFile("Show/b.mp3", bytes: 50)
        model.library.markDownloaded(b, relativePath: "Show/b.mp3", size: 50)  // size known, no checksum yet

        model.verifyLibrary(checksums: true)
        while model.verification?.isRunning == true { try await Task.sleep(for: .milliseconds(20)) }
        let report = try XCTUnwrap(model.verification)

        XCTAssertEqual(report.damaged.map(\.path), ["Show/a.mp3"])
        XCTAssertEqual(report.baselined, 1)
        XCTAssertEqual(model.library.downloaded[b.key]?.sha256, try FileHash.sha256(of: fileB))
        model.dismissVerification()
    }

    func testRefreshAllFetchesOnlyAFewFeedsAtOnce() async {
        for i in 0..<20 {
            model.library.subscribe(Podcast(title: "S\(i)", author: "", feedURL: URL(string: "https://example.com/\(i)")!))
        }
        let counter = ConcurrencyCounter()
        model.library.loadFeed = { _ in
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await counter.leave()
            var feed = ParsedFeed(); feed.title = "ok"
            return feed
        }

        await model.refreshAll()

        let peak = await counter.peak
        let total = await counter.total
        XCTAssertLessThanOrEqual(peak, AppModel.refreshConcurrency)
        XCTAssertGreaterThan(peak, 1, "still parallel, just bounded")
        XCTAssertEqual(total, 20, "every feed was refreshed")
        XCTAssertNotNil(model.library.lastFullRefresh)
    }

    func testFolderProblemSuspendsAutoDownloadAndIsReported() async throws {
        model.adoptMasterDirectory(root.appendingPathComponent("gone/volume/Podcasts"))
        try await Task.sleep(for: .milliseconds(300))   // rescan is detached
        XCTAssertEqual(model.folderProblem, .missing)
        model.adoptMasterDirectory(root.appendingPathComponent("master", isDirectory: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.folderProblem)
    }
}

/// Tracks how many callers are inside a section at the same time.
actor ConcurrencyCounter {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() { current += 1; total += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
