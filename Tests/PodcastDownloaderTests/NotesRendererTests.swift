import XCTest
@testable import PodcastDownloader

@MainActor
final class NotesRendererTests: XCTestCase {
    func testKeepsTextLinksAndEmphasisDropsEverythingElse() {
        let html = """
        <p>Guest: <b>Jane</b> on <i>design</i>.</p>
        <script>alert(1)</script><img src="https://example.com/t.gif">
        <p>Links: <a href="https://example.com/show">the show</a> and <a href="javascript:alert(1)">bad</a>.</p>
        """
        XCTAssertTrue(NotesRenderer.hasMarkup(html))
        XCTAssertFalse(NotesRenderer.hasMarkup("Plain notes\nwith lines"))

        let out = NotesRenderer.render(html)
        let text = String(out.characters)
        XCTAssertTrue(text.contains("Guest: Jane on design."), text)
        XCTAssertTrue(text.contains("Links: the show and bad."), text)
        XCTAssertFalse(text.contains("alert"), "scripts are dropped, not shown")
        XCTAssertFalse(text.hasSuffix("\n"))

        let links = out.runs.compactMap { $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] }
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/show"], "only web links survive")
        let strong = out.runs.filter { $0[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] == .stronglyEmphasized }
        XCTAssertEqual(strong.map { String(out[$0.range].characters) }, ["Jane"])
    }
}
