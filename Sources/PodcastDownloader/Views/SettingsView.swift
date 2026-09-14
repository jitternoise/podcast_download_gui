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
                            Button("Reveal in Finder") { model.openMasterFolder() }
                        }
                    }
                }
                Text("Each podcast gets its own sub-folder named after the show, e.g. “\(settings.masterDirectory.lastPathComponent)/My Podcast/2024-01-15 - Episode.mp3”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Downloads") {
                Stepper("Simultaneous downloads: \(settings.maxConcurrentDownloads)",
                        value: $settings.maxConcurrentDownloads, in: 1...10)
                    .onChange(of: settings.maxConcurrentDownloads) { _, _ in model.applySettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder where podcast sub-folders will be created."
        panel.directoryURL = model.settings.masterDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.masterDirectory = url
        }
    }
}
