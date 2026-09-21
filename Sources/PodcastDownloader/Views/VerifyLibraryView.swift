import SwiftUI

/// File ▸ Verify Library…: choose the depth of the check, watch it run, act
/// on what it found.
struct VerifyLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var checksums = false

    private var report: LibraryVerification? { model.verification }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify Library").font(.title2.bold())
            if let report {
                if report.isRunning { progress(report) } else { results(report) }
            } else {
                options
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Before

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checks that every episode the app downloaded is still in \(model.settings.masterDirectory.path) and still the same size as when it was fetched.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also compare checksums", isOn: $checksums)
            Text("Reads every file in full to catch changes that kept the size. Takes a few minutes per 100 GB.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.library.downloaded.count) downloads on record.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.dismissVerification() }.keyboardShortcut(.cancelAction)
                Button("Verify") { model.verifyLibrary(checksums: checksums) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.library.downloaded.isEmpty)
            }
        }
    }

    // MARK: During

    private func progress(_ report: LibraryVerification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(report.checked), total: Double(max(report.total, 1)))
            Text("\(report.checked) of \(report.total) files checked" + (report.checksums ? " (comparing checksums)" : ""))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop") { model.cancelVerification() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: After

    private func results(_ report: LibraryVerification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary(report)).fixedSize(horizontal: false, vertical: true)
            if !report.problems.isEmpty {
                List(report.problems) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.path).lineLimit(1).truncationMode(.middle)
                        Text(problem.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
            HStack {
                Spacer()
                if !report.problems.isEmpty {
                    Button("Download \(report.problems.count) Again") {
                        model.redownloadVerificationProblems()
                        model.dismissVerification()
                    }
                }
                Button("Done") { model.dismissVerification() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ report: LibraryVerification) -> String {
        var lines: [String] = []
        if report.cancelled {
            lines.append("Stopped after \(report.checked) of \(report.total) files.")
        } else {
            lines.append("\(report.checked) file\(report.checked == 1 ? "" : "s") checked.")
        }
        if report.problems.isEmpty, !report.cancelled {
            lines.append("Everything is where it should be and the size it should be" + (report.checksums ? ", byte for byte." : "."))
        }
        if !report.missing.isEmpty { lines.append("\(report.missing.count) missing.") }
        if !report.damaged.isEmpty { lines.append("\(report.damaged.count) changed or cut short.") }
        if report.inCloud > 0 { lines.append("\(report.inCloud) in iCloud Drive but not on this Mac (not checked).") }
        if report.baselined > 0 {
            lines.append("\(report.baselined) had no \(report.checksums ? "checksum" : "size") on record from an earlier version; recorded now so the next pass can compare.")
        }
        return lines.joined(separator: " ")
    }
}
