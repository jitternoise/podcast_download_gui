import AppKit
import SwiftUI

@main
struct PodcastDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Podcast Downloader", id: "main") {
            RootView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh All Subscriptions") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: .option)
                    .disabled(!model.player.hasItem)
                Button("Back \(Int(Player.skipInterval)) Seconds") { model.player.skipBackward() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!model.player.hasItem)
                Button("Forward \(Int(Player.skipInterval)) Seconds") { model.player.skipForward() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!model.player.hasItem)
                Divider()
                Button("Stop") { model.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.player.hasItem)
                Divider()
                Button(model.windowMode.isMini ? "Switch to Full Window" : "Switch to Mini Player") {
                    model.windowMode.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Handed over by the root view so quitting can flush state and warn about downloads.
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run) there is no bundle to
        // tell macOS this is a regular GUI app, so say so explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window quits, unless something is downloading or playing —
    /// then the app stays in the Dock and the window comes back from there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.hasWorkInProgress ?? false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // Save the resume point first; it is only written every 30 s otherwise.
        model.player.flushPosition()

        let active = model.downloads.activeItems.count
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active == 1
            ? "A download is still in progress."
            : "\(active) downloads are still in progress."
        alert.informativeText = "If you quit now they will be cancelled and will have to start over."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.player.flushPosition()
    }
}
