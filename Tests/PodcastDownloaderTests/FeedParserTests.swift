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
        <link>https://example.com/episodes/2</link>
        <pubDate>Mon, 08 Sep 2026 10:00:00 +0000</pubDate>
        <itunes:duration>3725</itunes:duration>
        <description><![CDATA[Second episode<br>with a line break]]></description>
        <content:encoded><![CDATA[<p>Second episode<br>with a line break</p><p>Links: <a href="https://example.com/2">notes</a></p>]]></content:encoded>
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

    func testKeepsLinkAndTheFullestNotesAsPublished() throws {
        let feed = try FeedParser().parse(Data(sampleFeed.utf8))
        let ep2 = feed.episodes[0], ep1 = feed.episodes[1]
        XCTAssertEqual(ep2.link?.absoluteString, "https://example.com/episodes/2")
        XCTAssertNil(ep1.link)
        XCTAssertEqual(feed.notesHTML["ep-2"], "<p>Second episode<br>with a line break</p><p>Links: <a href=\"https://example.com/2\">notes</a></p>",
                       "content:encoded is the fullest version")
        XCTAssertNil(feed.notesHTML["ep-1"], "nothing beyond the plain summary: nothing to keep")
        XCTAssertEqual(ep2.summary, "Second episode\nwith a line break", "the list text is unchanged")
    }

    func testRejectsNonFeed() {
        XCTAssertThrowsError(try FeedParser().parse(Data("<html><body>hi</body></html>".utf8)))
    }

    func testRejectsAtomAndWebPagesWithClearMessages() {
        let atom = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Blog</title><entry><title>x</title></entry></feed>"
        XCTAssertThrowsError(try FeedParser().parse(Data(atom.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Atom"), error.localizedDescription)
        }
        let xhtml = "<html><head><title>My Show</title></head><body><p>Welcome</p></body></html>"
        XCTAssertThrowsError(try FeedParser().parse(Data(xhtml.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("web page"), error.localizedDescription)
        }
        XCTAssertThrowsError(try FeedParser().parse(Data("<rss><channel><title>Broken".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("valid XML"), error.localizedDescription)
        }
    }

    func testToleratesHTMLEntitiesOutsideCDATA() throws {
        let feed = """
        <rss version="2.0"><channel><title>T</title>
          <item><title>It&rsquo;s here&nbsp;now &amp; &unknownthing; too</title><guid>a</guid>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let parsed = try FeedParser().parse(Data(feed.utf8))
        XCTAssertEqual(parsed.episodes.count, 1)
        XCTAssertEqual(parsed.episodes[0].title, "It\u{2019}s here\u{A0}now & &unknownthing; too")
    }

    func testDuplicateGuidsGetUniqueIDs() throws {
        let feed = """
        <rss version="2.0"><channel><title>T</title>
          <item><title>1</title><guid>g</guid><enclosure url="https://example.com/1.mp3"/></item>
          <item><title>2</title><guid>g</guid><enclosure url="https://example.com/2.mp3"/></item>
          <item><title>3</title><guid>g</guid><enclosure url="https://example.com/2.mp3"/></item>
        </channel></rss>
        """
        let parsed = try FeedParser().parse(Data(feed.utf8))
        let ids = parsed.episodes.map(\.id)
        XCTAssertEqual(ids, ["g", "g|https://example.com/2.mp3", "g|https://example.com/2.mp3#3"])
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testHTMLSnifferFindsAdvertisedFeed() {
        let page = """
        <!DOCTYPE html><html><head>
        <link href="/feed.xml" type="application/rss+xml" rel="alternate" title="RSS">
        </head><body></body></html>
        """
        XCTAssertTrue(HTMLSniffer.looksLikeHTML(Data(page.utf8)))
        XCTAssertFalse(HTMLSniffer.looksLikeHTML(Data("<?xml version=\"1.0\"?><rss/>".utf8)))
        let found = HTMLSniffer.discoverFeed(in: Data(page.utf8), relativeTo: URL(string: "https://show.example/about")!)
        XCTAssertEqual(found?.absoluteString, "https://show.example/feed.xml")
        XCTAssertNil(HTMLSniffer.discoverFeed(in: Data("<html><body>none</body></html>".utf8), relativeTo: URL(string: "https://x.example")!))
    }

    func testSanitize() {
        XCTAssertEqual(FileNaming.sanitize("  ...hidden/name?  ", fallback: "x"), "hidden name")
        XCTAssertEqual(FileNaming.sanitize("///", fallback: "fallback"), "fallback")
        XCTAssertLessThanOrEqual(FileNaming.sanitize(String(repeating: "a", count: 500), fallback: "x").count, 120)
    }

    func testSanitizeCleansTheFallbackToo() {
        // The fallback is the feed's <guid>; it must not be able to smuggle a path.
        XCTAssertEqual(FileNaming.sanitize("???", fallback: "../../../Users/me/Documents/x"), "Users me Documents x")
        XCTAssertEqual(FileNaming.sanitize("", fallback: ".."), "Untitled")
        XCTAssertEqual(FileNaming.sanitize("", fallback: ""), "Untitled")

        let hostile = Episode(id: "../../.zshrc", title: "***", summary: "", publishedAt: nil,
                              enclosureURL: URL(string: "https://example.com/a.sh")!,
                              enclosureLength: nil, mimeType: nil, duration: nil)
        XCTAssertFalse(hostile.fileName.contains("/"))
        XCTAssertFalse(hostile.fileName.hasPrefix("."))
        XCTAssertEqual(hostile.fileName, "zshrc.mp3", ".sh is not a media extension, so the MIME/default type wins")
    }

    func testUniqueURLAppendsCounterBeforeExtension() {
        let base = URL(fileURLWithPath: "/tmp/Show/2026-01-01 - Ep.mp3")
        let taken: Set<String> = ["/tmp/Show/2026-01-01 - Ep.mp3", "/tmp/Show/2026-01-01 - Ep (2).mp3"]
        XCTAssertEqual(FileNaming.uniqueURL(base) { taken.contains($0.path) }.path, "/tmp/Show/2026-01-01 - Ep (3).mp3")
        XCTAssertEqual(FileNaming.uniqueURL(base) { _ in false }, base)
    }

    func testOnlyWebEnclosuresAreAccepted() throws {
        let feed = """
        <rss version="2.0"><channel><title>T</title>
          <item><title>Local</title><guid>a</guid><enclosure url="file:///etc/passwd" type="audio/mpeg"/></item>
          <item><title>Data</title><guid>b</guid><enclosure url="data:audio/mpeg;base64,AAAA" type="audio/mpeg"/></item>
          <item><title>Padded</title><guid>c</guid><enclosure url="  https://example.com/c.mp3 " type="audio/mpeg"/></item>
          <item><title>Plain http</title><guid>d</guid><enclosure url="http://example.com/d.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let parsed = try FeedParser().parse(Data(feed.utf8))
        XCTAssertEqual(parsed.episodes.map(\.id), ["c", "d"])
        XCTAssertEqual(parsed.episodes[0].enclosureURL.absoluteString, "https://example.com/c.mp3")
    }

    func testDateFormats() {
        XCTAssertNotNil(RSSDate.parse("Mon, 08 Sep 2026 10:00:00 +0000"))
        XCTAssertNotNil(RSSDate.parse("Mon, 08 Sep 2026 10:00:00 PDT"))
        XCTAssertNotNil(RSSDate.parse("2026-09-08T10:00:00Z"))
        XCTAssertNil(RSSDate.parse("not a date"))
    }

    func testHTMLStripper() {
        XCTAssertEqual(HTMLStripper.strip("<p>Hello &amp; <a href='x'>world</a></p>"), "Hello & world")
        XCTAssertEqual(HTMLStripper.strip("It&#8217;s &#x2019;fine&#x2019; &rsquo; &nbsp;ok &bogus;"), "It’s ’fine’ ’  ok &bogus;")
    }

    func testTwoDigitYearsAndZonelessDatesParse() throws {
        let twoDigit = try XCTUnwrap(RSSDate.parse("Mon, 08 Sep 26 10:00:00 +0000"))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.year, from: twoDigit), 2026)
        XCTAssertNotNil(RSSDate.parse("Mon, 08 Sep 2026 10:00:00"), "no zone → assumed UTC")
        XCTAssertNotNil(RSSDate.parse("Tue, 8 Sep 2026 10:00:00 +0000"), "single-digit day")
    }

    func testDurationAndExtensionNormalisation() {
        func ep(url: String, mime: String? = nil, duration: String? = nil) -> Episode {
            Episode(id: "x", title: "t", summary: "", publishedAt: nil, enclosureURL: URL(string: url)!,
                    enclosureLength: nil, mimeType: mime, duration: duration)
        }
        XCTAssertEqual(ep(url: "https://x/a.php", mime: "audio/mpeg").fileExtension, "mp3", "a script isn't a file type")
        XCTAssertEqual(ep(url: "https://x/a.html", mime: "audio/x-m4a").fileExtension, "m4a")
        XCTAssertEqual(ep(url: "https://x/a.M4B").fileExtension, "m4b")
        XCTAssertEqual(ep(url: "https://x/a", duration: "3725").durationSeconds, 3725)
        XCTAssertEqual(ep(url: "https://x/a", duration: "01:02:03").durationSeconds, 3723)
        XCTAssertEqual(ep(url: "https://x/a", duration: "45:10").durationSeconds, 2710)
        XCTAssertNil(ep(url: "https://x/a", duration: "n/a").durationSeconds)
        XCTAssertEqual(TimeText.duration(3723), "1h 2m")
        XCTAssertEqual(TimeText.duration(2710), "45 min")
        XCTAssertEqual(TimeText.duration(3600), "1h")
    }

    func testFileNamesUseTheUTCDate() {
        // 23:30 UTC on Sep 8 is already Sep 9 east of UTC+1; the file name must not depend on the Mac's zone.
        let date = ISO8601DateFormatter().date(from: "2026-09-08T23:30:00Z")!
        let ep = Episode(id: "x", title: "Late", summary: "", publishedAt: date, enclosureURL: URL(string: "https://x/a.mp3")!,
                         enclosureLength: nil, mimeType: nil, duration: nil)
        XCTAssertEqual(ep.fileName, "2026-09-08 - Late.mp3")
    }

    func testFileNameLengthIsClampedInUTF16Units() {
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 40)   // 40 characters, 440 UTF-16 units
        let name = FileNaming.sanitize(emoji, fallback: "x")
        XCTAssertLessThanOrEqual(name.utf16.count, FileNaming.maxUTF16Length)
        XCTAssertFalse(name.isEmpty)
    }

    func testSpeedLabels() {
        XCTAssertEqual(TimeText.rate(1.0), "1×")
        XCTAssertEqual(TimeText.rate(2.0), "2×")
        XCTAssertEqual(TimeText.rate(1.25), "1.25×")
        XCTAssertEqual(TimeText.rate(1.75), "1.75×")
        XCTAssertEqual(TimeText.rate(0.75), "0.75×")
        XCTAssertEqual(TimeText.rate(1.5), "1.5×")
    }

    func testApplePodcastsLinksAreRecognised() {
        XCTAssertEqual(PodcastSearchService.applePodcastsID(in: URL(string: "https://podcasts.apple.com/us/podcast/planet-money/id290783428")!), "290783428")
        XCTAssertEqual(PodcastSearchService.applePodcastsID(in: URL(string: "https://podcasts.apple.com/gb/podcast/id123?i=456")!), "123")
        XCTAssertNil(PodcastSearchService.applePodcastsID(in: URL(string: "https://example.com/id123")!))
        XCTAssertEqual(PodcastDownloaderApp.webURL(from: URL(string: "feed://example.com/rss")!).absoluteString, "https://example.com/rss")
        XCTAssertEqual(PodcastDownloaderApp.webURL(from: URL(string: "feed:https://example.com/rss")!).absoluteString, "https://example.com/rss")
        XCTAssertEqual(PodcastDownloaderApp.webURL(from: URL(string: "https://example.com/rss")!).absoluteString, "https://example.com/rss")
    }

    func testOPMLRoundTrip() throws {
        let podcasts = [
            Podcast(title: "A & B", author: "", feedURL: URL(string: "https://example.com/a?x=1&y=2")!),
            Podcast(title: "Quotes \"here\"", author: "", feedURL: URL(string: "https://example.com/b")!),
        ]
        let data = OPML.export(podcasts)
        let entries = try OPML.parse(data)
        XCTAssertEqual(entries.map(\.title), ["A & B", "Quotes \"here\""])
        XCTAssertEqual(entries.map(\.feedURL), podcasts.map(\.feedURL))

        let foreign = """
        <opml version="1.0"><body><outline text="Folder">
          <outline type="rss" text="Show" xmlUrl="https://example.com/show.rss"/>
          <outline type="rss" text="Dup" xmlUrl="https://example.com/show.rss"/>
          <outline type="rss" text="Local" xmlUrl="file:///etc/passwd"/>
        </outline></body></opml>
        """
        XCTAssertEqual(try OPML.parse(Data(foreign.utf8)).map(\.feedURL.absoluteString), ["https://example.com/show.rss"])
        XCTAssertThrowsError(try OPML.parse(Data("<html/>".utf8)))
    }
}
