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
        let player = Player()
        player.play(episode, from: podcast, file: file)

        try await waitUntil { player.duration > 0 && player.isPlaying }
        XCTAssertEqual(player.duration, 30, accuracy: 0.1)

        try await Task.sleep(for: .seconds(1.2))
        XCTAssertGreaterThan(player.currentTime, 0.5, "time should advance while playing")

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
        let player = Player()
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
        let player = Player()
        player.play(episode, from: podcast, file: file)
        try await waitUntil { player.isPlaying }
        player.rate = 2.0
        try await Task.sleep(for: .seconds(1.0))
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 1.5, "2x should cover >1.5s of audio in ~1s")
        player.stop()
        XCTAssertFalse(player.hasItem)
    }

    // MARK: Helpers

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
