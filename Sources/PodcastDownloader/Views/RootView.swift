import AppKit
import SwiftUI

/// Hosts the full UI and hands the NSWindow to `WindowMode`, which shows a
/// separate mini-player window on demand without disturbing this one.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showLoadError = false

    var body: some View {
        ContentView()
            .frame(minWidth: 900, minHeight: 560)
            .onAppear { showLoadError = model.library.loadError != nil }
            .alert("Subscriptions couldn't be loaded", isPresented: $showLoadError) {
                Button("OK") {}
            } message: {
                Text(model.library.loadError ?? "")
            }
            .background(WindowAccessor { window in
                model.windowMode.mainWindow = window
            })
            .onAppear {
                model.windowMode.makeMiniContent = {
                    NSHostingView(rootView: MiniPlayerView().environment(model))
                }
            }
            // RootView lives for the whole app session, so this fires exactly once.
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
