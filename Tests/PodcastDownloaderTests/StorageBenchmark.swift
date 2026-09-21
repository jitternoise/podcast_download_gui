import XCTest
@testable import PodcastDownloader

/// Timings for the library storage against a real or synthetic library.
/// Skipped unless `PODCAST_BENCH_DIR` points at a folder holding a
/// `library.json` (any version); that folder is copied and never changed.
///
///     PODCAST_BENCH_DIR=/path/to/folder swift test -c release --filter StorageBenchmark
@MainActor
final class StorageBenchmark: XCTestCase {
    func testLoadAndSaveTimings() async throws {
        guard let source = ProcessInfo.processInfo.environment["PODCAST_BENCH_DIR"], !source.isEmpty else {
            throw XCTSkip("set PODCAST_BENCH_DIR to run")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        try fm.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("library.json"), to: file)
        let singleFileSize = try fm.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0

        func timed(_ label: String, _ work: () async throws -> Void) async rethrows {
            let start = ContinuousClock.now
            try await work()
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            print(String(format: "  %-44@ %8.0f ms", label, ms))
        }

        print("Library: \(singleFileSize / 1_000_000) MB single file")
        var lib: Library!
        await timed("load old single file (+ migrate in memory)") { lib = Library(fileURL: file) }
        print("  \(lib.podcasts.count) shows, \(lib.totalEpisodeCount) episodes, \(lib.downloaded.count) downloads on record")
        await timed("write split layout (every show)") { await lib.flush() }

        var reloaded: Library!
        await timed("launch: load split layout") { reloaded = Library(fileURL: file) }
        XCTAssertEqual(reloaded.totalEpisodeCount, lib.totalEpisodeCount)
        XCTAssertEqual(reloaded.downloaded.count, lib.downloaded.count)
        await timed("Latest Episodes (sort once)") { _ = reloaded.latestEpisodes() }

        // The biggest show is the worst case for a per-show write.
        let biggest = reloaded.podcasts.max { reloaded.episodes(for: $0).count < reloaded.episodes(for: $1).count }!
        let episode = reloaded.episodes(for: biggest)[0]
        reloaded.saveDelay = .zero
        await timed("position tick → save (\(reloaded.episodes(for: biggest).count)-episode show)") {
            reloaded.setPlaybackPosition(123, for: episode)
            await reloaded.flush()
        }
        await timed("download finished → save (same show)") {
            reloaded.markDownloaded(episode, relativePath: "x/y.mp3", size: 1, sha256: "0")
            await reloaded.flush()
        }
        await timed("subscription change → save index") {
            reloaded.markFullRefresh()
            await reloaded.flush()
        }

        func bytes(_ url: URL) -> Int64 {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        let indexSize = try fm.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0
        print("  on disk: library.json \(indexSize / 1_000) KB, shows/ \(bytes(dir.appendingPathComponent("shows")) / 1_000_000) MB, notes/ \(bytes(dir.appendingPathComponent("notes")) / 1_000_000) MB")
    }
}
