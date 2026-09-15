import XCTest
@testable import PodcastDownloader

final class LibraryFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, bytes: Int = 10) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testScanGroupsMediaFilesByPodcastFolder() throws {
        try touch("old/Show A/2026-01-01 - One.mp3", bytes: 100)
        try touch("old/Show A/2026-01-02 - Two.m4a", bytes: 50)
        try touch("old/Show A/notes.txt")            // not media, ignored
        try touch("old/Show A/.hidden.mp3")          // hidden, ignored
        try touch("old/Show B/2026-01-03 - Three.mp3")
        try touch("old/loose.mp3")                    // not inside a podcast folder, ignored

        let folders = LibraryFolder.scan(root.appendingPathComponent("old"))
        XCTAssertEqual(folders.map(\.name), ["Show A", "Show B"])
        XCTAssertEqual(folders[0].files.count, 2)
        XCTAssertEqual(folders[0].totalSize, 150)
        XCTAssertEqual(Set(folders[0].files.map(\.name)), ["2026-01-01 - One", "2026-01-02 - Two"])
        XCTAssertEqual(folders[1].files.count, 1)
    }

    func testMoveRelocatesEverythingAndMergesExistingFolders() throws {
        try touch("old/Show A/one.mp3")
        try touch("old/Show A/two.mp3")
        try touch("old/Show B/three.mp3")
        try touch("new/Show A/two.mp3")              // conflict: should be skipped, not overwritten
        try touch("new/Show C/four.mp3")             // unrelated existing content, untouched

        let result = try LibraryFolder.move(from: root.appendingPathComponent("old"), to: root.appendingPathComponent("new"))

        XCTAssertEqual(result.moved, 2, "one.mp3 and the whole Show B folder")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(exists("new/Show A/one.mp3"))
        XCTAssertTrue(exists("new/Show A/two.mp3"))
        XCTAssertTrue(exists("new/Show B/three.mp3"))
        XCTAssertTrue(exists("new/Show C/four.mp3"))
        XCTAssertTrue(exists("old/Show A/two.mp3"), "conflicting file is left behind rather than lost")
        XCTAssertFalse(exists("old/Show A/one.mp3"))
        XCTAssertFalse(exists("old/Show B"), "fully-moved folder is removed")
        XCTAssertTrue(exists("old"), "old root kept because a skipped file remains")
    }

    func testMoveRemovesEmptyOldRoot() throws {
        try touch("old/Show A/one.mp3")
        _ = try LibraryFolder.move(from: root.appendingPathComponent("old"), to: root.appendingPathComponent("new"))
        XCTAssertFalse(exists("old"))
        XCTAssertTrue(exists("new/Show A/one.mp3"))
    }

    func testMoveIntoNonexistentOldFolderIsANoop() throws {
        let result = try LibraryFolder.move(from: root.appendingPathComponent("missing"), to: root.appendingPathComponent("new"))
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(exists("new"), "destination is still created")
    }

    func testMoveRefusesNestedDestination() throws {
        try touch("old/Show A/one.mp3")
        XCTAssertThrowsError(try LibraryFolder.move(from: root.appendingPathComponent("old"),
                                                   to: root.appendingPathComponent("old/inner")))
    }

    func testMoveToSameFolderIsANoop() throws {
        try touch("old/Show A/one.mp3")
        let result = try LibraryFolder.move(from: root.appendingPathComponent("old"), to: root.appendingPathComponent("old"))
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(exists("old/Show A/one.mp3"))
    }
}
