import Foundation
import Observation

/// The observable settings model. Wraps a persisted `SettingsState` and exposes mutation methods;
/// SwiftUI views observe reads and update when a setting changes.
@MainActor
@Observable
final class SettingsModel {
    /// App-wide shared instance (the app has exactly one settings object).
    static let shared = SettingsModel(store: SettingsStore(bundleIdentifier: AppInfo.bundleIdentifier))

    private let store: SettingsStore
    private(set) var value: SettingsState

    init(store: SettingsStore) {
        self.store = store
        self.value = store.load() ?? .default
    }

    // MARK: - Read accessors

    var budgets: [String: Budget] { value.budgets }
    var menuBarFocus: MenuBarFocus { value.menuBarFocus }
    var thresholds: Thresholds { value.thresholds }
    var pollInterval: Duration { .seconds(value.pollIntervalSeconds) }
    var displayCurrency: DisplayCurrency { value.displayCurrency }

    /// Display order of providers, with any not-yet-recorded providers appended in canonical
    /// order (so a newly-added provider shows up instead of being silently dropped).
    var providerOrder: [Provider] {
        let stored = value.providerOrder
        let missing = Provider.allCases.filter { !stored.contains($0) }
        return stored + missing
    }

    func budget(for planID: String) -> Budget? { value.budgets[planID] }

    /// Apply the user's Budget (if any) to a spend Plan so it can render a Progress (ADR-0002).
    func applyingBudget(to plan: Plan) -> Plan {
        guard plan.kind == .spend else { return plan }
        var copy = plan
        copy.budget = value.budgets[plan.id]
        return copy
    }

    // MARK: - Mutations (each persists the change)

    /// Set or clear a monthly Budget for a spend plan. A nil/zero amount clears it (no urgency).
    func setBudget(_ amount: Decimal?, currencyCode: String, for planID: String) {
        commit {
            if let amount, amount > 0 {
                $0.budgets[planID] = Budget(amount: amount, currencyCode: currencyCode)
            } else {
                $0.budgets.removeValue(forKey: planID)
            }
        }
    }

    func setMenuBarFocus(_ focus: MenuBarFocus) {
        commit { $0.menuBarFocus = focus }
    }

    func setDisplayCurrency(_ currency: DisplayCurrency) {
        commit { $0.displayCurrency = currency }
    }

    func setThresholds(_ thresholds: Thresholds) {
        commit { $0.thresholds = thresholds }
    }

    func setPollIntervalSeconds(_ seconds: Double) {
        commit { $0.pollIntervalSeconds = seconds }
    }

    /// Persist a new relative order for a subset of providers (the visible ones). Any provider
    /// not in `ordered` keeps its prior relative order and trails the ordered subset.
    func reorderProviders(_ ordered: [Provider]) {
        let rest = providerOrder.filter { !ordered.contains($0) }
        commit { $0.providerOrder = ordered + rest }
    }

    // MARK: - Persistence

    private func commit(_ transform: (inout SettingsState) -> Void) {
        var next = value
        transform(&next)
        value = next
        try? store.save(next)
    }
}
