import Foundation
import Observation

/// The single source of truth for all Plan usage, backed by a last-good `Snapshot`.
@MainActor
@Observable
final class UsageStore {
    private(set) var plans: [Plan] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var errors: [Provider: String] = [:]
    private(set) var authStates: [Provider: ProviderAuthState] = [:]
    private(set) var globalError: String?

    private let providers: [any UsageProvider]
    private let cache: SnapshotCache
    private let backoff = BackoffPolicy.standard
    private let settings: SettingsModel
    private let notifier: NearLimitNotifier?
    private let rates: ExchangeRateStore

    /// Per-provider refresh timing: when it may next be polled, and its recent failure count.
    private struct ProviderState {
        var nextAllowedAt: Date = .distantPast
        var consecutiveFailures: Int = 0
    }
    private var states: [Provider: ProviderState] = [:]

    init(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        settings: SettingsModel,
        notifier: NearLimitNotifier? = nil,
        rates: ExchangeRateStore
    ) {
        self.providers = providers
        self.cache = cache
        self.settings = settings
        self.notifier = notifier
        self.rates = rates
    }

    /// The plans the widget has fetched, with Budgets applied (so spend plans can render a
    /// Progress). A signed-out provider has no plans here (sign-out clears them), so this is the
    /// full set of plans to show.
    var visiblePlans: [Plan] {
        plans.map { settings.applyingBudget(to: $0) }
    }

    /// The menu-bar's single `Progress` under the current focus. Plans without a computable
    /// Progress (e.g. spend with no Budget) are ignored.
    var menuBarProgress: Progress? {
        MenuBarSelection.progress(plans: visiblePlans, focus: settings.menuBarFocus)
    }

    /// Total EUR spent across spend plans (non-EUR converted via the cached rate). nil when there's
    /// no spend data, or when no exchange rate is available to convert non-EUR amounts.
    var totalSpentEUR: Decimal? {
        guard let eurPerUSD = rates.eurPerUSD else { return nil }
        var total = Decimal(0)
        var any = false
        for plan in visiblePlans where plan.kind == .spend {
            guard let spent = plan.spent,
                  let eur = CurrencyMath.toEUR(
                    amount: spent, code: plan.currencyCode ?? "USD", eurPerUSD: eurPerUSD
                  )
            else { continue }
            total += eur
            any = true
        }
        return any ? total : nil
    }

    /// Average percentage (0–1) across quota plans, for the menu-bar's second line.
    var averageQuotaProgress: Progress? {
        MenuBarSelection.averageQuotaProgress(plans: visiblePlans)
    }

    /// Restore the last-good `Snapshot` so the widget renders instantly on launch.
    func loadSnapshot() {
        guard let snapshot = cache.load() else { return }
        plans = snapshot.plans
        lastUpdatedAt = snapshot.fetchedAt
    }

    /// Refresh every `UsageProvider`, then persist the last-good `Snapshot` and run the
    /// near-limit notifier.
    ///
    /// Each provider is gated by its `minimumPollInterval` and an exponential backoff on failure.
    /// A signed-out provider throws `notSignedIn` (before any network call) and is skipped; a
    /// failed provider never clears existing usage — it falls back to the last-good value and
    /// records a per-provider error for the UI.
    ///
    /// `force` bypasses the gate (used after sign-in/sign-out and the manual refresh button) so a
    /// newly-connected method shows immediately instead of waiting out the poll interval.
    func refresh(force: Bool = false) async {
        await rates.refresh()
        let now = Date()

        for provider in providers {
            let id = provider.provider
            var state = states[id] ?? ProviderState()
            if force { state.nextAllowedAt = .distantPast }
            guard now >= state.nextAllowedAt else { continue }

            do {
                let usage = try await provider.fetchUsage()
                upsert(usage)
                state.consecutiveFailures = 0
                state.nextAllowedAt = now.addingTimeInterval(provider.minimumPollInterval)
                errors[id] = nil
            } catch {
                state.consecutiveFailures += 1
                state.nextAllowedAt = now.addingTimeInterval(
                    backoff.delaySeconds(afterConsecutiveFailures: state.consecutiveFailures)
                )
                errors[id] = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
            states[id] = state
        }

        // Refresh auth state so the UI can flip between "sign in" and plan cards.
        for provider in providers {
            authStates[provider.provider] = await provider.authState()
        }

        lastUpdatedAt = now
        do {
            try cache.save(Snapshot(plans: plans, fetchedAt: now))
            globalError = nil
        } catch {
            globalError = "Snapshot save failed: \(error.localizedDescription)"
        }

        notifier?.check(plans: visiblePlans, now: now)
    }

    /// Merge this provider's freshly-fetched plans into the store by plan `id`.
    ///
    /// Plans in the batch replace same-id plans; a provider's plans *not* in this batch (e.g. a
    /// Claude billing plan when only the subscription fetch succeeded) keep their last-good value.
    private func upsert(_ usage: ProviderUsage) {
        let incoming = Dictionary(usage.plans.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let old = Dictionary(
            plans.filter { $0.provider == usage.provider }.map { ($0.id, $0) },
            uniquingKeysWith: { $1 }
        )
        var merged = plans.filter { $0.provider != usage.provider }
        for id in Set(old.keys).union(incoming.keys).sorted() {
            if let plan = incoming[id] ?? old[id] {
                merged.append(plan)
            }
        }
        plans = merged
    }

    /// Sign one auth method out: clear its credential, drop the plans it owns, and persist the
    /// change so a stale card doesn't linger across launches. Other methods of the same provider
    /// stay connected.
    func signOut(_ method: AuthMethod) async {
        await method.signOut()
        if method.ownedPlanIDs.isEmpty {
            plans.removeAll { $0.provider == method.provider }
        } else {
            plans.removeAll { method.ownedPlanIDs.contains($0.id) }
        }
        errors[method.provider] = nil
        try? cache.save(Snapshot(plans: plans, fetchedAt: lastUpdatedAt ?? Date()))
    }
}
