import AppKit
import XCTest
@testable import PodcastDownloader

@MainActor
final class WindowModeTests: XCTestCase {
    override func setUpWithError() throws {
        // Real windows need a window server; on a headless runner skip cleanly
        // instead of crashing on a nil screen.
        try XCTSkipIf(NSScreen.main == nil, "no window server session")
    }

    private func makeMain() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        return w
    }

    private func makeMode(for main: NSWindow) -> WindowMode {
        let mode = WindowMode()
        mode.mainWindow = main
        mode.makeMiniContent = { NSView(frame: NSRect(origin: .zero, size: WindowMode.miniContentSize)) }
        return mode
    }

    /// Let the fade animations and their completion handlers run.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(WindowMode.fadeDuration + 0.2))
    }

    func testCollapseHidesMainWithoutChangingItAndShowsMiniAtTopLeft() {
        let main = makeMain()
        let original = main.frame
        let mode = makeMode(for: main)

        mode.collapse()
        settle()

        XCTAssertTrue(mode.isMini)
        let mini = try! XCTUnwrap(mode.miniWindow)
        XCTAssertTrue(mini.isVisible)
        XCTAssertFalse(main.isVisible, "main window is hidden, not closed")
        XCTAssertEqual(main.frame, original, "main window's frame is untouched")
        XCTAssertEqual(main.alphaValue, 1, "alpha restored after fade so it comes back opaque")
        XCTAssertEqual(mini.frame.minX, original.minX, accuracy: 1)
        XCTAssertEqual(mini.frame.maxY, original.maxY, accuracy: 1)
        XCTAssertEqual(mini.contentView!.frame.size.width, WindowMode.miniContentSize.width, accuracy: 1)
        XCTAssertFalse(mini.styleMask.contains(.resizable))
        XCTAssertTrue(mini.isMovableByWindowBackground)
        mode.expand(); settle()
    }

    func testExpandRestoresMainAndClosesMini() {
        let main = makeMain()
        let original = main.frame
        let mode = makeMode(for: main)
        mode.collapse(); settle()
        let mini = mode.miniWindow

        mode.expand()
        settle()

        XCTAssertFalse(mode.isMini)
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(main.alphaValue, 1)
        XCTAssertEqual(main.frame, original)
        XCTAssertEqual(mini?.isVisible, false, "mini window is hidden")
        XCTAssertTrue(mode.miniWindow === mini, "…but kept, so its position and content survive the next collapse")
    }

    func testMiniWindowRemembersWhereItWasLeft() {
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.collapse(); settle()
        let moved = NSPoint(x: 640, y: 420)
        mode.miniWindow?.setFrameOrigin(moved)
        mode.expand(); settle()

        mode.collapse(); settle()
        let origin = try! XCTUnwrap(mode.miniWindow?.frame.origin)
        XCTAssertEqual(origin.x, moved.x, accuracy: 1)
        XCTAssertEqual(origin.y, moved.y, accuracy: 1)
        mode.expand(); settle()
    }

    func testPinnedMiniWindowFollowsAcrossSpaces() {
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.collapse(); settle()
        mode.keepOnTop = true
        XCTAssertTrue(mode.miniWindow?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        XCTAssertTrue(mode.miniWindow?.collectionBehavior.contains(.fullScreenAuxiliary) == true)
        mode.keepOnTop = false
        XCTAssertFalse(mode.miniWindow?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        mode.expand(); settle()
    }

    func testClosingMiniWindowExpands() {
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.collapse(); settle()

        mode.miniWindow?.close()      // as if the user clicked its red button
        settle()

        XCTAssertFalse(mode.isMini)
        XCTAssertEqual(mode.miniWindow?.isVisible, false)
        XCTAssertTrue(main.isVisible)
    }

    func testClosingMiniWindowRestoresMainBeforeTheCloseCompletes() {
        // If the main window only came back on a later run-loop turn, the app would
        // have zero visible windows for a moment and terminate (see AppDelegate).
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.collapse(); settle()
        XCTAssertFalse(main.isVisible)

        mode.miniWindow?.close()

        XCTAssertTrue(main.isVisible, "main window is back synchronously")
        XCTAssertFalse(mode.isMini)
        settle()
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(main.alphaValue, 1)
    }

    func testRapidCollapseThenExpandLeavesMainVisible() {
        let main = makeMain()
        let mode = makeMode(for: main)

        mode.collapse()
        let mini = mode.miniWindow
        mode.expand()                 // before the collapse fade has finished
        settle()

        XCTAssertFalse(mode.isMini)
        XCTAssertTrue(main.isVisible, "stale collapse completion must not hide the main window")
        XCTAssertEqual(main.alphaValue, 1)
        XCTAssertEqual(mini?.isVisible, false)
    }

    func testRapidCollapseExpandCollapseEndsInMiniWithOneMiniWindow() {
        let main = makeMain()
        let mode = makeMode(for: main)

        mode.collapse()
        let first = mode.miniWindow
        mode.expand()
        mode.collapse()
        let second = mode.miniWindow
        settle()

        XCTAssertTrue(mode.isMini)
        XCTAssertFalse(main.isVisible)
        XCTAssertEqual(main.alphaValue, 1, "hidden main is reset to opaque for the next expand")
        XCTAssertNotNil(second)
        XCTAssertTrue(second === first, "one mini window, reused")
        XCTAssertEqual(second?.isVisible, true)
        XCTAssertEqual(second?.alphaValue, 1)
        mode.expand(); settle()
    }

    func testKeepOnTopFloatsOnlyTheMiniWindow() {
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.keepOnTop = true
        XCTAssertEqual(main.level, .normal)

        mode.collapse(); settle()
        XCTAssertEqual(mode.miniWindow?.level, .floating)
        XCTAssertEqual(main.level, .normal)

        mode.keepOnTop = false
        XCTAssertEqual(mode.miniWindow?.level, .normal)
        mode.expand(); settle()
    }

    func testToggleWithoutWindowIsANoop() {
        let mode = WindowMode()
        mode.toggle()
        XCTAssertFalse(mode.isMini)
    }
}
