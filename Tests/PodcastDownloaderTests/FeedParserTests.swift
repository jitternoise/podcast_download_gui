import XCTest
@testable import PodcastDownloader

final class FeedParserTests: XCTestCase {
    private let sampleFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
    <channel>
      <title>Test Show</title>
      <itunes:author>Jane Host</itunes:author>
      <description><![CDATA[<p>A <b>great</b> show &amp; more.</p>]]></description>
      <itunes:image href="https://example.com/art.jpg"/>
      <image><url>https://example.com/old.jpg</url><title>Test Show</title></image>
      <item>
        <title>Episode 2: Slashes / Colons: Stars*</title>
        <guid isPermaLink="false">ep-2</guid>
        <pubDate>Mon, 08 Sep 2026 10:00:00 +0000</pubDate>
        <itunes:duration>3725</itunes:duration>
        <description><![CDATA[Second episode<br>with a line break]]></description>
        <enclosure url="https://example.com/ep2.mp3" length="12345" type="audio/mpeg"/>
      </item>
      <item>
        <title>Episode 1</title>
        <guid>ep-1</guid>
        <pubDate>Tue, 01 Sep 2026 10:00:00 GMT</pubDate>
        <itunes:duration>01:02:03</itunes:duration>
        <enclosure url="https://example.com/ep1?id=1" type="audio/x-m4a"/>
      </item>
      <item>
        <title>No enclosure, should be skipped</title>
        <guid>ep-0</guid>
      </item>
    </channel>
    </rss>
    """

    func testParsesChannelAndEpisodes() throws {
        let feed = try FeedParser().parse(Data(sampleFeed.utf8))
        XCTAssertEqual(feed.title, "Test Show")
        XCTAssertEqual(feed.author, "Jane Host")
        XCTAssertEqual(feed.artworkURL?.absoluteString, "https://example.com/art.jpg")
        XCTAssertEqual(feed.episodes.count, 2)

        let ep2 = feed.episodes[0]
        XCTAssertEqual(ep2.id, "ep-2")
        XCTAssertEqual(ep2.enclosureLength, 12345)
        XCTAssertEqual(ep2.mimeType, "audio/mpeg")
        XCTAssertEqual(ep2.summary, "Second episode\nwith a line break")
        XCTAssertNotNil(ep2.publishedAt)
        XCTAssertEqual(ep2.fileName, "2026-09-08 - Episode 2 Slashes Colons Stars.mp3")

        let ep1 = feed.episodes[1]
        XCTAssertEqual(ep1.fileExtension, "m4a", "extension should come from MIME type when URL has none")
        XCTAssertEqual(ep1.fileName, "2026-09-01 - Episode 1.m4a")
    }

    func testRejectsNonFeed() {
        XCTAssertThrowsError(try FeedParser().parse(Data("<html><body>hi</body></html>".utf8)))
    }

    func testSanitize() {
        XCTAssertEqual(FileNaming.sanitize("  ...hidden/name?  ", fallback: "x"), "hidden name")
        XCTAssertEqual(FileNaming.sanitize("///", fallback: "fallback"), "fallback")
        XCTAssertLessThanOrEqual(FileNaming.sanitize(String(repeating: "a", count: 500), fallback: "x").count, 120)
    }

    func testDateFormats() {
        XCTAssertNotNil(RSSDate.parse("Mon, 08 Sep 2026 10:00:00 +0000"))
        XCTAssertNotNil(RSSDate.parse("Mon, 08 Sep 2026 10:00:00 PDT"))
        XCTAssertNotNil(RSSDate.parse("2026-09-08T10:00:00Z"))
        XCTAssertNil(RSSDate.parse("not a date"))
    }

    func testHTMLStripper() {
        XCTAssertEqual(HTMLStripper.strip("<p>Hello &amp; <a href='x'>world</a></p>"), "Hello & world")
    }
}
