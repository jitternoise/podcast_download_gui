import AppKit
import SwiftUI

/// Chooses between the full app UI and the mini player, and hands the
/// NSWindow to `WindowMode` so it can resize and restyle it.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.windowMode.isMini {
                MiniPlayerView()
                    .frame(width: WindowMode.miniContentSize.width, height: WindowMode.miniContentSize.height)
            } else {
                ContentView()
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
        .background(WindowAccessor { window in
            model.windowMode.window = window
        })
        // RootView lives for the whole app session (it is not rebuilt when
        // switching to/from the mini player), so this fires exactly once.
        .task {
            await model.refreshOnLaunchIfDue()
        }
    }
}

/// Zero-size helper view that reports the hosting NSWindow once it exists.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}
