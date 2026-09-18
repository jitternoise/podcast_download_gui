import AppKit
import Observation

/// Switches between the full main window and a compact mini-player window.
///
/// The main window is never torn down: collapsing fades it out and shows a
/// separate small window; expanding fades the main window back in exactly as
/// it was and hides the small one. The mini window is created once and kept,
/// so its position and loaded artwork survive toggling. All view state
/// (selection, scroll position) therefore survives the switch.
@MainActor
@Observable
final class WindowMode {
    static let miniContentSize = NSSize(width: 460, height: 124)
    static let fadeDuration: TimeInterval = 0.22

    private(set) var isMini = false
    var keepOnTop = false {
        didSet { applyLevel() }
    }

    /// The app's main window, supplied by the root view once it exists.
    weak var mainWindow: NSWindow?
    /// Builds the view hosted in the mini window. Set by the root view.
    var makeMiniContent: (() -> NSView)?

    private(set) var miniWindow: NSWindow?
    private var miniCloseObserver: NSObjectProtocol?
    private var fullScreenObserver: NSObjectProtocol?
    /// Bumped on every collapse/expand so a fade that finishes after the mode
    /// has already flipped again doesn't apply its stale end state.
    private var transition = 0
    /// Where the user last left the mini window; nil = next to the main window.
    private var miniOrigin: NSPoint?

    func toggle() {
        isMini ? expand() : collapse()
    }

    func collapse() {
        guard !isMini, let main = mainWindow else { return }
        // A full-screen window can't just be ordered out (it owns a Space);
        // leave full screen first and collapse once that has finished.
        if main.styleMask.contains(.fullScreen) {
            fullScreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: main, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let o = self.fullScreenObserver { NotificationCenter.default.removeObserver(o) }
                    self.fullScreenObserver = nil
                    self.collapse()
                }
            }
            main.toggleFullScreen(nil)
            return
        }
        guard let mini = miniWindow ?? makeMiniWindow() else { return }
        isMini = true

        // Sit where the user left it, else at the main window's top-left corner.
        let size = mini.frame.size
        let origin = miniOrigin ?? NSPoint(x: main.frame.minX, y: main.frame.maxY - size.height)
        mini.setFrameOrigin(constrained(origin, size: size, near: main))

        // Closing the mini window with its red button brings the main window back.
        // This must happen synchronously, inside the close: the main window is
        // ordered out, so if the mini window finished closing first the app
        // would have no visible windows and would terminate (see AppDelegate).
        miniCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: mini, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand(closingMini: false) }
        }

        transition += 1
        let generation = transition
        mini.alphaValue = 0
        mini.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            main.animator().alphaValue = 0
            mini.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // If expand() ran during the fade it owns the main window now.
                guard self?.transition == generation else { return }
                main.orderOut(nil)
                main.alphaValue = 1
            }
        })
    }

    func expand() {
        expand(closingMini: true)
    }

    private func expand(closingMini: Bool) {
        guard isMini, let main = mainWindow else { return }
        isMini = false

        if let miniCloseObserver { NotificationCenter.default.removeObserver(miniCloseObserver) }
        miniCloseObserver = nil
        let mini = miniWindow
        if let mini { miniOrigin = mini.frame.origin }
        if !closingMini {
            // The window is closing on its own (red button); it stays allocated
            // (isReleasedWhenClosed = false) and is reused next time.
        }

        transition += 1
        let generation = transition
        // Start from wherever the collapse fade left the main window: it may be
        // fully hidden, or still mid-fade if the user toggled quickly.
        if !main.isVisible { main.alphaValue = 0 }
        main.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            main.animator().alphaValue = 1
            mini?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Hide (not close) so the window and its content are reused.
                guard closingMini, self?.transition == generation else { return }
                mini?.orderOut(nil)
                mini?.alphaValue = 1
            }
        })
    }

    private func makeMiniWindow() -> NSWindow? {
        guard let content = makeMiniContent?() else { return nil }
        let mini = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.miniContentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        mini.title = "Podcast Downloader"
        mini.titleVisibility = .hidden
        mini.titlebarAppearsTransparent = true
        mini.isMovableByWindowBackground = true
        mini.isReleasedWhenClosed = false
        mini.contentView = content
        mini.setContentSize(Self.miniContentSize)
        miniWindow = mini
        applyLevel()
        return mini
    }

    /// Pinned: float above everything, follow the user across Spaces and show
    /// over other apps' full-screen windows — what "keep on top" means on a Mac.
    private func applyLevel() {
        guard let mini = miniWindow else { return }
        mini.level = keepOnTop ? .floating : .normal
        mini.collectionBehavior = keepOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace]
    }

    /// Keeps the mini window on a screen (the remembered spot may belong to a
    /// display that has since been unplugged).
    private func constrained(_ origin: NSPoint, size: NSSize, near main: NSWindow) -> NSPoint {
        let frame = NSRect(origin: origin, size: size)
        let screens = NSScreen.screens
        if screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return origin }
        let target = (main.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: target.minX + 40, y: target.maxY - size.height - 40)
    }
}
