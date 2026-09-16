import AppKit
import Observation

/// Switches between the full main window and a compact mini-player window.
///
/// The main window is never torn down: collapsing fades it out and shows a
/// separate small window in its top-left corner; expanding fades the main
/// window back in exactly as it was and closes the small one. All view state
/// (selection, scroll position, loaded artwork) therefore survives the switch.
@MainActor
@Observable
final class WindowMode {
    static let miniContentSize = NSSize(width: 460, height: 124)
    static let fadeDuration: TimeInterval = 0.22

    private(set) var isMini = false
    var keepOnTop = false {
        didSet { miniWindow?.level = keepOnTop ? .floating : .normal }
    }

    /// The app's main window, supplied by the root view once it exists.
    weak var mainWindow: NSWindow?
    /// Builds the view hosted in the mini window. Set by the root view.
    var makeMiniContent: (() -> NSView)?

    private(set) var miniWindow: NSWindow?
    private var miniCloseObserver: NSObjectProtocol?

    func toggle() {
        isMini ? expand() : collapse()
    }

    func collapse() {
        guard !isMini, let main = mainWindow, let content = makeMiniContent?() else { return }
        isMini = true

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
        mini.level = keepOnTop ? .floating : .normal
        mini.contentView = content
        mini.setContentSize(Self.miniContentSize)

        // Sit where the main window's top-left corner is.
        let size = mini.frame.size
        mini.setFrameOrigin(NSPoint(x: main.frame.minX, y: main.frame.maxY - size.height))

        // Closing the mini window with its red button brings the main window back.
        miniCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: mini, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.expand(closingMini: false) }
        }
        miniWindow = mini

        mini.alphaValue = 0
        mini.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            main.animator().alphaValue = 0
            mini.animator().alphaValue = 1
        }, completionHandler: {
            main.orderOut(nil)
            main.alphaValue = 1
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
        miniWindow = nil

        main.alphaValue = 0
        main.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            main.animator().alphaValue = 1
            mini?.animator().alphaValue = 0
        }, completionHandler: {
            if closingMini { mini?.close() }
        })
    }
}
