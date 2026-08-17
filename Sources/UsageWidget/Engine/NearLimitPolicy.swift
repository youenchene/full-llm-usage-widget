import Foundation

/// Pure rules for near-limit notifications: what triggers one, and how to identify the "cycle"
/// a notification is scoped to (so it fires once per window/reset cycle).
enum NearLimitPolicy {
    /// Progress at or above which a plan is considered "near limit" (90%).
    static let notificationThreshold: Double = 0.9

    /// The message to post when `plan` has crossed the threshold, or nil if it hasn't.
    static func message(for plan: Plan) -> (title: String, body: String)? {
        guard let progress = plan.progress, progress.value >= notificationThreshold else { return nil }
        let percent = Int((progress.value * 100).rounded())
        switch plan.kind {
        case .quota:
            return ("\(plan.name) near its limit", "\(plan.name) is at \(percent)% of its limit.")
        case .spend:
            return ("\(plan.name) near your budget", "\(plan.name) has used \(percent)% of its monthly budget.")
        }
    }

    /// A stable key identifying the current window/reset cycle for `plan`.
    ///
    /// Quota: the most-urgent `LimitWindow`'s reset time (falls back to its label when the reset
    /// time is unknown). Spend: the current month (a Budget is monthly). Returns nil when no
    /// meaningful cycle exists (e.g. a quota plan with no windows).
    static func cycleKey(for plan: Plan, now: Date) -> String? {
        switch plan.kind {
        case .quota:
            guard let window = plan.limitWindows.max(by: { $0.progress < $1.progress }) else { return nil }
            let reset = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            return "\(plan.id).\(window.label).\(reset)"
        case .spend:
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
            return "\(plan.id).\(components.year ?? 0).\(components.month ?? 0)"
        }
    }
}
