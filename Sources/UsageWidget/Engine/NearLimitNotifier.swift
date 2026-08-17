import Foundation

/// Fires a near-limit notification when any plan crosses the threshold, once per window/reset
/// cycle. The "notified this cycle" set is persisted so a relaunch doesn't re-notify.
///
/// Not actor-isolated on purpose: it's only ever called from the `@MainActor` store, and the
/// decision logic it wraps (`NearLimitPolicy`) is pure and self-check-testable.
final class NearLimitNotifier {
    private let poster: any NotificationPosting
    private let store: NotificationCycleStore
    private var notifiedCycles: [String: String]

    init(poster: any NotificationPosting, store: NotificationCycleStore) {
        self.poster = poster
        self.store = store
        self.notifiedCycles = store.load()
    }

    func check(plans: [Plan], now: Date = Date()) {
        for plan in plans {
            guard let message = NearLimitPolicy.message(for: plan) else { continue }
            guard let cycleKey = NearLimitPolicy.cycleKey(for: plan, now: now) else { continue }
            guard notifiedCycles[plan.id] != cycleKey else { continue }

            poster.post(title: message.title, body: message.body)
            notifiedCycles[plan.id] = cycleKey
            try? store.save(notifiedCycles)
        }
    }
}
