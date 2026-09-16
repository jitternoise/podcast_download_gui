import Foundation

/// Decides whether an automatic "refresh all" is allowed yet.
enum RefreshPolicy {
    /// Preset intervals offered in Settings, in minutes. `never` disables automatic refresh entirely.
    static let never = -1
    static let options: [(minutes: Int, label: String)] = [
        (0, "Every launch"),
        (15, "15 minutes"),
        (30, "30 minutes"),
        (60, "1 hour"),
        (180, "3 hours"),
        (360, "6 hours"),
        (720, "12 hours"),
        (1440, "24 hours"),
        (never, "Never (manual only)"),
    ]

    static func label(forMinutes minutes: Int) -> String {
        options.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes"
    }

    /// - Parameters:
    ///   - lastFullRefresh: when all subscriptions were last refreshed, if ever.
    ///   - minimumMinutes: the user's minimum gap; `never` means don't auto-refresh.
    static func isDue(lastFullRefresh: Date?, minimumMinutes: Int, now: Date = Date()) -> Bool {
        if minimumMinutes == never { return false }
        guard let last = lastFullRefresh else { return true }
        return now.timeIntervalSince(last) >= Double(minimumMinutes) * 60
    }
}
