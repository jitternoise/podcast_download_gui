import AppKit
import SwiftUI

/// Hosts the full UI and hands the NSWindow to `WindowMode`, which shows a
/// separate mini-player window on demand without disturbing this one.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showLoadError = false

    var body: some View {
        ContentView()
            // Small enough for window tiling on a 13" MacBook; the player bar
            // switches to its compact layout below ~900 pt.
            .frame(minWidth: 760, minHeight: 480)
            .onAppear { showLoadError = model.library.loadError != nil }
            .alert("Subscriptions couldn't be loaded", isPresented: $showLoadError) {
                Button("OK") {}
            } message: {
                Text(model.library.loadError ?? "")
            }
            .alert("Podcast Downloader", isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(model.alertMessage ?? "")
            }
            .sheet(isPresented: Binding(
                get: { model.verification != nil || model.showVerifyOptions },
                set: { if !$0 { model.dismissVerification() } }
            )) {
                VerifyLibraryView().environment(model)
            }
            .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
                // Drop a feed link (or a page/Apple Podcasts link) anywhere.
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await model.search.open(url, library: model.library) }
                    }
                }
                return true
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
