import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct PodcastDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned by the delegate (main actor, app lifetime) so quit/Dock-menu
    /// handling and the scenes share one instance.
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("Podcast Downloader", id: "main") {
            RootView()
                .environment(model)
                // feed:// podcast:// pcast:// links from Safari and other apps.
                .onOpenURL { url in
                    Task { await model.search.open(Self.webURL(from: url), library: model.library) }
                }
        }
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import Subscriptions (OPML)…") { importOPML() }
                Button("Export Subscriptions (OPML)…") { exportOPML() }
                    .disabled(model.library.podcasts.isEmpty)
                Divider()
                Button("Verify Library…") { model.showVerifyOptions = true }
                    .disabled(model.library.downloaded.isEmpty || model.verification != nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh All Subscriptions") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.library.podcasts.isEmpty)
                Divider()
            }
            CommandMenu("Playback") {
                // Space also works whenever a text field isn't focused (see ContentView).
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!model.player.hasItem)
                Button("Back \(Int(model.player.skipInterval)) Seconds") { model.player.skipBackward() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!model.player.hasItem)
                Button("Forward \(Int(model.player.skipInterval)) Seconds") { model.player.skipForward() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!model.player.hasItem)
                Button("Next Episode") { if let e = model.player.episode { model.playNext(after: e) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                    .disabled(!model.player.hasItem)
                Button("Previous Episode") { if let e = model.player.episode { model.playPrevious(before: e) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                    .disabled(!model.player.hasItem)
                Divider()
                Menu("Speed") {
                    ForEach(Player.rates, id: \.self) { rate in
                        Toggle(TimeText.rate(rate), isOn: Binding(
                            get: { model.player.rate == rate },
                            set: { if $0 { model.player.rate = rate } }
                        ))
                    }
                }
                Menu("Sleep Timer") {
                    Toggle("Off", isOn: sleepBinding(.off))
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Toggle("\(minutes) Minutes", isOn: sleepBinding(.minutes(minutes)))
                    }
                    Toggle("End of Episode", isOn: sleepBinding(.endOfEpisode))
                }
                Divider()
                Button("Go to Now Playing") { model.revealNowPlaying() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.player.episode?.podcastID.flatMap { model.library.podcast(withID: $0) } == nil)
                Button("Stop") { model.player.stop() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
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

    private func sleepBinding(_ timer: Player.SleepTimer) -> Binding<Bool> {
        Binding(
            get: { model.player.sleepTimer == timer },
            set: { if $0 { model.player.setSleepTimer(timer) } else if timer != .off { model.player.setSleepTimer(.off) } }
        )
    }

    /// feed://host/path and podcast://host/path mean https://host/path.
    nonisolated static func webURL(from url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), !["http", "https"].contains(scheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // "feed:https://…" wraps a full URL; "feed://example.com/rss" replaces the scheme.
        if let inner = URL(string: url.absoluteString.dropFirst(scheme.count + 1).description), inner.isWebURL {
            return inner
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an OPML file exported from another podcast app."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try OPML.parse(try Data(contentsOf: url))
            var added = 0
            for entry in entries where model.library.podcast(withID: entry.feedURL.absoluteString) == nil {
                model.library.subscribe(Podcast(title: entry.title, author: "", feedURL: entry.feedURL))
                added += 1
            }
            model.alertMessage = added == 0
                ? "No new subscriptions in that file (\(entries.count) already subscribed)."
                : "Added \(added) subscription\(added == 1 ? "" : "s"). Fetching their episodes now…"
            Task { await model.refreshAll() }
        } catch {
            model.alertMessage = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "Podcast Subscriptions.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OPML.export(model.library.podcasts).write(to: url)
        } catch {
            model.alertMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run) there is no bundle to
        // tell macOS this is a regular GUI app, so say so explicitly. The
        // packaged app must not steal focus (e.g. when opened at login).
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    /// Closing the window quits, unless something is downloading or playing —
    /// then the app stays in the Dock and the window comes back from there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.hasWorkInProgress
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save the resume point first; it is only written every 30 s otherwise.
        model.player.flushPosition()

        let active = model.downloads.activeItems.count
        let moving = model.moveStatus != nil
        guard active > 0 || moving else {
            model.library.flushNow()
            return .terminateNow
        }
        let alert = NSAlert()
        if moving {
            alert.messageText = "Your library is still being moved."
            alert.informativeText = "Quitting now can leave it split across two folders."
        } else {
            alert.messageText = active == 1
                ? "A download is still in progress."
                : "\(active) downloads are still in progress."
            alert.informativeText = "If you quit now they will be cancelled and will have to start over."
        }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.library.flushNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.player.flushPosition()
        model.library.flushNow()
    }

    /// Transport controls in the Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard model.player.hasItem else { return nil }
        let menu = NSMenu()
        let title = model.player.episode?.title ?? ""
        let now = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: model.player.isPlaying ? "Pause" : "Play", action: #selector(dockTogglePlay), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Back \(Int(model.player.skipInterval)) Seconds", action: #selector(dockSkipBack), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Forward \(Int(model.player.skipInterval)) Seconds", action: #selector(dockSkipForward), keyEquivalent: "").target = self
        return menu
    }

    @objc private func dockTogglePlay() { model.player.togglePlayPause() }
    @objc private func dockSkipBack() { model.player.skipBackward() }
    @objc private func dockSkipForward() { model.player.skipForward() }
}
