import Foundation

/// A distinct tracked consumption entity under a Provider.
///
/// A Provider can expose more than one (OpenCode has `Go` and `Zen`); every other
/// provider has exactly one. Each Plan carries its own latest usage.
struct Plan: Identifiable, Codable, Hashable, Sendable {
    /// A stable identifier, unique within its Provider (e.g. "opencode.go").
    let id: String
    let provider: Provider
    let name: String
    let kind: Kind

    /// Quota plans: one or more `LimitWindow`s.
    var limitWindows: [LimitWindow] = []

    /// Spend plans: remaining prepaid `Balance`, and the amount `spent` this period.
    var balance: Balance?
    var spent: Decimal?
    /// Spend plans: the currency `spent` is denominated in (e.g. "EUR"). Used to label the
    /// figure when the Plan has no `Balance`/`Budget` to carry a currency code.
    var currencyCode: String? = nil

    /// Spend plans: an optional user-set `Budget` turns the Plan into a Progress percentage.
    var budget: Budget?

    /// A short note rendered under the card (e.g. Gemini's "billing-export estimate" caveat).
    var note: String? = nil

    /// When this Plan's data was last fetched, for freshness/staleness display. Optional so
    /// existing plans (and persisted snapshots) decode unchanged.
    var fetchedAt: Date? = nil

    /// The normalized 0–1 `Progress` this Plan renders as.
    ///
    /// Quota: the most-urgent `LimitWindow` (closest to its limit).
    /// Spend: `spent / budget`; `nil` (no urgency) when no `Budget` is set.
    var progress: Progress? {
        switch kind {
        case .quota:
            return limitWindows.map(\.progress).max()
        case .spend:
            guard let spent, let budget, budget.amount > 0 else { return nil }
            let ratio = NSDecimalNumber(decimal: spent).doubleValue
                / NSDecimalNumber(decimal: budget.amount).doubleValue
            return Progress(value: ratio)
        }
    }
}
