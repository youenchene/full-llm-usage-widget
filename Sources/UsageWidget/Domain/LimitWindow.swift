import Foundation

/// A single `(used, limit, resetsAt)` measurement inside a quota Plan.
///
/// A quota Plan has one or more windows (e.g. a 5-hour and a weekly window).
struct LimitWindow: Identifiable, Codable, Hashable, Sendable {
    /// A short label distinguishing the window (e.g. "5h", "weekly", "monthly").
    let label: String
    let used: Double
    let limit: Double
    /// When this window rolls over. Optional — a provider may omit it (e.g. an unlimited plan).
    let resetsAt: Date?
    /// True for quotas with no cap (shown as "Unlimited" instead of a bar).
    var unlimited: Bool = false

    var id: String { label }

    /// Progress toward this window's limit, normalized 0–1. An unlimited window yields no urgency.
    var progress: Progress { unlimited ? Progress(used: 0, limit: 0) : Progress(used: used, limit: limit) }
}
