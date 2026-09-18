import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Storage") {
                LabeledContent("Master folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(settings.masterDirectory.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320, alignment: .trailing)
                        HStack {
                            Button("Choose…") { chooseFolder() }
                                .disabled(model.moveStatus != nil)
                            Button("Reveal in Finder") { model.openMasterFolder() }
                        }
                    }
                }
                Text("All downloads live in this one folder, in a sub-folder per podcast. Choosing a different folder moves your podcast folders there; anything else in the old folder is left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let status = model.moveStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout)
                    }
                }
                if let error = model.moveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Refreshing") {
                Picker("Check for new episodes", selection: $settings.autoRefreshMinutes) {
                    ForEach(RefreshPolicy.options, id: \.minutes) { option in
                        Text(RefreshPolicy.pickerLabel(forMinutes: option.minutes)).tag(option.minutes)
                    }
                }
                Text("Automatic checks happen at launch, after the Mac wakes, when the app comes to the front, and periodically while it stays open. Refresh All (⌘R) always checks immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = model.library.lastFullRefresh {
                    LabeledContent("Last full refresh") {
                        Text(last, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Downloads") {
                Stepper("Simultaneous downloads: \(settings.maxConcurrentDownloads)",
                        value: $settings.maxConcurrentDownloads, in: 1...10)
                    .onChange(of: settings.maxConcurrentDownloads) { _, _ in model.applySettings() }
                Toggle("Delete an episode's file after it has been played to the end", isOn: $settings.deleteAfterPlayed)
                Text("Automatic downloads stay off personal hotspots and Low Data Mode networks; downloads you start yourself always go ahead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Picker("Skip buttons jump", selection: $settings.skipInterval) {
                    ForEach(AppSettings.skipIntervalOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .onChange(of: settings.skipInterval) { _, _ in model.applySettings() }
                Toggle("Continue with the next downloaded episode when one ends", isOn: $settings.continuousPlay)
                LabeledContent("Playback speed") {
                    Text("\(TimeText.rate(settings.playbackRate)) — remembered from the player bar")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Library Here"
        panel.message = "Choose the folder where podcast sub-folders will be kept. Existing downloads will be moved there."
        panel.directoryURL = model.settings.masterDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.changeMasterDirectory(to: url) }
        }
    }
}
