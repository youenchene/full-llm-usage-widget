import Foundation

/// A single `(used, limit, resetsAt)` measurement inside a quota Plan.
///
/// A quota Plan has one or more windows (e.g. a 5-hour and a weekly window).
struct LimitWindow: Identifiable, Codable, Hashable, Sendable {
    /// A short label distinguishing the window (e.g. "5h", "weekly", "monthly").
    let label: String
    let used: Double
    let limit: Double
    let resetsAt: Date

    var id: String { label }

    /// Progress toward this window's limit, normalized 0–1.
    var progress: Progress { Progress(used: used, limit: limit) }
}
