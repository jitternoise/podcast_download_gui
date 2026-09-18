import Foundation

struct DownloadItem: Identifiable, Hashable {
    enum State: Hashable {
        case queued
        case downloading
        case finished
        case failed(String)
        case cancelled
    }

    let id: String            // Episode.key
    let episode: Episode
    let podcast: Podcast
    let destination: URL
    /// Started by auto-download rather than the user; such transfers stay off
    /// personal hotspots and Low Data Mode networks.
    var isAutomatic = false
    var state: State = .queued
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = -1
    let createdAt = Date()
    /// Partial-transfer data URLSession handed back on failure or cancel, so a
    /// retry continues where it stopped instead of starting from byte 0.
    var resumeData: Data?
    /// Automatic retries used so far for transient network errors.
    var autoRetries = 0

    var progress: Double? {
        guard bytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    var isActive: Bool {
        switch state {
        case .queued, .downloading: return true
        default: return false
        }
    }
}
