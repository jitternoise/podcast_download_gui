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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run) there is no bundle to
        // tell macOS this is a regular GUI app, so say so explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
