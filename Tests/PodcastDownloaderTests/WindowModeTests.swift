import AppKit
import XCTest
@testable import PodcastDownloader

@MainActor
final class WindowModeTests: XCTestCase {
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
        XCTAssertNil(mode.miniWindow)
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(main.alphaValue, 1)
        XCTAssertEqual(main.frame, original)
        XCTAssertEqual(mini?.isVisible, false, "mini window was closed")
    }

    func testClosingMiniWindowExpands() {
        let main = makeMain()
        let mode = makeMode(for: main)
        mode.collapse(); settle()

        mode.miniWindow?.close()      // as if the user clicked its red button
        settle()

        XCTAssertFalse(mode.isMini)
        XCTAssertNil(mode.miniWindow)
        XCTAssertTrue(main.isVisible)
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
