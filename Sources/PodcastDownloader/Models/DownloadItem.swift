import Foundation

struct DownloadItem: Identifiable, Hashable {
    enum State: Hashable {
        case queued
        case downloading
        case finished
        case failed(String)
        case cancelled
    }

    let id: String            // episode id
    let episode: Episode
    let podcast: Podcast
    let destination: URL
    var state: State = .queued
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = -1
    let createdAt = Date()

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
