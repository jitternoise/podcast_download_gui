import XCTest
@testable import PodcastDownloader

@MainActor
final class AppSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testMasterFolderFollowsAFinderRename() throws {
        let original = root.appendingPathComponent("Podcasts", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        settings.masterDirectory = original

        let renamed = root.appendingPathComponent("My Podcasts", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: renamed)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.masterDirectory.standardizedFileURL.path, renamed.standardizedFileURL.path)
        let stored = defaults.string(forKey: "masterDirectory").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(stored, renamed.resolvingSymlinksInPath().path, "path is re-saved from the bookmark")
    }

    func testMissingFolderFallsBackToTheStoredPath() throws {
        let folder = root.appendingPathComponent("Podcasts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        settings.masterDirectory = folder

        try FileManager.default.removeItem(at: folder)    // e.g. the external drive is unplugged

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.masterDirectory.standardizedFileURL.path, folder.standardizedFileURL.path,
                       "keeps pointing where the library was so nothing is silently re-created elsewhere")
    }

    func testFirstRunPinsTheResolvedDefault() {
        XCTAssertNil(defaults.string(forKey: "masterDirectory"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "masterDirectory"), settings.masterDirectory.path)
        XCTAssertFalse(settings.masterDirectory.path.contains("/Downloads/") && !FileManager.default.fileExists(atPath: settings.masterDirectory.path),
                       "a brand-new install never defaults into the TCC-protected Downloads folder")
    }
}
