import Foundation

/// Limits how many tasks run a section at once. Used to keep "Refresh All"
/// and artwork loading from opening one connection per show simultaneously,
/// which costs tens of MB of network buffers at peak.
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = self.limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available = min(limit, available + 1)
        }
    }

    /// Runs `body` once a slot is free, releasing it afterwards.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }
}
