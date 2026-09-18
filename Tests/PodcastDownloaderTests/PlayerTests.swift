import XCTest
@testable import PodcastDownloader

@MainActor
final class PlayerTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        try Self.makeWAV(seconds: 30, to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private var episode: Episode {
        Episode(id: "ep", title: "Tone", summary: "", publishedAt: nil, enclosureURL: file,
                enclosureLength: nil, mimeType: "audio/wav", duration: nil)
    }
    private var podcast: Podcast {
        Podcast(title: "Test", author: "", feedURL: URL(string: "https://example.com/feed")!)
    }

    func testLoadsDurationPlaysAndSkips() async throws {
        let player = makePlayer()
        player.play(episode, from: podcast, file: file)

        try await waitUntil { player.duration > 0 && player.isPlaying }
        XCTAssertEqual(player.duration, 30, accuracy: 0.1)

        try await waitUntil { player.currentTime > 0.5 }   // time advances while playing

        player.skipForward()
        XCTAssertEqual(player.currentTime, 10 + 1, accuracy: 1.5)

        player.skipBackward()
        player.skipBackward()
        XCTAssertEqual(player.currentTime, 0, "skipping back past the start clamps to 0")

        player.seek(to: 500)
        XCTAssertEqual(player.currentTime, 30, "seeking past the end clamps to duration")

        player.pause()
        XCTAssertFalse(player.isPlaying)
    }

    func testResumesFromStartPositionAndReportsPosition() async throws {
        let player = makePlayer()
        var reported: Double?
        player.onPositionUpdate = { _, seconds in reported = seconds }

        player.play(episode, from: podcast, file: file, startAt: 12)
        try await waitUntil { player.isPlaying }
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertGreaterThanOrEqual(player.currentTime, 12)
        XCTAssertLessThan(player.currentTime, 14)

        player.pause()
        let value = try XCTUnwrap(reported)
        XCTAssertGreaterThanOrEqual(value, 12)
    }

    func testRateChangeKeepsPlaying() async throws {
        let player = makePlayer()
        var reportedRate: Float?
        player.onRateChange = { reportedRate = $0 }
        player.play(episode, from: podcast, file: file)
        try await waitUntil { player.isPlaying && player.currentTime > 0.2 }
        player.rate = 2.0
        XCTAssertEqual(reportedRate, 2.0, "the owner is told so the speed can be remembered")

        // At 2× the player should cover 2 s of audio in clearly under 2 s of
        // wall-clock time; poll rather than sleep a fixed amount.
        let start = player.currentTime
        let began = Date()
        try await waitUntil(timeout: 4) { player.currentTime - start >= 2 }
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.7, "2 s of audio at 2× takes about 1 s")
        player.stop()
        XCTAssertFalse(player.hasItem)
    }

    func testFinishedEpisodeSavesZeroAndReplaysFromTheStart() async throws {
        let short = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).wav")
        try Self.makeWAV(seconds: 1, to: short)
        defer { try? FileManager.default.removeItem(at: short) }

        let player = makePlayer()
        var reported: [Double] = []
        var finished = false
        player.onPositionUpdate = { _, seconds in reported.append(seconds) }
        player.onFinished = { _ in finished = true }

        player.play(episode, from: podcast, file: short)
        try await waitUntil { finished }
        XCTAssertFalse(player.isPlaying)

        // Anything persisted after the end — e.g. on quit, or when another
        // episode is started — must be 0, not the full duration.
        player.flushPosition()
        XCTAssertEqual(reported.last, 0)

        player.resume()
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.currentTime, 0.9, "resuming a finished episode starts over")
        player.stop()
    }

    func testSwitchingEpisodesMidLoadDoesNotLeakTheFirstLoad() async throws {
        let short = FileManager.default.temporaryDirectory.appendingPathComponent("five-\(UUID().uuidString).wav")
        try Self.makeWAV(seconds: 5, to: short)
        defer { try? FileManager.default.removeItem(at: short) }
        let other = Episode(id: "ep2", title: "Five", summary: "", publishedAt: nil, enclosureURL: short,
                            enclosureLength: nil, mimeType: "audio/wav", duration: nil)

        let player = makePlayer()
        player.play(episode, from: podcast, file: file, startAt: 12)   // 30 s file, resume at 12
        player.play(other, from: podcast, file: short)                  // before the first load finishes
        try await waitUntil { player.isPlaying }
        try await Task.sleep(for: .seconds(0.3))

        XCTAssertEqual(player.episode?.id, "ep2")
        XCTAssertEqual(player.duration, 5, accuracy: 0.1, "duration is the second file's, not the first's")
        XCTAssertLessThan(player.currentTime, 2, "the first episode's seek to 12 s must not land on the second")
        player.stop()
    }

    func testUnplayableFileReportsAnErrorInsteadOfPlaying() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID().uuidString).mp3")
        try Data("<html><body>hotlinking not allowed</body></html>".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let player = makePlayer()
        player.play(episode, from: podcast, file: bogus)
        try await waitUntil { player.error != nil }

        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasItem, "the episode stays loaded so the message has context")
        player.togglePlayPause()
        XCTAssertFalse(player.isPlaying, "play is refused while the item is broken")
        player.stop()
        XCTAssertNil(player.error)
    }

    // MARK: Helpers

    /// Silent, and not wired to the Mac's Now Playing / media keys.
    private func makePlayer() -> Player {
        let player = Player(controlsNowPlaying: false)
        player.volume = 0
        return player
    }

    private func waitUntil(timeout: Double = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Writes a mono 16-bit 8 kHz WAV containing a quiet 440 Hz tone.
    private static func makeWAV(seconds: Int, to url: URL) throws {
        let sampleRate = 8000
        let frames = sampleRate * seconds
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) / Double(sampleRate) * 2 * .pi * 440) * 2000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
        try data.write(to: url)
    }
}
