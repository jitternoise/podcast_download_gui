import AppKit
import XCTest
@testable import PodcastDownloader

@MainActor
final class WindowModeTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Test"
        return w
    }

    private func pump() async throws {
        // Let the DispatchQueue.main.async frame updates run.
        try await Task.sleep(for: .milliseconds(100))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testCollapseShrinksAnchoredTopLeftAndExpandRestores() async throws {
        let window = makeWindow()
        let original = window.frame
        let mode = WindowMode()
        mode.window = window

        mode.collapse()
        try await pump()

        XCTAssertTrue(mode.isMini)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.isMovableByWindowBackground)
        let miniFrame = window.frame
        XCTAssertLessThan(miniFrame.width, 500)
        XCTAssertLessThan(miniFrame.height, 200)
        XCTAssertEqual(miniFrame.minX, original.minX, accuracy: 1, "left edge stays put")
        XCTAssertEqual(miniFrame.maxY, original.maxY, accuracy: 1, "top edge stays put")
        XCTAssertEqual(window.contentRect(forFrameRect: miniFrame).size.width, WindowMode.miniContentSize.width, accuracy: 1)

        mode.expand()
        try await pump()

        XCTAssertFalse(mode.isMini)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertEqual(window.frame, original)
    }

    func testKeepOnTopOnlyFloatsWhileMini() async throws {
        let window = makeWindow()
        let mode = WindowMode()
        mode.window = window

        mode.keepOnTop = true
        XCTAssertEqual(window.level, .normal, "full window never floats")

        mode.collapse()
        try await pump()
        XCTAssertEqual(window.level, .floating)

        mode.keepOnTop = false
        XCTAssertEqual(window.level, .normal)

        mode.keepOnTop = true
        mode.expand()
        try await pump()
        XCTAssertEqual(window.level, .normal)
    }

    func testToggleIsIdempotentWithoutWindow() {
        let mode = WindowMode()
        mode.toggle()
        XCTAssertFalse(mode.isMini, "nothing to collapse without a window")
    }
}
