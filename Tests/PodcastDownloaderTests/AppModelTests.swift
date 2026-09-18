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

    func testFolderProblemSuspendsAutoDownloadAndIsReported() async throws {
        model.adoptMasterDirectory(root.appendingPathComponent("gone/volume/Podcasts"))
        try await Task.sleep(for: .milliseconds(300))   // rescan is detached
        XCTAssertEqual(model.folderProblem, .missing)
        model.adoptMasterDirectory(root.appendingPathComponent("master", isDirectory: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.folderProblem)
    }
}
