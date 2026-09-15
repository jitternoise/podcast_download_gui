import AppKit
import Observation

/// Switches the main window between the full UI and a compact mini player.
/// The SwiftUI root view swaps its content based on `isMini`; this class
/// handles the NSWindow side (frame, chrome, floating level).
@MainActor
@Observable
final class WindowMode {
    static let miniContentSize = NSSize(width: 460, height: 124)

    private(set) var isMini = false
    var keepOnTop = false {
        didSet { applyLevel() }
    }

    /// Set by the root view once the NSWindow exists.
    weak var window: NSWindow? {
        didSet { if window !== oldValue { applyChrome() } }
    }

    private var savedFrame: NSRect?

    func toggle() {
        isMini ? expand() : collapse()
    }

    func collapse() {
        guard !isMini, let window else { return }
        savedFrame = window.frame
        isMini = true
        applyChrome()

        // SwiftUI installs the new (fixed) content size on the next pass;
        // then we place the small window where the big one's top-left corner was.
        let full = window.frame
        DispatchQueue.main.async {
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.miniContentSize)).size
            let target = NSRect(x: full.minX, y: full.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(target, display: true, animate: true)
        }
    }

    func expand() {
        guard isMini, let window else { return }
        isMini = false
        applyChrome()

        let restore = savedFrame
        DispatchQueue.main.async {
            if let restore {
                window.setFrame(restore, display: true, animate: true)
            }
        }
    }

    // MARK: Window chrome

    private func applyChrome() {
        guard let window else { return }
        if isMini {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        } else {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
        applyLevel()
    }

    private func applyLevel() {
        window?.level = (isMini && keepOnTop) ? .floating : .normal
    }
}
