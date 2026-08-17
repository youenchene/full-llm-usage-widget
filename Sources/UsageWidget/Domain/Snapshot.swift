import Foundation

/// A cached copy of the latest usage, persisted so the widget renders instantly
/// and survives a failed refresh.
struct Snapshot: Codable, Sendable {
    let plans: [Plan]
    let fetchedAt: Date
}
