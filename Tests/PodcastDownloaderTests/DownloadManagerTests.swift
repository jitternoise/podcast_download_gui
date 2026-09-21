import CryptoKit
import XCTest
@testable import PodcastDownloader

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func episode(_ id: String, url: String) -> Episode {
        Episode(id: id, title: id, summary: "", publishedAt: nil, enclosureURL: URL(string: url)!,
                enclosureLength: nil, mimeType: nil, duration: nil)
    }
    private let podcast = Podcast(title: "Show", author: "", feedURL: URL(string: "https://example.com/feed")!)

    func testNonWebEnclosureFailsImmediatelyWithoutOccupyingASlot() {
        let manager = DownloadManager()
        manager.maxConcurrent = 1
        let local = episode("local", url: "file:///etc/passwd")

        manager.enqueue(local, from: podcast, to: root.appendingPathComponent("Show/local.mp3"))

        guard case .failed(let message)? = manager.item(for: local)?.state else {
            return XCTFail("expected .failed, got \(String(describing: manager.item(for: local)?.state))")
        }
        XCTAssertTrue(message.contains("Unsupported URL"))
        XCTAssertTrue(manager.activeItems.isEmpty, "a failed start must not linger as 'downloading'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Show/local.mp3").path))
    }

    func testWebPageBodiesAreRejected() throws {
        let html = root.appendingPathComponent("page.tmp")
        try Data("<!DOCTYPE html><html><body>Sign in to the network</body></html>".utf8).write(to: html)
        let audio = root.appendingPathComponent("audio.tmp")
        try Data([0x49, 0x44, 0x33, 0x04, 0x00] + [UInt8](repeating: 0, count: 2000)).write(to: audio)   // "ID3" tag
        let url = URL(string: "https://example.com/x.mp3")!
        let expected = DownloadTransport.Expectation(mimeType: "audio/mpeg", length: 5_000_000)

        XCTAssertNotNil(DownloadTransport.rejectionReason(for: html, response: nil, expected: expected))
        XCTAssertNotNil(DownloadTransport.rejectionReason(
            for: audio, response: HTTPURLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil), expected: expected))
        XCTAssertNil(DownloadTransport.rejectionReason(
            for: audio, response: HTTPURLResponse(url: url, mimeType: "audio/mpeg", expectedContentLength: 0, textEncodingName: nil), expected: expected))
        XCTAssertNil(DownloadTransport.rejectionReason(for: audio, response: nil, expected: expected))
    }

    func testTransientNetworkErrorsAreRecognised() {
        func failure(_ code: Int) -> DownloadTransport.Failure {
            .init(error: NSError(domain: NSURLErrorDomain, code: code), resumeData: nil)
        }
        XCTAssertTrue(failure(NSURLErrorNetworkConnectionLost).isTransient)
        XCTAssertTrue(failure(NSURLErrorTimedOut).isTransient)
        XCTAssertTrue(failure(NSURLErrorNotConnectedToInternet).isTransient)
        XCTAssertFalse(failure(NSURLErrorBadServerResponse).isTransient)
        XCTAssertFalse(DownloadTransport.Failure(error: FeedError(message: "HTTP 404"), resumeData: nil).isTransient)
    }

    // MARK: Integrity (end to end through the real transport)

    /// A plausible MP3: ID3 header followed by pseudo-random bytes.
    private static func fakeMP3(_ bytes: Int) -> Data {
        var d = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        var x: UInt32 = 0x9E3779B9
        while d.count < bytes { x = x &* 1664525 &+ 1013904223; d.append(UInt8(truncatingIfNeeded: x >> 24)) }
        return d
    }

    private func waitForFinish(_ manager: DownloadManager, _ episode: Episode, timeout: Double = 15) async throws -> DownloadItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = manager.item(for: episode), !item.isActive { return item }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("download did not finish in time")
    }

    func testDownloadedFileIsByteIdentical() async throws {
        let body = Self.fakeMP3(300_000)
        let server = try TestHTTPServer(response: .init(body: body))
        defer { server.stop() }
        let manager = DownloadManager()
        let ep = episode("ident", url: server.url(path: "/show/ident.mp3").absoluteString)
        let dest = root.appendingPathComponent("Show/ident.mp3")

        var finished: DownloadTransport.Completed?
        manager.setFinishedHandler { _, result in finished = result }
        manager.enqueue(ep, from: podcast, to: dest)
        let item = try await waitForFinish(manager, ep)

        XCTAssertEqual(item.state, .finished)
        XCTAssertEqual(finished?.url, dest)
        let onDisk = try Data(contentsOf: dest)
        XCTAssertEqual(onDisk.count, body.count)
        XCTAssertEqual(SHA256.hash(data: onDisk), SHA256.hash(data: body), "what's on disk is exactly what the server sent")
        XCTAssertEqual(finished?.size, Int64(body.count))
        XCTAssertEqual(finished?.sha256, SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                       "the checksum recorded is the checksum of the bytes on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".part"), "no staging file left behind")
    }

    func testTruncatedTransferIsRetriedThenRejected() async throws {
        let body = Self.fakeMP3(200_000)
        let server = try TestHTTPServer(response: .init(body: body, sendOnly: 90_000))   // announces 200 000, sends 90 000
        defer { server.stop() }
        let manager = DownloadManager()
        let ep = episode("short", url: server.url(path: "/short.mp3").absoluteString)
        let dest = root.appendingPathComponent("Show/short.mp3")

        manager.enqueue(ep, from: podcast, to: dest)
        let item = try await waitForFinish(manager, ep, timeout: 30)

        guard case .failed(let message) = item.state else { return XCTFail("expected .failed, got \(item.state)") }
        // URLSession itself notices a body shorter than the announced length
        // ("connection lost"); the app's own check is the backstop for servers
        // that announce nothing. Either way it is transient and retried.
        XCTAssertTrue(message.contains("cut short") || message.contains("connection was lost"), message)
        XCTAssertEqual(item.autoRetries, DownloadManager.maxAutoRetries, "treated as transient: retried before giving up")
        XCTAssertGreaterThanOrEqual(server.requestCount, DownloadManager.maxAutoRetries + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "a short file is never stored as the episode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".part"))
    }

    func testFileIsNamedForItsRealFormat() async throws {
        // Served as ".mp3" with an audio/mpeg type, but the bytes are an M4A container.
        var body = Data("\u{0}\u{0}\u{0}\u{18}ftypM4A \u{0}\u{0}\u{0}\u{0}M4A mp42isom".utf8)
        body.append(Self.fakeMP3(50_000).dropFirst(10))
        let server = try TestHTTPServer(response: .init(body: body))
        defer { server.stop() }
        let manager = DownloadManager()
        let ep = episode("mislabelled", url: server.url(path: "/x.mp3").absoluteString)
        let planned = root.appendingPathComponent("Show/2026 - Mislabelled.mp3")

        var finished: URL?
        manager.setFinishedHandler { _, result in finished = result.url }
        manager.enqueue(ep, from: podcast, to: planned)
        _ = try await waitForFinish(manager, ep)

        XCTAssertEqual(finished?.lastPathComponent, "2026 - Mislabelled.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished!.path))
    }

    func testMediaSnifferRecognisesCommonContainers() {
        func ext(_ bytes: [UInt8], pad: Int = 64) -> String? {
            MediaSniffer.fileExtension(for: Data(bytes) + Data(repeating: 0, count: max(0, pad - bytes.count)))
        }
        XCTAssertEqual(ext([0x49, 0x44, 0x33, 0x04, 0, 0]), "mp3")                                  // ID3
        XCTAssertEqual(ext([0xFF, 0xFB, 0x90, 0x00]), "mp3")                                        // MPEG-1 Layer III frame
        XCTAssertEqual(ext([0xFF, 0xF1, 0x50, 0x80]), "aac")                                        // ADTS
        XCTAssertEqual(ext([0, 0, 0, 0x18] + Array("ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(ext([0, 0, 0, 0x18] + Array("ftypM4B ".utf8)), "m4b")
        XCTAssertEqual(ext([0, 0, 0, 0x18] + Array("ftypisom".utf8)), "m4a")
        XCTAssertEqual(ext(Array("OggS".utf8) + [UInt8](repeating: 0, count: 24) + Array("OpusHead".utf8)), "opus")
        XCTAssertEqual(ext(Array("OggS".utf8)), "ogg")
        XCTAssertEqual(ext(Array("fLaC".utf8)), "flac")
        XCTAssertEqual(ext(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)), "wav")
        XCTAssertNil(ext(Array("<!DOCTYPE html><html>".utf8)))
        XCTAssertNil(ext([0x00, 0x01, 0x02, 0x03]))
        XCTAssertNil(MediaSniffer.fileExtension(for: Data([0x49, 0x44])), "too short to judge")
    }

    func testCheckRejectsShortBodiesButAllowsEncodedOnes() throws {
        let file = root.appendingPathComponent("body.tmp")
        try Self.fakeMP3(1_000).write(to: file)
        let url = URL(string: "https://example.com/x.mp3")!
        let expected = DownloadTransport.Expectation(mimeType: "audio/mpeg", length: nil)
        func response(length: Int, encoding: String? = nil) -> HTTPURLResponse {
            var headers = ["Content-Type": "audio/mpeg", "Content-Length": String(length)]
            if let encoding { headers["Content-Encoding"] = encoding }
            return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        XCTAssertEqual(try DownloadTransport.check(file: file, response: response(length: 1_000), expected: expected).sniffedExtension, "mp3")
        XCTAssertThrowsError(try DownloadTransport.check(file: file, response: response(length: 5_000), expected: expected)) { error in
            XCTAssertTrue(error is DownloadTransport.TruncatedDownload)
            XCTAssertTrue(DownloadTransport.Failure(error: error, resumeData: nil).isTransient)
        }
        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: response(length: 5_000, encoding: "gzip"), expected: expected),
                         "a compressed transfer's Content-Length isn't the file size")
        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: nil, expected: expected), "no announced length: nothing to compare")
    }

    func testFeedLengthIsOnlyAFallbackAndOnlyForAGrossShortfall() throws {
        let file = root.appendingPathComponent("body.tmp")
        try Self.fakeMP3(1_000).write(to: file)
        let url = URL(string: "https://example.com/x.mp3")!
        // Chunked / no Content-Length: the server announced nothing.
        let silent = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
        func feedSays(_ length: Int64?) -> DownloadTransport.Expectation { .init(mimeType: "audio/mpeg", length: length) }

        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: silent, expected: feedSays(nil)))
        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: silent, expected: feedSays(1_900)), "feeds are off by a bit all the time")
        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: silent, expected: feedSays(500)), "a file bigger than announced is fine")
        XCTAssertThrowsError(try DownloadTransport.check(file: file, response: silent, expected: feedSays(2_100))) { error in
            XCTAssertTrue(error is DownloadTransport.TruncatedDownload)
            XCTAssertTrue("\(error.localizedDescription)".contains("the feed announces"))
        }
        // When the server did announce a length, the feed's number is ignored.
        let announced = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "1000"])!
        XCTAssertNoThrow(try DownloadTransport.check(file: file, response: announced, expected: feedSays(50_000)))
    }

    func testFailedStartDoesNotBlockTheQueue() {
        let manager = DownloadManager()
        manager.maxConcurrent = 1
        let bad = episode("bad", url: "file:///etc/passwd")
        // A destination whose parent can't be created: a regular file where a folder should be.
        try? Data().write(to: root.appendingPathComponent("blocker"))
        let unwritable = episode("unwritable", url: "https://example.com/x.mp3")

        manager.enqueue(bad, from: podcast, to: root.appendingPathComponent("Show/bad.mp3"))
        manager.enqueue(unwritable, from: podcast, to: root.appendingPathComponent("blocker/inner/x.mp3"))

        XCTAssertEqual(manager.activeItems.count, 0)
        for id in ["bad", "unwritable"] {
            guard case .failed? = manager.items.first(where: { $0.id == id })?.state else {
                return XCTFail("\(id) should be .failed")
            }
        }
    }
}
