import Foundation

/// The normalized 0–1 ratio every Plan renders as.
///
/// Quota plans: `used / limit` per `LimitWindow`. Spend plans: `spent / budget`.
/// The value is always clamped to `0...1`.
struct Progress: Codable, Hashable, Sendable, Comparable {
    /// The normalized value, clamped to `0...1`.
    let value: Double

    init(used: Double, limit: Double) {
        guard limit > 0 else {
            value = 0
            return
        }
        value = min(max(used / limit, 0), 1)
    }

    init(value: Double) {
        self.value = min(max(value, 0), 1)
    }

    static func < (lhs: Progress, rhs: Progress) -> Bool {
        lhs.value < rhs.value
    }
}
